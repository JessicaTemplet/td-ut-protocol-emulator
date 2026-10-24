open Hardcaml
open Tt_core

(* Loopback self-test through tt_um_dual's REAL pins: everything (prescale,
   25 configuration bytes ending in the loopback mask, both programs) is
   loaded over the byte-serial pins, exactly as a host would at bring-up.
   µE1 pushes a USB DATA0 packet; µE0 sends it bit by bit through the
   transmit pipe on uio pin 0 and samples each bit back through the receive
   pipe; µE1 checks the status word and raises PASS (uio 4) and DONE
   (uio 5). Same program and configuration as gen_vectors.ml's st_*
   (duplicated, as the other pin-level tests duplicate theirs), which
   gl_test/test.py replays on the shipped Verilog.

   1. Loopback on, nothing driving pin 0: PASS, and pin 0's pad is never
      driven (uio_oe[0] stays 0 for the whole run).
   2. Loopback on, the bench toggling pin 0's pad every cycle: still PASS,
      so the pad is really out of the loop.
   3. Loopback off (mask 0), pin 0's pad held at idle J: DONE without PASS
      (the test notices nothing came back), and this time the pad IS
      driven, which is what the mask suppresses in 1. *)

let line = 0
let flag_ok = 4
let flag_done = 5
let st_wait = 4
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

let usb_cfg = [ 0b1001_1011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]
let cfg_bytes ~mask = usb_cfg @ List.init (Profile_table.loopback_index - 9) (fun _ -> 0) @ [ mask ]
let packet = [ 0x80; 0xC3; 0xFF; 0xFF ]

let program =
  let wait n = Engine.wait_edge ~pin:7 ~falling:true ~payload:n in
  Engine.
    [ pipe_ctrl_ext ~reset:true ~prev_level:true ~tx_reset:true ()
    ; emit_state ~pin:line ~level:true
    ; wait 8
    ; emit_tx ~pin:line ()
    ; wait st_wait
    ; pipe_bit ~pin:line
    ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:3
    ; pipe_ctrl_ext ~tx_crc:true ()
    ; emit_tx ~pin:line ()
    ; wait st_wait
    ; pipe_bit ~pin:line
    ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:8
    ; pipe_status
    ; release_pin ~pin:line
    ; wait_edge ~pin:7 ~falling:true ~payload:0
    ]

let protocol_prog =
  let fail = 15 in
  let n = List.length packet in
  List.mapi (fun k b -> Protocol_engine.tx_push ~last:(k = n - 1) b) packet
  @ Protocol_engine.
      [ fifo_pop_instr
      ; branch_word ~bit:15 ~branch_if_one:true ~target:7
      ; branch_word ~bit:15 ~branch_if_one:false ~target:4
      ; branch_word ~bit:0 ~branch_if_one:false ~target:fail
      ; branch_word ~bit:1 ~branch_if_one:true ~target:fail
      ; branch_word ~bit:2 ~branch_if_one:false ~target:fail
      ; branch_word ~bit:8 ~branch_if_one:true ~target:fail
      ; branch_word ~bit:9 ~branch_if_one:false ~target:fail
      ; branch_word ~bit:10 ~branch_if_one:false ~target:fail
      ; branch_word ~bit:11 ~branch_if_one:true ~target:fail
      ; emit_state ~pin:flag_ok ~level:true
      ; emit_state ~pin:flag_done ~level:true
      ; fifo_pop_instr
      ]

module Sim = Cyclesim.With_interface (I) (O)

let uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
  (cfg_sel lsl 4) lor (engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe

(* returns (checksum ok, PASS, DONE, pin 0's pad ever driven during the run) *)
let run ~mask ~pad =
  let cfg = cfg_bytes ~mask in
  let sim = Sim.create tt_um_dual in
  let inputs = Cyclesim.inputs sim and outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in
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
    settle ();
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:1;
    settle ();
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:0;
    settle ()
  in
  pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:0 ~data:0 (* prescale *);
  List.iter (fun data -> pulse ~cfg_sel:1 ~engine_sel:0 ~byte_sel:0 ~data) cfg;
  let load ~engine_sel prog =
    List.iter
      (fun w ->
        pulse ~cfg_sel:0 ~engine_sel ~byte_sel:0 ~data:(lo w);
        pulse ~cfg_sel:0 ~engine_sel ~byte_sel:1 ~data:(hi w))
      prog
  in
  load ~engine_sel:0 program;
  load ~engine_sel:1 protocol_prog;
  let xor_words p = List.fold_left (fun a w -> a lxor lo w lxor hi w) 0 p in
  let expected = List.fold_left ( lxor ) 0 cfg lxor xor_words program lxor xor_words protocol_prog in
  let checksum_ok = Bits.to_int !(outputs.uo_out) = expected in
  set ~cfg_sel:0 ~engine_sel:0 ~go:1 ~byte_sel:0 ~strobe:0;
  settle ();
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  settle ();
  let driven = ref false in
  for c = 0 to 2999 do
    inputs.uio_in := Bits.of_int ~width:8 (pad c lsl line);
    cycle ();
    if (Bits.to_int !(outputs.uio_oe) lsr line) land 1 = 1 then driven := true
  done;
  let o = Bits.to_int !(outputs.uio_out) and e = Bits.to_int !(outputs.uio_oe) in
  let flag k = (o lsr k) land 1 = 1 && (e lsr k) land 1 = 1 in
  (checksum_ok, flag flag_ok, flag flag_done, !driven)

let () =
  Printf.printf "=== Loopback self-test through tt_um_dual's REAL pins ===\n";
  let failures = ref 0 in
  let check name ok =
    Printf.printf "  %-72s %s\n" name (if ok then "ok" else "FAIL");
    if not ok then incr failures
  in
  let cs, ok, dn, driven = run ~mask:(1 lsl line) ~pad:(fun _ -> 0) in
  check "load checksum (25 config bytes incl. the loopback mask) matches at uo_out" cs;
  check "loopback on, nothing attached: PASS and DONE" (ok && dn);
  check "loopback on: pin 0's pad never driven" (not driven);
  let _, ok, dn, driven = run ~mask:(1 lsl line) ~pad:(fun c -> (c * 7 / 3) land 1) in
  check "loopback on, pad toggled by the bench: still PASS (pad not in the loop)" (ok && dn && not driven);
  let _, ok, dn, driven = run ~mask:0 ~pad:(fun _ -> 1) in
  check "loopback off, pad held at idle J: DONE without PASS" ((not ok) && dn);
  check "loopback off: pin 0's pad is driven" driven;
  if !failures = 0 then print_endline "RESULT: PASS"
  else (
    Printf.printf "RESULT: FAIL (%d)\n" !failures;
    exit 1)
