open Hardcaml
open Tt_core

(* Program-overrun guard (halt_guard.ml), on the dual-engine core.

   Instruction SRAM is not cleared on the chip, so running past the last
   loaded word would execute power-up garbage. Cyclesim's RAM reads zero
   there instead, and for µE1 zero decodes as FIFO_POP, so an unguarded
   µE1 that falls off its program silently keeps draining the FIFO. That
   makes µE1 the sharp probe: with the guard, the words it never popped
   are still in the FIFO; without it, they are gone.

   Cases:
   1. µE1 falls through its last word: it halts there, the FIFO keeps the
      bytes it never asked for, and µE0 is unaffected.
   2. µE0 branches to an address it never loaded: it halts at the target,
      and the pin it drove keeps its level.
   3. µE0 falls through after an EMIT: halts at the next address, the pin
      keeps its level for the rest of the run.
   4. A program that ends with an explicit halt (edge-only wait) never
      trips the guard, so existing programs behave exactly as before. *)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let failures = ref 0

let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

(* Load both programs through Dual's direct write ports, start both
   engines with every pin high, run [cycles], return the outputs. *)
let run ~phys ~protocol ~cycles =
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.pins_in := Bits.of_int ~width:8 0xFF;
  cycle ();
  i.rst_n := Bits.vdd;
  let load we addr data prog =
    List.iteri
      (fun k w ->
        addr := Bits.of_int ~width:9 k;
        data := Bits.of_int ~width:16 w;
        we := Bits.vdd;
        cycle ())
      prog;
    we := Bits.gnd
  in
  load i.phys_write_enable i.phys_write_addr i.phys_write_data phys;
  load i.protocol_write_enable i.protocol_write_addr i.protocol_write_data protocol;
  for _ = 1 to Dual.sync_latency do
    cycle ()
  done;
  i.run := Bits.vdd;
  i.protocol_run := Bits.vdd;
  for _ = 1 to cycles do
    cycle ()
  done;
  o

let b o = Bits.to_int !o
let pin o n = (b o lsr n) land 1 = 1

(* µE0: 8 shifts of the (high) pin 0 per byte, push, three bytes, then halt *)
let three_bytes_then_halt =
  List.concat
    (List.init 3 (fun _ ->
       List.init 7 (fun _ -> Engine.shift_in ~pin:0) @ [ Engine.shift_in_push ~pin:0 ]))
  @ [ Engine.wait_edge ~pin:7 ~falling:true ~payload:0 ]

let () =
  Printf.printf "=== Program-overrun guard ===\n";

  (* 1. µE1 pops once and falls off its 1-word program *)
  let o = run ~phys:three_bytes_then_halt ~protocol:[ Protocol_engine.fifo_pop_instr ] ~cycles:200 in
  check "uE1 past its last word: halted" (b o.Dual.O.protocol_halted = 1);
  check "uE1 stopped at the first unloaded address (pc = 1)" (b o.Dual.O.protocol_pc = 1);
  check "the two bytes uE1 never asked for are still in the FIFO" (b o.Dual.O.fifo_empty = 0);
  check "uE0 (ends with an explicit halt) is not halted by the guard" (b o.Dual.O.phys_halted = 0);
  check "uE0 finished its program and sits on its own halt (pc = 24)" (b o.Dual.O.phys_pc = 24);

  (* 2. µE0 drives pin 3 high, then branches (pin 1 is high) to an unloaded address *)
  let o =
    run
      ~phys:Engine.[ emit_state ~pin:3 ~level:true; branch_cond ~pin:1 ~branch_if_high:true ~target:200 ]
      ~protocol:[ Protocol_engine.fifo_pop_instr ] ~cycles:100
  in
  check "uE0 branch to an unloaded address: halted" (b o.Dual.O.phys_halted = 1);
  check "uE0 stopped at the branch target (pc = 200)" (b o.Dual.O.phys_pc = 200);
  check "pin 3 keeps the level uE0 drove" (pin o.Dual.O.phys_pins_out 3 && pin o.Dual.O.phys_pins_oe 3);

  (* 3. µE0 drives pin 2 high and falls through *)
  let o =
    run ~phys:Engine.[ emit_state ~pin:2 ~level:true ] ~protocol:[ Protocol_engine.fifo_pop_instr ] ~cycles:100
  in
  check "uE0 fall-through: halted at pc = 1" (b o.Dual.O.phys_halted = 1 && b o.Dual.O.phys_pc = 1);
  check "pin 2 keeps its level" (pin o.Dual.O.phys_pins_out 2);

  (* 4. explicit halts on both engines: the guard never trips *)
  let o =
    run
      ~phys:Engine.[ emit_state ~pin:2 ~level:true; wait_edge ~pin:7 ~falling:true ~payload:0 ]
      ~protocol:Protocol_engine.[ emit_state ~pin:5 ~level:true; fifo_pop_instr ]
      ~cycles:100
  in
  check "programs ending in an explicit halt: neither engine is halted by the guard"
    (b o.Dual.O.phys_halted = 0 && b o.Dual.O.protocol_halted = 0);

  if !failures = 0 then print_endline "RESULT: PASS"
  else (
    Printf.printf "RESULT: FAIL (%d)\n" !failures;
    exit 1)
