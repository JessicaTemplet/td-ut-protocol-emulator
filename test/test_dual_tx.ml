open Hardcaml
open Tt_core

(* The transmit path on the whole dual-engine core (dual.ml): µE1 decides
   the data at run time (TX_PUSH / TX_ECHO), it crosses the TX FIFO, and
   µE0's EMIT_TX turns it into line bits through the transmit pipe, with
   the profile table supplying each direction's configuration.

   Scenarios:
   1. UART TX: two bytes chosen by µE1 go out as 8N1 frames; every bit cell
      is the same length (one EMIT per cell, no gap at byte boundaries).
   2. SPI mode 0 full duplex with a RUNTIME MOSI payload: two bytes from
      µE1 go out MSB-first while the slave's bytes come back to µE1.
   3. USB low speed, differential D-/D+: an ACK handshake (no CRC) and the
      GET_DESCRIPTOR DATA0 packet with CRC16, plus 40 random data packets,
      decoded from the pins and compared with an independent reference
      encoder. One EMIT_TX per line bit, a constant bit cell across the
      data/CRC boundary, and the EOP (two SE0 cells, then J).
   4. CFG_WR: a configuration byte received from the host at run time is
      written into profile 1, µE1 points the TX pipe at it, and the same
      TX_PUSH comes out MSB-first instead of LSB-first.
   5. Open-drain EMIT_TX (I2C write data): 0 bits drive low, 1 bits
      release the pin. *)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let bit x n = (x lsr n) land 1
let bits_lsb b = List.init 8 (fun i -> bit b i)
let bits_msb b = List.init 8 (fun i -> bit b (7 - i))
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

(* profile p byte k lives at index 32p + k *)
let profile p bytes = List.mapi (fun k b -> ((32 * p) + k, b)) bytes

(* pin 7 is held low by every scenario:  and  rely on it *)
let halt = Engine.wait_edge ~pin:7 ~falling:true ~payload:0
let wait t = Engine.wait_edge ~pin:7 ~falling:true ~payload:t
let nop = Engine.release_pin ~pin:7
let e1_halt = Protocol_engine.fifo_pop_instr (* pops forever once drained *)

type trace =
  { out : int array (* combined pin levels after each cycle *)
  ; oe : int array
  ; phys_pc : int array
  ; rx_words : int list (* every word µE1 popped, in order *)
  }

(* Run both engines. [drive t out oe] gives pins_in for cycle t from the
   pins as they were after cycle t-1. [pop_pcs]: µE1 addresses of FIFO_POPs
   whose popped word should be recorded. *)
let run ?(cfg = []) ?(pop_pcs = []) ~phys ~proto ~cycles ~drive () =
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  cycle ();
  i.rst_n := Bits.vdd;
  List.iter
    (fun (a, b) ->
      i.cfg_addr := Bits.of_int ~width:7 a;
      i.cfg_data := Bits.of_int ~width:8 b;
      i.cfg_we := Bits.vdd;
      cycle ())
    cfg;
  i.cfg_we := Bits.gnd;
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
  load i.phys_write_enable i.phys_write_addr i.phys_write_data phys;
  load i.protocol_write_enable i.protocol_write_addr i.protocol_write_data proto;
  i.run := Bits.vdd;
  i.protocol_run := Bits.vdd;
  let out = Array.make cycles 0 and oe = Array.make cycles 0 and pcs = Array.make cycles 0 in
  let words = ref [] and prev_ppc = ref 0 in
  let cur_out = ref 0 and cur_oe = ref 0 in
  for t = 0 to cycles - 1 do
    i.pins_in := Bits.of_int ~width:8 (drive t !cur_out !cur_oe land 0x7F);
    cycle ();
    let g f = Bits.to_int !(f o) in
    let p_oe = g (fun o -> o.Dual.O.protocol_pins_oe) and p_out = g (fun o -> o.Dual.O.protocol_pins_out) in
    let e_oe = g (fun o -> o.Dual.O.phys_pins_oe) and e_out = g (fun o -> o.Dual.O.phys_pins_out) in
    cur_oe := p_oe lor e_oe;
    cur_out := (p_out land p_oe) lor (e_out land lnot p_oe);
    out.(t) <- !cur_out;
    oe.(t) <- !cur_oe;
    pcs.(t) <- g (fun o -> o.Dual.O.phys_pc);
    let ppc = g (fun o -> o.Dual.O.protocol_pc) in
    if ppc <> !prev_ppc && List.mem !prev_ppc pop_pcs then
      words := g (fun o -> o.Dual.O.rx_word) :: !words;
    prev_ppc := ppc
  done;
  { out; oe; phys_pc = pcs; rx_words = List.rev !words }

