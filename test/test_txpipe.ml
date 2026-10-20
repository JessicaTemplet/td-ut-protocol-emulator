open Hardcaml
open Tt_core

(* Standalone proof of txpipe.ml (byte shift-out, CRC append, stuff
   insertion, NRZI encode) before anything depends on it.

   Two independent checks, because each alone can hide a fault:
   - Reference ENCODERS written here in plain OCaml (USB: CRC16 + stuffing
     + NRZI; CAN: CRC15 + both-polarity stuffing). The transmit pipe's line
     output must match them bit for bit. Loopback alone could hide a fault
     shared by encode and decode, such as the wrong polynomial in both.
   - LOOPBACK into the receive pipe (bitpipe.ml, already validated against
     an independent transmitter): every transmitted packet must decode to
     the same bytes with crc_ok and no stuffing error.

   Checks:
   1. UART: all-zero profile = plain LSB-first shift-out, bytes taken from
      the FIFO with no gap (auto-load), `more` stays high with no `last`.
   2. SPI: msb_first alone = plain MSB-first shift-out.
   3. USB GET_DESCRIPTOR data packet: CRC16 0xDD94 goes out as 94 DD.
   4. 300 random USB data packets (runs of 1s force stuffing, including
      stuffing inside and right after the CRC): reference match + loopback.
   5. 300 random CAN payloads (MSB-first, CRC15 not inverted, stuffing on
      both polarities): reference match + loopback.
   6. Underrun: with the FIFO empty the pipe asks for a stall, and does not
      pop. *)

