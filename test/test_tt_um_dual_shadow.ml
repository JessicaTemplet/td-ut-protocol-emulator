open Hardcaml
open Tt_core

(* Shadow through tt_um_dual's REAL pins, with nothing attached: an on-chip
   check of the comparator and of the host readout.

   Everything is loaded over the byte-serial pins: 30 configuration bytes
   (profile 0 all zero, the loopback mask on uio pin 4, the Shadow mode byte,
   both settle delays). µE1 runs in Drive and holds pin 4 high. µE0 runs in
   Shadow and claims pin 4 high, then low (wrong), then high again. Pin 4 is
   looped back, so the wire is µE1's drive and the pad is out of the loop.

   Expected: exactly two µE0 records, a mismatch (pc 4, pin 4, actual high)
   and an episode end (pc 6); nothing for µE1; µE0 drives no pad. The host
   reads them through the readout: ui_in[7] view, ui_in[5:3] byte, ui_in[1]
   status, ui_in[2] pop, all on uo_out. With the trace_readout bit clear,
   ui_in[7] does nothing and uo_out stays the pin mirror. *)

let pin = 4
let settle = 4
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

let cfg_bytes ~mode =
  List.init Profile_table.loopback_index (fun _ -> 0)
  @ [ 1 lsl pin; mode; lo settle; hi settle; lo settle; hi settle ]

let phys_prog =
  let wait n = Engine.wait_edge ~pin:7 ~falling:true ~payload:n in
  Engine.
    [ release_pin ~pin:7 (* no-op: a timed wait cannot come first *)
    ; wait 30
    ; emit_state ~pin ~level:true
    ; wait 20
    ; emit_state ~pin ~level:false (* wrong: µE1 holds it high *)
    ; wait 20
    ; emit_state ~pin ~level:true
    ; wait 20
    ; wait_edge ~pin:6 ~falling:true ~payload:0
    ]

let protocol_prog = Protocol_engine.[ emit_state ~pin ~level:true; fifo_pop_instr ]

module Sim = Cyclesim.With_interface (I) (O)

let uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
  (cfg_sel lsl 4) lor (engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe

let failures = ref 0

let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let boot ~mode =
  let sim = Sim.create tt_um_dual in
  let inputs = Cyclesim.inputs sim and outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle_ () = for _ = 1 to 3 do cycle () done in
  let set ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
    inputs.uio_in := Bits.of_int ~width:8 (uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe)
  in
  inputs.ena := Bits.vdd;
  inputs.rst_n := Bits.gnd;
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  let pulse ~cfg_sel ~engine_sel ~byte_sel ~data =
    inputs.ui_in := Bits.of_int ~width:8 data;
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:0;
    settle_ ();
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:1;
    settle_ ();
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:0;
    settle_ ()
  in
  pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:0 ~data:0 (* prescale *);
  List.iter (fun data -> pulse ~cfg_sel:1 ~engine_sel:0 ~byte_sel:0 ~data) (cfg_bytes ~mode);
  let load ~engine_sel prog =
    List.iter
      (fun w ->
        pulse ~cfg_sel:0 ~engine_sel ~byte_sel:0 ~data:(lo w);
        pulse ~cfg_sel:0 ~engine_sel ~byte_sel:1 ~data:(hi w))
      prog
  in
  load ~engine_sel:0 phys_prog;
  load ~engine_sel:1 protocol_prog;
  (* the host parks ui_in at 0 before go, so nothing reads as a request *)
  inputs.ui_in := Bits.of_int ~width:8 0;
  set ~cfg_sel:0 ~engine_sel:0 ~go:1 ~byte_sel:0 ~strobe:0;
  settle_ ();
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  settle_ ();
  (sim, inputs, outputs)

let () =
  Printf.printf "=== Shadow through tt_um_dual's REAL pins (loopback, nothing attached) ===\n";
  let mode = Profile_table.(mode_e0_shadow lor mode_trace_readout) in
  let sim, inputs, outputs = boot ~mode in
  let cycle () = Cyclesim.cycle sim in
  let pin4_driven = ref false and pin4_other = ref false in
  for c = 0 to 399 do
    (* the bench toggles every pad: looped pin 4 must not care *)
    inputs.uio_in := Bits.of_int ~width:8 (if c land 1 = 1 then 0xBF else 0x00);
    cycle ();
    if (Bits.to_int !(outputs.uio_oe) lsr pin) land 1 = 1 then pin4_driven := true;
    if Bits.to_int !(outputs.uio_oe) land lnot (1 lsl pin) <> 0 then pin4_other := true
  done;
  inputs.uio_in := Bits.of_int ~width:8 0;
  Printf.printf "    after the run: uio_out 0x%02x uio_oe 0x%02x uo_out 0x%02x\n"
    (Bits.to_int !(outputs.uio_out)) (Bits.to_int !(outputs.uio_oe)) (Bits.to_int !(outputs.uo_out));
  check "looped pin 4: pad never driven; µE0 (Shadow) drives no other pad" ((not !pin4_driven) && not !pin4_other);
  (* host readout *)
  let ask ui =
    inputs.ui_in := Bits.of_int ~width:8 ui;
    for _ = 1 to 3 do cycle () done;
    Bits.to_int !(outputs.uo_out)
  in
  let status () = ask 0x82 in
  (* as an Int64: OCaml's native int is 63 bits, one short of a record *)
  let read_record engine =
    List.fold_left
      (fun acc k ->
        Int64.logor acc
          (Int64.shift_left (Int64.of_int (ask (0x80 lor (engine lsl 6) lor (k lsl 3)))) (8 * k)))
      0L (List.init 8 Fun.id)
  in
  let pop engine =
    ignore (ask (0x84 lor (engine lsl 6)));
    ignore (ask (0x80 lor (engine lsl 6)))
  in
  let st = status () in
  Printf.printf "    status byte 0x%02x\n" st;
  check "status: µE0 holds 2 records, µE1 none" (st land 7 = 2 && (st lsr 3) land 7 = 0);
  let r1 = read_record 0 in
  pop 0;
  let r2 = read_record 0 in
  pop 0;
  let f r hi lo =
    Int64.to_int (Int64.logand (Int64.shift_right_logical r lo) (Int64.of_int ((1 lsl (hi - lo + 1)) - 1)))
  in
  Printf.printf "    record 1 %016Lx\n    record 2 %016Lx\n" r1 r2;
  check "record 1: mismatch, pc 4, mask = pin 4, actual pin 4 high"
    (f r1 63 63 = 0 && f r1 62 54 = 4 && f r1 53 46 = 1 lsl pin && (f r1 45 38 lsr pin) land 1 = 1);
  check "record 2: episode end, pc 6, later than record 1"
    (f r2 63 63 = 1 && f r2 62 54 = 6 && f r2 31 0 > f r1 31 0);
  check "after two pops: empty" (status () land 0x3F = 0);
  (* readout off: ui_in[7] must not take uo_out over *)
  let sim, inputs, outputs = boot ~mode:Profile_table.mode_e0_shadow in
  for _ = 1 to 200 do Cyclesim.cycle sim done;
  inputs.ui_in := Bits.of_int ~width:8 0x82;
  for _ = 1 to 3 do Cyclesim.cycle sim done;
  let mirror = Bits.to_int !(outputs.uio_out) in
  check "trace_readout clear: uo_out stays the pin mirror whatever ui_in says"
    (Bits.to_int !(outputs.uo_out) = mirror && (mirror lsr pin) land 1 = 1);
  Printf.printf "RESULT: %s\n" (if !failures = 0 then "PASS" else "FAIL");
  if !failures > 0 then exit 1
