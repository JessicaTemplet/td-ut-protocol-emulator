open Hardcaml
open Tt_core

(* Roadmap item #4 (docs/design/design_rationale.txt): the first real protocol microcode run
   through the dual-engine core, not a synthetic byte relay. SPI
   master, mode 0 (CPOL=0/CPHA=0: idle-low clock, data setup while
   SCLK is low, sampled on SCLK's rising edge), full duplex, one byte.

   Pin assignment (all on the shared 8-bit pins_in/separate-per-engine
   pins_out buses dual.ml already provides):
     0 = SCLK  (uE0 output, master-generated)
     1 = MOSI  (uE0 output)
     2 = MISO  (uE0 input, sampled via SHIFT_IO)
     3 = CS_n  (uE0 output, active low)
     4 = DATA_FLAG (uE1 output -- reflects bit 7 of the received byte,
         a real "packet FSM" use of BRANCH_COND_WORD, not just a
         synthetic FIFO relay like test_dual.ml)

   Split across the two engines exactly per the design blueprint's own
   division: uE0 owns bit-level timing (SCLK generation via EMIT_STATE
   + timed WAIT_EDGE half-period delays, MOSI drive, MISO sample),
   uE1 owns packet-level response (pop the assembled byte, branch on
   its content, drive a response pin).

   Real ISA limitation surfaced writing this: EMIT_STATE's driven
   level is a compile-time bit baked into the instruction (`mode`),
   not sourced from a register -- there is no "shift a live register
   out one bit per cycle" primitive. So MOSI's byte is a fixed,
   unrolled compile-time pattern here (0xA5), the same way the
   UART RX microcode already unrolls its 8 data-bit waits -- this
   proves the bit-timing/full-duplex mechanism genuinely works, but a
   host wanting to transmit ARBITRARY runtime data would need either a
   new opcode (shift-register-driven output) or per-transfer
   reprogramming through the loader. Worth flagging in docs/design/design_rationale.txt
   rather than glossing over.

   Verification strategy: a software SPI SLAVE model lives in this
   testbench's own per-cycle loop (not in RTL) -- it watches uE0's
   SCLK/MOSI outputs, drives MISO from its own known TX byte, and
   independently reconstructs what it received on MOSI. This checks
   BOTH directions bit-for-bit: the master's own transmitted pattern
   (against the slave's independent capture) and the received byte
   (against Dual.O.rx_word, which came through uE0's SHIFT_IO -> FIFO
   -> uE1's FIFO_POP, the same pipeline test_dual.ml already proved
   for a synthetic payload -- this is the first time it carries a
   real sampled protocol byte). *)

let half_period = 4
let master_tx_byte = 0xA5 (* 1010_0101 *)
let slave_tx_byte = 0x96 (* 1001_0110, MSB=1 so DATA_FLAG should end up high *)

let sclk = 0
let mosi = 1
let miso = 2
let cs_n = 3
let data_flag = 4

let spi_master_prog tx_byte =
  let bits = List.init 8 (fun i -> (tx_byte lsr (7 - i)) land 1 = 1) in
  Engine.[ emit_state ~pin:cs_n ~level:false
         ; wait_edge ~pin:0 ~falling:true ~payload:half_period
         ]
  @ List.concat
      (List.mapi
         (fun i bit ->
           let last = i = 7 in
           Engine.
             [ emit_state ~pin:mosi ~level:bit
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; emit_state ~pin:sclk ~level:true
             ; (if last then shift_in_push ~pin:miso else shift_in ~pin:miso)
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; emit_state ~pin:sclk ~level:false
             ])
         bits)
  @ Engine.[ emit_state ~pin:cs_n ~level:true ]

(* 0: pop the received byte
   1: if bit 7 = 1, jump to 4 (MSB=1 path)
   2: DATA_FLAG = 0            (MSB=0 path)
   3: unconditional-in-this-path skip to 5 (bit 7 is still 0 here,
      same rx_word, no FIFO_POP in between -- deterministic, not a race)
   4: DATA_FLAG = 1            (MSB=1 path)
   5: pop again (idle/loop point -- also just what running off the end
      into zero-valued memory would do anyway, written explicitly for
      clarity) *)
let protocol_prog =
  Protocol_engine.
    [ fifo_pop_instr
    ; branch_word ~bit:7 ~branch_if_one:true ~target:4
    ; emit_state ~pin:data_flag ~level:false
    ; branch_word ~bit:7 ~branch_if_one:false ~target:5
    ; emit_state ~pin:data_flag ~level:true
    ; fifo_pop_instr
    ]

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

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

  let master_prog = spi_master_prog master_tx_byte in
  List.iteri
    (fun i w ->
      inputs.phys_write_addr := Bits.of_int ~width:9 i;
      inputs.phys_write_data := Bits.of_int ~width:16 w;
      inputs.phys_write_enable := Bits.vdd;
      cycle ())
    master_prog;
  inputs.phys_write_enable := Bits.gnd;

  List.iteri
    (fun i w ->
      inputs.protocol_write_addr := Bits.of_int ~width:9 i;
      inputs.protocol_write_data := Bits.of_int ~width:16 w;
      inputs.protocol_write_enable := Bits.vdd;
      cycle ())
    protocol_prog;
  inputs.protocol_write_enable := Bits.gnd;

  inputs.run := Bits.vdd;
  inputs.protocol_run := Bits.vdd;

  (* Software SPI slave model: drives MISO from its own shift register,
     samples MOSI on every SCLK rising edge it observes. Rotating the
     slave's own register happens on the FOLLOWING falling edge, not
     the rising edge itself -- uE0's pins_out/pc are both registered
     off the same combinational decode of `instr`, so the cycle where
     this loop observes "SCLK just went high" is actually one cycle
     BEHIND the emit_state instruction that caused it; uE0's shift_in
     (the instruction right after emit_state SCLK-high in program
     order) doesn't actually sample pins_in until the NEXT cycle after
     that. Rotating at the rising edge presented the wrong (next) bit
     one step too early for every sample -- confirmed by hand: 0x96
     shifted early with a zero-fill tail is exactly 0x2c, the wrong
     value this test first produced. Rotating on the falling edge
     instead (a full half-period later, well after the real sample
     already happened) fixes it with no RTL change needed -- this was
     a testbench modeling bug, not an engine.ml bug. *)
  let slave_shift = ref slave_tx_byte in
  let prev_sclk = ref 0 in
  let received_mosi_bits = ref [] in

  let total_cycles = 1 + half_period + (8 * ((2 * half_period) + 4)) + 20 in
  for _ = 1 to total_cycles do
    let slave_bit = (!slave_shift lsr 7) land 1 in
    inputs.pins_in := Bits.of_int ~width:8 (slave_bit lsl miso);
    cycle ();
    let phys_out = Bits.to_int !(outputs.phys_pins_out) in
    let cur_sclk = (phys_out lsr sclk) land 1 in
    if cur_sclk = 1 && !prev_sclk = 0 then begin
      let mosi_bit = (phys_out lsr mosi) land 1 in
      received_mosi_bits := mosi_bit :: !received_mosi_bits
    end;
    if cur_sclk = 0 && !prev_sclk = 1 then begin
      slave_shift := (!slave_shift lsl 1) land 0xFF
    end;
    prev_sclk := cur_sclk
  done;

  let received_mosi_bits = List.rev !received_mosi_bits in
  let slave_received_byte =
    List.fold_left (fun acc b -> (acc lsl 1) lor b) 0 received_mosi_bits
  in
  let rx_word = Bits.to_int !(outputs.rx_word) in
  let protocol_pins_out = Bits.to_int !(outputs.protocol_pins_out) in
  let data_flag_bit = (protocol_pins_out lsr data_flag) land 1 in
  let expected_data_flag = (slave_tx_byte lsr 7) land 1 in

  Printf.printf "=== SPI master microcode, mode 0, full duplex ===\n";
  Printf.printf "  bits sampled by slave on MOSI: %d (expected 8)\n"
    (List.length received_mosi_bits);
  Printf.printf "  slave-reconstructed MOSI byte: 0x%02x (expected 0x%02x)\n"
    slave_received_byte master_tx_byte;
  Printf.printf "  uE1 rx_word (uE0's sampled MISO byte, via FIFO): 0x%04x (expected 0x%02x)\n"
    rx_word slave_tx_byte;
  Printf.printf "  DATA_FLAG (uE1, bit 7 of received byte): %d (expected %d)\n"
    data_flag_bit expected_data_flag;

  let mosi_ok = slave_received_byte = master_tx_byte in
  let miso_ok = rx_word = slave_tx_byte in
  let flag_ok = data_flag_bit = expected_data_flag in
  let passed = mosi_ok && miso_ok && flag_ok && List.length received_mosi_bits = 8 in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
