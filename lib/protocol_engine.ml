open Hardcaml
open Signal

(* ============================================================
   µE1: the protocol-layer engine -- Core-1 in the design blueprint
   ("Packet State Machine", "Memory Bus Interface" [the shadow FIFO],
   "Raw Pin Bypass Access", "Command Response"). Consumes the words
   µE0 (engine.ml) streams through shadow_fifo.ml, tests their
   content, and drives response pins -- this is the other half of the
   dual-engine architecture the design blueprint's novelty claim rests
   on (this is deliberately not collapsed into a single engine).

   Own, small, purpose-built ISA -- NOT a reuse of engine.ml's opcode
   table, since µE1's job (consume FIFO words, branch on their
   content, respond) is genuinely different from µE0's (bit-level
   timing/sampling), and forcing one shared 4-opcode table across both
   would mean overloading fields with two unrelated meanings for no
   benefit -- there is no existing microcode or test depending on a
   shared encoding, so a clean, separate table costs nothing.

   Same 16-bit word shape as engine.ml for consistency: [15:14]
   opcode | [13:11] pin_sel | [10] mode | [9:0] payload.

   opcode 00 = FIFO_POP     (stalls the fetch stage exactly like
               WAIT_EDGE does in engine.ml -- but the condition is
               "the shadow FIFO is non-empty" instead of an edge
               match. Once data is available, pops it into the held
               `rx_word` register and advances. `pin_sel`/`mode`/
               `payload` are unused/reserved (0) for this opcode.)
   opcode 00 with mode = 1: the transmit and configuration group,
               pin_sel[1:0] choosing the operation (pin_sel[2] = 0):
                 0 TX_PUSH imm   push {last = payload[8], payload[7:0]}
                                 into the TX FIFO (µE0's transmit pipe
                                 reads it). Stalls while the FIFO is full,
                                 like FIFO_POP stalls while it is empty.
                 1 TX_ECHO       push {payload[8], low byte of rx_word}:
                                 relay a received byte back out.
                 2 CFG_WR        write one byte of rx_word (the high byte
                                 if payload[7]) into the profile table at
                                 index payload[6:0]. Lets a program build
                                 or retune a profile from data it measured
                                 (e.g. a bit period from CAPTURE records).
                 3 PROFILE       point the RX pipe (payload[2]) and/or the
                                 TX pipe (payload[3]) at profile
                                 payload[1:0]; payload[4] reloads the RX
                                 CRC from the new profile a cycle later.
                                 This is how a USB program switches to the
                                 CRC5 or CRC16 profile after reading a PID.
   opcode 01 = EMIT_STATE   (byte-for-byte the same semantics as
               engine.ml's EMIT_STATE, including the payload-bit-0
               release/tri-state flag -- µE1 needs its own response
               pins, e.g. an I2C ACK/NACK drive or SPI response byte,
               and reuses the identical open-drain-capable mechanism.)
   opcode 10 = BRANCH_COND_WORD (single-cycle, always advances.
               Branches to payload's low pc_width bits when bit
               `pin_sel` (0-7) of the LAST POPPED word (`rx_word`)
               matches `mode` (1=branch-if-1, 0=branch-if-0);
               otherwise falls through to pc+1. This is the actual
               "Packet FSM" primitive -- data-dependent branching on
               protocol content, e.g. checking a command byte's type
               bit without needing a general ALU/compare unit.)
   opcode 11 = BRANCH_PIN   (single-cycle, always advances. Same shape
               as engine.ml's BRANCH_COND: branches on the CURRENT
               level of a real external pin (`pin_sel`-selected,
               `pins_in` bus), not FIFO content -- the design
               blueprint's "Raw Pin Bypass Access" escape hatch, e.g.
               checking a hold/ready line that doesn't go through
               µE0's FIFO pipeline at all.)

   Instruction memory: its own read/write RAM, same Ram.create shape
   and same Loader.addr_width sizing as engine.ml's, so both engines'
   programs can eventually share the loader's byte-serial protocol
   with a consistent address width. Deliberately a SEPARATE RAM
   instance for this increment, not yet the single shared 512x16
   macro the design blueprint's gate-budget table assumes (open
   decision, same class as the still-unverified macro-size assumption
   already flagged in the project log) -- wiring the loader to load BOTH
   engines' programs is its own follow-on step, kept separate so this
   module's own instruction-execution semantics can be tested in
   isolation first, same "test every increment" discipline used for
   every other slice of this design.

   Pin mux and output-enable demux are copied verbatim from engine.ml
   (same bug class already guarded there: `pin_sel_stable`-style
   concerns don't apply here since neither BRANCH opcode stalls the
   fetch stage on a pin, only FIFO_POP does, and FIFO_POP doesn't read
   pins_in at all).
   ============================================================ *)
