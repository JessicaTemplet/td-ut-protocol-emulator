open Hardcaml
open Tt_core

(* Real pin-level proof that the I2C master READ microcode
   (test_i2c_master.ml, already proven at the Dual/behavioral-RAM
   level) also runs correctly through tt_um_dual's REAL host-facing
   pins -- same gap this closes for SPI in test_tt_um_dual_spi.ml, now
   for the genuinely open-drain protocol (SDA/SCL both use
   release_pin/pins_oe, unlike SPI's plain push-pull), which is the
   more demanding case for tt_core.ml's per-pin output-enable combine
   logic: a real, dynamically-changing oe signal (SDA toggles between
   driven and released every half-period through the microcode) has to
   survive the OR-of-both-engines'-oe / protocol-wins-on-contention
   arbitration and still come out onto uio_oe/uio_out correctly.

   ONLY the ACK (full read) scenario is ported here, not the NACK/abort
   scenario test_i2c_master.ml also covers -- the NACK branch is a pure
   uE0-internal decision (BRANCH_COND on a level already visible to
   uE0) that doesn't exercise anything new at THIS wrapper level (SDA/
   SCL are never contended between uE0 and uE1 in this microcode --
   uE1 only ever drives DATA_FLAG, pin 2 -- so tt_core.ml's
   protocol-wins-on-contention policy is never actually invoked by
   either scenario). The NACK path stays fully covered by
   test_i2c_master.ml at the Dual level; re-deriving it here would only
   re-prove uE0's own branch logic, not the pin wrapper.

   Microcode is intentionally duplicated from test_i2c_master.ml, same
   self-containment reasoning as test_tt_um_dual_spi.ml. `load_and_go`
   is duplicated from test_tt_um_dual.ml/test_tt_um_dual_spi.ml for the
   same reason. *)

let sda = 0
let scl = 1
let half_period = 4
let addr_rw_byte = 0xB5
let slave_data_byte = 0x6C (* MSB=0 -> DATA_FLAG should end up low *)
let data_flag = 2

let stop_addr = 105