module Sim = Cyclesim.With_interface (Txpipe.I) (Txpipe.O)
module Rx = Cyclesim.With_interface (Bitpipe.I) (Bitpipe.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

(* ---- profiles ---- *)
let cfg_of_bytes bytes =
  let bytes = bytes @ List.init (Bitpipe.cfg_bytes - List.length bytes) (fun _ -> 0) in
  Bits.concat_msb (List.rev_map (fun b -> Bits.of_int ~width:8 (b land 0xFF)) bytes)

let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

(* nrzi, stuff, crc, reflected, crc_out_invert; LSB-first; skip SYNC+PID *)
let usb_bytes =
  [ 0b1001_1011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

(* stuff on both polarities after 5, crc, MSB-first, CRC15 0x4599, init 0 *)
let can_bytes = [ 0b0010_1110; 5; 14; lo 0x4599; hi 0x4599; 0; 0; 0; 0 ]

(* ---- reference encoders (independent of the hardware) ---- *)
let bits_lsb b = List.init 8 (fun i -> (b lsr i) land 1)
let bits_msb b = List.init 8 (fun i -> (b lsr (7 - i)) land 1)

let usb_crc16 bytes =
  let crc = ref 0xFFFF in
  List.iter
    (fun bit ->
      let fb = (!crc land 1) lxor bit in
      crc := !crc lsr 1;
      if fb = 1 then crc := !crc lxor 0xA001)
    (List.concat_map bits_lsb bytes);
  lnot !crc land 0xFFFF

let usb_stuff bits =
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

(* SYNC, PID, payload, CRC16 over the payload *)
let usb_packet payload = (0x80 :: 0xC3 :: payload)

let usb_reference payload =
  let c = usb_crc16 payload in
  nrzi (usb_stuff (List.concat_map bits_lsb (usb_packet payload @ [ lo c; hi c ])))

let can_crc15 bits =
  let crc = ref 0 in
  List.iter
    (fun b ->
      let fb = ((!crc lsr 14) land 1) lxor b in
      crc := (!crc lsl 1) land 0x7FFF;
      if fb = 1 then crc := !crc lxor 0x4599)
    bits;
  !crc

let can_stuff bits =
  let out = ref [] and run_bit = ref (-1) and cnt = ref 0 in
  List.iter
    (fun b ->
      out := b :: !out;
      if b = !run_bit then incr cnt else (run_bit := b; cnt := 1);
      if !cnt = 5 then (
        out := (1 - b) :: !out;
        run_bit := 1 - b;
        cnt := 1))
    bits;
  List.rev !out

let can_reference payload =
  let bits = List.concat_map bits_msb payload in
  let c = can_crc15 bits in
  can_stuff (bits @ List.init 15 (fun k -> (c lsr (14 - k)) land 1))

(* ---- drive the transmit pipe ----
   [words]: FIFO contents (bit 8 = last). With [crc] the program's sequence
   is modelled: EMIT_TX while `more`, PIPE_CTRL tx_crc, EMIT_TX while `more`.
   Without it, [steps] EMIT_TXs are issued. Returns the line bits and whether
   a stall was ever requested. *)
let run_tx ~cfg ?(prev_init = 1) ?(crc = false) ?steps words =
  let sim = Sim.create Txpipe.create in
  let i = Cyclesim.inputs sim in
  let ob = Cyclesim.outputs ~clock_edge:Before sim in
  let oa = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.cfg := cfg;
  cycle ();
  i.rst_n := Bits.vdd;
  i.ctrl_reset := Bits.vdd;
  i.prev_init := Bits.of_int ~width:1 prev_init;
  cycle ();
  i.ctrl_reset := Bits.gnd;
  let queue = ref words and line = ref [] and stalled = ref false in
  let set_fifo () =
    match !queue with
    | [] -> i.fifo_empty := Bits.vdd; i.fifo_data := Bits.zero 16
    | w :: _ -> i.fifo_empty := Bits.gnd; i.fifo_data := Bits.of_int ~width:16 w
  in
  let step () =
    set_fifo ();
    i.step := Bits.vdd;
    cycle ();
    i.step := Bits.gnd;
    if Bits.to_int !(ob.would_stall) = 1 then stalled := true;
    line := Bits.to_int !(ob.line) :: !line;
    (* µE0 never steps a stalled pipe; this unit-level model does, so only
       pop what is really there *)
    if Bits.to_int !(ob.fifo_pop) = 1 && !queue <> [] then queue := List.tl !queue
  in
  let more () = Bits.to_int !(oa.more) = 1 in
  let guard = ref 0 in
  let loop () =
    while more () && !guard < 4000 && not !stalled do
      incr guard;
      step ()
    done
  in
  (match steps with
   | Some n -> for _ = 1 to n do step () done
   | None ->
     loop ();
     if crc then (
       i.ctrl_crc_append := Bits.vdd;
       set_fifo ();
       cycle ();
       i.ctrl_crc_append := Bits.gnd;
       loop ()));
  List.rev !line, !stalled

let with_last bytes =
  let n = List.length bytes in
  List.mapi (fun k b -> if k = n - 1 then 0x100 lor b else b) bytes

(* ---- feed line bits into the receive pipe ---- *)
let rx_decode ~cfg ?(prev_init = 1) lines =
  let sim = Rx.create Bitpipe.create in
  let i = Cyclesim.inputs sim in
  let ob = Cyclesim.outputs ~clock_edge:Before sim in
  let oa = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.cfg := cfg;
  cycle ();
  i.rst_n := Bits.vdd;
  i.ctrl_reset := Bits.vdd;
  i.prev_init := Bits.of_int ~width:1 prev_init;
  cycle ();
  i.ctrl_reset := Bits.gnd;
  let got = ref [] in
  List.iter
    (fun l ->
      i.step := Bits.vdd;
      i.line := Bits.of_int ~width:1 l;
      cycle ();
      if Bits.to_int !(ob.byte_done) = 1 then got := Bits.to_int !(ob.byte_data) :: !got)
    lines;
  i.step := Bits.gnd;
  cycle ();
  let st = Bits.to_int !(oa.status) in
  List.rev !got, st land 1 = 1, st land 2 = 2

let random_payload ~max_len =
  let n = Random.int (max_len + 1) in
  List.init n (fun _ ->
    (* bias toward 0xFF so long runs of 1s force stuffing *)
    if Random.int 3 = 0 then 0xFF else Random.int 256)

let () =
  Random.init 2026;
  Printf.printf "=== txpipe: shift-out / CRC append / stuff insert / NRZI encode ===\n";

  (* 1. UART: plain LSB-first, back-to-back bytes, no last flag *)
  let zero_cfg = cfg_of_bytes [] in
  let line, stalled = run_tx ~cfg:zero_cfg ~steps:24 [ 0x55; 0xA3; 0x0F ] in
  check "all-zero profile shifts 55 A3 0F out LSB-first, back to back"
    ((not stalled) && line = List.concat_map bits_lsb [ 0x55; 0xA3; 0x0F ]);

  (* 2. SPI: msb_first only *)
  let spi_cfg = cfg_of_bytes [ 0b0010_0000 ] in
  let line, _ = run_tx ~cfg:spi_cfg ~steps:16 [ 0xA5; 0x3C ] in
  check "msb_first profile shifts A5 3C out MSB-first"
    (line = List.concat_map bits_msb [ 0xA5; 0x3C ]);

  (* 3. golden USB vector *)
  let usb_cfg = cfg_of_bytes usb_bytes in
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  (* on the wire the CRC goes low byte first: the well-known "... 40 00 DD 94" *)
  check "reference CRC16 of GET_DESCRIPTOR goes out as wire bytes DD 94"
    (usb_crc16 gd = 0x94DD);
  let line, stalled = run_tx ~cfg:usb_cfg ~crc:true (with_last (usb_packet gd)) in
  check "hardware line output matches the reference encoder bit for bit"
    ((not stalled) && line = usb_reference gd);
  let bytes, ok, serr = rx_decode ~cfg:usb_cfg line in
  check "loopback: receive pipe decodes ... 40 00 DD 94 with crc_ok"
    (ok && (not serr) && bytes = usb_packet gd @ [ 0xDD; 0x94 ]);

  (* 4. random USB packets *)
  let ref_ok = ref 0 and loop_ok = ref 0 and stuffed = ref 0 in
  for _ = 1 to 300 do
    let p = random_payload ~max_len:12 in
    let line, stalled = run_tx ~cfg:usb_cfg ~crc:true (with_last (usb_packet p)) in
    let expected = usb_reference p in
    if (not stalled) && line = expected then incr ref_ok;
    let nbits = 8 * (List.length p + 4) in
    if List.length expected > nbits then incr stuffed;
    let bytes, ok, serr = rx_decode ~cfg:usb_cfg line in
    let c = usb_crc16 p in
    if ok && (not serr) && bytes = usb_packet p @ [ lo c; hi c ] then incr loop_ok
  done;
  Printf.printf "    (%d of 300 packets needed stuffing)\n" !stuffed;
  check "300 random USB packets match the reference encoder" (!ref_ok = 300);
  check "300 random USB packets loop back through the receive pipe" (!loop_ok = 300);

  (* 5. random CAN payloads *)
  let can_cfg = cfg_of_bytes can_bytes in
  let ref_ok = ref 0 and loop_ok = ref 0 in
  for _ = 1 to 300 do
    let p = random_payload ~max_len:8 in
    let line, stalled = run_tx ~cfg:can_cfg ~prev_init:0 ~crc:true (with_last (0x00 :: p)) in
    let expected = can_reference (0x00 :: p) in
    if (not stalled) && line = expected then incr ref_ok;
    let bytes, ok, serr = rx_decode ~cfg:can_cfg ~prev_init:0 line in
    if ok && (not serr) && List.length bytes >= List.length p + 1
       && List.filteri (fun k _ -> k <= List.length p) bytes = 0x00 :: p
    then incr loop_ok
  done;
  check "300 random CAN payloads match the reference encoder" (!ref_ok = 300);
  check "300 random CAN payloads loop back (crc_ok, no stuff error)" (!loop_ok = 300);

  (* 6. underrun *)
  let line, stalled = run_tx ~cfg:zero_cfg ~steps:1 [] in
  check "empty FIFO: the pipe requests a stall" (stalled && List.length line = 1);

  if !failures = 0 then print_endline "RESULT: PASS"
  else (Printf.printf "RESULT: FAIL (%d)\n" !failures; exit 1)
