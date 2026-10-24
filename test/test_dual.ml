open Hardcaml
open Tt_core

(* End-to-end proof of the actual dual-engine architecture: µE0
   (engine.ml) streaming bytes through shadow_fifo.ml into µE1
   (protocol_engine.ml). This is the thing the design blueprint's
   novelty claim rests on -- if this test and the three standalone
   suites (test_engine_push.ml, test_shadow_fifo.ml,
   test_protocol_engine.ml) ever disagree, the bug is in dual.ml's
   wiring, not in any of the three already-independently-tested
   modules.

   Two things need proving, each its own test:
   1. Backpressure/liveness (the actual hardware form of the design
      blueprint's WAIT_DRAIN story, and the closest thing this project
      has to the formal liveness proof the blueprint calls for -- that
      part is still SymbiYosys/BMC work, not done here, this is
      directed simulation, not a formal proof): with µE1 paused
      (run=0), µE0 races ahead pushing bytes as fast as it can. Once
      the shadow FIFO (depth 4) is full, µE0's 5th push must STALL --
      held at that exact instruction, not silently drop the byte or
      advance past it -- for as long as µE1 stays paused. Enabling µE1
      then drains the FIFO and releases µE0 to finish.
   2. No data lost, correct order: the 5 distinct byte values µE0
      pushes come out of µE1's `rx_word` in the SAME order, byte for
      byte, despite the stall in between -- proving the FIFO's
      ordering guarantee survives backpressure, not just a clean run. *)

let bits_of_byte n = List.init 8 (fun i -> (n lsr (7 - i)) land 1)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let byte_values = [ 10; 11; 12; 13; 14 ]

(* 8 SHIFT_IOs per byte (7 plain + 1 push), all back to back, for
   every value in byte_values -- races ahead as fast as advance
   allows, exactly the producer half of the backpressure scenario. *)
let phys_prog =
  List.concat_map
    (fun _ ->
      Engine.[ shift_in ~pin:0; shift_in ~pin:0; shift_in ~pin:0; shift_in ~pin:0
             ; shift_in ~pin:0; shift_in ~pin:0; shift_in ~pin:0; shift_in_push ~pin:0 ])
    byte_values

let protocol_prog = List.init 8 (fun _ -> Protocol_engine.fifo_pop_instr)

let () =
  let sim = Sim.create Dual.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in

  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 0;
  inputs.prescale := Bits.of_int ~width:8 0;
  inputs.run := Bits.gnd;
  inputs.protocol_run := Bits.gnd;
  for _ = 1 to 4 do
    cycle ()
  done;
  inputs.rst_n := Bits.vdd;
  cycle ();

  List.iteri
    (fun i w ->
      inputs.phys_write_addr := Bits.of_int ~width:9 i;
      inputs.phys_write_data := Bits.of_int ~width:16 w;
      inputs.phys_write_enable := Bits.vdd;
      cycle ())
    phys_prog;
  inputs.phys_write_enable := Bits.gnd;

  List.iteri
    (fun i w ->
      inputs.protocol_write_addr := Bits.of_int ~width:9 i;
      inputs.protocol_write_data := Bits.of_int ~width:16 w;
      inputs.protocol_write_enable := Bits.vdd;
      cycle ())
    protocol_prog;
  inputs.protocol_write_enable := Bits.gnd;

  (* Start ONLY µE0 -- µE1 stays paused (protocol_run=0) so it can't
     drain anything while µE0 races ahead filling the FIFO. Without
     this, µE1 (1 cycle per pop) would drain every byte the instant it
     existed, since µE0 takes 8 cycles per byte -- the FIFO would
     never reach full and backpressure would go untested (see dual.ml's
     header comment). *)
  (* Feed the 5 bytes' bits one per cycle, back to back -- the 5th
     byte's last bit is held steady once µE0 stalls on the full FIFO,
     since a stalled SHIFT_IO retries using whatever pins_in shows.
     Dual's input synchronizer delays the pins by Dual.sync_latency
     cycles, so the stream starts that many cycles before µE0 runs and
     the last bit is held that many cycles after: µE0 sees exactly one
     bit per cycle from its first running cycle. *)
  let all_bits = List.concat_map bits_of_byte byte_values in
  List.iteri
    (fun k b ->
      if k = Dual.sync_latency then inputs.run := Bits.vdd;
      inputs.pins_in := Bits.of_int ~width:8 b;
      cycle ())
    all_bits;
  for _ = 1 to Dual.sync_latency do
    cycle ()
  done;

  let phys_pc_at_stall = Bits.to_int !(outputs.phys_pc) in
  let fifo_full_at_stall = Bits.to_int !(outputs.fifo_full) = 1 in
  Printf.printf "=== Backpressure: mu-E0 races ahead, stalls once the FIFO (depth 4) is full ===\n";
  Printf.printf "  phys_pc after racing through all bit-feed cycles: %d (expected 39, the 5th push)\n"
    phys_pc_at_stall;
  Printf.printf "  fifo_full: %b (expected true)\n" fifo_full_at_stall;

  (* Hold for several more cycles with mu-E1 STILL paused -- confirms
     the stall isn't a one-cycle fluke and mu-E0 genuinely waits for
     as long as backpressure is asserted. *)
  let stall_held = ref true in
  for _ = 1 to 5 do
    cycle ();
    if Bits.to_int !(outputs.phys_pc) <> phys_pc_at_stall then stall_held := false
  done;
  Printf.printf "  phys_pc still held at %d after 5 more cycles: %b (expected true)\n" phys_pc_at_stall
    !stall_held;

  (* Now let mu-E1 actually drain: run enough cycles, recording
     rx_word every time protocol_pc advances (a completed FIFO_POP). *)
  inputs.protocol_run := Bits.vdd;
  let popped = ref [] in
  let last_protocol_pc = ref (Bits.to_int !(outputs.protocol_pc)) in
  for _ = 1 to 80 do
    cycle ();
    let pc_now = Bits.to_int !(outputs.protocol_pc) in
    if pc_now <> !last_protocol_pc then begin
      popped := Bits.to_int !(outputs.rx_word) :: !popped;
      last_protocol_pc := pc_now
    end
  done;
  let popped = List.rev !popped in
  Printf.printf "=== Order preserved through the stall ===\n";
  Printf.printf "  popped: [%s] (expected [%s])\n"
    (String.concat "; " (List.map string_of_int popped))
    (String.concat "; " (List.map string_of_int byte_values));
  let order_ok = popped = byte_values in

  let phys_pc_final = Bits.to_int !(outputs.phys_pc) in
  let fifo_empty_final = Bits.to_int !(outputs.fifo_empty) = 1 in
  Printf.printf "  mu-E0 finished all 5 pushes (phys_pc=%d, expected >= 40): %b\n" phys_pc_final
    (phys_pc_final >= 40);
  Printf.printf "  fifo empty after full drain: %b (expected true)\n" fifo_empty_final;

  let passed =
    phys_pc_at_stall = 39 && fifo_full_at_stall && !stall_held && order_ok && phys_pc_final >= 40
    && fifo_empty_final
  in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