(* Executed emits: [pcs] are the program addresses of the EMIT
   instructions of interest; an emit at pc p has executed when phys_pc
   moves off p. Returns (cycle, out, oe) right after each one. *)
let emits tr pcs =
  let n = Array.length tr.phys_pc in
  let acc = ref [] in
  for t = 0 to n - 1 do
    (* pc is 0 before the first cycle *)
    let before = if t = 0 then 0 else tr.phys_pc.(t - 1) in
    if List.mem before pcs && tr.phys_pc.(t) <> before then
      acc := (t, tr.out.(t), tr.oe.(t)) :: !acc
  done;
  List.rev !acc

let uniform times =
  match times with
  | a :: (b :: _ as rest) ->
    let d = b - a in
    let rec ok prev = function [] -> true | x :: r -> x - prev = d && ok x r in
    ok a rest, d
  | _ -> true, 0

let byte_of_lsb bits = List.fold_left (fun (acc, k) b -> (acc lor (b lsl k), k + 1)) (0, 0) bits |> fst

let rec chunks n = function
  | [] -> []
  | l ->
    let rec take k l = if k = 0 then [], l else match l with [] -> [], [] | x :: r -> let a, b = take (k - 1) r in x :: a, b in
    let a, b = take n l in
    a :: chunks n b

(* ---------------- 1. UART TX ---------------- *)
let uart_tx () =
  let tx = 0 and t = 20 in
  let frame = Engine.([ emit_state ~pin:tx ~level:false; wait t ])
    @ List.concat (List.init 8 (fun _ -> [ Engine.emit_tx ~pin:tx (); wait t ]))
    @ Engine.[ emit_state ~pin:tx ~level:true; wait t ] in
  let phys = Engine.[ emit_state ~pin:tx ~level:true; wait t ] @ frame @ frame @ [ halt ] in
  let proto = Protocol_engine.[ tx_push 0x4F; tx_push 0x4B; e1_halt ] in
  let tr = run ~phys ~proto ~cycles:1200 ~drive:(fun _ _ _ -> 0) () in
  let emit_pcs = List.filteri (fun k _ -> k mod 2 = 0) (List.init (List.length phys) Fun.id) |> List.filter (fun k -> k < List.length phys - 1) in
  let ev = emits tr emit_pcs in
  let levels = List.map (fun (_, o, _) -> bit o tx) ev in
  let times = List.map (fun (t, _, _) -> t) ev in
  let frames = match levels with _idle :: rest -> chunks 10 rest | [] -> [] in
  let decode f = match f with s :: rest when s = 0 && List.length rest = 9 && List.nth rest 8 = 1 -> Some (byte_of_lsb (List.filteri (fun k _ -> k < 8) rest)) | _ -> None in
  let bytes = List.map decode frames in
  let uni, cell = uniform (List.tl times) in
  Printf.printf "    UART: %d emits, cell %d cycles\n" (List.length ev) cell;
  check "UART TX: µE1's bytes 'O' 'K' leave as two 8N1 frames" (bytes = [ Some 0x4F; Some 0x4B ]);
  check "UART TX: constant bit cell, no gap where the pipe auto-loads a byte" uni;
  check "UART TX: pin driven throughout" (List.for_all (fun (_, _, oe) -> bit oe tx = 1) ev)

