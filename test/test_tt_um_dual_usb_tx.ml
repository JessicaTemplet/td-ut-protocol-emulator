open Hardcaml
open Tt_core

(* USB low-speed TRANSMIT through tt_um_dual's REAL pins: the program, µE1's
   packet and the profile are loaded over the byte-serial pins (profile
   bytes with cfg_sel), then D-/D+ are read off uio_out and sampled
   mid-cell against an independent reference encoder. This is the Cyclesim
   twin of gl_test/test.py's usb_low_speed_transmit, with the same program
   (duplicated from gen_vectors.ml, as the SPI/I2C/USB-receive pin-level
   tests duplicate theirs). *)

let dm = 0
let dp = 1
let t = 30
let cell = t + 3
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

let cfg_bytes =
  [ 0b1001_1011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

let program =
  let wait n = Engine.wait_edge ~pin:7 ~falling:true ~payload:n in
  Engine.
    [ pipe_ctrl_ext ~tx_reset:true ~prev_level:true ()
    ; emit_state ~pin:dm ~level:true
    ; emit_state ~pin:dp ~level:false
    ; wait t
    ; emit_tx ~differential:true ~pin:dm ()
    ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:3
    ; pipe_ctrl_ext ~tx_crc:true ()
    ; wait (t - 1)
    ; emit_tx ~differential:true ~pin:dm ()
    ; release_pin ~pin:7
    ; wait t
    ; emit_tx ~differential:true ~pin:dm ()
    ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:10
    ; wait t
    ; emit_state ~pin:dm ~level:false
    ; emit_state ~pin:dp ~level:false
    ; wait ((2 * t) + 4)
    ; emit_state ~pin:dm ~level:true
    ; wait t
    ; release_pin ~pin:dm
    ; release_pin ~pin:dp
    ; wait_edge ~pin:7 ~falling:true ~payload:0
    ]

let protocol_prog packet =
  let n = List.length packet in
  List.mapi (fun k b -> Protocol_engine.tx_push ~last:(k = n - 1) b) packet
  @ [ Protocol_engine.fifo_pop_instr ]

(* ---- reference encoder ---- *)
let bits_lsb x = List.init 8 (fun i -> (x lsr i) land 1)

let crc16 bytes =
  let crc = ref 0xFFFF in
  List.iter
    (fun b ->
      let fb = (!crc land 1) lxor b in
      crc := !crc lsr 1;
      if fb = 1 then crc := !crc lxor 0xA001)
    (List.concat_map bits_lsb bytes);
  lnot !crc land 0xFFFF

let stuff bits =
  let out = ref [] and ones = ref 0 in
  List.iter
    (fun b ->
      out := b :: !out;
      if b = 1 then incr ones else ones := 0;
      if !ones = 6 then (out := 0 :: !out; ones := 0))
    bits;
  List.rev !out

let nrzi bits =
  let level = ref 1 in
  List.map (fun b -> if b = 0 then level := 1 - !level; !level) bits

(* 1 = J, 0 = K, 2 = SE0 *)
let reference payload =
  let c = crc16 payload in
  nrzi (stuff (List.concat_map bits_lsb ((0x80 :: 0xC3 :: payload) @ [ lo c; hi c ]))) @ [ 2; 2; 1 ]

module Sim = Cyclesim.With_interface (I) (O)

let uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
  (cfg_sel lsl 4) lor (engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe

(* returns (checksum ok, symbols seen, D+ always the complement during data) *)
let run payload =
  let packet = 0x80 :: 0xC3 :: payload in
  let proto = protocol_prog packet in
  let sim = Sim.create tt_um_dual in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in
  let set ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
    inputs.uio_in := Bits.of_int ~width:8 (uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe)
  in
  inputs.ena := Bits.vdd;
  inputs.rst_n := Bits.gnd;
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  let pulse ~cfg_sel ~engine_sel ~byte_sel ~data =
    inputs.ui_in := Bits.of_int ~width:8 data;
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:0;
    settle ();
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:1;
    settle ();
    set ~cfg_sel ~engine_sel ~go:0 ~byte_sel ~strobe:0;
    settle ()
  in
  pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:0 ~data:0 (* prescale *);
  List.iter (fun data -> pulse ~cfg_sel:1 ~engine_sel:0 ~byte_sel:0 ~data) cfg_bytes;
  let load ~engine_sel prog =
    List.iter
      (fun w ->
        pulse ~cfg_sel:0 ~engine_sel ~byte_sel:0 ~data:(lo w);
        pulse ~cfg_sel:0 ~engine_sel ~byte_sel:1 ~data:(hi w))
      prog
  in
  load ~engine_sel:0 program;
  load ~engine_sel:1 proto;
  let xor_words p = List.fold_left (fun a w -> a lxor lo w lxor hi w) 0 p in
  let expected = List.fold_left ( lxor ) 0 cfg_bytes lxor xor_words program lxor xor_words proto in
  let checksum_ok = Bits.to_int !(outputs.uo_out) = expected in
  set ~cfg_sel:0 ~engine_sel:0 ~go:1 ~byte_sel:0 ~strobe:0;
  settle ();
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  settle ();
  let n_sym = List.length (reference payload) in
  let total = 200 + ((n_sym + 4) * cell) in
  let trace = Array.make total (0, 0) in
  for c = 0 to total - 1 do
    cycle ();
    trace.(c) <- (Bits.to_int !(outputs.uio_out), Bits.to_int !(outputs.uio_oe))
  done;
  let bit x k = (x lsr k) land 1 in
  let start = ref (-1) in
  Array.iteri (fun c (o, e) -> if !start < 0 && bit e dm = 1 && bit o dm = 0 then start := c) trace;
  if !start < 0 then (checksum_ok, [], false)
  else begin
    let comp = ref true in
    let seen =
      List.init n_sym (fun k ->
        let o, e = trace.(!start + (k * cell) + (cell / 2)) in
        if bit e dm = 0 || bit e dp = 0 then comp := false;
        if k < n_sym - 3 && bit o dp <> 1 - bit o dm then comp := false;
        if bit o dm = 0 && bit o dp = 0 then 2 else bit o dm)
    in
    (checksum_ok, seen, !comp)
  end

let () =
  Printf.printf "=== USB low-speed TX through tt_um_dual's REAL pins (profile loaded via cfg_sel) ===\n";
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let cs, seen, comp = run gd in
  Printf.printf "  load checksum incl. profile bytes matches at uo_out: %b (expected true)\n" cs;
  Printf.printf "  GET_DESCRIPTOR DATA0 line matches the reference encoder: %b (expected true)\n" (seen = reference gd);
  Printf.printf "  D+ the complement of D- in every data cell: %b (expected true)\n" comp;
  let stuffy = [ 0xFF; 0xFF; 0x7F; 0x00 ] in
  let cs2, seen2, comp2 = run stuffy in
  Printf.printf "  stuffing-heavy payload FF FF 7F 00 matches too: %b (expected true)\n" (seen2 = reference stuffy);
  let passed = cs && seen = reference gd && comp && cs2 && seen2 = reference stuffy && comp2 in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
