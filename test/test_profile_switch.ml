open Hardcaml
open Tt_core

(* Profile switches at the awkward points, on the dual-engine core.

   The selected profile is registered on its way to the pipes, so a pointer
   write reaches them Profile_table.select_latency cycles later. Two things
   must hold despite that, and each case below fails if one does not:

   1. A control that comes with the switch acts on the NEW profile: a
      PIPE_CTRL that selects profile 1 and resets the stream loads profile
      1's CRC init, not profile 0's (`after_select` alignment).
   2. A pipe instruction issued right after the switch uses the NEW profile:
      a PIPE_BIT on the very next instruction is held until the switch has
      landed (`settling` interlock), so all 8 bits go through profile 1.

   The two profiles differ only in what makes each failure visible: profile
   0 has the CRC off and init 0x1234, profile 1 a CRC16 (0x8005, MSB-first
   shift, init 0xFFFF, residue 0). µE0 switches, reads 8 bits of a line
   held high, and pushes the CRC (PIPE_STATUS crc_lo); µE1 pops it. The
   reference CRC is computed here, independently:
   - correct:             CRC16 of 8 ones from 0xFFFF
   - interlock missing:   the first bits are stepped before the switch lands
                          (on profile 0, no CRC, or into the reset): fewer
                          than 8 ones reach the CRC
   - alignment missing:   the reset loads profile 0's init: 8 ones from 0x1234
   The mutation check (scripts/run_tx_mutation_test.sh) removes each
   mechanism in turn and confirms this test fails. *)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let crc16 ~init ~n_ones =
  let c = ref init in
  for _ = 1 to n_ones do
    let fb = ((!c lsr 15) land 1) lxor 1 in
    c := ((!c lsl 1) land 0xFFFF) lxor (if fb = 1 then 0x8005 else 0)
  done;
  !c

let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

(* profile byte k (bitpipe.ml layout); everything not listed is 0 *)
let profile0 = [ (5, lo 0x1234); (6, hi 0x1234) ]

let profile1 =
  [ (0, 0b0000_1000) (* crc_en; NRZI, stuffing, reflection off; LSB-first bytes *)
  ; (2, 15) (* CRC width 16, skip 0 bytes *)
  ; (3, lo 0x8005); (4, hi 0x8005)
  ; (5, 0xFF); (6, 0xFF)
  ]

let phys_prog =
  Engine.(
    [ pipe_ctrl_ext ~reset:true ~prev_level:true ~sel_rx:true ~profile:1 () ]
    @ List.init 8 (fun _ -> pipe_bit ~pin:0)
    @ [ pipe_crc_lo; wait_edge ~pin:7 ~falling:true ~payload:0 ])

let protocol_prog = Protocol_engine.[ fifo_pop_instr; fifo_pop_instr; fifo_pop_instr ]

let () =
  Printf.printf "=== Profile switch: controls and pipe instructions act on the new profile ===\n";
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.pins_in := Bits.of_int ~width:8 0xFF;
  cycle ();
  i.rst_n := Bits.vdd;
  let cfg p bytes =
    List.iter
      (fun (k, v) ->
        i.cfg_addr := Bits.of_int ~width:7 ((Profile_table.stride * p) + k);
        i.cfg_data := Bits.of_int ~width:8 v;
        i.cfg_we := Bits.vdd;
        cycle ())
      bytes;
    i.cfg_we := Bits.gnd
  in
  cfg 0 profile0;
  cfg 1 profile1;
  let load we addr data prog =
    List.iteri
      (fun k w ->
        addr := Bits.of_int ~width:9 k;
        data := Bits.of_int ~width:16 w;
        we := Bits.vdd;
        cycle ())
      prog;
    we := Bits.gnd
  in
  load i.phys_write_enable i.phys_write_addr i.phys_write_data phys_prog;
  load i.protocol_write_enable i.protocol_write_addr i.protocol_write_data protocol_prog;
  for _ = 1 to Dual.sync_latency do cycle () done;
  i.run := Bits.vdd;
  i.protocol_run := Bits.vdd;
  for _ = 1 to 200 do cycle () done;
  let got = Bits.to_int !(o.Dual.O.rx_word) land 0xFFFF in
  let expect = crc16 ~init:0xFFFF ~n_ones:8 in
  let fewer = List.init 8 (fun n -> crc16 ~init:0xFFFF ~n_ones:n) in
  let misaligned = crc16 ~init:0x1234 ~n_ones:8 in
  Printf.printf "  CRC read back by uE1: 0x%04x\n" got;
  Printf.printf "  expected (all 8 bits on profile 1, its init): 0x%04x\n" expect;
  let distinct = (not (List.mem expect fewer)) && expect <> misaligned in
  Printf.printf "  the three outcomes are distinguishable: %b\n" distinct;
  let rx_on_1 = Bits.to_int !(o.Dual.O.rx_profile) = 1 in
  Printf.printf "  RX pointer now on profile 1: %b\n" rx_on_1;
  let passed = distinct && got = expect && rx_on_1 in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
