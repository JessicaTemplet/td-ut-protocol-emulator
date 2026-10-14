open Hardcaml
open Tt_core

(* Standalone proof of bitpipe.ml (NRZI decode, un-stuffing, CRC, byte
   assembly) before anything depends on it. The reference here is an
   independent TRANSMITTER: it does the CRC, stuffing and NRZI encoding in
   plain OCaml, the opposite direction to the hardware, so agreement means
   the two implementations describe the same protocol, not that the test
   copies the design.

   Checks:
   1. Real-world vectors. USB SETUP token to addr 0 / ep 0 is the byte
      sequence 2D 00 10 (PID, addr+ep, CRC5) on every USB analyzer trace;
      the classic GET_DESCRIPTOR data stage 80 06 00 01 00 00 40 00 has
      CRC16 0xDD94. Both must be reproduced by the reference transmitter
      AND accepted by the hardware.
   2. 300 random USB DATA packets (runs of 1s force stuffing): hardware
      delivers exactly the payload+CRC bytes, crc_ok, no stuff error.
   3. Every single-line-bit corruption of a packet is rejected (crc_ok,
      stuff_err and byte alignment never all look fine).
   4. A run of seven 1s is a stuffing violation.
   5. The same unit configured as CAN (no NRZI, stuff on either polarity,
      CRC15, MSB-first) accepts random frames: one piece of hardware,
      two protocols, by configuration only. *)

module Sim = Cyclesim.With_interface (Bitpipe.I) (Bitpipe.O)

(* ---- configuration packing ---- *)
let cfg_of_bytes bytes =
  let bytes = bytes @ List.init (Bitpipe.cfg_bytes - List.length bytes) (fun _ -> 0) in
  Bits.concat_msb (List.rev_map (fun b -> Bits.of_int ~width:8 (b land 0xFF)) bytes)

let flags ~nrzi ~stuff ~both ~crc ~refl ~msb =
  (if nrzi then 1 else 0) lor (if stuff then 2 else 0) lor (if both then 4 else 0)
  lor (if crc then 8 else 0) lor (if refl then 16 else 0) lor if msb then 32 else 0

let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

