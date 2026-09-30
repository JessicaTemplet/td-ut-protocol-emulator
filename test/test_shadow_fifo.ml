open Hardcaml
open Tt_core

(* Standalone proof of shadow_fifo.ml's push/pop/full/empty/backpressure
   contract before anything (dual.ml) depends on it -- same
   "test every increment before building on it" discipline as
   timer.ml/loader.ml before they were wired into engine.ml/system.ml.

   Four things need proving:
   1. Basic push/pop preserves FIFO order (4 items in, same 4 out).
   2. `full` asserts at exactly 4 items, and a push attempted while
      full is silently dropped (no overflow corruption of slot 0).
   3. `empty` asserts once drained, and a pop attempted while empty is
      silently a no-op (pop_data doesn't go garbage).
   4. Simultaneous push+pop (steady-state streaming) keeps count flat
      and preserves order -- this is the mode dual.ml will actually
      use once both engines are running concurrently. *)

module Sim = Cyclesim.With_interface (Shadow_fifo.I) (Shadow_fifo.O)

let new_sim () =
  let sim = Sim.create Shadow_fifo.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  inputs.rst_n := Bits.gnd;
  inputs.push := Bits.gnd;
  inputs.pop := Bits.gnd;
  inputs.push_data := Bits.of_int ~width:16 0;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  (inputs, outputs, cycle)

let do_push inputs cycle data =
  inputs.Shadow_fifo.I.push := Bits.vdd;
  inputs.push_data := Bits.of_int ~width:16 data;
  cycle ();
  inputs.push := Bits.gnd

let do_pop inputs outputs cycle =
  let d = Bits.to_int !(outputs.Shadow_fifo.O.pop_data) in
  inputs.Shadow_fifo.I.pop := Bits.vdd;
  cycle ();
  inputs.pop := Bits.gnd;
  d

let test_order_and_fill () =
  Printf.printf "=== Order + full/empty flags ===\n";
  let inputs, outputs, cycle = new_sim () in
  let empty0 = Bits.to_int !(outputs.empty) = 1 in
  Printf.printf "  empty on reset: %b (expected true)\n" empty0;
  List.iter (fun d -> do_push inputs cycle d) [ 0x1111; 0x2222; 0x3333; 0x4444 ];
  let full_after_4 = Bits.to_int !(outputs.full) = 1 in
  Printf.printf "  full after 4 pushes: %b (expected true)\n" full_after_4;
  (* Push attempted while full must be dropped, not corrupt slot 0. *)
  do_push inputs cycle 0xDEAD;
  let still_full = Bits.to_int !(outputs.full) = 1 in
  let popped = List.init 4 (fun _ -> do_pop inputs outputs cycle) in
  Printf.printf "  popped in order: [%s] (expected [0x1111; 0x2222; 0x3333; 0x4444])\n"
    (String.concat "; " (List.map (Printf.sprintf "0x%04x") popped));
  let order_ok = popped = [ 0x1111; 0x2222; 0x3333; 0x4444 ] in
  let empty_after = Bits.to_int !(outputs.empty) = 1 in
  Printf.printf "  empty after draining: %b (expected true)\n" empty_after;
  (* Pop attempted while empty must be a no-op, not underflow. *)
  let stale = do_pop inputs outputs cycle in
  let still_empty = Bits.to_int !(outputs.empty) = 1 in
  Printf.printf "  pop while empty: stays empty=%b (expected true), no crash (stale read=0x%04x)\n"
    still_empty stale;
  let passed = empty0 && full_after_4 && still_full && order_ok && empty_after && still_empty in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let test_simultaneous_push_pop () =
  Printf.printf "=== Simultaneous push+pop (steady-state streaming) ===\n";
  let inputs, outputs, cycle = new_sim () in
  (* Prime with 2 entries first. *)
  do_push inputs cycle 0xAAAA;
  do_push inputs cycle 0xBBBB;
  let count_check1 = Bits.to_int !(outputs.full) = 0 && Bits.to_int !(outputs.empty) = 0 in
  (* Now push 0xCCCC and pop simultaneously for 2 cycles -- count
     should stay flat at 2 throughout, order preserved. *)
  let results = ref [] in
  List.iter
    (fun d ->
      let peeked = Bits.to_int !(outputs.pop_data) in
      results := peeked :: !results;
      inputs.push := Bits.vdd;
      inputs.push_data := Bits.of_int ~width:16 d;
      inputs.pop := Bits.vdd;
      cycle ();
      inputs.push := Bits.gnd;
      inputs.pop := Bits.gnd)
    [ 0xCCCC; 0xDDDD ];
  let results = List.rev !results in
  Printf.printf "  peeked during simultaneous push+pop: [%s] (expected [0xaaaa; 0xbbbb])\n"
    (String.concat "; " (List.map (Printf.sprintf "0x%04x") results));
  let stream_order_ok = results = [ 0xAAAA; 0xBBBB ] in
  (* Drain the remaining 2 (0xCCCC, 0xDDDD) to confirm they landed correctly. *)
  let drained = List.init 2 (fun _ -> do_pop inputs outputs cycle) in
  Printf.printf "  drained tail: [%s] (expected [0xcccc; 0xdddd])\n"
    (String.concat "; " (List.map (Printf.sprintf "0x%04x") drained));
  let tail_ok = drained = [ 0xCCCC; 0xDDDD ] in
  let empty_final = Bits.to_int !(outputs.empty) = 1 in
  let passed = count_check1 && stream_order_ok && tail_ok && empty_final in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let r1 = test_order_and_fill () in
  let r2 = test_simultaneous_push_pop () in
  let all_pass = r1 && r2 in
  Printf.printf "==================\nFIFO suite: %s\n" (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
