open Hardcaml
open Tt_core

(* Targeted tests for CAPTURE (SHIFT_IO with mode=1), the new
   Drive/Shadow/Capture primitive added this session. No FIFO involved
   yet -- that's test_dual_capture.ml -- this only proves Engine's own
   half of the contract:
   1. A capture pushes exactly the documented 16-bit record
      {pin_sel, sampled level, elapsed cycles since the previous
      capture} and never disturbs the plain byte-accumulator path.
   2. `elapsed` genuinely measures inter-capture spacing and resets to
      0 after every capture push.
   3. `push_stall` holds a CAPTURE at the current pc (retried, not
      dropped) exactly like it already does a pushing SHIFT_IO. *)

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

let decode_capture data =
  let pin_sel = (data lsr 13) land 0x7 in
  let level = (data lsr 12) land 0x1 in
  let elapsed = data land 0xFFF in
  (pin_sel, level, elapsed)

let test_capture_record_shape () =
  Printf.printf "=== CAPTURE record shape: pin_sel/level/elapsed pack correctly ===\n";
  (* Two captures on different pins, with a known, different number of
     idle cycles (plain shift_in, non-pushing) in between each. *)
  let prog =
    Engine.
      [ capture ~pin:3      (* elapsed since reset = 0 *)
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; capture ~pin:5      (* elapsed since prior capture = 3 *)
      ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.pins_in := Bits.of_int ~width:8 0b00101000 (* pin3=1, pin5=1 *);
  let records = ref [] in
  for _ = 1 to 6 do
    cycle ();
    if Bits.to_int !(outputs.capture_ready) = 1 then
      records := Bits.to_int !(outputs.capture_data) :: !records
  done;
  let records = List.rev !records in
  let ok =
    match records with
    | [ r0; r1 ] ->
      let p0, l0, e0 = decode_capture r0 in
      let p1, l1, e1 = decode_capture r1 in
      Printf.printf
        "  capture 0: pin=%d level=%d elapsed=%d (expected pin=3 level=1 elapsed=0)\n" p0 l0 e0;
      Printf.printf
        "  capture 1: pin=%d level=%d elapsed=%d (expected pin=5 level=1 elapsed=3)\n" p1 l1 e1;
      p0 = 3 && l0 = 1 && e0 = 0 && p1 = 5 && l1 = 1 && e1 = 3
    | _ ->
      Printf.printf "  expected exactly 2 capture_ready pulses, got %d\n" (List.length records);
      false
  in
  Printf.printf "RESULT: %s\n\n" (if ok then "PASS" else "FAIL");
  ok

let test_capture_does_not_disturb_byte_path () =
  Printf.printf "=== CAPTURE never touches the byte accumulator / byte_ready ===\n";
  (* Interleave real byte-assembly shifts with a capture in the middle.
     The capture (index 2) samples pin 0 for its own record but must
     NOT shift into the accumulator -- so the 8-bit accumulator (reset
     value 0) only ever receives the 7 real shift_in samples
     (1,0,1,1,0,0,1), shifting left-and-insert-at-LSB each time:
       0000_0000 -1-> 0000_0001 -0-> 0000_0010 -1-> 0000_0101
       -1-> 0000_1011 -0-> 0001_0110 -0-> 0010_1100 -1(push)-> 0101_1001
     Expected final byte_data = 0x59. *)
  let prog =
    Engine.
      [ shift_in ~pin:0
      ; shift_in ~pin:0
      ; capture ~pin:1
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in_push ~pin:0
      ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  let bits = [ 1; 0; 0; 1; 1; 0; 0; 1 ] in
  let byte_ready_on_capture_cycle = ref false in
  let final_byte = ref (-1) in
  List.iteri
    (fun i b ->
      inputs.pins_in := Bits.of_int ~width:8 b;
      cycle ();
      if i = 2 && Bits.to_int !(outputs.byte_ready) = 1 then byte_ready_on_capture_cycle := true;
      if Bits.to_int !(outputs.byte_ready) = 1 then final_byte := Bits.to_int !(outputs.byte_data))
    bits;
  let expected = 0x59 in
  Printf.printf "  byte_ready fired on the capture's cycle: %b (expected false)\n"
    !byte_ready_on_capture_cycle;
  Printf.printf "  final assembled byte: 0x%02x (expected 0x%02x)\n" !final_byte expected;
  let passed = (not !byte_ready_on_capture_cycle) && !final_byte = expected in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_elapsed_resets_and_accumulates () =
  Printf.printf "=== elapsed counter resets to 0 after a capture, accumulates between captures ===\n";
  let prog =
    Engine.
      [ capture ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; shift_in ~pin:0
      ; capture ~pin:0
      ; capture ~pin:0 (* immediately back-to-back: elapsed should be 0 *)
      ]
  in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.pins_in := Bits.of_int ~width:8 0;
  let elapsed_values = ref [] in
  for _ = 1 to 8 do
    cycle ();
    if Bits.to_int !(outputs.capture_ready) = 1 then begin
      let _, _, e = decode_capture (Bits.to_int !(outputs.capture_data)) in
      elapsed_values := e :: !elapsed_values
    end
  done;
  let elapsed_values = List.rev !elapsed_values in
  Printf.printf "  elapsed sequence: [%s] (expected [0; 5; 0])\n"
    (String.concat "; " (List.map string_of_int elapsed_values));
  let passed = elapsed_values = [ 0; 5; 0 ] in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_backpressure_holds_capture () =
  Printf.printf "=== push_stall holds a CAPTURE at its pc, then retries when cleared ===\n";
  let prog = Engine.[ capture ~pin:0; emit_state ~pin:1 ~level:true ] in
  let _sim, inputs, outputs, cycle = new_sim ~prog in
  inputs.push_stall := Bits.vdd;
  inputs.pins_in := Bits.of_int ~width:8 1;
  let held = ref true in
  for _ = 1 to 4 do
    cycle ();
    if Bits.to_int !(outputs.pc) <> 0 || Bits.to_int !(outputs.capture_ready) <> 0 then held := false
  done;
  Printf.printf "  pc held at 0, capture_ready never fired across 4 stalled cycles: %b (expected true)\n"
    !held;
  inputs.push_stall := Bits.gnd;
  cycle ();
  let advanced = Bits.to_int !(outputs.pc) = 1 in
  let fired = Bits.to_int !(outputs.capture_ready) = 1 in
  Printf.printf "  releasing push_stall: pc -> 1 (%b), capture_ready fired this cycle (%b)\n"
    advanced fired;
  let passed = !held && advanced && fired in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let r1 = test_capture_record_shape () in
  let r2 = test_capture_does_not_disturb_byte_path () in
  let r3 = test_elapsed_resets_and_accumulates () in
  let r4 = test_backpressure_holds_capture () in
  let all_pass = r1 && r2 && r3 && r4 in
  Printf.printf "==================\nCapture suite: %s\n" (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
