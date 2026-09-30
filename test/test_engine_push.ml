open Hardcaml
open Tt_core

(* Targeted tests for the new shift-accumulator + FIFO push interface
   on SHIFT_IO (payload bit 0), added to make Engine usable as µE0 in
   the dual-engine architecture. No FIFO involved yet -- that's
   dual.ml/test_dual.ml -- this only proves Engine's own half of the
   contract: byte assembly is correct, `byte_ready` fires exactly on a
   pushing SHIFT_IO, and `push_stall` genuinely stalls (retries) only
   that instruction, never a plain accumulate-only shift.

   Three things need proving:
   1. Byte assembly: 8 SHIFT_IOs (last one pushing) assemble the
      sampled bits into `byte_data` in the documented order (first bit
      sampled ends up the MSB), with `byte_ready` pulsing on exactly
      that one cycle.
   2. Backpressure: holding `push_stall` high while a pushing SHIFT_IO
      is fetched stalls the fetch stage (pc doesn't advance,
      `byte_ready` doesn't fire) for as long as it's held; releasing
      it lets the SAME instruction complete -- retried, not dropped.
   3. A plain (non-pushing) SHIFT_IO is never stalled by `push_stall`,
      even held high the whole time -- only the handoff instruction
      itself can ever be blocked. *)

module Sim = Cyclesim.With_interface (Engine.I) (Engine.O)

let new_sim ~prog =
  let sim = Sim.create Engine.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 0;
  inputs.prescale := Bits.of_int ~width:8 0;
  inputs.push_stall := Bits.gnd;
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

let test_byte_assembly () =
  Printf.printf "=== Byte assembly: 8 SHIFT_IOs (last pushing) assemble byte_data, first bit = MSB ===\n";
  (* Bits sampled in order 1,0,1,1,0,0,1,0 -- expected assembled byte
     0b10110010 (first bit sampled is the MSB). *)
  let bits = [ 1; 0; 1; 1; 0; 0; 1; 0 ] in
  let prog =
    Engine.
      [ shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in_push ~pin:0
      ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  let last_ready = ref false in
  let last_data = ref 0 in
  List.iter
    (fun b ->
      inputs.pins_in := Bits.of_int ~width:8 b;
      cycle ();
      if Bits.to_int !(outputs.byte_ready) = 1 then begin
        last_ready := true;
        last_data := Bits.to_int !(outputs.byte_data)
      end)
    bits;
  let expected = 0b10110010 in
  Printf.printf "  byte_ready pulsed on the pushing instruction: %b (expected true)\n" !last_ready;
  Printf.printf "  byte_data = 0b%08x (expected 0b%08x)\n" !last_data expected;
  let passed = !last_ready && !last_data = expected in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_backpressure_stalls_and_retries () =
  Printf.printf "=== Backpressure: push_stall holds the pushing SHIFT_IO, then retries when cleared ===\n";
  let prog = Engine.[ shift_in_push ~pin:0; emit_state ~pin:1 ~level:true ] in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.push_stall := Bits.vdd;
  inputs.pins_in := Bits.of_int ~width:8 1;
  let held = ref true in
  for _ = 1 to 4 do
    cycle ();
    if Bits.to_int !(outputs.pc) <> 0 || Bits.to_int !(outputs.byte_ready) <> 0 then held := false
  done;
  Printf.printf "  pc held at 0, byte_ready never fired across 4 stalled cycles: %b (expected true)\n" !held;
  inputs.push_stall := Bits.gnd;
  cycle ();
  let advanced = Bits.to_int !(outputs.pc) = 1 in
  let fired = Bits.to_int !(outputs.byte_ready) = 1 in
  Printf.printf "  releasing push_stall: pc -> 1 (%b), byte_ready fired this cycle (%b)\n" advanced fired;
  let passed = !held && advanced && fired in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_plain_shift_never_stalled () =
  Printf.printf "=== A plain (non-pushing) SHIFT_IO ignores push_stall entirely ===\n";
  let prog = Engine.[ shift_in ~pin:0; shift_in ~pin:0; emit_state ~pin:1 ~level:true ] in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.push_stall := Bits.vdd (* held high the whole time *);
  inputs.pins_in := Bits.of_int ~width:8 1;
  cycle ();
  let pc1 = Bits.to_int !(outputs.pc) in
  cycle ();
  let pc2 = Bits.to_int !(outputs.pc) in
  cycle ();
  let pc3 = Bits.to_int !(outputs.pc) in
  Printf.printf "  pc progression with push_stall held high throughout: 0 -> %d -> %d -> %d (expected 1,2,3)\n"
    pc1 pc2 pc3;
  let passed = pc1 = 1 && pc2 = 2 && pc3 = 3 in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let r1 = test_byte_assembly () in
  let r2 = test_backpressure_stalls_and_retries () in
  let r3 = test_plain_shift_never_stalled () in
  let all_pass = r1 && r2 && r3 in
  Printf.printf "==================\nEngine push/backpressure suite: %s\n"
    (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
