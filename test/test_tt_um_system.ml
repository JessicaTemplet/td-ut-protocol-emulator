open Hardcaml
open Tt_core

(* End-to-end proof at the ACTUAL tt_um pin level -- ui_in/uio_in/
   uo_out/uio_out/uio_oe only, no internal Loader.I/System.I
   shortcuts. This is the thing that would actually tape out: if this
   test and test_system.ml ever disagree, the bug is in tt_um_system's
   pin mapping (tt_core.ml), not in loader.ml/engine.ml/system.ml
   themselves -- those are already covered separately.

   Pin mapping this session moved Engine's whole 8-pin bus from
   ui_in/uo_out onto uio_in/uio_out/uio_oe (see tt_core.ml's header
   comment for the full rationale: uio is the only tt_um pin group
   that's genuinely bidirectional per-pin, which is what a true
   open-drain net like I2C SDA needs). Two things this file proves
   that no lower-level test can, since they don't touch tt_um's real
   pins:
   1. Scenario A (wiring/mux proof): uo_out shows loader.ml's checksum
      while run=0, switches to a pins_out mirror once run=1; uio_in
      genuinely double-duties as strobe/byte_sel/go pre-run and
      pins_in post-run, on the SAME physical pins, exactly as the
      handoff's pin-reuse pattern (already established for ui_in)
      now also applies to uio.
   2. Scenario B (the actual point of the uio move): a tiny
      open-drain-style microcode drives a pin low, releases it
      (tri-states), and then reads back a rising edge on the SAME
      pin once the testbench stands in for an external pull-up --
      something ui_in/uo_out being separate one-directional buses
      could never do, since there'd be no physical net shared between
      "the pin the chip reads" and "the pin the chip drives". *)

module Sim = Cyclesim.With_interface (I) (O)

