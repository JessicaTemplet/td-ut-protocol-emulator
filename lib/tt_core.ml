open Hardcaml
open Signal

(* ============================================================
   Tiny Tapeout I/O Signature
   ============================================================ *)
module I = struct
  type 'a t = {
    clk    : 'a;
    rst_n  : 'a;
    ena    : 'a;
    (* Part of the real tt_um contract (high when the TT harness's pin
       mux has this design selected) -- caught by LibreLane/tt_tool.py's
       port check when running roadmap item #3's synthesis pass ("port
       'ena' missing from top module"), not something any Cyclesim
       testbench could have caught since none of them go through the
       real tt_tool.py/LibreLane port-matching step. Deliberately left
       UNUSED here, same as most simple tt_um example projects: every
       one of our three top-level cores already fully gates its own
       activity on `run`/`go` (parked at pc=0 until the host loads a
       program), so there is no separate behavior to gate on `ena` --
       adding it only satisfies the port contract, it doesn't change
       any design behavior. *)
    ui_in  : 'a; [@bits 8]
    uio_in : 'a; [@bits 8]
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    uo_out  : 'a; [@bits 8]
    uio_out : 'a; [@bits 8]
    uio_oe  : 'a; [@bits 8]
  } [@@deriving sexp_of, hardcaml]
end

(* ============================================================
   Core-0 : UART RX with Down-Counter Phase Anchoring
   ============================================================
   ui_in[0]  = RX pin
   uio_in    = full bit period (in clock cycles)
   uo_out[0] = sample pulse
   uo_out[1] = busy
   uo_out[2] = start detected (sticky)

   Down-counter semantics: `counter` holds "cycles remaining until the
   next sample point". It is loaded with (N - 1) so that it reaches 0
   exactly N cycles after loading, and the reload for the *next*
   period happens on the very same cycle it expires (not the cycle
   after) -- this is what keeps successive sample points exactly
   bit_time apart with no drift.

   Day-1 version had two related bugs:
     1. The Half-bit state left unconditionally after one cycle
        instead of waiting for the counter to actually count down,
        so the first sample fired far too early.
     2. Reload was gated on `counter == 0` one cycle *after* expiry
        (a separate "0" dwell cycle), adding a spurious +1 cycle to
        every period. Both are fixed by loading/expiring on the same
        cycle as above.
   ============================================================ *)
