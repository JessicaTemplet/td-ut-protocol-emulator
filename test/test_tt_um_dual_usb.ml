open Hardcaml
open Tt_core

(* The USB low-speed receive demo (test_usb_rx.ml, proven at the Dual level)
   through tt_um_dual's REAL pins: program AND bit-pipe/glitch-filter
   configuration are loaded over the byte-serial pins (the new cfg_sel bit,
   uio_in[4], routes strobes to the 9 config bytes), then a packet is played
   on uio_in[1:0] (D+/D-) and the verdict is read off uio_out[3:2].

   Microcode, config and calibrated timings (B = 32 cycles/bit, i.e. USB low
   speed at 48 MHz; t0 = 12, t_wait = 27 from test_usb_rx's calibration) are
   duplicated from test_usb_rx.ml, the same self-containment convention the
   SPI/I2C pin-level tests use. If the loop's cycle cost ever changes, rerun
   test_usb_rx, which prints the new calibration. *)

let dm = 0
let dp = 1
let flag_ok = 2
let flag_done = 3
let b = 32
let t0 = 12
let t_wait = 27

let program =
  Engine.
    [ pipe_ctrl ~reset:true ~prev_level:true ~crc_init:false
    ; wait_edge ~pin:dm ~falling:true ~payload:0
    ; wait_edge ~pin:dm ~falling:true ~payload:t0
    ; branch_cond ~pin:dm ~branch_if_high:false ~target:5
    ; wait_edge ~pin:dm ~falling:true ~payload:t_wait
    ; branch_cond ~pin:dp ~branch_if_high:true ~target:8
    ; branch_cond ~pin:dm ~branch_if_high:true ~target:11
    ; branch_cond ~pin:dm ~branch_if_high:false ~target:13
    ; release_pin ~pin:7
    ; pipe_bit ~pin:dm
    ; branch_cond ~pin:dm ~branch_if_high:false ~target:4
    ; pipe_bit ~pin:dm
    ; branch_cond ~pin:dm ~branch_if_high:true ~target:4
    ; pipe_status
    ; wait_edge ~pin:7 ~falling:true ~payload:0
    ]

let protocol_prog =
  Protocol_engine.
    [ fifo_pop_instr
    ; branch_word ~bit:15 ~branch_if_one:true ~target:3
    ; branch_word ~bit:15 ~branch_if_one:false ~target:0
    ; branch_word ~bit:0 ~branch_if_one:false ~target:8
    ; branch_word ~bit:1 ~branch_if_one:true ~target:8
    ; branch_word ~bit:2 ~branch_if_one:false ~target:8
    ; emit_state ~pin:flag_ok ~level:true
    ; branch_word ~bit:15 ~branch_if_one:true ~target:9
    ; emit_state ~pin:flag_ok ~level:false
    ; emit_state ~pin:flag_done ~level:true
    ; fifo_pop_instr
    ]

let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

let cfg_bytes =
  [ 0b011011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

let bits_of_byte_lsb x = List.init 8 (fun i -> (x lsr i) land 1)

let usb_crc16 bytes =
  let crc = ref 0xFFFF in
  List.iter
    (fun by ->
      List.iter
        (fun bit ->
          let fb = (!crc land 1) lxor bit in
          crc := !crc lsr 1;
          if fb = 1 then crc := !crc lxor 0xA001)
        (bits_of_byte_lsb by))
    bytes;
  lnot !crc land 0xFFFF

let stuff bits =
  let out = ref [] and ones = ref 0 in
  List.iter
    (fun x ->
      out := x :: !out;
      if x = 1 then incr ones else ones := 0;
      if !ones = 6 then (out := 0 :: !out; ones := 0))
    bits;
  List.rev !out

let nrzi bits =
  let level = ref 1 in
  List.map (fun x -> if x = 0 then level := 1 - !level; !level) bits

let packet_symbols payload =
  let c = usb_crc16 payload in
  let bits =
    bits_of_byte_lsb 0x80 @ bits_of_byte_lsb 0xC3
    @ List.concat_map bits_of_byte_lsb (payload @ [ lo c; hi c ])
  in
  nrzi (stuff bits) @ [ 2; 2; 1 ]

module Sim = Cyclesim.With_interface (I) (O)

let uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
  (cfg_sel lsl 4) lor (engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe

(* returns (checksum_ok, flag_ok, flag_done) after playing [symbols] *)
let run symbols =
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
  inputs.ui_in := Bits.of_int ~width:8 0;
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
  load ~engine_sel:1 protocol_prog;
  let xor_words p = List.fold_left (fun a w -> a lxor lo w lxor hi w) 0 p in
  let expected = List.fold_left ( lxor ) 0 cfg_bytes lxor xor_words program lxor xor_words protocol_prog in
  let checksum_ok = Bits.to_int !(outputs.uo_out) = expected in
  set ~cfg_sel:0 ~engine_sel:0 ~go:1 ~byte_sel:0 ~strobe:0;
  settle ();
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  settle ();
  (* play the packet on D-/D+ (uio_in[0], uio_in[1]) *)
  let syms = Array.of_list symbols in
  let n = Array.length syms in
  let total = 40 + (n * b) + 400 in
  for t = 0 to total - 1 do
    let s = if t < 40 then 1 else (let k = (t - 40) / b in if k < n then syms.(k) else 1) in
    let dmv = if s = 1 then 1 else 0 and dpv = if s = 0 then 1 else 0 in
    inputs.uio_in := Bits.of_int ~width:8 ((dmv lsl dm) lor (dpv lsl dp));
    cycle ()
  done;
  let out = Bits.to_int !(outputs.uio_out) and oe = Bits.to_int !(outputs.uio_oe) in
  let bit x k = (x lsr k) land 1 in
  (checksum_ok, bit out flag_ok = 1 && bit oe flag_ok = 1, bit out flag_done = 1 && bit oe flag_done = 1)

let () =
  Printf.printf "=== USB low-speed RX through tt_um_dual's REAL pins (config loaded via cfg_sel) ===\n";
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let cs, ok, dn = run (packet_symbols gd) in
  Printf.printf "  load checksum incl. config bytes matches at uo_out: %b (expected true)\n" cs;
  Printf.printf "  good packet: flag_ok=%b flag_done=%b (expected true,true)\n" ok dn;
  let bad = Array.of_list (packet_symbols gd) in
  let k = 36 in
  bad.(k) <- (if bad.(k) = 1 then 0 else 1);
  let cs2, ok2, dn2 = run (Array.to_list bad) in
  Printf.printf "  corrupted packet: flag_ok=%b flag_done=%b (expected false,true)\n" ok2 dn2;
  let passed = cs && ok && dn && cs2 && (not ok2) && dn2 in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