module I = struct
  type 'a t = {
    clk           : 'a;
    rst_n         : 'a;
    pins_in       : 'a; [@bits 8]
    run           : 'a;
    write_enable  : 'a;
    write_addr    : 'a; [@bits 9]
    write_data    : 'a; [@bits 16]
    fifo_pop_data : 'a; [@bits 16]
    fifo_empty    : 'a;
    tx_fifo_full  : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    pc        : 'a; [@bits 9]
    pins_out  : 'a; [@bits 8]
    pins_oe   : 'a; [@bits 8]
    fifo_pop  : 'a;
    rx_word   : 'a; [@bits 16]
    tx_push   : 'a;
    tx_data   : 'a; [@bits 16]
    cfg_we    : 'a;
    cfg_addr  : 'a; [@bits 7]
    cfg_data  : 'a; [@bits 8]
    sel_rx    : 'a;
    sel_tx    : 'a;
    sel_id    : 'a; [@bits 2]
    rx_crc_init : 'a;
  } [@@deriving sexp_of, hardcaml]
end

let encode ~opcode ~pin ~mode ~payload =
  ((opcode land 0x3) lsl 14)
  lor ((pin land 0x7) lsl 11)
  lor ((mode land 0x1) lsl 10)
  lor (payload land 0x3FF)

let fifo_pop_instr = encode ~opcode:0 ~pin:0 ~mode:0 ~payload:0

let emit_state ~pin ~level = encode ~opcode:1 ~pin ~mode:(if level then 1 else 0) ~payload:0

let release_pin ~pin = encode ~opcode:1 ~pin ~mode:0 ~payload:1

let branch_word ~bit ~branch_if_one ~target =
  (* bit 0-7 lives in the pin field; bits 8-15 set payload[9] (above the 9-bit target) *)
  encode ~opcode:2 ~pin:(bit land 7) ~mode:(if branch_if_one then 1 else 0)
    ~payload:(target lor if bit >= 8 then 0x200 else 0)

let branch_pin ~pin ~branch_if_high ~target =
  encode ~opcode:3 ~pin ~mode:(if branch_if_high then 1 else 0) ~payload:target

let tx_push ?(last = false) byte =
  encode ~opcode:0 ~pin:0 ~mode:1 ~payload:((if last then 0x100 else 0) lor (byte land 0xFF))

let tx_echo ?(last = false) () = encode ~opcode:0 ~pin:1 ~mode:1 ~payload:(if last then 0x100 else 0)

let cfg_wr ?(high_byte = false) ~index () =
  encode ~opcode:0 ~pin:2 ~mode:1 ~payload:((if high_byte then 0x80 else 0) lor (index land 0x7F))

let profile ?(rx = false) ?(tx = false) ?(crc_init = false) id =
  let b c n = if c then 1 lsl n else 0 in
  encode ~opcode:0 ~pin:3 ~mode:1 ~payload:((id land 3) lor b rx 2 lor b tx 3 lor b crc_init 4)

let pc_width = Loader.addr_width
let ram_depth = 1 lsl pc_width

