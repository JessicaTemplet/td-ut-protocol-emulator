open Hardcaml

(* ============================================================
   Top-level glue: Loader's write port feeds Engine's instruction
   RAM, Loader's `run` output gates Engine's fetch/execute. This is
   the actual end-to-end path a real chip would use -- host talks
   only to Loader's pins (ui_in/uio_in-shaped), never touches
   Engine's RAM ports directly (test_engine.ml does that, but only
   as a shortcut to test the engine's execution logic in isolation
   from the load protocol).

   Not yet a full tt_um_logic: doesn't map onto real ui_in/uio_in/
   uo_out pins (that's main.ml's job). This just wires the two
   existing tested modules together for an end-to-end Cyclesim test.

   `prescale` is NOT a top-level input here -- Loader now owns it
   (the first byte-serial strobe after reset loads it, see
   loader.ml), so it comes from `loader_out.Loader.O.prescale`, same
   as `run`/`write_enable`/etc. already did. This is what makes
   Engine.I.prescale reachable from a real chip's pins at all: there
   was no other way to get an 8-bit config value in beyond the
   byte-serial protocol Loader already owns.

   This is the SINGLE-engine path: one Engine instance, no shadow
   FIFO, `push_stall` tied to 0 (nothing to ever back-pressure it).
   `dual.ml` is the actual dual-engine architecture (µE0 physical +
   shadow FIFO + µE1 protocol) the design blueprint's novelty claim is
   built on -- this module stays as its own tested, working,
   single-engine baseline alongside it, same "don't replace a working
   path, add the new one next to it" pattern `tt_um_logic`/
   `tt_um_system` already established.
   ============================================================ *)
module I = struct
  type 'a t = {
    clk      : 'a;
    rst_n    : 'a;
    pins_in  : 'a; [@bits 8]
    data_in  : 'a; [@bits 8]
    strobe   : 'a;
    byte_sel : 'a;
    go       : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    sample_pulse : 'a;
    sampled_bit  : 'a;
    pins_out     : 'a; [@bits 8]
    pins_oe      : 'a; [@bits 8]
    pc           : 'a; [@bits 9]
    checksum     : 'a; [@bits 8]
    run          : 'a;
  } [@@deriving sexp_of, hardcaml]
end

(* `engine_create` selects `Engine.create` (behavioral RAM, what
   test_system.ml/test_tt_um_system.ml simulate) or `Engine.create_asic`
   (real hard macro, what main.ml's tapeout Verilog generation uses) --
   see engine.ml's module header for why these can't be the same
   function (Cyclesim can't simulate through the hard-macro path). *)
let create_generic ~engine_create (inputs : Signal.t I.t) =
  let open Signal in
  let loader_out =
    Loader.create
      { Loader.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; data_in = inputs.data_in
      ; strobe = inputs.strobe
      ; byte_sel = inputs.byte_sel
      ; go = inputs.go
      }
  in
  let engine_out =
    engine_create
      { Engine.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; pins_in = inputs.pins_in
      ; prescale = loader_out.Loader.O.prescale
      ; run = loader_out.Loader.O.run
      ; write_enable = loader_out.Loader.O.write_enable
      ; write_addr = loader_out.Loader.O.write_addr
      ; write_data = loader_out.Loader.O.write_data
      ; push_stall = gnd (* single-engine path, no FIFO to stall on -- see dual.ml *)
      (* single-engine path: pipes unconfigured (all stages off), and no
         µE1 to feed the transmit pipe *)
      ; rx_cfg = zero Bitpipe.cfg_bits
      ; tx_cfg = zero Bitpipe.cfg_bits
      ; tx_fifo_data = zero 16
      ; tx_fifo_empty = vdd
      ; ext_rx_crc_init = gnd
      }
  in
  { O.sample_pulse = engine_out.Engine.O.sample_pulse
  ; sampled_bit = engine_out.Engine.O.sampled_bit
  ; pins_out = engine_out.Engine.O.pins_out
  ; pins_oe = engine_out.Engine.O.pins_oe
  ; pc = engine_out.Engine.O.pc
  ; checksum = loader_out.Loader.O.checksum
  ; run = loader_out.Loader.O.run
  }

let create (inputs : Signal.t I.t) = create_generic ~engine_create:Engine.create inputs
let create_asic (inputs : Signal.t I.t) = create_generic ~engine_create:Engine.create_asic inputs