(* ---------------- 2. SPI full duplex ---------------- *)
let spi () =
  let sck = 0 and mosi = 1 and miso = 2 and cs = 3 and h = 6 in
  let bit_block last =
    Engine.
      [ emit_tx ~pin:mosi ()
      ; wait h
      ; emit_state ~pin:sck ~level:true
      ; (if last then shift_in_push ~pin:miso else shift_in ~pin:miso)
      ; wait h
      ; emit_state ~pin:sck ~level:false ]
  in
  let byte_block = List.concat (List.init 8 (fun k -> bit_block (k = 7))) in
  let phys =
    Engine.[ emit_state ~pin:sck ~level:false; emit_state ~pin:cs ~level:false ]
    @ byte_block @ byte_block @ Engine.[ emit_state ~pin:cs ~level:true; halt ]
  in
  (* bytes that read differently in the two bit orders: 0xA5 and 0x5A
     are bit palindromes and cannot tell MSB-first from LSB-first *)
  let proto = Protocol_engine.[ tx_push 0xA6; tx_push 0x3B; fifo_pop_instr; fifo_pop_instr; e1_halt ] in
  let slave_tx = [| 0x3C; 0xC3 |] in
  let s_rx = ref 0 and s_bits = ref 0 and prev_sck = ref 0 and miso_v = ref (bit slave_tx.(0) 7) in
  let drive _ out _ =
    let sck_v = bit out sck in
    if sck_v = 1 && !prev_sck = 0 then (s_rx := (!s_rx lsl 1) lor bit out mosi; incr s_bits);
    if sck_v = 0 && !prev_sck = 1 && !s_bits < 16 then
      miso_v := bit slave_tx.(!s_bits / 8) (7 - (!s_bits mod 8));
    prev_sck := sck_v;
    !miso_v lsl miso
  in
  let tr = run ~cfg:(profile 0 [ 0x20 ]) ~pop_pcs:[ 2; 3 ] ~phys ~proto ~cycles:800 ~drive () in
  check "SPI: slave received µE1's runtime MOSI bytes A6 3B, MSB-first"
    (!s_bits = 16 && !s_rx land 0xFFFF = 0xA63B);
  check "SPI: µE1 popped the slave's MISO bytes 3C C3 (full duplex)" (tr.rx_words = [ 0x3C; 0xC3 ])