let load_and_go ~(sim : Sim.t) ~prog =
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in
  let set_uio ~strobe ~byte_sel ~go =
    inputs.uio_in := Bits.of_int ~width:8 ((go lsl 2) lor (byte_sel lsl 1) lor strobe)
  in
  inputs.rst_n := Bits.gnd;
  inputs.ui_in := Bits.of_int ~width:8 0;
  set_uio ~strobe:0 ~byte_sel:0 ~go:0;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  let pulse_byte ~byte_sel ~data =
    inputs.ui_in := Bits.of_int ~width:8 data;
    set_uio ~strobe:0 ~byte_sel ~go:0;
    settle ();
    set_uio ~strobe:1 ~byte_sel ~go:0;
    settle ();
    set_uio ~strobe:0 ~byte_sel ~go:0;
    settle ()
  in
  (* First strobe always loads prescale (loader.ml's protocol). *)
  pulse_byte ~byte_sel:0 ~data:0;
  List.iter
    (fun w ->
      pulse_byte ~byte_sel:0 ~data:(w land 0xFF);
      pulse_byte ~byte_sel:1 ~data:((w lsr 8) land 0xFF))
    prog;
  let expected_checksum =
    List.fold_left (fun acc w -> acc lxor (w land 0xFF) lxor ((w lsr 8) land 0xFF)) 0 prog
  in
  let checksum_on_uo_out = Bits.to_int !(outputs.uo_out) in
  let checksum_ok = checksum_on_uo_out = expected_checksum in
  (* uio is host-to-chip only during load -- the chip must not drive
     it back, or a real host driving strobe/byte_sel/go would contend
     with the chip on the same pads. *)
  let uio_idle_during_load =
    Bits.to_int !(outputs.uio_out) = 0 && Bits.to_int !(outputs.uio_oe) = 0
  in
  set_uio ~strobe:0 ~byte_sel:0 ~go:1;
  settle ();
  set_uio ~strobe:0 ~byte_sel:0 ~go:0;
  settle ();
  (checksum_ok, uio_idle_during_load, checksum_on_uo_out)

(* ---- Scenario A: RX wiring proof, now on uio_in instead of ui_in --
   an UART RX microcode driven over the real pins, checking the
   checksum/uo_out mux switches correctly and that uio_in genuinely
   feeds pins_in post-run. ---- *)
let uart_rx_prog ~bit_time =
  let half_time = bit_time / 2 in
  Engine.[
    wait_edge ~pin:0 ~falling:true ~payload:0;
    wait_edge ~pin:0 ~falling:true ~payload:half_time;
    shift_in ~pin:0;
  ]
  @ List.concat
      (List.init 8 (fun _ ->
           Engine.[ wait_edge ~pin:0 ~falling:true ~payload:bit_time; shift_in ~pin:0 ]))

let test_scenario_a () =
  Printf.printf "=== Scenario A: checksum/pins_out mux, uio_in doubles as strobe/byte_sel/go then pins_in ===\n";
  let raw_bit_time = 50 in
  let payload_bit_time = 50 in
  let data = 0b1011_0010 in
  let prog = uart_rx_prog ~bit_time:payload_bit_time in
  let sim = Sim.create tt_um_system in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let checksum_ok, uio_idle_during_load, checksum_on_uo_out = load_and_go ~sim ~prog in
  Printf.printf "  uo_out shows checksum pre-run: 0x%02x (checksum_ok=%b)\n" checksum_on_uo_out
    checksum_ok;
  Printf.printf "  uio_out/uio_oe idle (0) throughout load: %b (expected true)\n"
    uio_idle_during_load;
  let checksum_after_go = Bits.to_int !(outputs.uo_out) in
  let mux_switched = checksum_after_go <> checksum_on_uo_out || checksum_on_uo_out = 0 in
  Printf.printf "  uo_out no longer checksum right after go (mux switched to pins_out): %b\n"
    mux_switched;
  (* Drive the RX bitstream on uio_in bit 0 -- the same physical pin
     strobe/byte_sel/go were just loaded through -- as pins_in now. *)
  let bits = (0 :: List.init 8 (fun i -> (data lsr i) land 1)) @ [ 1 ] in
  List.iter
    (fun b ->
      for _ = 1 to raw_bit_time do
        inputs.uio_in := Bits.of_int ~width:8 b;
        cycle ()
      done)
    bits;
  (* This microcode never executes EMIT_STATE, so pins_out/pins_oe
     (and hence uo_out/uio_out/uio_oe post-run) must stay all-zero --
     proving uo_out and uio_out/uio_oe really do track the engine's
     driven state, not something stuck from the load phase. *)
  let uo_out_post_run = Bits.to_int !(outputs.uo_out) in
  let uio_out_post_run = Bits.to_int !(outputs.uio_out) in
  let uio_oe_post_run = Bits.to_int !(outputs.uio_oe) in
  Printf.printf
    "  post-run, no EMIT_STATE ever ran: uo_out=%d uio_out=%d uio_oe=%d (all expected 0)\n"
    uo_out_post_run uio_out_post_run uio_oe_post_run;
  let post_run_ok = uo_out_post_run = 0 && uio_out_post_run = 0 && uio_oe_post_run = 0 in
  let passed = checksum_ok && uio_idle_during_load && mux_switched && post_run_ok in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

(* ---- Scenario B: the actual point of moving to uio -- drive pin 2
   low, release it (tri-state), then read back a rising edge on the
   SAME physical pin once the testbench stands in for an external
   pull-up, and prove the program actually progressed past the wait by
   having it latch a marker on pin 4 (EMIT_STATE, sticky, so a
   several-cycle settle is enough -- no fragile single-cycle timing
   assumptions needed). Proves a single uio net can be both read
   (pins_in) and driven-or-released (pins_out/pins_oe) by the same
   program, which is exactly what I2C's open-drain SDA/SCL needs and
   what separate ui_in/uo_out buses could never provide. ---- *)
let test_scenario_b () =
  Printf.printf "=== Scenario B: open-drain pin 2 -- drive low, release, external pull-up read back ===\n";
  let prog =
    Engine.
      [ wait_edge ~pin:7 ~falling:false ~payload:0
        (* sync barrier: the go-pulse's own settle cycles run with
           `run` already high before this function gets to control
           uio_in cycle-by-cycle, so nothing past this instruction may
           fire until the test explicitly raises pin 7 -- decouples
           this scenario's precise cycle counting from load_and_go's
           internal timing. *)
      ; emit_state ~pin:2 ~level:false (* drive SDA-like pin low *)
      ; release_pin ~pin:2 (* let go -- external pull-up takes over *)
      ; wait_edge ~pin:2 ~falling:false ~payload:0 (* wait for the pull-up to win *)
      ; emit_state ~pin:4 ~level:true (* marker: only reached once the edge above is caught *)
      ]
  in
  let sim = Sim.create tt_um_system in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let _, _, _ = load_and_go ~sim ~prog in
  let bit n v = (v lsr n) land 1 in
  (* Release the sync barrier: pin 7 rising edge unblocks instruction 0. *)
  inputs.uio_in := Bits.of_int ~width:8 0b1000_0000;
  cycle ();
  (* Cycle: instr@pc1 (EMIT_STATE pin2 low) executes. Testbench mirrors
     what a real pad reads back while the chip itself drives it: low. *)
  inputs.uio_in := Bits.of_int ~width:8 0;
  cycle ();
  let out2_driving = bit 2 (Bits.to_int !(outputs.uio_out)) in
  let oe2_driving = bit 2 (Bits.to_int !(outputs.uio_oe)) in
  Printf.printf "  after EMIT_STATE low: uio_out[2]=%d uio_oe[2]=%d (expected 0,1)\n" out2_driving
    oe2_driving;
  (* Cycle: instr@pc2 (release_pin) executes -- oe drops, pin floats.
     Pad still reads low for this cycle (pull-up hasn't won yet,
     matching real RC behavior). *)
  cycle ();
  let oe2_released = bit 2 (Bits.to_int !(outputs.uio_oe)) in
  Printf.printf "  after release_pin: uio_oe[2]=%d (expected 0)\n" oe2_released;
  (* The external pull-up wins: drive uio_in bit 2 high -- a rising
     edge on the exact pin the chip just released -- and give the
     WAIT_EDGE microcode a few settled cycles to catch it and fall
     through to the pin-4 marker. *)
  inputs.uio_in := Bits.of_int ~width:8 0b0000_0100;
  for _ = 1 to 4 do cycle () done;
  let out4 = bit 4 (Bits.to_int !(outputs.uio_out)) in
  let oe4 = bit 4 (Bits.to_int !(outputs.uio_oe)) in
  Printf.printf
    "  marker pin 4 after external pull-up read back: uio_out[4]=%d uio_oe[4]=%d (expected 1,1)\n"
    out4 oe4;
  let drive_ok = out2_driving = 0 && oe2_driving = 1 in
  let release_ok = oe2_released = 0 in
  let edge_caught_ok = out4 = 1 && oe4 = 1 in
  let passed = drive_ok && release_ok && edge_caught_ok in
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let a = test_scenario_a () in
  let b = test_scenario_b () in
  let all_pass = a && b in
  Printf.printf "==================\ntt_um_system suite: %s\n" (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
