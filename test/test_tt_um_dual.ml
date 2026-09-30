open Hardcaml
open Tt_core

(* End-to-end proof of tt_um_dual at the ACTUAL tt_um pin level --
   ui_in/uio_in/uo_out/uio_out/uio_oe only, no internal Dual_loader.I/
   Dual.I shortcuts. Mirrors test_tt_um_system.ml's role: if this test
   and test_dual_loader.ml/test_dual.ml ever disagree, the bug is in
   tt_um_dual's pin mapping (tt_core.ml), not in dual_loader.ml/dual.ml
   themselves.

   Two things only this level can prove:
   1. The load path routes both engines' programs correctly through
      the real pins (uio_in bit 3 = engine_sel, alongside the existing
      strobe/byte_sel/go bits) and the combined checksum matches.
   2. The per-pin output ARBITRATION policy documented in tt_core.ml's
      tt_um_dual header actually behaves as specified: a pin only one
      engine drives shows that engine's value untouched, and a pin
      BOTH engines drive shows protocol/uE1's value, not phys/uE0's --
      this is the one behavior that only exists at this wrapper level,
      since dual.ml itself keeps the two engines' output buses
      completely separate. *)

module Sim = Cyclesim.With_interface (I) (O)

let load_and_go ~(sim : Sim.t) ~phys_prog ~protocol_prog =
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in
  let set_uio ~strobe ~byte_sel ~go ~engine_sel =
    inputs.uio_in :=
      Bits.of_int ~width:8
        ((engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe)
  in
  inputs.rst_n := Bits.gnd;
  inputs.ui_in := Bits.of_int ~width:8 0;
  set_uio ~strobe:0 ~byte_sel:0 ~go:0 ~engine_sel:0;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  let pulse_byte ~engine_sel ~byte_sel ~data =
    inputs.ui_in := Bits.of_int ~width:8 data;
    set_uio ~strobe:0 ~byte_sel ~go:0 ~engine_sel;
    settle ();
    set_uio ~strobe:1 ~byte_sel ~go:0 ~engine_sel;
    settle ();
    set_uio ~strobe:0 ~byte_sel ~go:0 ~engine_sel;
    settle ()
  in
  (* First strobe always loads prescale (dual_loader.ml's protocol,
     unchanged from loader.ml) -- engine_sel is don't-care for it. *)
  pulse_byte ~engine_sel:0 ~byte_sel:0 ~data:0;
  let load_prog ~engine_sel prog =
    List.iter
      (fun w ->
        pulse_byte ~engine_sel ~byte_sel:0 ~data:(w land 0xFF);
        pulse_byte ~engine_sel ~byte_sel:1 ~data:((w lsr 8) land 0xFF))
      prog
  in
  load_prog ~engine_sel:0 phys_prog;
  load_prog ~engine_sel:1 protocol_prog;
  let checksum_of prog =
    List.fold_left (fun acc w -> acc lxor (w land 0xFF) lxor ((w lsr 8) land 0xFF)) 0 prog
  in
  let expected_checksum = checksum_of phys_prog lxor checksum_of protocol_prog in
  let checksum_on_uo_out = Bits.to_int !(outputs.uo_out) in
  let checksum_ok = checksum_on_uo_out = expected_checksum in
  let uio_idle_during_load =
    Bits.to_int !(outputs.uio_out) = 0 && Bits.to_int !(outputs.uio_oe) = 0
  in
  set_uio ~strobe:0 ~byte_sel:0 ~go:1 ~engine_sel:0;
  settle ();
  set_uio ~strobe:0 ~byte_sel:0 ~go:0 ~engine_sel:0;
  settle ();
  (checksum_ok, uio_idle_during_load)

(* mu-E0 (phys): drives pin 3 high (disjoint), then drives pin 2 LOW
   (contended -- mu-E1 will also drive pin 2), then parks forever on
   the unwritten RAM's implicit WAIT_EDGE(pin 0, falling, no timeout)
   -- pin 0 is never toggled by this test, so this is a clean halt. *)
let phys_prog =
  Engine.[ emit_state ~pin:3 ~level:true; emit_state ~pin:2 ~level:false ]

(* mu-E1 (protocol): drives pin 5 high (disjoint), then drives pin 2
   HIGH (the same contended pin, opposite value from mu-E0), then
   parks forever on the unwritten RAM's implicit FIFO_POP (opcode 0)
   -- the FIFO is never pushed to in this test (mu-E0 never executes a
   SHIFT_IO), so fifo_empty stays true and FIFO_POP stalls forever. *)
let protocol_prog =
  Protocol_engine.[ emit_state ~pin:5 ~level:true; emit_state ~pin:2 ~level:true ]

let () =
  Printf.printf "=== tt_um_dual: load routes both programs, then output arbitration on a contended pin ===\n";
  let sim = Sim.create tt_um_dual in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let checksum_ok, uio_idle_during_load = load_and_go ~sim ~phys_prog ~protocol_prog in
  Printf.printf "  combined checksum matches at uo_out during load: %b\n" checksum_ok;
  Printf.printf "  uio_out/uio_oe idle (0) throughout load: %b (expected true)\n" uio_idle_during_load;

  (* Give both engines a few cycles post-go to reach their respective
     halts (2 EMIT_STATEs each, well under this margin). *)
  for _ = 1 to 6 do cycle () done;

  let uio_out = Bits.to_int !(outputs.uio_out) in
  let uio_oe = Bits.to_int !(outputs.uio_oe) in
  let bit n v = (v lsr n) land 1 in
  Printf.printf "  uio_out=0x%02x uio_oe=0x%02x\n" uio_out uio_oe;

  let pin3_ok = bit 3 uio_oe = 1 && bit 3 uio_out = 1 in
  Printf.printf "  pin 3 (phys-only, drive high): oe=%d out=%d (expected 1,1) %s\n"
    (bit 3 uio_oe) (bit 3 uio_out) (if pin3_ok then "ok" else "BUG");

  let pin5_ok = bit 5 uio_oe = 1 && bit 5 uio_out = 1 in
  Printf.printf "  pin 5 (protocol-only, drive high): oe=%d out=%d (expected 1,1) %s\n"
    (bit 5 uio_oe) (bit 5 uio_out) (if pin5_ok then "ok" else "BUG");

  (* The contended pin: phys wants it low, protocol wants it high --
     the documented policy says protocol/uE1 wins. *)
  let pin2_ok = bit 2 uio_oe = 1 && bit 2 uio_out = 1 in
  Printf.printf
    "  pin 2 (CONTENDED: phys drives low, protocol drives high): oe=%d out=%d (expected 1,1 -- protocol wins)\n    %s\n"
    (bit 2 uio_oe) (bit 2 uio_out) (if pin2_ok then "ok" else "BUG");

  let untouched_ok =
    List.for_all (fun i -> bit i uio_oe = 0) [ 0; 1; 4; 6; 7 ]
  in
  Printf.printf "  untouched pins (0,1,4,6,7) stay released (oe=0): %b (expected true)\n" untouched_ok;

  let passed =
    checksum_ok && uio_idle_during_load && pin3_ok && pin5_ok && pin2_ok && untouched_ok
  in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
