open Hardcaml
open Tt_core

(* Standalone proof of protocol_engine.ml (µE1) in isolation, no
   shadow_fifo.ml or engine.ml involved -- same "test every increment"
   discipline as engine.ml before it was wired into system.ml. FIFO
   inputs (fifo_pop_data/fifo_empty) are driven directly here, the
   same shortcut test_engine.ml/test_engine_pinmux.ml take with
   pins_in instead of going through loader.ml.

   Four things need proving:
   1. FIFO_POP stalls (pc held) while fifo_empty=1, pops rx_word and
      advances exactly the cycle fifo_empty drops -- mirrors
      test_engine_pinmux.ml's WAIT_EDGE-stall proof, same contract,
      different condition source.
   2. BRANCH_COND_WORD branches on the correct bit of the last popped
      word, not a live pin -- proven by branching on a word whose
      relevant bit is 1 while pins_in is held at all-0 throughout (if
      it were accidentally testing a pin instead, this would never
      branch).
   3. BRANCH_PIN branches on a real external pin, not FIFO content --
      the mirror-image proof of (2): a word with the relevant bit at
      0 sits in rx_word throughout, only pins_in ever goes high.
   4. EMIT_STATE (plus release_pin) work identically to engine.ml's,
      reusing the exact same per-pin sticky pins_out/pins_oe demux. *)

module Sim = Cyclesim.With_interface (Protocol_engine.I) (Protocol_engine.O)

let new_sim ~prog =
  let sim = Sim.create Protocol_engine.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 0;
  inputs.fifo_pop_data := Bits.of_int ~width:16 0;
  inputs.fifo_empty := Bits.vdd;
  for _ = 1 to 4 do cycle () done;
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

let test_fifo_pop_stalls_and_pops () =
  Printf.printf "=== FIFO_POP: stalls while empty, pops rx_word and advances once data arrives ===\n";
  let prog = Protocol_engine.[ fifo_pop_instr; emit_state ~pin:0 ~level:true ] in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  let held = ref true in
  for _ = 1 to 3 do
    cycle ();
    if Bits.to_int !(outputs.pc) <> 0 then held := false
  done;
  Printf.printf "  pc held at 0 while fifo_empty=1 for 3 cycles: %b (expected true)\n" !held;
  inputs.fifo_pop_data := Bits.of_int ~width:16 0xBEEF;
  inputs.fifo_empty := Bits.gnd;
  cycle ();
  let advanced = Bits.to_int !(outputs.pc) = 1 in
  let popped = Bits.to_int !(outputs.rx_word) = 0xBEEF in
  Printf.printf "  pc advanced to 1 (%b), rx_word=0x%04x (expected 0xbeef, ok=%b)\n" advanced
    (Bits.to_int !(outputs.rx_word)) popped;
  let passed = !held && advanced && popped in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_branch_word () =
  Printf.printf "=== BRANCH_COND_WORD: branches on rx_word's bit, ignores a live pin ===\n";
  (* rx_word will be 0b101 (bit0=1); branch on bit0=1 to pc=2 (a marker
     EMIT_STATE), skipping pc=1's EMIT_STATE. pins_in stays 0 the
     whole time -- if this were accidentally reading a pin instead of
     rx_word, it would never branch. *)
  let prog =
    Protocol_engine.
      [ fifo_pop_instr
      ; branch_word ~bit:0 ~branch_if_one:true ~target:3
      ; emit_state ~pin:5 ~level:true (* should be skipped *)
      ; emit_state ~pin:6 ~level:true (* branch target: marker *)
      ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.fifo_pop_data := Bits.of_int ~width:16 0b101;
  inputs.fifo_empty := Bits.gnd;
  cycle ();
  (* instr0: FIFO_POP completes, pc->1 *)
  cycle ();
  (* instr1: BRANCH_COND_WORD, bit0 of rx_word(0b101)=1 -> branch to pc=3 *)
  cycle ();
  (* instr3: EMIT_STATE pin6 *)
  let pins_out = Bits.to_int !(outputs.pins_out) in
  let pin5_untouched = (pins_out lsr 5) land 1 = 0 in
  let pin6_set = (pins_out lsr 6) land 1 = 1 in
  Printf.printf "  pins_out=0x%02x: pin5 untouched (skipped)=%b, pin6 set (branch target)=%b\n" pins_out
    pin5_untouched pin6_set;
  let passed = pin5_untouched && pin6_set in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_branch_pin () =
  Printf.printf "=== BRANCH_PIN: branches on a real external pin, ignores rx_word content ===\n";
  (* rx_word will be 0 (bit0=0, would NOT branch if BRANCH_PIN were
     accidentally reading rx_word). pins_in bit3 goes high instead --
     that's what must drive the branch. *)
  let prog =
    Protocol_engine.
      [ fifo_pop_instr
      ; branch_pin ~pin:3 ~branch_if_high:true ~target:3
      ; emit_state ~pin:5 ~level:true (* should be skipped *)
      ; emit_state ~pin:6 ~level:true (* branch target: marker *)
      ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.fifo_pop_data := Bits.of_int ~width:16 0;
  inputs.fifo_empty := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 0b0000_1000;
  cycle ();
  cycle ();
  cycle ();
  let pins_out = Bits.to_int !(outputs.pins_out) in
  let pin5_untouched = (pins_out lsr 5) land 1 = 0 in
  let pin6_set = (pins_out lsr 6) land 1 = 1 in
  Printf.printf "  pins_out=0x%02x: pin5 untouched (skipped)=%b, pin6 set (branch target)=%b\n" pins_out
    pin5_untouched pin6_set;
  let passed = pin5_untouched && pin6_set in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_emit_state_and_release () =
  Printf.printf "=== EMIT_STATE + release_pin: same per-pin sticky demux as engine.ml ===\n";
  let prog =
    Protocol_engine.
      [ emit_state ~pin:2 ~level:true; emit_state ~pin:4 ~level:true; release_pin ~pin:2 ]
  in
  let _sim, _inputs, outputs, cycle = new_sim ~prog in
  cycle ();
  cycle ();
  let oe_before = (Bits.to_int !(outputs.pins_oe) lsr 2) land 1 in
  cycle ();
  let oe_after = (Bits.to_int !(outputs.pins_oe) lsr 2) land 1 in
  let pin4_oe = (Bits.to_int !(outputs.pins_oe) lsr 4) land 1 in
  Printf.printf "  pin2 oe: driving=%d -> released=%d (expected 1,0); pin4 unaffected oe=%d (expected 1)\n"
    oe_before oe_after pin4_oe;
  let passed = oe_before = 1 && oe_after = 0 && pin4_oe = 1 in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let r1 = test_fifo_pop_stalls_and_pops () in
  let r2 = test_branch_word () in
  let r3 = test_branch_pin () in
  let r4 = test_emit_state_and_release () in
  let all_pass = r1 && r2 && r3 && r4 in
  Printf.printf "==================\nProtocol engine suite: %s\n"
    (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
