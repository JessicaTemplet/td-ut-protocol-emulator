open Hardcaml
open Signal

(* ============================================================
   ISA v0.3 engine slice: WAIT_EDGE + EMIT_STATE + SHIFT_IO +
   BRANCH_COND. Enough to run the UART RX microcode end-to-end
   against the already-validated prescaled Timer (reproducing the
   exact pulse timing of tt_core.ml's hand-written RTL), plus a
   program-defined loop point for protocols that need to drive
   pins and branch on a response (SPI/I2C), not just receive.

   16-bit instruction word: [15:14] opcode | [13:11] pin_sel (real
   1-of-8 pin select, decoded below -- this closes former open
   decision #1) | [10] mode | [9:0] payload.
   opcode 00 = WAIT_EDGE    (mode: 0=falling,1=rising; payload=timeout
               ticks, 0=wait forever for the edge)
   opcode 01 = EMIT_STATE   (single-cycle: drives the selected output
               pin to `mode`, always advances. payload bit 0 = release:
               0 (default -- every existing program encodes payload 0,
               so this is backward compatible) drives the pin as
               before; 1 tri-states it (pins_oe -> 0 for that pin,
               pins_out's value becomes a don't-care) instead of
               driving `mode`. This is what makes open-drain protocols
               possible: I2C SDA/SCL only ever drive low or release,
               relying on an external pull-up for the high level. See
               `release_pin` below and the pins_oe field on O.t.)
   opcode 10 = SHIFT_IO     (single-cycle, `mode` selects one of two
               unrelated behaviors -- `mode` was otherwise unused by
               this opcode, so this is a free bit, not a repurposed one:

               `mode`=0 (NORMAL, every pre-existing program encodes this):
               samples the selected pin into an 8-bit accumulator that
               shifts on every SHIFT_IO regardless of payload, advances.
               payload bit 0 = push: 0 (default, backward compatible)
               just accumulates; 1 additionally hands the accumulator's
               current contents (post-shift, i.e. including THIS cycle's
               sampled bit) to the physical-layer FIFO interface (see
               `byte_ready`/`byte_data` on O.t and `push_stall` on I.t
               below -- both are REGISTERED, so they read exactly like
               `pins_out`/`pins_oe`: valid the cycle AFTER the pushing
               instruction was AT the current pc, not the same cycle
               `pc` itself already shows having moved past it) --
               this is what makes Engine usable as µE0, the dual-
               engine architecture's physical/producer half: it
               streams assembled bytes to µE1 through a shadow FIFO
               instead of a program having to hand-assemble bytes
               itself. A microcode doesn't have to shift in exact
               multiples of 8 before pushing -- since the accumulator
               is a plain shift register, only its last 8 samples
               matter at push time, so e.g. the UART RX microcode's
               leading start-bit-verify shift naturally falls off once
               8 more real data-bit shifts follow it. If `push_stall`
               is high exactly when a pushing SHIFT_IO would fire, the
               fetch stage stalls (retries next cycle) instead of
               silently dropping the byte or advancing past it -- the
               same "stall the whole fetch stage until the condition
               clears" contract WAIT_EDGE already has, and the actual
               hardware implementation of the design blueprint's
               "Core 0 enters WAIT_DRAIN, stops accepting new physical
               pin transitions" backpressure story. A non-pushing
               SHIFT_IO is NEVER stalled by `push_stall` -- only the
               handoff instruction itself can be held back, so
               mid-frame bit-level timing is never at the mercy of
               whether µE1 is keeping up.

               `mode`=1 (CAPTURE, new this session): doesn't touch the
               byte accumulator at all -- always pushes instead, no
               payload bit needed to opt in. Assembles a 16-bit
               timestamped trace record -- {pin_sel (bits 15:13),
               the selected pin's CURRENT sampled level (bit 12),
               elapsed cycles since the previous capture push (bits
               11:0, a free-running counter that resets to 0 on every
               capture push and saturates at 0xFFF instead of
               wrapping)} -- and hands it to the FIFO interface via
               `capture_ready`/`capture_data` (same registered,
               pc-aligned contract as `byte_ready`/`byte_data`,
               independent signals so normal byte-relay programs are
               completely unaffected). Respects `push_stall` exactly
               like a pushing SHIFT_IO -- backpressure holds a CAPTURE
               instruction at the current pc, retried, never dropped.
               This is the hardware primitive a "record actual bus
               activity with timestamps, for reverse-engineering an
               unknown protocol or conformance-checking a known one
               against a live trace" mode needs -- pairing a WAIT_EDGE
               (rising or falling) with a CAPTURE on the same pin turns
               µE0 into a timestamped logic-analyzer channel, reusing
               the exact same FIFO/backpressure path byte-relay already
               proved out; µE1 can already pop and inspect these
               16-bit words with its existing FIFO_POP/BRANCH_COND_WORD
               opcodes with no changes needed there.

               `mode`=1 is further split by payload[9:8] (CAPTURE is
               sub-op 0 and keeps payload 0, so every existing program is
               untouched). Sub-ops 1-3 drive the BIT PIPE (bitpipe.ml):
                 1 PIPE_BIT    sample the selected pin and run it through
                               NRZI decode, bit un-stuffing, CRC and byte
                               assembly; a completed byte is pushed to the
                               FIFO through the same port as a pushing
                               SHIFT_IO (stalls while the FIFO is full).
                               Everything protocol-specific (NRZI on/off,
                               stuff rule, CRC polynomial/width/reflection,
                               residue, bytes to skip) is config loaded once
                               through the loader's cfg_sel path, so one
                               instruction per bit replaces the ~10 a
                               software bit-banger needs for USB / CAN.
                               payload[0] = sync: first wait for the bit-
                               clock recovery's sample strobe
                               (clock_recovery.ml), so the sample point
                               follows the sender's clock instead of a
                               timer. payload[1] = nostep: only that wait,
                               no sample (`pipe_sync`).
                 2 PIPE_STATUS push a status word {1, bytes, 5'b0, aligned,
                               stuff_err, crc_ok} to the FIFO (bit 15 marks
                               it so the protocol engine can tell it from
                               a zero-extended data byte).
                 3 PIPE_CTRL   payload[0] reset the stream, payload[1] idle
                               line level for NRZI, payload[2] reload the
                               CRC only. Transmit pipe (txpipe.ml):
                               payload[3] reset the TX stream (idle level
                               payload[1] too), payload[4] start appending
                               the CRC. Profile table (profile_table.ml):
                               payload[5] point the RX pipe and payload[6]
                               the TX pipe at profile pin_sel[1:0]. When an
                               instruction selects a profile, its reset /
                               CRC actions fire one cycle later, so they
                               load the NEW profile's CRC init.)
   opcode 01 with payload[1] = 1 is EMIT_TX (transmit pipe): drives the
               selected pin with the transmit pipe's next line bit
               (shift-out, CRC append, stuff insert, NRZI encode -- see
               txpipe.ml) instead of `mode`. payload[0] = open-drain: a 0
               drives low, a 1 releases the pin (I2C write data).
               payload[2] = differential: the paired pin (pin_sel xor 1)
               is driven with the complement in the same cycle (USB D-/D+,
               RS-485). Stalls while the pipe needs a new byte and the TX
               FIFO is empty.
   opcode 11 = BRANCH_COND  (single-cycle, always advances the fetch
               stage; payload's low pc_width bits are a branch
               target. Condition is a level check against the SAME
               selected pin WAIT_EDGE/SHIFT_IO already read -- not an
               edge -- so it can test a steady-state response line
               (e.g. an I2C ACK/NACK held for a whole clock cell):
               `mode`=1 branches when the pin currently reads high,
               `mode`=0 when it reads low. Falls through to pc+1
               otherwise. Fixed loop counts (e.g. "8 SPI bits") don't
               need this at all -- they're unrolled in program memory,
               same as the UART RX microcode's 8 unrolled data-bit
               waits -- BRANCH_COND exists specifically for the
               protocol layer's data-dependent branches.
               payload[9] = 1 (above the 9-bit target, 0 in every
               earlier program) branches on an internal FLAG instead of a
               pin, pin_sel choosing which: 0 = TX more (the transmit
               pipe still has data, CRC or a stuff bit to send),
               1 = clock-recovery overrun (a sample strobe passed while
               the previous one was still unconsumed).)

   Instruction memory is a real read/write RAM, sized and addressed to
   match Loader.addr_width -- this is what makes the core actually
   reprogrammable via loader.ml's byte-serial protocol, instead of a
   program baked in at Hardcaml-elaboration time. `run` (driven by
   loader.ml: 0 while loading, 1 once GO is latched) gates all
   fetch/execute activity -- the engine stays fully parked at pc=0,
   never advancing, until the host has finished loading.

   As of this session, there are TWO instruction-memory backends,
   `create` (behavioral Ram.create, what every existing testbench
   uses) and `create_asic` (two real IHP RM_IHPSG13_1P_512x8_c3_bm_bist
   hard macro instances, low/high byte -- what main.ml actually
   generates tapeout Verilog from). See `hard_macro_ram`'s comment
   below for why these had to be split rather than swapping `create`
   outright: this is the real fix for the "16,076 sequential cells,
   ~5x over budget" finding in docs/design/design_rationale.txt ("THE FINDING"), but
   Cyclesim cannot simulate through the hard-macro path at all.

   Fetch-latency note: a real synchronous RAM's read data is
   registered -- valid the cycle AFTER its address is presented --
   unlike a compile-time mux-ROM, which reads combinationally in the
   same cycle. Feeding the RAM with the CURRENT (registered) `pc` and
   stalling `advance`/`load` for a bubble cycle whenever a fetch is in
   flight is correct but adds raw cycles of dispatch overhead that
   can walk a tight sample point into the wrong bit by a frame's end
   (caught once already by test_engine.ml as a bits-mismatch, not a
   hang). Fixed by feeding the RAM's read port with `next_pc` (the
   same "pc after this cycle's advance/branch decision" expression
   pc's own register uses) instead of `pc` itself: the RAM then
   starts fetching the next instruction the SAME cycle the decision
   fires, so its 1-cycle latency lands exactly when `pc` updates --
   `instr` and `pc` stay in lockstep every cycle, zero bubble. This
   now covers BRANCH_COND too: `next_pc` and `pc`'s own reg_fb must
   compute the SAME branch-target-vs-pc+1 mux, or the RAM and the pc
   register would disagree about what comes next.

   (A related but distinct bug was hit and fixed getting here: `load`,
   which arms Timer with the CURRENT `payload`, was for one intermediate
   version a blind `reg spec advance` that fired mid-bubble while
   `payload` still showed the PREVIOUS instruction -- arming Timer with
   garbage and hanging the engine forever on the next timed wait. Once
   fetch was made bubble-free via `next_pc`, `load = reg spec advance`
   is correct again, exactly as in the original design, since by the
   cycle it fires `payload` already reflects the new instruction.)

   Pin mux (this slice): pins_in/pins_out are real 8-wide buses.
   `pin_sel` (3 bits, decoded from the instruction) selects which of
   the 8 input pins WAIT_EDGE/SHIFT_IO/BRANCH_COND reads, and which of
   the 8 output pins EMIT_STATE drives. Each output pin is its own
   sticky register (like the old single tx_pin), latched only when
   EMIT_STATE targets it -- the other 7 hold their last-driven level,
   same "holds across cycles" contract as before.

   Output-enable / tri-state (this slice, closes the bidirectional gap
   flagged in open decision #1): pins_oe is a matching 8-wide bus, one
   sticky register per pin, same demux structure as pins_out. Resets
   to 0 (not driving -- safe as an input by default) and only updates
   when EMIT_STATE targets that pin; `release_pin` sets it to 0
   (tri-state), plain `emit_state` sets it to 1 (drive `pins_out`'s
   level). This only matters once pins_in/pins_out/pins_oe are wired
   onto a physically bidirectional pin -- tt_um's dedicated ui_in/
   uo_out can't tri-state (one is hard-wired input-only, the other
   output-only), but tt_um's uio_in/uio_out/uio_oe genuinely can, so
   tt_core.ml's tt_um_system now routes this whole 8-pin bus through
   uio instead of ui_in/uo_out. That's what lets a single physical net
   act as I2C's SDA (or SCL, for clock-stretching): read it via
   pins_in, and either drive it low or let go via pins_out/pins_oe,
   exactly like a real open-drain pin.

   Same-bug-class risk this introduces, guarded explicitly: the edge
   detector's `rx_d` register samples whatever pin was muxed in on the
   PREVIOUS cycle. If instruction N watches pin 3 and instruction N+1
   (a new WAIT_EDGE) watches pin 5, the first cycle of N+1 would compare
   pin 5's current level against pin 3's stale sampled level -- a
   spurious "edge" that never happened on pin 5, same class of bug as
   the start_edge/idle guard (#3) and the WAIT payload race (#4) in the
   project log. Fixed the same way: an explicit guard, `pin_sel_stable`,
   requires pin_sel to have been the SAME pin last cycle too before an
   edge_match is trusted; the first cycle watching a newly-selected pin
   only establishes a baseline sample, exactly like real hardware can't
   detect a transition from a single sample. This only matters at
   instruction boundaries -- while a WAIT_EDGE instruction stalls
   fetch/pc, pin_sel (decoded from the unchanging `instr`) is constant
   across the whole wait, so the guard is true from the second cycle of
   any given wait onward. BRANCH_COND's condition is a level check, not
   an edge, so it needs no such guard -- it reads the muxed pin directly
   every cycle regardless of history.
   ============================================================ *)
module I = struct
  type 'a t = {
    clk          : 'a;
    rst_n        : 'a;
    pins_in      : 'a; [@bits 8]
    prescale     : 'a; [@bits 8]
    run          : 'a;
    write_enable : 'a;
    write_addr   : 'a; [@bits 9]
    write_data   : 'a; [@bits 16]
    push_stall   : 'a;
    rx_cfg       : 'a; [@bits 192]
    tx_cfg       : 'a; [@bits 192]
    tx_fifo_data : 'a; [@bits 16]
    tx_fifo_empty : 'a;
    ext_rx_crc_init : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    sample_pulse  : 'a;
    sampled_bit   : 'a;
    pins_out      : 'a; [@bits 8]
    pins_oe       : 'a; [@bits 8]
    pc            : 'a; [@bits 9]
    byte_ready    : 'a;
    byte_data     : 'a; [@bits 8]
    capture_ready : 'a;
    capture_data  : 'a; [@bits 16]
    tx_fifo_pop   : 'a;
    sel_rx        : 'a;
    sel_tx        : 'a;
    sel_id        : 'a; [@bits 2]
  } [@@deriving sexp_of, hardcaml]
end

let encode ~opcode ~pin ~mode ~payload =
  ((opcode land 0x3) lsl 14)
  lor ((pin land 0x7) lsl 11)
  lor ((mode land 0x1) lsl 10)
  lor (payload land 0x3FF)

let wait_edge ~pin ~falling ~payload =
  encode ~opcode:0 ~pin ~mode:(if falling then 0 else 1) ~payload

let emit_state ~pin ~level = encode ~opcode:1 ~pin ~mode:(if level then 1 else 0) ~payload:0

(* Tri-state the selected pin (pins_oe -> 0) instead of driving it --
   payload bit 0 is the release flag; see the module-header note. `level`
   is irrelevant when releasing (mode is a don't-care electrically once
   oe=0), so this takes no such argument, unlike `emit_state`. *)
let release_pin ~pin = encode ~opcode:1 ~pin ~mode:0 ~payload:1

let shift_in ~pin = encode ~opcode:2 ~pin ~mode:0 ~payload:0

(* Same sample as shift_in, but also hands the accumulator (including
   this cycle's bit) to the FIFO interface -- see the module-header
   note on SHIFT_IO's payload bit 0. *)
let shift_in_push ~pin = encode ~opcode:2 ~pin ~mode:0 ~payload:1

(* CAPTURE: SHIFT_IO with mode=1 -- see the module-header note. Always
   pushes a timestamped {pin_sel, level, elapsed} record; payload is
   unused/reserved. *)
let capture ~pin = encode ~opcode:2 ~pin ~mode:1 ~payload:0

(* Bit-pipe operations (see bitpipe.ml): SHIFT_IO with mode=1 and a sub-op in
   payload[9:8]. Sub-op 0 is CAPTURE, unchanged, so every existing program
   (which encodes payload 0) is untouched. *)
let pipe_sub sub ~pin ~ops = encode ~opcode:2 ~pin ~mode:1 ~payload:((sub lsl 8) lor ops)

(* PIPE_BIT: sample `pin` and run the sample through NRZI decode, un-stuffing,
   CRC and byte assembly. A completed byte is pushed to the FIFO (stalling
   while the FIFO is full). *)
let pipe_bit ~pin = pipe_sub 1 ~pin ~ops:0

(* PIPE_BIT sync: wait for the clock-recovery sample strobe, then sample. *)
let pipe_bit_sync ~pin = pipe_sub 1 ~pin ~ops:1

(* PIPE_BIT sync + nostep: wait for the clock-recovery sample strobe, then
   continue without stepping the pipe (the program inspects the line, e.g.
   for USB's SE0, and steps with a plain PIPE_BIT right after). *)
let pipe_sync = pipe_sub 1 ~pin:0 ~ops:3

(* PIPE_STATUS: push one 16-bit status record {1, bytes[6:0], 5'b0,
   aligned, stuff_err, crc_ok} to the FIFO. Bit 15 marks it as a status
   word (data bytes are zero-extended). *)
let pipe_status = pipe_sub 2 ~pin:0 ~ops:0

(* PIPE_CTRL: [reset] clears the stream state and loads the idle line level
   `prev_level` for NRZI; [crc_init] reloads only the CRC (USB: the CRC covers
   the data stage, not SYNC/PID). *)
let pipe_ctrl ~reset ~prev_level ~crc_init =
  pipe_sub 3 ~pin:0
    ~ops:((if reset then 1 else 0) lor (if prev_level then 2 else 0) lor if crc_init then 4 else 0)

(* The full PIPE_CTRL: receive-pipe and transmit-pipe controls and profile
   selection in one instruction. `profile` goes in pin_sel[1:0]. *)
let pipe_ctrl_ext ?(reset = false) ?(prev_level = false) ?(crc_init = false) ?(tx_reset = false)
    ?(tx_crc = false) ?(sel_rx = false) ?(sel_tx = false) ?(profile = 0) () =
  let b c n = if c then 1 lsl n else 0 in
  pipe_sub 3 ~pin:profile
    ~ops:
      (b reset 0 lor b prev_level 1 lor b crc_init 2 lor b tx_reset 3 lor b tx_crc 4 lor b sel_rx 5
     lor b sel_tx 6)

(* EMIT_TX: drive `pin` with the transmit pipe's next line bit. With
   [open_drain] a 0 drives low and a 1 releases the pin. *)
let emit_tx ?(open_drain = false) ?(differential = false) ~pin () =
  encode ~opcode:1 ~pin ~mode:0
    ~payload:(2 lor (if open_drain then 1 else 0) lor if differential then 4 else 0)

let branch_cond ~pin ~branch_if_high ~target =
  encode ~opcode:3 ~pin ~mode:(if branch_if_high then 1 else 0) ~payload:target

(* Branch on an internal flag (payload[9] = 1); flag 0 = TX more. *)
let flag_tx_more = 0

let branch_flag ~flag ~branch_if_set ~target =
  encode ~opcode:3 ~pin:flag ~mode:(if branch_if_set then 1 else 0) ~payload:(0x200 lor target)

let pc_width = Loader.addr_width
let ram_depth = 1 lsl pc_width

(* The ORIGINAL instruction-memory implementation: Hardcaml's generic
   Ram.create, synthesizable but only as inferred flip-flops (Yosys's
   memory_map pass has no rule mapping it onto a real SRAM macro).
   Kept as the default `create` below specifically because it's the
   only variant Cyclesim can simulate through -- see `hard_macro_ram`'s
   comment for why. This is what every existing testbench still
   exercises, unchanged. *)
let behavioral_ram ~clk ~write_enable ~write_addr ~write_data ~read_addr =
  (Ram.create
     ~collision_mode:Ram.Collision_mode.Write_before_read
     ~size:ram_depth
     ~write_ports:
       [| { Write_port.write_clock = clk
          ; write_address = write_addr
          ; write_enable
          ; write_data
          }
       |]
     ~read_ports:
       [| { Read_port.read_clock = clk; read_address = read_addr; read_enable = one 1 } |]
     ()).(0)

(* The REAL instruction-memory implementation for tapeout: two IHP
   RM_IHPSG13_1P_512x8_c3_bm_bist hard macros (see sram.ml) instead of
   Ram.create -- this is the actual fix for the "16,076 sequential
   cells, ~5x over budget" finding in docs/design/design_rationale.txt.

   NOT usable with Cyclesim: Hardcaml's simulator schedules
   Instantiation nodes as pure combinational primitives -- it has no
   way to know the macro is internally clocked/registered. Since
   `read_addr` here is `next_pc`, which depends on `advance`/
   `branch_taken`, which depend on `opcode`(decoded from this same
   RAM's own output), Cyclesim sees an unbroken combinational loop
   through the instantiation and refuses to build the simulation
   (confirmed directly: swapping this in for `create`'s RAM made every
   existing Cyclesim testbench fail with "Combinational loop" through
   the `instantiation` node, even though the identical topology with
   Ram.create -- a real sequential Signal kind Cyclesim's scheduler
   DOES recognize -- was never a problem). This is why `create_asic`
   exists as a separate entry point instead of being the default: RTL
   generation doesn't care (Rtl.output emits the instantiation as
   plain Verilog either way, confirmed working), only Cyclesim does.
   Verified correct by construction instead: the macro's datasheet
   operation table (A_MEN=1,A_REN=1,A_WEN=1 = "Write-Through", new
   data appears on A_DOUT the same operation) is the exact same
   contract as `behavioral_ram`'s
   ~collision_mode:Ram.Collision_mode.Write_before_read. Closing this
   verification gap for real would mean a post-synthesis gate-level
   sim (iverilog/Verilator against the generated tt_um_dual.v +
   the vendor's own behavioral macro model compiled with
   `+define+FUNCTIONAL`) -- not done yet, flagged in docs/design/design_rationale.txt as the
   next real step. *)
let hard_macro_ram = Sram.create_512x16 ~instance_prefix:"mue0_instr"

let create_generic ~build_instr (inputs : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:inputs.clk ~clear:((~:) inputs.rst_n) () in

  let pc = wire pc_width in
  let advance = wire 1 in
  let branch_taken = wire 1 in
  let branch_target = wire pc_width in
  (* "pc as it will be after this cycle's advance/branch decision" --
     see the fetch-latency note above. Deliberately the SAME
     expression pc's own reg_fb below uses, so the RAM and the pc
     register always agree on what "next" means. *)
  let next_pc = mux2 advance (mux2 branch_taken branch_target (pc +:. 1)) pc in

  let instr =
    build_instr
      ~clk:inputs.clk
      ~write_enable:inputs.write_enable
      ~write_addr:inputs.write_addr
      ~write_data:inputs.write_data
      ~read_addr:next_pc
  in
  let opcode = select instr 15 14 in
  let pin_sel = select instr 13 11 in
  let mode = select instr 10 10 in
  let payload = select instr 9 0 in
  (* payload bit 0 is an opcode-specific side-effect flag: "release"
     for EMIT_STATE, "push to FIFO" for SHIFT_IO -- see each opcode's
     note above. Both are gated by is_emit/is_shift respectively where
     used, so sharing one name is safe (WAIT_EDGE/BRANCH_COND never
     read it). *)
  let payload_bit0 = select payload 0 0 in

  let is_wait = opcode ==:. 0 in
  let is_emit = opcode ==:. 1 in
  let is_shift = opcode ==:. 2 in
  let is_branch = opcode ==:. 3 in
  (* SHIFT_IO's mode bit: 0 = normal byte-accumulate (every pre-existing
     program), 1 = CAPTURE (new this session) -- see the module-header
     note. Mutually exclusive by construction (mode is a single bit). *)
  let pipe_sub_op = select payload 9 8 in
  let is_capture = is_shift &&: mode &&: (pipe_sub_op ==:. 0) in
  let is_pipe_bit = is_shift &&: mode &&: (pipe_sub_op ==:. 1) in
  let is_pipe_status = is_shift &&: mode &&: (pipe_sub_op ==:. 2) in
  let is_pipe_ctrl = is_shift &&: mode &&: (pipe_sub_op ==:. 3) in
  let is_normal_shift = is_shift &&: (~:mode) in
  let is_emit_tx = is_emit &&: select payload 1 1 in
  let is_flag_branch = is_branch &&: select payload 9 9 in

  (* Input pin mux: 1-of-8, selected by the current instruction's
     pin_sel. See the module-header note on the pin_sel_stable guard
     below -- it's what keeps this mux from producing spurious edges
     when consecutive instructions watch different physical pins. *)
  let pin_inputs = List.init 8 (fun i -> select inputs.pins_in i i) in
  let rx_pin = mux pin_sel pin_inputs in

  let pin_sel_d = reg spec pin_sel in
  let pin_sel_stable = pin_sel ==: pin_sel_d in

  let rx_d = reg spec rx_pin in
  let raw_edge_match = mux2 mode (rx_pin &&: (~:rx_d)) ((~:rx_pin) &&: rx_d) in
  let edge_match = pin_sel_stable &&: raw_edge_match in

  let load = reg spec advance in

  let timer_out =
    Timer.create
      { Timer.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; load
      ; prescale = inputs.prescale
      ; payload
      }
  in
  (* payload=0 means "wait for the edge only, no timeout"; nonzero
     payload means "pure timed wait, ignore edges" -- e.g. a mid-frame
     data-bit transition must NOT be mistaken for framing. The two
     conditions are mutually exclusive by construction, never raced. *)
  let payload_is_zero = payload ==: zero 10 in
  let wait_condition = mux2 payload_is_zero edge_match timer_out.Timer.O.expired in

  (* WAIT_EDGE stalls the fetch stage on an unmet edge/timer condition;
     a SHIFT_IO that's pushing to the FIFO (payload_bit0, normal mode)
     OR a CAPTURE (which always pushes) stalls it on backpressure
     (`push_stall`, e.g. wired to the FIFO's `full`) -- see the
     module-header note on SHIFT_IO. Every other case (EMIT_STATE,
     BRANCH_COND, a non-pushing SHIFT_IO) is single-cycle and always
     advances while running. *)
  (* Bit pipe (bitpipe.ml). `advance` is a forward wire, so `step` can depend
     on it while `would_push` (registered state only) feeds back into it
     without a combinational loop. *)
  (* PIPE_CTRL. Profile selection takes effect at the next edge; reset and
     CRC actions in the SAME instruction are delayed one cycle so they load
     the newly selected profile's CRC init (see the module header). *)
  let ctrl = advance &&: is_pipe_ctrl in
  let pbit n = select payload n n in
  let sel_rx = ctrl &&: pbit 5 in
  let sel_tx = ctrl &&: pbit 6 in
  let selecting = pbit 5 |: pbit 6 in
  let now_or_later s =
    let s_now = ctrl &&: s in
    mux2 selecting gnd s_now |: reg spec (s_now &&: selecting)
  in
  let prev_level = mux2 (reg spec (ctrl &&: selecting)) (reg spec (pbit 1)) (pbit 1) in
  (* PIPE_BIT payload[0] = sync: wait for the clock-recovery sample strobe
     first; payload[1] = nostep: only wait, do not step the pipe (a USB loop
     checks for SE0 between the strobe and the step) *)
  let rx_reset = now_or_later (pbit 0) in
  let bit_sync = is_pipe_bit &&: pbit 0 in
  let bit_step = is_pipe_bit &&: (~:(pbit 1)) in
  let rec_ =
    Clock_recovery.create
      { Clock_recovery.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; cfg = inputs.rx_cfg
      ; pins_in = inputs.pins_in
      ; arm = rx_reset
      ; consume = advance &&: bit_sync
      }
  in
  let bp =
    Bitpipe.create
      { Bitpipe.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; cfg = inputs.rx_cfg
      ; step = advance &&: bit_step
      ; line = rx_pin
      ; ctrl_reset = rx_reset
      ; ctrl_crc_init = now_or_later (pbit 2) |: inputs.ext_rx_crc_init
      ; prev_init = prev_level
      }
  in
  let tx =
    Txpipe.create
      { Txpipe.I.clk = inputs.clk
      ; rst_n = inputs.rst_n
      ; cfg = inputs.tx_cfg
      ; step = advance &&: is_emit_tx
      ; ctrl_reset = now_or_later (pbit 3)
      ; ctrl_crc_append = now_or_later (pbit 4)
      ; prev_init = prev_level
      ; fifo_data = inputs.tx_fifo_data
      ; fifo_empty = inputs.tx_fifo_empty
      }
  in
  let would_push =
    (is_normal_shift &&: payload_bit0)
    ||: is_capture ||: is_pipe_status
    ||: (bit_step &&: bp.Bitpipe.O.would_push)
  in
  let shift_advance_ok =
    ~:((would_push &&: inputs.push_stall)
       |: (is_emit_tx &&: tx.Txpipe.O.would_stall)
       |: (bit_sync &&: (~:(rec_.Clock_recovery.O.pending))))
  in
  advance <== (inputs.run &&: mux2 is_wait wait_condition shift_advance_ok);

  (* internal flags for BRANCH_COND's flag form, selected by pin_sel *)
  let flags = [ tx.Txpipe.O.more; rec_.Clock_recovery.O.overrun ] in
  let flag = mux pin_sel (flags @ List.init (8 - List.length flags) (fun _ -> gnd)) in
  let cond = mux2 is_flag_branch flag rx_pin in
  branch_taken <== (is_branch &&: mux2 mode cond (~:cond));
  branch_target <== select payload (pc_width - 1) 0;

  pc <==
    reg_fb ~enable:(one 1) spec ~width:pc_width ~f:(fun cur ->
      mux2 advance (mux2 branch_taken branch_target (cur +:. 1)) cur);

  (* Output pin demux: 8 independent sticky registers, one per pin.
     Only the pin EMIT_STATE currently targets latches a new level;
     the other 7 hold whatever they last held, same contract the
     single tx_pin register had. *)
  (* `advance` rather than `run`: an EMIT_TX can stall, and a stalled one
     must not latch anything. EMIT_STATE never stalls, so for it the two
     are the same. *)
  let emit_level = mux2 is_emit_tx tx.Txpipe.O.line mode in
  (* differential EMIT_TX also writes the paired pin, complemented *)
  let is_diff = is_emit_tx &&: pbit 2 in
  let pair_hit i = advance &&: is_diff &&: (pin_sel ==:. i lxor 1) in
  let out_reg i =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
      mux2 (advance &&: is_emit &&: (pin_sel ==:. i)) emit_level
        (mux2 (pair_hit i) (~:(tx.Txpipe.O.line)) cur))
  in
  let pins_out = concat_msb (List.init 8 (fun i -> out_reg (7 - i))) in

  (* Output-enable demux: same per-pin sticky structure as out_reg
     above. Only updates when EMIT_STATE targets pin i; `payload_release`
     clear (0, the default every pre-existing program encodes) means
     "drive" (oe=1), set means "release" (oe=0) regardless of `mode`.
     Resets to 0 so an untouched pin defaults to a safe input, not an
     accidental driver. *)
  (* EMIT_TX open-drain (payload bit 0): drive only the 0s, release the 1s *)
  let emit_oe = mux2 is_emit_tx (~:(payload_bit0 &&: tx.Txpipe.O.line)) (~:payload_bit0) in
  let oe_reg i =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
      mux2 (advance &&: is_emit &&: (pin_sel ==:. i)) emit_oe (mux2 (pair_hit i) vdd cur))
  in
  let pins_oe = concat_msb (List.init 8 (fun i -> oe_reg (7 - i))) in

  (* Shift accumulator: plain 8-bit shift register, shifts in rx_pin
     on every SHIFT_IO that actually advances (pushing or not). Only
     the last 8 samples ever matter -- older ones fall off the top --
     so a microcode doesn't need to align pushes to exact multiples of
     8 shifts (see the UART RX example in the module header).
     `shift_reg`'s own reg_fb recomputes the shift purely from its
     closure's `cur`, matching the discipline `pc`'s reg_fb uses. *)
  let shift_advances = advance &&: is_normal_shift in
  let shift_reg =
    reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
      mux2 shift_advances (concat_msb [ select cur 6 0; rx_pin ]) cur)
  in
  let next_shift = concat_msb [ select shift_reg 6 0; rx_pin ] in
  (* a completed PIPE_BIT byte shares the same push port as shift_in_push *)
  let pipe_byte_done = bp.Bitpipe.O.byte_done in
  let byte_ready_now = (shift_advances &&: payload_bit0) ||: pipe_byte_done in

  (* `byte_ready`/`byte_data` are REGISTERED (plain one-cycle
     pipeline regs, not reg_fb -- no holding needed, a completing push
     is a genuine one-cycle event), unlike `sample_pulse`/`sampled_bit`
     above which stay raw combinational functions of `instr`. This
     matters: `instr` (and everything read straight off it, like
     `sample_pulse`) reflects the RAM's registered output, which is
     always one RAM-latency ahead of `pc` when observed from OUTSIDE
     the module immediately after a clock edge -- fine for
     sample_pulse/sampled_bit, whose only existing consumer
     (test_engine.ml) reads them by relative pulse spacing, never by
     correlating against an externally-tracked pc. `pins_out`/`pins_oe`
     avoid this because out_reg/oe_reg are THEMSELVES registers: their
     "next" logic consumes `instr` at the same pre-edge instant `pc`'s
     own reg_fb does, so their post-edge value lines up with "the
     instruction that was at pc going into this cycle" -- the same
     alignment test_engine_branch.ml's docstring describes. Since
     `dual.ml` needs to wire `byte_ready`/`byte_data` into a FIFO's
     push port as a clean, predictable strobe (and get this right on
     the first try, not by re-deriving RAM-latency arithmetic), giving
     them the SAME registered, pc-aligned contract pins_out already
     has is the safer interface, not just a stylistic choice -- this
     was caught by test_engine_push.ml comparing against pc_before and
     getting an apparently-one-instruction-early result before the fix. *)
  let byte_ready = reg spec byte_ready_now in
  let byte_data = reg spec (mux2 pipe_byte_done bp.Bitpipe.O.byte_data next_shift) in

  (* CAPTURE datapath: `elapsed` is a free-running 12-bit counter,
     incremented once per running cycle, reset to 0 the same cycle a
     capture push commits (highest-priority mux arm), saturating at
     0xFFF instead of wrapping so a long idle gap before the next
     capture reads as "very long" rather than silently wrapping into a
     small, wrong-looking number. `capture_data_now` reads `elapsed`'s
     CURRENT (pre-update) value -- "cycles since the previous capture,
     not counting this one" -- same convention `next_shift` uses when
     it reads `shift_reg`'s current value alongside this cycle's fresh
     sample. `capture_ready`/`capture_data` are then registered exactly
     like `byte_ready`/`byte_data` above, for the identical reason: the
     pc-aligned, one-cycle-after contract every other pushed/held
     output in this module already follows. *)
  let elapsed = wire 12 in
  let capture_now = advance &&: is_capture in
  elapsed <==
    reg_fb ~enable:(one 1) spec ~width:12 ~f:(fun cur ->
      mux2 capture_now (zero 12)
        (mux2 (inputs.run &&: (~:(cur ==:. 0xFFF))) (cur +:. 1) cur));
  let capture_data_now = concat_msb [ pin_sel; rx_pin; elapsed ] in
  (* PIPE_STATUS pushes through the same registered push port as CAPTURE;
     it does not touch the capture `elapsed` counter. *)
  let status_now = advance &&: is_pipe_status in
  let capture_ready = reg spec (capture_now ||: status_now) in
  let capture_data = reg spec (mux2 status_now bp.Bitpipe.O.status capture_data_now) in

  { O.sample_pulse = inputs.run &&: is_shift
  ; sampled_bit = rx_pin
  ; pins_out
  ; pins_oe
  ; pc
  ; byte_ready
  ; byte_data
  ; capture_ready
  ; capture_data
  ; tx_fifo_pop = tx.Txpipe.O.fifo_pop
  ; sel_rx
  ; sel_tx
  ; sel_id = select pin_sel 1 0
  }

(* Every existing testbench calls this one -- behavioral RAM, fully
   Cyclesim-simulatable, unchanged behavior from before this session. *)
let create (inputs : Signal.t I.t) = create_generic ~build_instr:behavioral_ram inputs

(* Real hard-macro instruction memory, for tapeout RTL generation only
   (main.ml) -- see hard_macro_ram's comment above for why this can't
   also be what the testbenches use. *)
let create_asic (inputs : Signal.t I.t) = create_generic ~build_instr:hard_macro_ram inputs