let i2c_master_read_prog =
  let addr_bits = List.init 8 (fun i -> (addr_rw_byte lsr (7 - i)) land 1 = 1) in
  let drive_bit ~pin ~bit = if bit then Engine.release_pin ~pin else Engine.emit_state ~pin ~level:false in
  Engine.
    [ release_pin ~pin:sda
    ; release_pin ~pin:scl
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; emit_state ~pin:sda ~level:false
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; emit_state ~pin:scl ~level:false
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
      [ release_pin ~pin:sda
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; release_pin ~pin:scl
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; branch_cond ~pin:sda ~branch_if_high:true ~target:stop_addr
      ; emit_state ~pin:scl ~level:false
      ]
  @ List.concat
      (List.init 8 (fun i ->
           let last = i = 7 in
           Engine.
             [ release_pin ~pin:sda
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; release_pin ~pin:scl
             ; (if last then shift_in_push ~pin:sda else shift_in ~pin:sda)
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; emit_state ~pin:scl ~level:false
             ]))
  @ Engine.
      [ release_pin ~pin:sda
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
    ; release_pin ~pin:sda
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

module Sim = Cyclesim.With_interface (I) (O)

let load_and_go ~(sim : Sim.t) ~phys_prog ~protocol_prog =
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in
  let set_uio ~strobe ~byte_sel ~go ~engine_sel =
    inputs.uio_in :=
      Bits.of_int ~width:8
        ((engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe)
  in
  inputs.rst_n := Bits.gnd;
  inputs.ui_in := Bits.of_int ~width:8 0;
  set_uio ~strobe:0 ~byte_sel:0 ~go:0 ~engine_sel:0;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  let pulse_byte ~engine_sel ~byte_sel ~data =
    inputs.ui_in := Bits.of_int ~width:8 data;
    set_uio ~strobe:0 ~byte_sel ~go:0 ~engine_sel;
    settle ();
    set_uio ~strobe:1 ~byte_sel ~go:0 ~engine_sel;
    settle ();
    set_uio ~strobe:0 ~byte_sel ~go:0 ~engine_sel;
    settle ()
  in
  pulse_byte ~engine_sel:0 ~byte_sel:0 ~data:0;
  let load_prog ~engine_sel prog =
    List.iter
      (fun w ->
        pulse_byte ~engine_sel ~byte_sel:0 ~data:(w land 0xFF);
        pulse_byte ~engine_sel ~byte_sel:1 ~data:((w lsr 8) land 0xFF))
      prog
  in
  load_prog ~engine_sel:0 phys_prog;
  load_prog ~engine_sel:1 protocol_prog;
  let checksum_of prog =
    List.fold_left (fun acc w -> acc lxor (w land 0xFF) lxor ((w lsr 8) land 0xFF)) 0 prog
  in
  let expected_checksum = checksum_of phys_prog lxor checksum_of protocol_prog in
  let checksum_ok = Bits.to_int !(outputs.uo_out) = expected_checksum in
  set_uio ~strobe:0 ~byte_sel:0 ~go:1 ~engine_sel:0;
  settle ();
  set_uio ~strobe:0 ~byte_sel:0 ~go:0 ~engine_sel:0;
  settle ();
  checksum_ok

let () =
  Printf.printf "=== I2C master READ microcode through tt_um_dual's REAL pins (open-drain SDA/SCL over uio) ===\n";
  let sim = Sim.create tt_um_dual in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in

  assert (List.length i2c_master_read_prog - 6 = stop_addr);

  let checksum_ok = load_and_go ~sim ~phys_prog:i2c_master_read_prog ~protocol_prog in
  Printf.printf "  combined load checksum matches at uo_out: %b (expected true)\n" checksum_ok;

  (* Wired-AND SDA modeling, same technique test_i2c_master.ml uses,
     now reading/driving through the real combined uio_out/uio_oe/
     uio_in instead of Dual's internal phys_pins_out/phys_pins_oe/
     pins_in -- since uE1 never drives pins 0/1, the combined signals
     equal uE0's own values for those two bits, so this is a faithful
     port, not an approximation. *)
  let edge_index = ref 0 in
  let slave_data_shift = ref slave_data_byte in
  let slave_drive = ref 1 in
  let addr_captured = ref 0 in
  let prev_scl = ref 1 in

  let total_cycles =
    3 + (2 * half_period)
    + (8 * (2 * half_period))
    + (2 * half_period)
    + (8 * (2 * half_period))
    + (2 * half_period)
    + (3 * half_period)
    + 30
  in
  for _ = 1 to total_cycles do
    let master_out = Bits.to_int !(outputs.uio_out) in
    let master_oe = Bits.to_int !(outputs.uio_oe) in
    let master_drives_sda_low = ((master_oe lsr sda) land 1 = 1) && ((master_out lsr sda) land 1 = 0) in
    let sda_net = if master_drives_sda_low || !slave_drive = 0 then 0 else 1 in
    let scl_net = if (master_oe lsr scl) land 1 = 1 then (master_out lsr scl) land 1 else 1 in
    inputs.uio_in := Bits.of_int ~width:8 ((sda_net lsl sda) lor (scl_net lsl scl));
    cycle ();
    let cur_scl = scl_net in
    if cur_scl = 1 && !prev_scl = 0 then begin
      if !edge_index < 8 then addr_captured := (!addr_captured lsl 1) lor sda_net;
      incr edge_index
    end;
    if cur_scl = 0 && !prev_scl = 1 then begin
      if !edge_index < 8 then slave_drive := 1
      else if !edge_index = 8 then slave_drive := 0 (* ACK *)
      else if !edge_index = 9 then slave_drive := (!slave_data_shift lsr 7) land 1
      else if !edge_index <= 16 then begin
        slave_data_shift := (!slave_data_shift lsl 1) land 0xFF;
        slave_drive := (!slave_data_shift lsr 7) land 1
      end
      else slave_drive := 1
    end;
    prev_scl := cur_scl
  done;

  let final_uio_out = Bits.to_int !(outputs.uio_out) in
  let final_uio_oe = Bits.to_int !(outputs.uio_oe) in
  let data_flag_bit = (final_uio_out lsr data_flag) land 1 in
  let data_flag_oe = (final_uio_oe lsr data_flag) land 1 in
  let expected_data_flag = (slave_data_byte lsr 7) land 1 in
  let addr_ok = !addr_captured = addr_rw_byte in

  Printf.printf
    "  SCL rising edges observed: %d (expected 19: 8 addr + 1 ack + 8 data + 1 master-nack + 1 STOP's own release)\n"
    !edge_index;
  Printf.printf "  slave-captured address+R/W byte (via uio_out wired-AND): 0x%02x (expected 0x%02x)\n"
    !addr_captured addr_rw_byte;
  Printf.printf "  DATA_FLAG on real pin %d: oe=%d level=%d (expected oe=1, level=%d)\n" data_flag
    data_flag_oe data_flag_bit expected_data_flag;

  let edges_ok = !edge_index = 19 in
  let flag_ok = data_flag_oe = 1 && data_flag_bit = expected_data_flag in
  let passed = checksum_ok && edges_ok && addr_ok && flag_ok in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