(* ---------------- 3. USB low-speed transmit ---------------- *)
let usb_bytes =
  [ 0b1001_1011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

let usb_crc16 bytes =
  let crc = ref 0xFFFF in
  List.iter
    (fun b ->
      let fb = (!crc land 1) lxor b in
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

let dm = 0 and dp = 1

(* [with_crc]: DATA packet (CRC16 appended) or handshake (none). Returns
   the program and the pcs of the EMIT_TX instructions and of the SE0/J
   emits. Cells: every path between two EMIT_TXs costs the same cycles. *)
let usb_tx_program ~t ~with_crc =
  let open Engine in
  let head =
    [ pipe_ctrl_ext ~tx_reset:true ~prev_level:true ()
    ; emit_state ~pin:dm ~level:true
    ; emit_state ~pin:dp ~level:false
    ; wait t (* 3: loop *)
    ; emit_tx ~differential:true ~pin:dm ()
    ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:3 ]
  in
  let crc_part =
    if with_crc then
      [ pipe_ctrl_ext ~tx_crc:true () (* 6 *)
      ; wait (t - 1)
      ; emit_tx ~differential:true ~pin:dm () (* 8 *)
      ; nop
      ; wait t (* 10: loop *)
      ; emit_tx ~differential:true ~pin:dm () (* 11 *)
      ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:10 ]
    else []
  in
  let base = List.length head + List.length crc_part in
  let eop =
    [ wait t
    ; emit_state ~pin:dm ~level:false (* SE0 *)
    ; emit_state ~pin:dp ~level:false
    ; wait ((2 * t) + 4) (* SE0 = two cells, from the dp emit to J *)
    ; emit_state ~pin:dm ~level:true (* J *)
    ; wait t
    ; release_pin ~pin:dm
    ; release_pin ~pin:dp
    ; halt ]
  in
  let tx_pcs = if with_crc then [ 4; 8; 11 ] else [ 4 ] in
  head @ crc_part @ eop, tx_pcs, (base + 1, base + 4)

let usb_send ?(t = 30) ~with_crc bytes =
  let phys, tx_pcs, (se0_pc, j_pc) = usb_tx_program ~t ~with_crc in
  let n = List.length bytes in
  let proto = List.mapi (fun k b -> Protocol_engine.tx_push ~last:(k = n - 1) b) bytes @ [ e1_halt ] in
  let cycles = 400 + ((n + 4) * 8 * (t + 6) * 7 / 6) in
  let tr = run ~cfg:(profile 0 usb_bytes) ~phys ~proto ~cycles ~drive:(fun _ _ _ -> 0) () in
  let ev = emits tr tx_pcs in
  let line = List.map (fun (_, o, _) -> bit o dm) ev in
  let diff_ok = List.for_all (fun (_, o, oe) -> bit o dp = 1 - bit o dm && bit oe dp = 1 && bit oe dm = 1) ev in
  let uni, cell = uniform (List.map (fun (t, _, _) -> t) ev) in
  let se0 = emits tr [ se0_pc ] and j = emits tr [ j_pc ] in
  let eop_ok =
    match ev, se0, j with
    | _ :: _, [ (ts, _, _) ], [ (tj, o, _) ] ->
      let tlast = let (t, _, _) = List.nth ev (List.length ev - 1) in t in
      if Sys.getenv_opt "TX_DEBUG" <> None then begin
        Printf.printf "    eop: cell %d, last->se0 %d, se0->J %d, uniform %b\n" cell (ts - tlast) (tj - ts) uni;
        let ts_l = List.map (fun (t, _, _) -> t) ev in
        List.iteri (fun k t -> if k > 0 then Printf.printf "%d " (t - List.nth ts_l (k - 1))) ts_l;
        print_newline ();
        List.iteri
          (fun k t ->
            if k > 0 && t - List.nth ts_l (k - 1) < cell then begin
              let t0 = List.nth ts_l (k - 1) - 3 in
              Printf.printf "    pcs from cycle %d:" t0;
              for u = t0 to t + 2 do Printf.printf " %d" tr.phys_pc.(u) done;
              print_newline ()
            end)
          ts_l
      end;
      ts - tlast = cell && tj - ts = (2 * cell) + 1
      && bit tr.out.(ts + 1) dm = 0 && bit tr.out.(ts + 1) dp = 0
      && bit o dm = 1 && bit o dp = 0
    | _ -> false
  in
  line, diff_ok, uni, cell, eop_ok

let usb () =
  (* ACK handshake: SYNC + PID, no CRC *)
  let line, diff_ok, uni, cell, eop_ok = usb_send ~with_crc:false [ 0x80; 0xD2 ] in
  let expect = nrzi (usb_stuff (List.concat_map bits_lsb [ 0x80; 0xD2 ])) in
  Printf.printf "    USB: bit cell %d cycles (1.5 Mbit/s low speed is 33 at 50 MHz)\n" cell;
  check "USB ACK: D- carries NRZI(SYNC, PID ACK) exactly, D+ its complement" (line = expect && diff_ok);
  check "USB ACK: constant bit cell, then SE0 for two cells and J" (uni && eop_ok);
  (* GET_DESCRIPTOR DATA0 with CRC16 *)
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let c = usb_crc16 gd in
  let pkt = 0x80 :: 0xC3 :: gd in
  let line, diff_ok, uni, _, eop_ok = usb_send ~with_crc:true pkt in
  let expect = nrzi (usb_stuff (List.concat_map bits_lsb (pkt @ [ lo c; hi c ]))) in
  check "USB DATA0 GET_DESCRIPTOR: line matches reference incl. CRC DD 94" (line = expect && diff_ok);
  check "USB DATA0: constant cell across the data/CRC boundary, EOP correct" (uni && eop_ok);
  (* random packets; µE1 runs ahead through the 4-entry FIFO *)
  Random.init 7;
  let ok = ref 0 in
  for _ = 1 to 40 do
    let p = List.init (Random.int 9) (fun _ -> if Random.bool () then 0xFF else Random.int 256) in
    let c = usb_crc16 p in
    let pkt = 0x80 :: 0xC3 :: p in
    let line, diff_ok, uni, _, eop_ok = usb_send ~with_crc:true pkt in
    if line = nrzi (usb_stuff (List.concat_map bits_lsb (pkt @ [ lo c; hi c ]))) && diff_ok && uni && eop_ok
    then incr ok
  done;
  check "40 random USB DATA0 packets: exact line bits, constant cell, EOP" (!ok = 40)

(* ---------------- 4. CFG_WR ---------------- *)
let cfg_wr host_byte =
  let mosi = 2 and sck = 3 and tx = 0 in
  let rx_block = List.concat (List.init 8 (fun k ->
    Engine.[ wait_edge ~pin:sck ~falling:false ~payload:0
           ; (if k = 7 then shift_in_push ~pin:mosi else shift_in ~pin:mosi) ])) in
  let tx_block = List.concat (List.init 8 (fun _ -> Engine.[ emit_tx ~pin:tx (); wait 4 ])) in
  let phys = rx_block @ tx_block @ [ halt ] in
  let proto =
    Protocol_engine.
      [ fifo_pop_instr; cfg_wr ~index:32 (); profile ~tx:true 1; tx_push 0xA6; e1_halt ]
  in
  (* host: SPI master, MSB-first, 20-cycle bit cell *)
  let drive t _ _ =
    let k = (t - 10) / 20 and ph = (t - 10) mod 20 in
    if t < 10 || k > 7 then 0
    else (bit host_byte (7 - k) lsl mosi) lor ((if ph >= 10 then 1 else 0) lsl sck)
  in
  let tr = run ~phys ~proto ~cycles:400 ~drive () in
  let tx_pcs = List.init 8 (fun k -> List.length rx_block + (2 * k)) in
  List.map (fun (_, o, _) -> bit o tx) (emits tr tx_pcs)

let cfg_wr_test () =
  let msb = cfg_wr 0x20 and plain = cfg_wr 0x00 in
  check "CFG_WR: host sends 0x00 -> profile 1 is plain, A6 goes out LSB-first" (plain = bits_lsb 0xA6);
  check "CFG_WR: host sends 0x20 -> profile 1 is msb_first, A6 goes out MSB-first" (msb = bits_msb 0xA6)

(* ---------------- 5. open-drain EMIT_TX ---------------- *)
let open_drain () =
  let sda = 4 in
  let phys = List.concat (List.init 8 (fun _ -> Engine.[ emit_tx ~open_drain:true ~pin:sda (); wait 4 ])) @ [ halt ] in
  let proto = Protocol_engine.[ tx_push 0xA6; e1_halt ] in
  let tr = run ~cfg:(profile 0 [ 0x20 ]) ~phys ~proto ~cycles:200 ~drive:(fun _ _ _ -> 0) () in
  let ev = emits tr (List.init 8 (fun k -> 2 * k)) in
  let ok =
    List.length ev = 8
    && List.for_all2
         (fun (_, o, oe) b -> if b = 0 then bit oe sda = 1 && bit o sda = 0 else bit oe sda = 0)
         ev (bits_msb 0xA6)
  in
  check "open-drain EMIT_TX: A6 MSB-first, 0s driven low, 1s released" ok

(* ---------------- 6. timer regression ----------------
   A timed WAIT right after an instruction whose payload is 1 used to
   expire on its first cycle (timer.ml). Here: release_pin (payload 1),
   then wait 20, then an emit; the emit must come a full wait later than
   when the wait follows an instruction with a different payload. *)
let timer_regression () =
  (* the timer is loaded with an instruction's payload when the instruction
     BEFORE it advances, so [prev] needs a predecessor *)
  let gap prev =
    let phys = Engine.[ emit_state ~pin:5 ~level:false; prev; wait 20; emit_state ~pin:0 ~level:true; halt ] in
    let tr = run ~phys ~proto:[ e1_halt ] ~cycles:80 ~drive:(fun _ _ _ -> 0) () in
    match emits tr [ 3 ] with [ (t, _, _) ] -> t | _ -> -1
  in
  let after_payload1 = gap (Engine.release_pin ~pin:6) in
  let after_payload0 = gap (Engine.emit_state ~pin:6 ~level:false) in
  Printf.printf "    WAIT 20 after release_pin: emit at %d; after emit_state: %d\n" after_payload1 after_payload0;
  check "timed WAIT after a payload-1 instruction waits its full payload"
    (after_payload1 = after_payload0 && after_payload1 > 20)

let () =
  Printf.printf "=== transmit path on the dual-engine core ===\n";
  timer_regression ();
  uart_tx ();
  spi ();
  usb ();
  cfg_wr_test ();
  open_drain ();
  if !failures = 0 then print_endline "RESULT: PASS"
  else (Printf.printf "RESULT: FAIL (%d)\n" !failures; exit 1)