(* Same two-backend split as engine.ml, same reason: Cyclesim cannot
   simulate through a black-boxed hard-macro Instantiation feeding its
   own address across a clock edge (reads as an unbroken combinational
   loop -- confirmed directly, see engine.ml's `hard_macro_ram`
   comment for the full explanation). `create` (behavioral, what every
   existing testbench uses) stays default; `create_asic` (real IHP
   macro pair, distinct instance_prefix from engine.ml's µE0 so both
   engines' macro instances stay uniquely named in the generated
   netlist) is only used by main.ml's tapeout Verilog generation. *)
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

let hard_macro_ram = Sram.create_512x16 ~instance_prefix:"mue1_instr"

let create_generic ~build_instr (inputs : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:inputs.clk ~clear:((~:) inputs.rst_n) () in

  let pc = wire pc_width in
  let advance = wire 1 in
  let branch_taken = wire 1 in
  let branch_target = wire pc_width in
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
  let payload_bit0 = select payload 0 0 in

  let is_pop = (opcode ==:. 0) &&: (~:mode) in
  let is_emit = opcode ==:. 1 in
  let is_branch_word = opcode ==:. 2 in
  let is_branch_pin = opcode ==:. 3 in
  let is_group = (opcode ==:. 0) &&: mode in
  let is_tx_push = is_group &&: (pin_sel ==:. 0) in
  let is_tx_echo = is_group &&: (pin_sel ==:. 1) in
  let is_cfg_wr = is_group &&: (pin_sel ==:. 2) in
  let is_profile = is_group &&: (pin_sel ==:. 3) in
  let is_push = is_tx_push |: is_tx_echo in

  advance
  <== (inputs.run
      &&: mux2 is_pop (~:(inputs.fifo_empty)) (mux2 is_push (~:(inputs.tx_fifo_full)) vdd));

  (* Pop exactly on the cycle a FIFO_POP instruction completes --
     drives both the external `fifo_pop` (wired to the shadow FIFO's
     `pop`) and `rx_word`'s own capture below, same "one combinational
     signal, two consistent consumers within the same cycle" pattern
     `shift_advances` uses in engine.ml. *)
  let fifo_pop = advance &&: is_pop in
  let rx_word =
    reg_fb ~enable:(one 1) spec ~width:16 ~f:(fun cur -> mux2 fifo_pop inputs.fifo_pop_data cur)
  in

  let pin_inputs = List.init 8 (fun i -> select inputs.pins_in i i) in
  let rx_pin = mux pin_sel pin_inputs in
  (* BRANCH_COND_WORD tests bit {payload[9], pin_sel} of rx_word: payload[9]
     (unused by the 9-bit branch target, 0 in every pre-existing program)
     selects the upper byte, so bits 8-15 are reachable too -- needed to
     spot the bit-pipe status word (bit 15) among zero-extended data bytes. *)
  let rx_word_bits = List.init 16 (fun i -> select rx_word i i) in
  let rx_word_bit = mux (concat_msb [ select payload 9 9; pin_sel ]) rx_word_bits in

  branch_taken
  <== ((is_branch_word &&: mux2 mode rx_word_bit (~:rx_word_bit))
      |: (is_branch_pin &&: mux2 mode rx_pin (~:rx_pin)));
  branch_target <== select payload (pc_width - 1) 0;

  pc <==
    reg_fb ~enable:(one 1) spec ~width:pc_width ~f:(fun cur ->
      mux2 advance (mux2 branch_taken branch_target (cur +:. 1)) cur);

  let out_reg i =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
      mux2 (inputs.run &&: is_emit &&: (pin_sel ==:. i)) mode cur)
  in
  let pins_out = concat_msb (List.init 8 (fun i -> out_reg (7 - i))) in

  let oe_reg i =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
      mux2 (inputs.run &&: is_emit &&: (pin_sel ==:. i)) (~:payload_bit0) cur)
  in
  let pins_oe = concat_msb (List.init 8 (fun i -> oe_reg (7 - i))) in

  let pbit n = select payload n n in
  let tx_byte = mux2 is_tx_echo (select rx_word 7 0) (select payload 7 0) in
  let do_profile = advance &&: is_profile in
  { O.pc
  ; pins_out
  ; pins_oe
  ; fifo_pop
  ; rx_word
  ; tx_push = advance &&: is_push
  ; tx_data = concat_msb [ zero 7; pbit 8; tx_byte ]
  ; cfg_we = advance &&: is_cfg_wr
  ; cfg_addr = select payload 6 0
  ; cfg_data = mux2 (pbit 7) (select rx_word 15 8) (select rx_word 7 0)
  ; sel_rx = do_profile &&: pbit 2
  ; sel_tx = do_profile &&: pbit 3
  ; sel_id = select payload 1 0
  ; rx_crc_init = reg spec (do_profile &&: pbit 4)
  }

let create (inputs : Signal.t I.t) = create_generic ~build_instr:behavioral_ram inputs
let create_asic (inputs : Signal.t I.t) = create_generic ~build_instr:hard_macro_ram inputs
