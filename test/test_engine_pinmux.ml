open Hardcaml
open Tt_core

(* Targeted tests for the real 1-of-8 pin mux added on top of ISA
   v0.3 (former open decision #1). Every other suite still only ever
   uses pin_sel=0, which never exercises the mux decode path or its
   guard, so none of them would have caught a mux bug -- this file
   is written specifically to.

   Four things need proving, each its own test:
   1. Output demux: EMIT_STATE on pin N only latches pin N's sticky
      register; the other 7 hold their prior level.
   2. Input mux: WAIT_EDGE/pin N only reacts to pin N's real edges;
      wiggling an unselected pin must not trigger it.
   3. The pin_sel_stable guard: switching which pin an instruction
      watches must not produce a spurious edge purely from the mux
      output jumping between two physical pins with different
      levels. This is the same bug class as tt_core.ml's start_edge/
      idle guard and engine.ml's WAIT payload race (project-log bugs #3/
      #4) -- introduced fresh by adding the mux, so it needs its own
      proof, not an inference from the other suites passing.
   4. Output-enable demux: `release_pin` drops a pin's pins_oe bit to
      0 without touching any other pin's oe or out state; plain
      `emit_state` drives it back to 1. This is what makes a pin
      genuinely tri-state-able once wired onto tt_um's uio (see
      tt_core.ml/test_tt_um_system.ml) -- the mechanism I2C's
      open-drain SDA/SCL needs, closing the bidirectional-pin gap the
      project log flagged under open decision #1. *)

module Sim = Cyclesim.With_interface (Engine.I) (Engine.O)

let new_sim ~prog =
  let sim = Sim.create Engine.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 0;
  inputs.prescale := Bits.of_int ~width:8 0;
  for _ = 1 to 4 do
    cycle ()
  done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  List.iteri
    (fun i w ->
      inputs.write_addr := Bits.of_int ~width:9 i;
      inputs.write_data := Bits.of_int ~width:16 w;
      inputs.write_enable := Bits.vdd;
      cycle ())
    prog;
  inputs.write_enable := Bits.gnd;
  inputs.run := Bits.vdd;
  (sim, inputs, outputs, cycle)

(* ---- Test 1: output demux -- EMIT_STATE on pin 3, then pin 5, then
   pin 3 again, must only ever touch the targeted bit. ---- *)
let test_output_demux () =
  Printf.printf "=== Output demux: EMIT_STATE only latches its own pin's register ===\n";
  let prog =
    Engine.
      [ emit_state ~pin:3 ~level:true
      ; emit_state ~pin:5 ~level:true
      ; emit_state ~pin:3 ~level:false
      ]
  in
  let _sim, _inputs, outputs, cycle = new_sim ~prog in
  let expected = [ 0b0000_1000; 0b0010_1000; 0b0010_0000 ] in
  let results =
    List.map
      (fun exp ->
        cycle ();
        let got = Bits.to_int !(outputs.pins_out) in
        Printf.printf "  pins_out=0b%08x (expected 0b%08x)\n" got exp;
        got = exp)
      expected
  in
  let passed = List.for_all (fun x -> x) results in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

(* ---- Test 2: input mux -- WAIT_EDGE on pin 3 must ignore pin 0
   wiggling and only react to pin 3's own rising edge. ---- *)
let test_input_mux_basic () =
  Printf.printf "=== Input mux: WAIT_EDGE/pin 3 ignores pin 0, reacts to pin 3 ===\n";
  let prog =
    Engine.[ wait_edge ~pin:3 ~falling:false ~payload:0; emit_state ~pin:0 ~level:true ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  (* Wiggle pin 0 (bit 0) for 5 cycles while pin 3 (bit 3) stays low --
     must NOT advance pc off 0. *)
  let stayed = ref true in
  for i = 0 to 4 do
    inputs.pins_in := Bits.of_int ~width:8 (i land 1);
    cycle ();
    if Bits.to_int !(outputs.pc) <> 0 then stayed := false
  done;
  Printf.printf "  pc held at 0 while pin 0 wiggled: %b (expected true)\n" !stayed;
  (* Now drive pin 3's bit high -- the real rising edge -- must advance. *)
  inputs.pins_in := Bits.of_int ~width:8 0b0000_1000;
  cycle ();
  let advanced = Bits.to_int !(outputs.pc) = 1 in
  Printf.printf "  pc advanced to 1 on pin 3 rising edge: %b (expected true)\n" advanced;
  let passed = !stayed && advanced in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

(* ---- Test 3: pin_sel_stable guard -- switching from a WAIT_EDGE on
   pin 0 (rising) to a WAIT_EDGE on pin 7 (falling) must not fire
   spuriously off pin 0's stale sampled level. Without the guard,
   rx_d still holds pin 0's last value (1, since that's what just
   triggered the rising-edge match) on the very first cycle pin 7 is
   selected; pin 7 reads 0 (never driven); a falling-edge check
   (~rx_pin && rx_d) would wrongly read 1 && 1 = fire immediately,
   even though pin 7 never transitioned. ---- *)
let test_pin_switch_guard () =
  Printf.printf "=== pin_sel_stable guard: no spurious edge when switching watched pin ===\n";
  let prog =
    Engine.
      [ wait_edge ~pin:0 ~falling:false ~payload:0 (* rising edge on pin 0 *)
      ; wait_edge ~pin:7 ~falling:true ~payload:0 (* falling edge on pin 7 *)
      ; emit_state ~pin:1 ~level:true
      ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.pins_in := Bits.of_int ~width:8 0;
  cycle ();
  (* pc still 0: waiting for pin 0 rising *)
  let pc0 = Bits.to_int !(outputs.pc) in
  (* Drive pin 0 high: rising edge, instruction 0 completes, pc -> 1.
     Pin 7 (bit 7) is 0 the whole time -- it must never have
     transitioned, so instruction 1 must NOT complete on its first
     cycle. *)
  inputs.pins_in := Bits.of_int ~width:8 0b0000_0001;
  cycle ();
  let pc1 = Bits.to_int !(outputs.pc) in
  (* First cycle pc=1 is live (pin_sel=7 just latched this cycle);
     guard means this cycle's edge check can't fire yet regardless of
     rx_d's stale content. Hold pin 7 low for a few more cycles to
     confirm it's genuinely stalled, not a one-cycle coincidence. *)
  let held = ref true in
  for _ = 1 to 3 do
    cycle ();
    if Bits.to_int !(outputs.pc) <> 1 then held := false
  done;
  Printf.printf "  pc=%d after pin0 rising (expected 0->1: %d), then held at 1 for 3 more cycles: %b\n"
    pc1 pc0 !held;
  (* Now genuinely toggle pin 7 high then low -- THIS must advance. *)
  inputs.pins_in := Bits.of_int ~width:8 0b1000_0000;
  cycle ();
  inputs.pins_in := Bits.of_int ~width:8 0b0000_0000;
  cycle ();
  let pc2 = Bits.to_int !(outputs.pc) in
  Printf.printf "  pc=%d after real pin7 falling edge (expected 2)\n" pc2;
  let passed = pc0 = 0 && pc1 = 1 && !held && pc2 = 2 in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

(* ---- Test 4: output-enable demux -- `release_pin` drops pin 2's oe
   to 0 without disturbing pin 3's independently-driven state (proving
   this is a real per-pin demux, same structure as out_reg's, not a
   single shared oe bit); a later plain `emit_state` on pin 2 drives
   it back to 1. ---- *)
let test_output_enable_demux () =
  Printf.printf "=== Output-enable demux: release_pin/emit_state independently control each pin's oe ===\n";
  let prog =
    Engine.
      [ emit_state ~pin:3 ~level:true (* pin 3: drive high, stays driven throughout *)
      ; emit_state ~pin:2 ~level:false (* pin 2: drive low *)
      ; release_pin ~pin:2 (* pin 2: let go -- must not affect pin 3 *)
      ; emit_state ~pin:2 ~level:true (* pin 2: drive again *)
      ]
  in
  let _sim, _inputs, outputs, cycle = new_sim ~prog in
  let bit n v = (v lsr n) land 1 in
  cycle ();
  (* after instr0: pin3 driven high *)
  let oe3_after_drive = bit 3 (Bits.to_int !(outputs.pins_oe)) in
  let out3_after_drive = bit 3 (Bits.to_int !(outputs.pins_out)) in
  cycle ();
  (* after instr1: pin2 driven low *)
  let oe2_driving = bit 2 (Bits.to_int !(outputs.pins_oe)) in
  let out2_driving = bit 2 (Bits.to_int !(outputs.pins_out)) in
  cycle ();
  (* after instr2: pin2 released -- pin3's driven state must be untouched *)
  let oe2_released = bit 2 (Bits.to_int !(outputs.pins_oe)) in
  let oe3_unaffected = bit 3 (Bits.to_int !(outputs.pins_oe)) in
  let out3_unaffected = bit 3 (Bits.to_int !(outputs.pins_out)) in
  cycle ();
  (* after instr3: pin2 driven again *)
  let oe2_redriven = bit 2 (Bits.to_int !(outputs.pins_oe)) in
  Printf.printf
    "  pin3 drive: oe=%d out=%d | pin2 drive: oe=%d out=%d | pin2 release: oe=%d (pin3 still oe=%d out=%d) | pin2 re-drive: oe=%d\n"
    oe3_after_drive out3_after_drive oe2_driving out2_driving oe2_released oe3_unaffected
    out3_unaffected oe2_redriven;
  let passed =
    oe3_after_drive = 1 && out3_after_drive = 1 && oe2_driving = 1 && out2_driving = 0
    && oe2_released = 0 && oe3_unaffected = 1 && out3_unaffected = 1 && oe2_redriven = 1
  in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let r1 = test_output_demux () in
  let r2 = test_input_mux_basic () in
  let r3 = test_pin_switch_guard () in
  let r4 = test_output_enable_demux () in
  let all_pass = r1 && r2 && r3 && r4 in
  Printf.printf "==================\nPin mux suite: %s\n" (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
