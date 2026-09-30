open Hardcaml
open Tt_core

(* Targeted tests for EMIT_STATE and BRANCH_COND (ISA v0.3) --
   test_engine.ml already covers WAIT_EDGE/SHIFT_IO end-to-end via
   the UART RX microcode; this file is the same "test every
   increment" discipline applied to the two opcodes added on top of
   it, since they're new decode paths and a new pc/next_pc mux term
   (branch_taken) that UART RX never exercises.

   Both tests rely on one precise timing fact established when
   engine.ml's fetch stage was made bubble-free: `instr` at any
   moment is program[pc] using the CURRENT (pre-edge) value of `pc`,
   so reading outputs.pc immediately before Cyclesim.cycle() tells
   you which instruction is about to execute, and outputs.tx_pin
   immediately after that same cycle() call reflects that
   instruction's effect (tx_pin is a held register, unlike the
   one-shot sample_pulse/sampled_bit outputs). *)

module Sim = Cyclesim.With_interface (Engine.I) (Engine.O)

(* ---- Test 1: EMIT_STATE drives tx_pin, single-cycle, always
   advances pc regardless of rx_pin. ---- *)
let test_emit_state () =
  Printf.printf "=== EMIT_STATE: tx_pin follows program, pc free-runs ===\n";
  let prog =
    Engine.
      [ emit_state ~pin:0 ~level:true
      ; emit_state ~pin:0 ~level:false
      ; emit_state ~pin:0 ~level:true
      ; emit_state ~pin:0 ~level:false
      ]
  in
  let sim = Sim.create Engine.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in

  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 1;
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

  let expected_pc_before = [ 0; 1; 2; 3 ] in
  let expected_tx = [ 1; 0; 1; 0 ] in
  let results =
    List.map
      (fun (exp_pc, exp_tx) ->
        let pc_before = Bits.to_int !(outputs.pc) in
        cycle ();
        let tx_after = Bits.to_int !(outputs.pins_out) land 1 in
        Printf.printf "  pc_before=%d (expected %d)  tx_after=%d (expected %d)\n" pc_before
          exp_pc tx_after exp_tx;
        pc_before = exp_pc && tx_after = exp_tx)
      (List.combine expected_pc_before expected_tx)
  in
  let passed = List.for_all (fun x -> x) results in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

(* ---- Test 2: BRANCH_COND loops on pc=0 while rx_pin is high (the
   condition it tests), falls through to pc=1 the cycle rx_pin reads
   low, then execution proceeds normally (EMIT_STATE) from there. ---- *)
let test_branch_cond () =
  Printf.printf "=== BRANCH_COND: loop while pin high, fall through on low ===\n";
  let prog =
    Engine.
      [ branch_cond ~pin:0 ~branch_if_high:true ~target:0
      ; emit_state ~pin:0 ~level:true
      ; emit_state ~pin:0 ~level:false
      ]
  in
  let sim = Sim.create Engine.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in

  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 1;
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

  (* rx_pin (pins_in bit 0) high for the first 5 cycles (loop should
     hold pc at 0), then low from cycle 6 onward (loop should release). *)
  let rx_schedule = [ 1; 1; 1; 1; 1; 0; 0; 0 ] in
  let expected_pc_before = [ 0; 0; 0; 0; 0; 0; 1; 2 ] in
  let expected_tx_after = [ 0; 0; 0; 0; 0; 0; 1; 0 ] in
  let steps = List.combine rx_schedule (List.combine expected_pc_before expected_tx_after) in
  let results =
    List.map
      (fun (rx, (exp_pc, exp_tx)) ->
        inputs.pins_in := Bits.of_int ~width:8 rx;
        let pc_before = Bits.to_int !(outputs.pc) in
        cycle ();
        let tx_after = Bits.to_int !(outputs.pins_out) land 1 in
        Printf.printf "  rx=%d  pc_before=%d (expected %d)  tx_after=%d (expected %d)\n" rx
          pc_before exp_pc tx_after exp_tx;
        pc_before = exp_pc && tx_after = exp_tx)
      steps
  in
  let passed = List.for_all (fun x -> x) results in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let r1 = test_emit_state () in
  let r2 = test_branch_cond () in
  let all_pass = r1 && r2 in
  Printf.printf "==================\nEngine branch/emit suite: %s\n"
    (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
