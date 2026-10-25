open Hardcaml
open Signal

(* ============================================================
   The actual dual-engine architecture: µE0 (engine.ml, physical
   layer) streaming assembled bytes through shadow_fifo.ml into µE1
   (protocol_engine.ml), with real hardware backpressure -- this is
   the novelty claim the design blueprint and docs/design/design_rationale.txt describe, and
   what the earlier `system.ml`/`tt_um_system` single-engine path
   deliberately does NOT attempt (see system.ml's own header comment).

   Wiring, matching the design blueprint's own diagram exactly:
     µE0.byte_ready/byte_data --push/push_data--> shadow_fifo
     shadow_fifo.full         --push_stall-->     µE0
     shadow_fifo.pop_data/empty --fifo_pop_data/fifo_empty--> µE1
     µE1.fifo_pop              --pop-->            shadow_fifo
   `byte_data` (8 bits) widens into the FIFO's 16-bit word with zero
   in the high byte -- the FIFO is generic and 16-bit-wide (matching
   the instruction word width, and headroom for future 16-bit
   payloads).

   µE0 has TWO independent push sources now (this session): the
   original byte-relay path (`byte_ready`/`byte_data`, SHIFT_IO mode=0)
   and the new CAPTURE path (`capture_ready`/`capture_data`, SHIFT_IO
   mode=1 -- see engine.ml's module header). They share ONE physical
   push port into the same shadow FIFO rather than needing a second
   FIFO: a single instruction is always either a normal push or a
   capture, never both (mode is one bit), and both are registered with
   the identical pc-aligned latency, so `byte_ready`/`capture_ready`
   stay mutually exclusive after registration too -- ORing them for
   `push` and muxing the data by which one fired is safe, not a race.
   `push_stall` (wired from the FIFO's `full`) already covers both,
   since engine.ml's own `would_push`/`shift_advance_ok` gates a
   CAPTURE on backpressure the same way it already gated a pushing
   SHIFT_IO. µE1 needs no changes at all to receive capture records --
   it already pops arbitrary 16-bit FIFO words with FIFO_POP and can
   inspect them with BRANCH_COND_WORD exactly as it does byte-relay
   words.

   Both engines' program RAMs are loaded via their own direct write
   ports here (the same shortcut test_engine.ml/test_protocol_engine.ml
   already use), not through loader.ml's byte-serial protocol --
   wiring a single host-facing load path for BOTH programs (and
   deciding whether they share one physical RAM macro, per the design
   blueprint's gate-budget table, or use two) is real, separate,
   follow-on work, same "test the mechanism before wiring the host
   protocol into it" order engine.ml/system.ml already followed.

   Pin buses: `pins_in` is shared -- both engines can read the same
   external pins (µE1's BRANCH_PIN is the design blueprint's "Raw Pin
   Bypass Access", reading the SAME pins µE0 also samples, not a
   separate bus). Output pins are kept SEPARATE per engine
   (`phys_pins_out/oe` from µE0, `protocol_pins_out/oe` from µE1) --
   deciding which physical pins each engine actually owns on a real
   chip is a pin-mapping decision for whoever writes the first real
   dual-engine protocol microcode (SPI/I2C), not something to guess at
   here.

   `run`/`protocol_run` are SEPARATE, one per engine, not a single
   shared enable -- this matters for more than just staged bring-up
   (mirroring the single-engine path's host-controlled `run` latch):
   without independent control, there is no way to actually exercise
   backpressure in simulation. µE1 pops a word in 1 cycle; µE0 takes 8
   cycles to assemble one. If both engines always ran in lockstep, µE1
   would drain every byte the moment it existed and the shadow FIFO
   would never reach `full` -- the whole backpressure mechanism would
   sit untested. A real host has the same problem in reverse (it needs
   to bring µE0 up before µE1's program is even loaded), so this
   isn't purely a testability hack -- see test_dual.ml, which pauses
   µE1 deliberately to prove µE0 actually stalls, not just races
   through unopposed.

   Transmit direction (the receive path reversed): µE1's TX_PUSH /
   TX_ECHO push bytes into a SECOND Shadow_fifo instance, and µE0's
   transmit pipe (txpipe.ml, driven by EMIT_TX) pops them. Same FIFO
   module, so the formal proof and the bounded-exhaustive check on
   Shadow_fifo cover this instance unchanged.

   The bit-pipe configuration lives in the profile table
   (profile_table.ml), written by the loader (`cfg_we`/`cfg_addr`/
   `cfg_data`, pre-run) and by µE1's CFG_WR (post-run). µE0's PIPE_CTRL
   and µE1's PROFILE move the RX and TX pointers.
   ============================================================ *)
module I = struct
  type 'a t = {
    clk                   : 'a;
    rst_n                 : 'a;
    pins_in               : 'a; [@bits 8]
    prescale              : 'a; [@bits 8]
    run                   : 'a;
    protocol_run          : 'a;
    phys_write_enable     : 'a;
    phys_write_addr       : 'a; [@bits 9]
    phys_write_data       : 'a; [@bits 16]
    protocol_write_enable : 'a;
    protocol_write_addr   : 'a; [@bits 9]
    protocol_write_data   : 'a; [@bits 16]
    cfg_we                : 'a;
    cfg_addr              : 'a; [@bits 7]
    cfg_data              : 'a; [@bits 8]
    trace_pop0            : 'a; (* pop µE0's / µE1's Shadow trace FIFO *)
    trace_pop1            : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    phys_pc           : 'a; [@bits 9]
    phys_halted       : 'a;
    protocol_halted   : 'a;
    phys_pins_out      : 'a; [@bits 8]
    phys_pins_oe       : 'a; [@bits 8]
    protocol_pc        : 'a; [@bits 9]
    protocol_pins_out  : 'a; [@bits 8]
    protocol_pins_oe   : 'a; [@bits 8]
    rx_word            : 'a; [@bits 16]
    fifo_full          : 'a;
    fifo_empty         : 'a;
    tx_fifo_full       : 'a;
    tx_fifo_empty      : 'a;
    rx_profile         : 'a; [@bits 2]
    tx_profile         : 'a; [@bits 2]
    loopback           : 'a; [@bits 8]
    shadow_mode        : 'a; [@bits 8]
    trace0_head        : 'a; [@bits 64] (* oldest record, valid while count > 0 *)
    trace0_count       : 'a; [@bits 3]
    trace1_head        : 'a; [@bits 64]
    trace1_count       : 'a; [@bits 3]
  } [@@deriving sexp_of, hardcaml]
end

(* `engine_create`/`protocol_create` select the behavioral pair
   (Engine.create/Protocol_engine.create -- what test_dual.ml/
   test_tt_um_dual.ml simulate) or the real-hard-macro pair
   (Engine.create_asic/Protocol_engine.create_asic -- what main.ml's
   tapeout Verilog generation uses). See engine.ml's module header for
   why these can't be the same functions (Cyclesim can't simulate
   through the hard-macro path). *)
(* Cycles from a level change on `pins_in` to the first cycle either engine
   can see it (the input synchronizer below). Testbenches that drive pins
   on exact cycles use this instead of a literal. *)
let sync_latency = 2

let create_generic ~engine_create ~protocol_create (inputs : Signal.t I.t) =
  let push_stall = wire 1 in
  let e0_sel_rx = wire 1 and e0_sel_tx = wire 1 and e0_sel_id = wire 2 in
  let e1_sel_rx = wire 1 and e1_sel_tx = wire 1 and e1_sel_id = wire 2 in
  let rt_we = wire 1 and rt_addr = wire 7 and rt_data = wire 8 in
  let table =
    Profile_table.create
      { Profile_table.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; load_we = inputs.cfg_we
      ; load_addr = inputs.cfg_addr
      ; load_data = inputs.cfg_data
      ; rt_we
      ; rt_addr
      ; rt_data
      ; e0_sel_rx
      ; e0_sel_tx
      ; e0_sel_id
      ; e1_sel_rx
      ; e1_sel_tx
      ; e1_sel_id
      }
  in
  (* Two-flop synchronizer on every input pin, ahead of everything else.
     The pins are asynchronous to clk, and one sampled level fans out to
     many flops in the same cycle (edge detect, the branch decision that
     picks the next pc, the shift register, the bit pipe). Unsynchronized,
     an edge landing near a clock edge could be seen by some of those flops
     and not others -- e.g. a branch whose pc bits disagree on taken/not
     taken. Same 2-FF pattern dual_loader.ml uses for strobe/go. Costs two
     cycles of input latency, identical for every pin and for loopback. *)
  let sync_spec = Reg_spec.create ~clock:inputs.clk ~clear:((~:) inputs.rst_n) () in
  let pins_sync = reg sync_spec (reg sync_spec inputs.pins_in) in
  (* Per-pin glitch filter on the shared pin bus, configured by profile 0
     byte 1 bits [7:4] (0 = bypass, so invisible unless a program's config
     asks for it). Both engines see the filtered pins. *)
  let pins_in =
    (Glitch_filter.create
       { Glitch_filter.I.clk = inputs.clk
       ; rst_n = inputs.rst_n
       ; run = inputs.run
       ; pins_in = pins_sync
       ; n = table.Profile_table.O.glitch_n
       }).Glitch_filter.O.pins_out
  in
  let tx_push = wire 1 and tx_push_data = wire 16 and tx_pop = wire 1 in
  let tx_fifo =
    Shadow_fifo.create
      { Shadow_fifo.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; push = tx_push
      ; push_data = tx_push_data
      ; pop = tx_pop
      }
  in
  let protocol_crc_init = wire 1 in
  let engine_out =
    engine_create
      { Engine.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; pins_in
      ; rx_cfg = table.Profile_table.O.rx_cfg
      ; tx_cfg = table.Profile_table.O.tx_cfg
      ; tx_fifo_data = tx_fifo.Shadow_fifo.O.pop_data
      ; tx_fifo_empty = tx_fifo.Shadow_fifo.O.empty
      ; ext_rx_crc_init = protocol_crc_init
      ; profile_settling =
          Profile_table.settling sync_spec
            (e0_sel_rx |: e0_sel_tx |: e1_sel_rx |: e1_sel_tx)
      ; prescale = inputs.prescale
      ; run = inputs.run
      ; write_enable = inputs.phys_write_enable
      ; write_addr = inputs.phys_write_addr
      ; write_data = inputs.phys_write_data
      ; push_stall
      }
  in
  tx_pop <== engine_out.Engine.O.tx_fifo_pop;
  e0_sel_rx <== engine_out.Engine.O.sel_rx;
  e0_sel_tx <== engine_out.Engine.O.sel_tx;
  e0_sel_id <== engine_out.Engine.O.sel_id;

  let fifo_pop_req = wire 1 in
  (* Two mutually-exclusive push sources (byte-relay, capture) share one
     physical push port -- see the module-header note above. *)
  let push = engine_out.Engine.O.byte_ready ||: engine_out.Engine.O.capture_ready in
  let push_data =
    mux2 engine_out.Engine.O.capture_ready
      engine_out.Engine.O.capture_data
      (concat_msb [ zero 8; engine_out.Engine.O.byte_data ])
  in
  let fifo_out =
    Shadow_fifo.create
      { Shadow_fifo.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; push
      ; push_data
      ; pop = fifo_pop_req
      }
  in
  push_stall <== fifo_out.Shadow_fifo.O.full;

  let protocol_out =
    protocol_create
      { Protocol_engine.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; pins_in
      ; run = inputs.protocol_run
      ; write_enable = inputs.protocol_write_enable
      ; write_addr = inputs.protocol_write_addr
      ; write_data = inputs.protocol_write_data
      ; fifo_pop_data = fifo_out.Shadow_fifo.O.pop_data
      ; fifo_empty = fifo_out.Shadow_fifo.O.empty
      ; tx_fifo_full = tx_fifo.Shadow_fifo.O.full
      }
  in
  fifo_pop_req <== protocol_out.Protocol_engine.O.fifo_pop;
  tx_push <== protocol_out.Protocol_engine.O.tx_push;
  tx_push_data <== protocol_out.Protocol_engine.O.tx_data;
  rt_we <== protocol_out.Protocol_engine.O.cfg_we;
  rt_addr <== protocol_out.Protocol_engine.O.cfg_addr;
  rt_data <== protocol_out.Protocol_engine.O.cfg_data;
  e1_sel_rx <== protocol_out.Protocol_engine.O.sel_rx;
  e1_sel_tx <== protocol_out.Protocol_engine.O.sel_tx;
  e1_sel_id <== protocol_out.Protocol_engine.O.sel_id;
  protocol_crc_init <== protocol_out.Protocol_engine.O.rx_crc_init;

  (* Shadow (shadow.ml). One timestamp for both engines, zero until run and
     counting from its rise: both trace streams share that epoch by
     construction, so the host merges them by timestamp. Each engine has its
     own comparator and its own 4 x 64 trace FIFO; a full FIFO drops, never
     stalls. In Shadow an engine's pads are released (its output enables
     masked here), so its pins_out/pins_oe registers are a claim only. *)
  let mode = table.Profile_table.O.shadow_mode in
  let mbit m = (mode &: of_int ~width:8 m) <>:. 0 in
  let e0_shadow = mbit Profile_table.mode_e0_shadow in
  let e1_shadow = mbit Profile_table.mode_e1_shadow in
  let timestamp =
    reg_fb ~enable:(one 1) sync_spec ~width:32 ~f:(fun cur ->
      mux2 inputs.run (cur +:. 1) (zero 32))
  in
  let trace ~enable ~settle ~claim ~claim_pc ~pins_out ~pins_oe ~pop =
    let push = wire 1 and record = wire Shadow.record_bits in
    let head, _, full, count =
      Shadow_fifo.create_sized ~depth:4 ~ptr_width:2 ~clk:inputs.clk ~rst_n:inputs.rst_n ~push
        ~push_data:record ~pop
    in
    let s =
      Shadow.create
        { Shadow.I.clk = inputs.clk
        ; rst_n = inputs.rst_n
        ; enable = enable &: inputs.run
        ; settle
        ; claim
        ; claim_pc
        ; pins_in
        ; pins_out
        ; pins_oe
        ; timestamp
        ; full
        }
    in
    push <== s.Shadow.O.push;
    record <== s.Shadow.O.record;
    (head, count)
  in
  let trace0_head, trace0_count =
    trace
      ~enable:(e0_shadow |: mbit Profile_table.mode_e0_check)
      ~settle:table.Profile_table.O.e0_settle ~claim:engine_out.Engine.O.emit_claim
      ~claim_pc:engine_out.Engine.O.claim_pc ~pins_out:engine_out.Engine.O.pins_out
      ~pins_oe:engine_out.Engine.O.pins_oe ~pop:inputs.trace_pop0
  in
  let trace1_head, trace1_count =
    trace
      ~enable:(e1_shadow |: mbit Profile_table.mode_e1_check)
      ~settle:table.Profile_table.O.e1_settle ~claim:protocol_out.Protocol_engine.O.emit_claim
      ~claim_pc:protocol_out.Protocol_engine.O.claim_pc
      ~pins_out:protocol_out.Protocol_engine.O.pins_out
      ~pins_oe:protocol_out.Protocol_engine.O.pins_oe ~pop:inputs.trace_pop1
  in

  { O.phys_pc = engine_out.Engine.O.pc
  ; phys_halted = engine_out.Engine.O.halted
  ; protocol_halted = protocol_out.Protocol_engine.O.halted
  ; phys_pins_out = engine_out.Engine.O.pins_out
  ; phys_pins_oe = engine_out.Engine.O.pins_oe &: repeat (~:e0_shadow) 8
  ; protocol_pc = protocol_out.Protocol_engine.O.pc
  ; protocol_pins_out = protocol_out.Protocol_engine.O.pins_out
  ; protocol_pins_oe = protocol_out.Protocol_engine.O.pins_oe &: repeat (~:e1_shadow) 8
  ; rx_word = protocol_out.Protocol_engine.O.rx_word
  ; fifo_full = fifo_out.Shadow_fifo.O.full
  ; fifo_empty = fifo_out.Shadow_fifo.O.empty
  ; tx_fifo_full = tx_fifo.Shadow_fifo.O.full
  ; tx_fifo_empty = tx_fifo.Shadow_fifo.O.empty
  ; rx_profile = table.Profile_table.O.rx_id
  ; tx_profile = table.Profile_table.O.tx_id
  ; loopback = table.Profile_table.O.loopback
  ; shadow_mode = mode
  ; trace0_head
  ; trace0_count
  ; trace1_head
  ; trace1_count
  }

let create (inputs : Signal.t I.t) =
  create_generic ~engine_create:Engine.create ~protocol_create:Protocol_engine.create inputs

let create_asic (inputs : Signal.t I.t) =
  create_generic ~engine_create:Engine.create_asic ~protocol_create:Protocol_engine.create_asic inputs