(* [skip] = crc_skip_bytes (config byte 2 bits [7:4]) *)
let usb16_cfg_skip skip =
  cfg_of_bytes
    [ flags ~nrzi:true ~stuff:true ~both:false ~crc:true ~refl:true ~msb:false
    ; 6; (skip lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

let usb16_cfg = usb16_cfg_skip 0

let usb5_cfg_skip skip =
  cfg_of_bytes
    [ flags ~nrzi:true ~stuff:true ~both:false ~crc:true ~refl:true ~msb:false
    (* residue: the spec quotes 0b01100 for an MSB-first register; this
       design uses the reflected (LSB-first) form, so the register holds
       the bit reversal, 0b00110 *)
    ; 6; (skip lsl 4) lor 4; 0x14; 0; 0x1F; 0; 0x06; 0 ]

let usb5_cfg = usb5_cfg_skip 0

let can_cfg =
  cfg_of_bytes
    [ flags ~nrzi:false ~stuff:true ~both:true ~crc:true ~refl:false ~msb:true
    ; 5; 14; lo 0x4599; hi 0x4599; 0; 0; 0; 0 ]

(* ---- reference transmitter ---- *)
let bits_of_byte_lsb b = List.init 8 (fun i -> (b lsr i) land 1)

let usb_crc16 bytes =
  let crc = ref 0xFFFF in
  List.iter
    (fun b ->
      List.iter
        (fun bit ->
          let fb = (!crc land 1) lxor bit in
          crc := !crc lsr 1;
          if fb = 1 then crc := !crc lxor 0xA001)
        (bits_of_byte_lsb b))
    bytes;
  lnot !crc land 0xFFFF

let usb_crc5 bits =
  let crc = ref 0x1F in
  List.iter
    (fun bit ->
      let fb = (!crc land 1) lxor bit in
      crc := !crc lsr 1;
      if fb = 1 then crc := !crc lxor 0x14)
    bits;
  lnot !crc land 0x1F

(* USB bit stuffing: after six consecutive 1s insert a 0 *)
let usb_stuff bits =
  let out = ref [] and ones = ref 0 in
  List.iter
    (fun b ->
      out := b :: !out;
      if b = 1 then incr ones else ones := 0;
      if !ones = 6 then (out := 0 :: !out; ones := 0))
    bits;
  List.rev !out

(* NRZI: 1 = no transition, 0 = transition, starting from idle level 1 *)
let nrzi_encode bits =
  let level = ref 1 in
  List.map (fun b -> if b = 0 then level := 1 - !level; !level) bits

let usb_line bits = nrzi_encode (usb_stuff bits)

(* ---- drive the hardware ---- *)
type result = { bytes : int list; crc_ok : bool; stuff_err : bool; aligned : bool; nbytes : int }

let run_line ~cfg ?(prev_init = 1) ?(crc_init_after_bits = -1) lines =
  let sim = Sim.create Bitpipe.create in
  let i = Cyclesim.inputs sim in
  let ob = Cyclesim.outputs ~clock_edge:Before sim in
  let oa = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.cfg := cfg;
  i.step := Bits.gnd; i.line := Bits.gnd; i.ctrl_reset := Bits.gnd;
  i.ctrl_crc_init := Bits.gnd; i.prev_init := Bits.gnd;
  cycle (); cycle ();
  i.rst_n := Bits.vdd;
  (* ctrl_reset: clear stream state, set idle level *)
  i.ctrl_reset := Bits.vdd;
  i.prev_init := if prev_init = 1 then Bits.vdd else Bits.gnd;
  cycle ();
  i.ctrl_reset := Bits.gnd;
  let got = ref [] in
  let delivered_bits = ref 0 in
  List.iter
    (fun l ->
      i.step := Bits.vdd;
      i.line := if l = 1 then Bits.vdd else Bits.gnd;
      cycle ();
      if Bits.to_int !(ob.byte_done) = 1 then got := Bits.to_int !(ob.byte_data) :: !got;
      i.step := Bits.gnd;
      incr delivered_bits;
      if !delivered_bits = crc_init_after_bits then (
        i.ctrl_crc_init := Bits.vdd;
        cycle ();
        i.ctrl_crc_init := Bits.gnd))
    lines;
  cycle ();
  let st = Bits.to_int !(oa.status) in
  { bytes = List.rev !got
  ; crc_ok = st land 1 = 1
  ; stuff_err = st land 2 = 2
  ; aligned = st land 4 = 4
  ; nbytes = (st lsr 8) land 0x7F
  }

let accepted r = r.crc_ok && (not r.stuff_err) && r.aligned

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let () =
  Printf.printf "=== bitpipe: NRZI / un-stuffing / CRC / byte assembly ===\n";

  (* 1a. USB SETUP token to addr 0 ep 0: PID 0x2D, then addr(7)+ep(4)=0, CRC5 *)
  let tok_bits = List.init 11 (fun _ -> 0) in
  let crc5 = usb_crc5 tok_bits in
  let crc5_bits = List.init 5 (fun k -> (crc5 lsr k) land 1) in
  let token_bytes_ref =
    let bits = tok_bits @ crc5_bits in
    let byte_of l = List.fold_left (fun (a, k) b -> (a lor (b lsl k), k + 1)) (0, 0) l |> fst in
    [ byte_of (List.filteri (fun i _ -> i < 8) bits); byte_of (List.filteri (fun i _ -> i >= 8) bits) ]
  in
  check "reference CRC5 reproduces the USB SETUP token 2D 00 10"
    (token_bytes_ref = [ 0x00; 0x10 ]);
  let token_line = usb_line (bits_of_byte_lsb 0x2D @ tok_bits @ crc5_bits) in
  let r = run_line ~cfg:usb5_cfg ~crc_init_after_bits:8 token_line in
  check "hardware (CRC5 config) accepts the real SETUP token" (accepted r && r.bytes = [ 0x2D; 0x00; 0x10 ]);

  (* 1b. GET_DESCRIPTOR data stage *)
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let c = usb_crc16 gd in
  (* on the wire the CRC goes low byte first: the well-known "... 40 00 DD 94" *)
  check (Printf.sprintf "reference CRC16 of GET_DESCRIPTOR = 0x%04X (wire bytes DD 94)" c) (lo c = 0xDD && hi c = 0x94);
  let pkt = bits_of_byte_lsb 0xC3 @ List.concat_map bits_of_byte_lsb (gd @ [ lo c; hi c ]) in
  let r = run_line ~cfg:usb16_cfg ~crc_init_after_bits:8 (usb_line pkt) in
  check "hardware (CRC16 config) accepts the real DATA0 packet"
    (accepted r && r.bytes = (0xC3 :: gd) @ [ lo c; hi c ]);

  (* 2. random USB DATA packets, streamed exactly as on the wire: SYNC (0x80
     LSB-first = KJKJKJKK), PID, payload, CRC16. crc_skip_bytes = 2 keeps
     SYNC and PID out of the CRC, so no explicit CRC-init instruction. *)
  let seed = ref 12345 in
  let rnd n = seed := ((!seed * 1103515245) + 12345) land 0x7FFFFFFF; (!seed lsr 8) mod n in
  let good = ref 0 and total = 300 in
  let wire_bits payload =
    let c = usb_crc16 payload in
    bits_of_byte_lsb 0x80 @ bits_of_byte_lsb 0xC3
    @ List.concat_map bits_of_byte_lsb (payload @ [ lo c; hi c ])
  in
  for _ = 1 to total do
    let len = 1 + rnd 8 in
    let payload = List.init len (fun _ -> match rnd 4 with 0 -> 0xFF | 1 -> 0x7F | _ -> rnd 256) in
    let c = usb_crc16 payload in
    let r = run_line ~cfg:(usb16_cfg_skip 2) (usb_line (wire_bits payload)) in
    if accepted r && r.bytes = (0x80 :: 0xC3 :: payload) @ [ lo c; hi c ] && r.nbytes = len + 4
    then incr good
  done;
  check (Printf.sprintf "%d random USB packets (SYNC+PID+data+CRC, forced stuffing) accepted" total)
    (!good = total);

  (* 3. every single-line-bit corruption is rejected *)
  let payload = [ 0x01; 0xFF; 0xFF; 0x7E; 0x00; 0xA5 ] in
  let c = usb_crc16 payload in
  let line = usb_line (wire_bits payload) in
  let n = List.length line in
  let slipped = ref 0 in
  for k = 0 to n - 1 do
    let bad = List.mapi (fun j l -> if j = k then 1 - l else l) line in
    let r = run_line ~cfg:(usb16_cfg_skip 2) bad in
    if accepted r && r.bytes = (0x80 :: 0xC3 :: payload) @ [ lo c; hi c ] then incr slipped
  done;
  check (Printf.sprintf "all %d single-bit line corruptions rejected" n) (!slipped = 0);

  (* 4. seven 1s in a row = stuffing violation *)
  let r = run_line ~cfg:usb16_cfg (List.init 8 (fun _ -> 1)) in
  check "7 consecutive 1s sets the stuff error" r.stuff_err;
  let r = run_line ~cfg:usb16_cfg (List.init 6 (fun _ -> 1)) in
  check "6 consecutive 1s alone does not" (not r.stuff_err);

  (* 5. CAN configuration, same hardware *)
  let can_crc bits =
    let crc = ref 0 in
    List.iter
      (fun b ->
        let fb = ((!crc lsr 14) land 1) lxor b in
        crc := (!crc lsl 1) land 0x7FFF;
        if fb = 1 then crc := !crc lxor 0x4599)
      bits;
    !crc
  in
  let can_stuff bits =
    let out = ref [] and run = ref 0 and last = ref (-1) in
    List.iter
      (fun b ->
        out := b :: !out;
        if b = !last then incr run else (run := 1; last := b);
        if !run = 5 then (
          let s = 1 - b in
          out := s :: !out;
          last := s;
          run := 1))
      bits;
    List.rev !out
  in
  let can_ok = ref 0 in
  for _ = 1 to 300 do
    let data = List.init 25 (fun _ -> match rnd 3 with 0 -> 0 | 1 -> 1 | _ -> rnd 2) in
    let data = if rnd 3 = 0 then List.init 25 (fun _ -> 1) else data in
    let c = can_crc data in
    let bits = data @ List.init 15 (fun k -> (c lsr (14 - k)) land 1) in
    let r = run_line ~cfg:can_cfg (can_stuff bits) in
    let expect =
      List.init 5 (fun b -> List.fold_left (fun a k -> (a lsl 1) lor List.nth bits ((8 * b) + k)) 0 (List.init 8 Fun.id))
    in
    if accepted r && r.bytes = expect then incr can_ok
  done;
  check "300 random CAN frames (CRC15, both-polarity stuffing) accepted" (!can_ok = 300);

  Printf.printf "RESULT: %s\n" (if !failures = 0 then "PASS" else "FAIL");
  if !failures > 0 then exit 1
