open Hardcaml
open Tt_core

(* Roadmap item #4 (docs/design/design_rationale.txt), second real protocol: I2C master
   READ, one address+R/W byte followed by one data byte, standard
   7-bit-address framing (the address+R/W byte's actual 7/1 split
   doesn't matter to this microcode -- it's just 8 bits clocked out
   the same way as any other byte; a real host driver would form it
   from a 7-bit address + R/W, this test just picks a fixed pattern).

   Both SDA and SCL are genuinely open-drain here (unlike SPI, which
   never needed release_pin at all) -- this is what actually exercises
   the bidirectional-pin mechanism `release_pin`/`pins_oe` were built
   for (see docs/design/design_rationale.txt's "Pin bus moved onto uio" section), not just
   SPI's simpler push-pull drive.

   Pins: 0 = SDA, 1 = SCL (both open-drain, master + software slave
   model both only ever drive low or release -- external pull-up is
   emulated in this testbench's own per-cycle wired-AND, same
   technique test_tt_um_dual.ml already used for its pin-release
   proof).

   Sequence, all on uE0 (bit-level timing is entirely a physical-layer
   concern here, same split as SPI):
     START (SDA falls while SCL held high)
     -> 8 address+R/W bits (MSB first, set up while SCL low, clocked
        on SCL rising)
     -> ACK1: release SDA, clock SCL, BRANCH_COND on SDA's level
        (SDA low = ACK, keeps going; SDA high = NACK, branches
        straight to the STOP sequence -- a real uE0-level protocol
        decision, not deferred to uE1)
     -> 8 data bits, released and driven by the SLAVE now, sampled by
        uE0 via SHIFT_IO (push on the 8th) -- the actual open-drain
        RX path
     -> master NACK (release SDA, standard "stop sending, this was the
        last byte" signal)
     -> STOP (SDA released -- rises -- while SCL held high). This
        address is ALSO the ACK1-failure branch target, so the abort
        and success paths share the same STOP code -- no separate
        abort sequence needed.

   uE1: same shape as the SPI test's demo -- pop the received data
   byte, BRANCH_COND_WORD on its MSB, reflect it on a response pin.
   Proves the FIFO/uE1 packet-layer path carries a real I2C-sampled
   byte just as well as it carried SPI's.

   Verification is the same discipline as the SPI test: a software
   slave lives in the testbench's own cycle loop, but this one has to
   model a genuinely bidirectional, wired-AND bus (SDA), not just
   watch and reproduce fixed levels -- the actual bus value each cycle
   is computed as "low if EITHER side is pulling low, else high (pulled
   up)", and fed back into BOTH the master's own pins_in (so it can
   read what it and/or the slave are jointly driving) exactly like a
   real shared net. Same falling-edge-only rotation discipline the SPI
   test's fix established applies here too, for the same reason
   (uE0's registered pc/pins_out pipeline means a value must be stable
   one full half-period before the cycle that actually samples it, not
   just "as soon as we know it"). *)

let sda = 0
let scl = 1
let half_period = 4
let addr_rw_byte = 0xB5 (* 1011_0101 -- arbitrary fixed address+R/W pattern *)
let slave_data_byte = 0x6C (* 0110_1100, MSB=0 -> DATA_FLAG should end up low *)
let data_flag = 2

let stop_addr = 105

