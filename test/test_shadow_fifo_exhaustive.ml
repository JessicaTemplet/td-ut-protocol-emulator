open Hardcaml
open Tt_core

(* Bounded-EXHAUSTIVE check of shadow_fifo.ml against a reference model.

   Why exhaustive rather than sampled: the FIFO's control state is tiny
   (count 0..4, two 2-bit pointers), and its behaviour does not depend on the
   data values (data is only stored and returned). Every reachable control
   state is reached within ~8 cycles, so enumerating EVERY push/pop sequence
   of length 10 (4^10 = 1,048,576 sequences, each starting from reset) visits
   every reachable state and every transition out of it, including all pointer
   wrap-arounds and all four (push,pop) combinations in each of full / empty /
   partial. Idle cycles (no push, no pop) are part of the alphabet, so shorter
   histories are covered too.

   Properties, checked every cycle on the real RTL (Cyclesim) against a list
   model whose spec is: a push is ignored when full, a pop is ignored when
   empty, both are decided on the PRE-edge state (so push+pop while full drops
   the push, push+pop while empty drops the pop):
     P1 empty/full flags equal (len = 0)/(len = 4) at all times
     P2 whenever not empty, pop_data is the oldest accepted, un-popped item
        (order preserved, no loss, no duplication, no corruption by dropped
        pushes)
   and after every sequence, from the state it reached:
     P3 drain (liveness): asserting pop every cycle empties the FIFO in at
        most 4 cycles, returning the remaining items in order, then `empty`
        holds (a full FIFO always makes room; nothing is stuck)
     P4 fill (liveness): asserting push every cycle fills an empty FIFO in
        exactly 4 cycles, then `full` holds (an empty FIFO always accepts)
   P3+P4 are the FIFO-side half of "never deadlocks": backpressure on the
   producer is always released by a consumer pop, and a starved consumer is
   always released by a producer push. test_dual.ml shows the two engines
   using it. This is a bounded model check of the RTL, not a SymbiYosys
   unbounded proof; the argument above is why the bound is complete for this
   design (state space saturates well inside it). *)

module Sim = Cyclesim.With_interface (Shadow_fifo.I) (Shadow_fifo.O)

let seq_len = 10

let () =
  Printf.printf "=== shadow_fifo bounded-exhaustive check (all 4^%d push/pop sequences) ===\n" seq_len;
  let sim = Sim.create Shadow_fifo.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let failures = ref 0 in
  let first_failure = ref "" in
  let fail fmt =
    Printf.ksprintf
      (fun s ->
        incr failures;
        if !failures = 1 then first_failure := s)
      fmt
  in
  let counter = ref 0 in
  let states_seen = Hashtbl.create 64 in
  let model = ref [] in
  let flag o = Bits.to_int !o = 1 in
  let check_state tag =
    let len = List.length !model in
    let empty = flag outputs.empty and full = flag outputs.full in
    if empty <> (len = 0) then fail "%s: empty=%b but model len=%d" tag empty len;
    if full <> (len = 4) then fail "%s: full=%b but model len=%d" tag full len;
    if len > 0 then begin
      let got = Bits.to_int !(outputs.pop_data) and want = List.hd !model in
      if got <> want then fail "%s: pop_data=%d expected %d (len=%d)" tag got want len
    end
  in
  (* one clock: apply (push,pop) per the spec, mirror in the model *)
  let step ~push ~pop =
    let len = List.length !model in
    incr counter;
    let data = !counter land 0xFFFF in
    inputs.push := if push then Bits.vdd else Bits.gnd;
    inputs.pop := if pop then Bits.vdd else Bits.gnd;
    inputs.push_data := Bits.of_int ~width:16 (if data = 0 then 1 else data);
    let d = if data = 0 then 1 else data in
    let do_pop = pop && len > 0 and do_push = push && len < 4 in
    cycle ();
    if do_pop then model := List.tl !model;
    if do_push then model := !model @ [ d ]
  in
  let reset () =
    inputs.rst_n := Bits.gnd;
    inputs.push := Bits.gnd;
    inputs.pop := Bits.gnd;
    cycle ();
    inputs.rst_n := Bits.vdd;
    model := []
  in
  inputs.rst_n := Bits.gnd;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  let total = 1 lsl (2 * seq_len) in
  for n = 0 to total - 1 do
    reset ();
    check_state "after reset";
    for i = 0 to seq_len - 1 do
      let sym = (n lsr (2 * i)) land 3 in
      step ~push:(sym land 1 = 1) ~pop:(sym land 2 = 2);
      check_state (Printf.sprintf "seq %d step %d" n i)
    done;
    Hashtbl.replace states_seen (List.length !model) ();
    (* P3: drain liveness *)
    let remaining = List.length !model in
    for i = 1 to 4 do
      if List.length !model > 0 then begin
        step ~push:false ~pop:true;
        check_state (Printf.sprintf "seq %d drain %d" n i)
      end
    done;
    if List.length !model <> 0 || not (flag outputs.empty) then
      fail "seq %d: not empty after draining %d items in 4 pops" n remaining;
    (* P4: fill liveness *)
    for i = 1 to 4 do
      step ~push:true ~pop:false;
      check_state (Printf.sprintf "seq %d fill %d" n i)
    done;
    if not (flag outputs.full) then fail "seq %d: not full after 4 pushes into empty FIFO" n
  done;
  Printf.printf "  sequences checked: %d, cycles simulated: ~%d\n" total (total * (1 + seq_len + 8));
  Printf.printf "  distinct fill levels reached at sequence end: %d (expected 5: 0..4)\n"
    (Hashtbl.length states_seen);
  Printf.printf "  property violations: %d (expected 0)\n" !failures;
  if !failures > 0 then Printf.printf "  first violation: %s\n" !first_failure;
  let passed = !failures = 0 && Hashtbl.length states_seen = 5 in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