let tt_um_logic (inputs : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:inputs.clk ~clear:((~:) inputs.rst_n) () in

  (* ---- Inputs ---- *)
  let rx        = select inputs.ui_in 0 0 in
  let bit_time  = concat_msb [ zero 8; inputs.uio_in ] in
  let half_time = srl bit_time 1 in

  (* ---- Edge detection ---- *)
  let rx_d    = reg spec rx in
  let falling = (~: rx) &&: rx_d in

  (* ---- Wires for feedback ---- *)
  let running = wire 1 in
  let counter = wire 16 in
  let bit_idx = wire 4 in
  (* bit_idx: 0 = start-bit verify sample, 1..8 = data bit0..7 samples *)

  (* Only a falling edge seen while idle starts a new frame -- a
     falling edge on a mid-frame data bit (e.g. 1 -> 0) must NOT
     reset framing while we're already running. *)
  let start_edge = falling &&: (~: running) in

  let counter_expired = counter ==: zero 16 in
  let last_bit         = bit_idx ==:. 8 in
  let frame_done        = running &&: counter_expired &&: last_bit in
  let advance_to_next   = running &&: counter_expired &&: (~: last_bit) in

  running <==
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun r ->
      mux2 start_edge (one 1) (mux2 frame_done (zero 1) r));

  counter <==
    reg_fb ~enable:(one 1) spec ~width:16 ~f:(fun c ->
      mux2 start_edge (half_time -:. 1)
        (mux2 advance_to_next (bit_time -:. 1)
           (mux2 counter_expired c (c -:. 1))));

  bit_idx <==
    reg_fb ~enable:(one 1) spec ~width:4 ~f:(fun idx ->
      mux2 start_edge (zero 4)
        (mux2 advance_to_next (idx +:. 1) idx));

  (* ---- Outputs ---- *)
  let sample_pulse = running &&: counter_expired in
  let busy         = running in
  let start_seen   = reg spec ~enable:start_edge (one 1) in

  {
    O.uo_out = concat_msb [ zero 5; start_seen; busy; sample_pulse ];
    uio_out  = zero 8;
    uio_oe   = zero 8;
  }

(* ============================================================
   tt_um_system : the actual reprogrammable core (System) wrapped
   onto real tt_um pins -- this is the wiring the project log calls
   "still open decision #1's follow-on" / "needed before this can
   generate real Tiny Tapeout Verilog for the reprogrammable core".
   `tt_um_logic` above is untouched (still the tested hardwired
   proof-of-concept core, still what test_main.ml exercises).

   Pin mapping -- changed this session to close the OTHER half of open
   decision #1 (the bidirectional-pin gap the project log flagged: "no
   true single-wire bidirectional pin... can't do I2C SDA without
   external wiring"). Engine's 8-pin bus now routes through uio, the
   only tt_um pin group that's genuinely bidirectional per-pin
   (uio_in to read, uio_out/uio_oe to drive-or-release) -- ui_in is
   input-only and uo_out is output-only, so neither can tri-state:
     ui_in[7:0]  -> System.data_in ONLY (no longer also pins_in --
                    that reuse is superseded by the uio move below).
     uio_in[0]   -> strobe (pre-run) / pins_in bit 0 (post-run)
     uio_in[1]   -> byte_sel (pre-run) / pins_in bit 1 (post-run)
     uio_in[2]   -> go (pre-run) / pins_in bit 2 (post-run)
     uio_in[7:3] -> unused pre-run / pins_in bits 3-7 post-run
                    Same "reuse what's already there" pattern the
                    project log already established for ui_in's
                    data_in/pins_in double-duty -- these bits are
                    loader-control before `run` latches and ordinary
                    protocol input after, never both at once (Engine
                    is parked at pc=0, not reading pins_in, until
                    `run`=1).
     uio_out[7:0], uio_oe[7:0] -> Engine's pins_out/pins_oe once
                    `run`=1, else forced to 0. The `run`=0 side isn't
                    just "nothing to show yet" -- it's load-side event
                    (registers reset to 0 and Engine.O.pins_oe never
                    updates while `run`=0 anyway, see engine.ml), but
                    forcing it explicitly here is the same defensive
                    pattern the uo_out mux below already uses, and
                    documents the real requirement: the chip must NOT
                    drive uio while the host is driving uio_in for
                    strobe/byte_sel/go, or the two would contend on
                    the same physical pads.
     uo_out[7:0] -> unchanged: pins_out once `run`=1 (now a pure debug
                    mirror of what the core WOULD drive on uio, since
                    uio_out/uio_oe above are the real bidirectional
                    signaling -- uo_out is always chip-driven so it can
                    show this for free, e.g. for an external logic
                    analyzer, without disturbing an open-drain bus);
                    loader.ml's `checksum` while `run`=0, unchanged
                    from before.
   ============================================================ *)
(* `system_create` selects System.create (behavioral, what
   test_tt_um_system.ml simulates) or System.create_asic (real hard
   macro, what main.ml's tapeout Verilog generation uses). *)
let tt_um_system_generic ~system_create (inputs : Signal.t I.t) =
  let sys_out =
    system_create
      { System.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; pins_in = inputs.uio_in
      ; data_in = inputs.ui_in
      ; strobe = select inputs.uio_in 0 0
      ; byte_sel = select inputs.uio_in 1 1
      ; go = select inputs.uio_in 2 2
      }
  in
  { O.uo_out = mux2 sys_out.System.O.run sys_out.System.O.pins_out sys_out.System.O.checksum
  ; uio_out = mux2 sys_out.System.O.run sys_out.System.O.pins_out (zero 8)
  ; uio_oe = mux2 sys_out.System.O.run sys_out.System.O.pins_oe (zero 8)
  }

let tt_um_system (inputs : Signal.t I.t) =
  tt_um_system_generic ~system_create:System.create inputs

(* Real hard-macro instruction memory -- what main.ml actually
   generates tt_um_system.v from. Not Cyclesim-testable, same
   structural limitation as Engine.create_asic; see engine.ml. *)
let tt_um_system_asic (inputs : Signal.t I.t) =
  tt_um_system_generic ~system_create:System.create_asic inputs

(* ============================================================
   tt_um_dual : the dual-engine core (Dual: µE0 + shadow FIFO + µE1)
   wrapped onto real tt_um pins via dual_loader.ml -- this is roadmap
   item #2 ("decide RAM-sharing for the dual-engine core, then wire
   its load path onto real tt_um pins"). RAM-sharing was resolved in
   design_rationale.txt's Deviations section: separate single-port
   memories per engine, which is already what engine.ml/
   protocol_engine.ml do, so no RTL change was needed there -- this
   wrapper is the actual "wire it onto real pins" half of the item.

   tt_um_system (single-engine) is untouched and stays as the tested
   fallback, same "add the new path next to the working one" pattern
   already used for tt_um_logic/tt_um_system.

   Pin mapping -- same "reuse what's already there, pre-run vs.
   post-run" discipline tt_um_system established, with one new bit:
     ui_in[7:0]  -> Dual_loader.data_in ONLY (never pins_in -- see
                    below, pins_in now lives entirely on uio_in,
                    exactly like tt_um_system).
     uio_in[0]   -> strobe     (pre-run) / pins_in bit 0 (post-run)
     uio_in[1]   -> byte_sel   (pre-run) / pins_in bit 1 (post-run)
     uio_in[2]   -> go         (pre-run) / pins_in bit 2 (post-run)
     uio_in[3]   -> engine_sel (pre-run) / pins_in bit 3 (post-run)
     uio_in[4]   -> cfg_sel    (pre-run) / pins_in bit 4 (post-run): while
                    high, a strobe writes a BIT-PIPE / GLITCH-FILTER
                    configuration byte (auto-incrementing profile-table
                    index 0..127, see profile_table.ml) instead of a
                    program word
     uio_in[7:5] -> unused pre-run / pins_in bits 5-7 post-run
                    engine_sel costs zero new physical pins by the
                    same double-duty argument tt_um_system already
                    uses for strobe/byte_sel/go -- it's load-control
                    before `run` latches, ordinary protocol input
                    after, never both (Dual's engines are parked at
                    pc=0 until `run`=1, same guarantee Engine/System
                    already give).
     uio_out[7:0], uio_oe[7:0] -> the two engines' pins_out/pins_oe
                    buses COMBINED per pin (see below), once `run`=1;
                    forced to 0 while `run`=0, same anti-contention
                    reasoning as tt_um_system.
     uo_out[7:0] -> combined pins_out mirror once `run`=1 (debug
                    view, same role as tt_um_system's); loader's
                    `checksum` while `run`=0.

   Per-pin output arbitration (genuinely new versus tt_um_system,
   which only ever had one engine's outputs to place): µE0 and µE1
   each drive their own independent 8-wide pins_out/pins_oe (Dual
   deliberately keeps these separate -- see dual.ml's header comment,
   "deciding which physical pins each engine actually owns... is a
   pin-mapping decision for whoever writes the first real dual-engine
   protocol microcode"). Only one physical 8-bit uio bus exists on
   the real chip, so those two buses must combine onto it somehow.
   Policy adopted here, per pin: OR the two engines' output-enables
   (a pin is driven if EITHER engine drives it), and on a pin both
   claim, µE1/protocol wins the value -- it's the response/packet
   layer, so in practice it's finalizing a value µE0 already
   sampled/started (e.g. an ACK driven back on the same line µE0
   reads), making "protocol's value wins" the more sensible default
   than an arbitrary tie-break. This is a real, documented ASSUMPTION,
   not a proven-correct arbitration scheme -- it is expected to be
   revisited once real SPI/I2C microcode (roadmap item #4) actually
   exercises which engine drives which pin and when; nothing today
   tests two engines contending for the same pin on purpose.
   ============================================================ *)
(* `dual_create` selects Dual.create (behavioral, what
   test_tt_um_dual.ml simulates) or Dual.create_asic (real hard macro
   pair, what main.ml's tapeout Verilog generation uses). *)
let tt_um_dual_generic ~dual_create (inputs : Signal.t I.t) =
  let loader_out =
    Dual_loader.create
      { Dual_loader.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; data_in = inputs.ui_in
      ; strobe = select inputs.uio_in 0 0
      ; byte_sel = select inputs.uio_in 1 1
      ; go = select inputs.uio_in 2 2
      ; engine_sel = select inputs.uio_in 3 3
      ; cfg_sel = select inputs.uio_in 4 4
      }
  in
  let looped_pins = wire 8 in
  let dual_out =
    dual_create
      { Dual.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; pins_in = looped_pins
      ; prescale = loader_out.Dual_loader.O.prescale
      ; run = loader_out.Dual_loader.O.run
      ; protocol_run = loader_out.Dual_loader.O.run
      ; phys_write_enable = loader_out.Dual_loader.O.phys_write_enable
      ; phys_write_addr = loader_out.Dual_loader.O.phys_write_addr
      ; phys_write_data = loader_out.Dual_loader.O.write_data
      ; protocol_write_enable = loader_out.Dual_loader.O.protocol_write_enable
      ; protocol_write_addr = loader_out.Dual_loader.O.protocol_write_addr
      ; protocol_write_data = loader_out.Dual_loader.O.write_data
      ; cfg_we = loader_out.Dual_loader.O.cfg_we
      ; cfg_addr = loader_out.Dual_loader.O.cfg_addr
      ; cfg_data = loader_out.Dual_loader.O.cfg_data
      }
  in
  let combine_bit i =
    let p_oe = select dual_out.Dual.O.protocol_pins_oe i i in
    let p_out = select dual_out.Dual.O.protocol_pins_out i i in
    let e_oe = select dual_out.Dual.O.phys_pins_oe i i in
    let e_out = select dual_out.Dual.O.phys_pins_out i i in
    (p_oe |: e_oe, mux2 p_oe p_out e_out)
  in
  let bits = List.init 8 (fun i -> combine_bit (7 - i)) in
  let combined_oe = concat_msb (List.map fst bits) in
  let combined_out = concat_msb (List.map snd bits) in
  (* Internal loopback (profile_table.ml's loopback mask): on a masked pin
     the engines read the chip's own output instead of the pad, and the pad
     is not driven, so a self-test needs nothing attached and cannot fight
     whatever is. A released (oe=0) masked pin reads high, like a pulled-up
     open-drain bus. The looped level still goes through Dual's input
     synchronizer, so it arrives with the same latency as an external pin. *)
  let mask = dual_out.Dual.O.loopback in
  let own_level = combined_out |: (~:combined_oe) in
  looped_pins <== ((inputs.uio_in &: (~:mask)) |: (own_level &: mask));
  { O.uo_out = mux2 loader_out.Dual_loader.O.run combined_out loader_out.Dual_loader.O.checksum
  ; uio_out = mux2 loader_out.Dual_loader.O.run combined_out (zero 8)
  ; uio_oe = mux2 loader_out.Dual_loader.O.run (combined_oe &: (~:mask)) (zero 8)
  }

let tt_um_dual (inputs : Signal.t I.t) =
  tt_um_dual_generic ~dual_create:Dual.create inputs

(* Real hard-macro instruction memory pair -- what main.ml actually
   generates tt_um_dual.v from. Not Cyclesim-testable, same structural
   limitation as Engine.create_asic; see engine.ml. *)
let tt_um_dual_asic (inputs : Signal.t I.t) =
  tt_um_dual_generic ~dual_create:Dual.create_asic inputs

(* Re-export sibling modules so they are reachable as Tt_core.<Name>
   -- dune only auto-generates that aliasing when no file in the
   library shares the library name; tt_core.ml does, so it has to be
   done explicitly. *)
module Timer = Timer
module Engine = Engine
module Loader = Loader
module System = System
module Shadow_fifo = Shadow_fifo
module Protocol_engine = Protocol_engine
module Dual = Dual
module Dual_loader = Dual_loader
module Bitpipe = Bitpipe
module Txpipe = Txpipe
module Clock_recovery = Clock_recovery
module Profile_table = Profile_table
module Glitch_filter = Glitch_filter
module Halt_guard = Halt_guard