let i2c_master_read_prog =
  let addr_bits = List.init 8 (fun i -> (addr_rw_byte lsr (7 - i)) land 1 = 1) in
  let drive_bit ~pin ~bit = if bit then Engine.release_pin ~pin else Engine.emit_state ~pin ~level:false in
  Engine.
    [ release_pin ~pin:sda
    ; release_pin ~pin:scl
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; emit_state ~pin:sda ~level:false (* START: SDA falls while SCL released/high *)
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; emit_state ~pin:scl ~level:false (* begin clocking *)
    ]
  @ List.concat_map
      (fun bit ->
        Engine.
          [ drive_bit ~pin:sda ~bit
          ; wait_edge ~pin:0 ~falling:true ~payload:half_period
          ; release_pin ~pin:scl
          ; wait_edge ~pin:0 ~falling:true ~payload:half_period
          ; emit_state ~pin:scl ~level:false
          ])
      addr_bits
  @ Engine.
      [ release_pin ~pin:sda (* ACK1: let slave drive *)
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; release_pin ~pin:scl
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; branch_cond ~pin:sda ~branch_if_high:true ~target:stop_addr (* NACK -> straight to STOP *)
      ; emit_state ~pin:scl ~level:false
      ]
  @ List.concat
      (List.init 8 (fun i ->
           let last = i = 7 in
           Engine.
             [ release_pin ~pin:sda (* let slave drive this data bit *)
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; release_pin ~pin:scl
             ; (if last then shift_in_push ~pin:sda else shift_in ~pin:sda)
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; emit_state ~pin:scl ~level:false
             ]))
  @ Engine.
      [ release_pin ~pin:sda (* master NACK: release, don't pull low *)
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; release_pin ~pin:scl
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; emit_state ~pin:scl ~level:false
      ]
  @ (* stop_addr: *)
  Engine.
    [ emit_state ~pin:sda ~level:false
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; release_pin ~pin:scl
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; release_pin ~pin:sda (* STOP: SDA rises while SCL held high *)
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ]

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

(* Runs the microcode against a software slave that either always ACKs
   (proving the full read path) or never ACKs (proving uE0's own
   BRANCH_COND actually aborts straight to STOP -- an untested branch
   target is exactly the kind of thing this project's own "test every
   increment" discipline exists to catch). Returns true on success. *)
let run_scenario ~slave_acks =
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
    i2c_master_read_prog;
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

  (* Software I2C slave model. `edge_index` counts SCL rising edges
     seen so far: 0-7 = address+R/W bits (slave just samples, no
     timing hazard, same as SPI's MOSI capture), 8 = ACK1 (slave
     drives), 9-16 = 8 data bits (slave drives, uE0 samples via
     SHIFT_IO), 17 = master's NACK (slave doesn't care). `slave_drive`
     (1 = release/high contribution, 0 = actively pull low) is only
     ever updated on a FALLING edge -- one full half-period before the
     next rising edge actually samples it, for the same reason the SPI
     test's slave had to rotate on the falling edge, not the rising
     edge, to avoid presenting next-bit-too-early. *)
  let edge_index = ref 0 in
  let slave_data_shift = ref slave_data_byte in
  let slave_drive = ref 1 in
  let addr_captured = ref 0 in
  let prev_scl = ref 1 in

  (* A half period costs its WAIT (payload + 1 cycles) plus up to two
     single-cycle pin instructions. This budget once assumed half_period
     flat, which only fit because timer.ml used to cut a WAIT that follows
     a release_pin short -- i.e. SCL's high phase was 1-2 cycles. *)
  let half_cycles = half_period + 3 in
  let total_cycles =
    3 + (2 * half_cycles) (* start *)
    + (8 * (2 * half_cycles)) (* addr bits *)
    + (2 * half_cycles) (* ack1 *)
    + (8 * (2 * half_cycles)) (* data bits *)
    + (2 * half_cycles) (* master nack *)
    + (3 * half_cycles) (* stop *)
    + 30
  in
  (* shortest SCL high phase, rise to fall: I2C's tHIGH. The master holds
     SCL released for one half-period WAIT, so it must be at least
     half_period cycles. *)
  let min_high = ref max_int and rise_t = ref 0 in
  for t = 1 to total_cycles do
    let master_out = Bits.to_int !(outputs.phys_pins_out) in
    let master_oe = Bits.to_int !(outputs.phys_pins_oe) in
    let master_drives_sda_low = ((master_oe lsr sda) land 1 = 1) && ((master_out lsr sda) land 1 = 0) in
    let sda_net = if master_drives_sda_low || !slave_drive = 0 then 0 else 1 in
    let scl_net = if (master_oe lsr scl) land 1 = 1 then (master_out lsr scl) land 1 else 1 in
    inputs.pins_in := Bits.of_int ~width:8 ((sda_net lsl sda) lor (scl_net lsl scl));
    cycle ();
    let cur_scl = scl_net in
    if cur_scl = 1 && !prev_scl = 0 then begin
      (* rising edge: sample phase only reads, never drives, so no
         timing hazard capturing here (see module header) *)
      if !edge_index < 8 then
        addr_captured := (!addr_captured lsl 1) lor sda_net;
      incr edge_index;
      rise_t := t
    end;
    if cur_scl = 0 && !prev_scl = 1 then begin
      if !rise_t > 0 then min_high := min !min_high (t - !rise_t);
      (* falling edge: decide what the slave presents for the NEXT
         rising edge *)
      if !edge_index < 8 then slave_drive := 1 (* address phase: slave never drives *)
      else if !edge_index = 8 then slave_drive := (if slave_acks then 0 else 1) (* ACK1 *)
      else if !edge_index = 9 then slave_drive := (!slave_data_shift lsr 7) land 1
      else if !edge_index <= 16 then begin
        slave_data_shift := (!slave_data_shift lsl 1) land 0xFF;
        slave_drive := (!slave_data_shift lsr 7) land 1
      end
      else slave_drive := 1
    end;
    prev_scl := cur_scl
  done;

  let rx_word = Bits.to_int !(outputs.rx_word) in
  let phys_pc = Bits.to_int !(outputs.phys_pc) in
  let fifo_empty = Bits.to_int !(outputs.fifo_empty) = 1 in
  let addr_ok = !addr_captured = addr_rw_byte in
  let high_ok = !min_high >= half_period in
  Printf.printf "  shortest SCL high phase: %d cycles (must be >= half_period = %d)\n" !min_high half_period;

  high_ok
  &&
  if slave_acks then begin
    let protocol_pins_out = Bits.to_int !(outputs.protocol_pins_out) in
    let data_flag_bit = (protocol_pins_out lsr data_flag) land 1 in
    let expected_data_flag = (slave_data_byte lsr 7) land 1 in
    Printf.printf "=== I2C master READ microcode, ACK path, open-drain SDA/SCL ===\n";
    Printf.printf
      "  SCL rising edges observed: %d (expected 19: 8 addr + 1 ack + 8 data + 1 master-nack + 1 STOP's own release)\n"
      !edge_index;
    Printf.printf "  slave-captured address+R/W byte: 0x%02x (expected 0x%02x)\n" !addr_captured addr_rw_byte;
    Printf.printf "  uE1 rx_word (uE0's sampled SDA data byte, via FIFO): 0x%04x (expected 0x%02x)\n" rx_word
      slave_data_byte;
    Printf.printf "  DATA_FLAG (uE1, bit 7 of received byte): %d (expected %d)\n" data_flag_bit
      expected_data_flag;
    !edge_index = 19 && addr_ok && rx_word = slave_data_byte && data_flag_bit = expected_data_flag
  end
  else begin
    Printf.printf "=== I2C master READ microcode, NACK/abort path ===\n";
    Printf.printf "  SCL rising edges observed: %d (expected 9: 8 addr + 1 ack, aborts before any data bit)\n"
      !edge_index;
    Printf.printf "  slave-captured address+R/W byte: 0x%02x (expected 0x%02x)\n" !addr_captured addr_rw_byte;
    Printf.printf "  phys_pc landed at %d (expected >= %d, inside/after the STOP sequence)\n" phys_pc stop_addr;
    Printf.printf "  fifo empty (no byte ever pushed, since no data bits were ever clocked): %b (expected true)\n"
      fifo_empty;
    Printf.printf "  uE1 rx_word (should never have received anything): 0x%04x (expected 0x0000)\n" rx_word;
    !edge_index = 9 && addr_ok && phys_pc >= stop_addr && fifo_empty && rx_word = 0
  end

let () =
  (* Sanity check on the hand-computed branch target, before it can
     silently point at the wrong instruction. *)
  assert (List.length i2c_master_read_prog - 6 = stop_addr);
  let ack_ok = run_scenario ~slave_acks:true in
  let nack_ok = run_scenario ~slave_acks:false in
  let passed = ack_ok && nack_ok in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
