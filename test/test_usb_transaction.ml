open Hardcaml
open Tt_core

(* What the profile table is for, shown on real USB low-speed traffic.

   1. One USB transaction, one run: a SETUP token (CRC5) followed by a
      DATA0 packet (CRC16) on the same line. µE0 runs the same four-
      instruction receive loop for both; µE1 reads each PID and switches
      the RX pipe to the CRC5 or the CRC16 profile (PROFILE, which also
      reloads the CRC from the new profile) before the first CRC'd bit
      arrives. Both packets must be accepted.
   2. Controls: the same traffic with the RX profile pinned to CRC5 or to
      CRC16 (no switching) accepts only one of the two packets. Runtime
      switching is what makes a real transaction decodable.
   3. Protocol bridge: a USB DATA0 packet comes in through the RX pipe on
      profile 0 (USB) and its bytes go out as UART frames through the TX
      pipe on profile 1 (plain), both configured at once; µE1 relays with
      TX_ECHO and reports the CRC check on a flag pin. *)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let bit x n = (x lsr n) land 1
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF
let bits_lsb b = List.init 8 (fun i -> bit b i)
let profile p bytes = List.mapi (fun k b -> ((32 * p) + k, b)) bytes

let dm = 0 (* D-, the NRZI line: J = 1, K = 0 for low speed *)
let dp = 1
let tok_ok = 2
let data_ok = 3
let uart_tx = 4

(* ---- profiles ---- *)
let flags = 0b011011 (* nrzi, stuff (ones only), crc, reflected, LSB-first *)
let usb5 = [ flags; 6; (2 lsl 4) lor 4; 0x14; 0; 0x1F; 0; 0x06; 0 ] (* skip SYNC+PID *)
let usb16 = [ flags; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

(* ---- reference transmitter (independent of the hardware) ---- *)
let crc_reflected ~poly ~init ~width bits =
  let crc = ref init in
  List.iter
    (fun b ->
      let fb = (!crc land 1) lxor b in
      crc := !crc lsr 1;
      if fb = 1 then crc := !crc lxor poly)
    bits;
  lnot !crc land ((1 lsl width) - 1)

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

(* symbols: 1 = J, 0 = K, 2 = SE0. Packet, EOP, then idle J. *)
let line_of bits = nrzi (stuff bits) @ [ 2; 2 ] @ List.init 8 (fun _ -> 1)

(* SETUP to address [addr], endpoint [ep]: PID 2D, 11 bits, CRC5 *)
let token_bits ~addr ~ep =
  let body = List.init 7 (fun i -> bit addr i) @ List.init 4 (fun i -> bit ep i) in
  let c = crc_reflected ~poly:0x14 ~init:0x1F ~width:5 body in
  bits_lsb 0x80 @ bits_lsb 0x2D @ body @ List.init 5 (fun i -> bit c i)

let data_bits payload =
  let c = crc_reflected ~poly:0xA001 ~init:0xFFFF ~width:16 (List.concat_map bits_lsb payload) in
  List.concat_map bits_lsb ((0x80 :: 0xC3 :: payload) @ [ lo c; hi c ])

(* ---- µE0: the receive loop of test_usb_rx.ml, re-armed after every
   packet (pc 14 jumps back to 0 instead of halting) ---- *)
let rx_loop ~t0 ~t_wait =
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
    ; pipe_status ]

(* ---- µE1: per packet, pop SYNC and PID, pick the profile from the PID,
   pop to the status word, raise [flag] if the packet was good ---- *)
let packet_block ~base ~flag ~switch =
  let open Protocol_engine in
  let next = base + 12 in
  (* without switching, the PROFILE slots become no-ops (a branch on the
     PID word's bit 15, which is never set) so timing stays identical *)
  let select_profile p =
    if switch then profile ~rx:true ~crc_init:true p
    else branch_word ~bit:15 ~branch_if_one:true ~target:(base + 6)
  in
  [ fifo_pop_instr (* SYNC *)
  ; fifo_pop_instr (* PID *)
  ; branch_word ~bit:1 ~branch_if_one:true ~target:(base + 5) (* 2D: bit1 = 0; C3: bit1 = 1 *)
  ; select_profile 0 (* token: CRC5 *)
  ; branch_word ~bit:15 ~branch_if_one:false ~target:(base + 6)
  ; select_profile 1 (* data: CRC16 *)
  ; fifo_pop_instr
  ; branch_word ~bit:15 ~branch_if_one:false ~target:(base + 6)
  ; branch_word ~bit:0 ~branch_if_one:false ~target:next (* crc_ok *)
  ; branch_word ~bit:1 ~branch_if_one:true ~target:next (* stuff_err *)
  ; branch_word ~bit:2 ~branch_if_one:false ~target:next (* aligned *)
  ; emit_state ~pin:flag ~level:true ]

type outcome = { pins : int; samples : int list; words : int list; uart : (int * int) list }

let lead = 40

(* Drive [symbols] at [b] cycles per symbol. [samples]: cycles at which
   µE0 executed a PIPE_BIT. [uart]: (cycle, level) of the UART pin after
   each change. *)
let simulate ~b ~cfg ~phys ~proto ?(pop_pcs = []) ?(tail = 400) symbols =
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.pins_in := Bits.of_int ~width:8 (1 lsl dm);
  cycle ();
  i.rst_n := Bits.vdd;
  List.iter
    (fun (a, v) ->
      i.cfg_addr := Bits.of_int ~width:7 a;
      i.cfg_data := Bits.of_int ~width:8 v;
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
  let syms = Array.of_list symbols in
  let n = Array.length syms in
  let samples = ref [] and words = ref [] and uart = ref [] in
  let prev_ppc = ref 0 and prev_uart = ref (-1) in
  for t = 0 to lead + (n * b) + tail - 1 do
    let s = if t < lead then 1 else (let k = (t - lead) / b in if k < n then syms.(k) else 1) in
    let dmv = if s = 1 then 1 else 0 and dpv = if s = 0 then 1 else 0 in
    i.pins_in := Bits.of_int ~width:8 ((dmv lsl dm) lor (dpv lsl dp));
    cycle ();
    let pc = Bits.to_int !(o.phys_pc) in
    if pc = 9 || pc = 11 then samples := t :: !samples;
    let ppc = Bits.to_int !(o.protocol_pc) in
    if ppc <> !prev_ppc && List.mem !prev_ppc pop_pcs then words := Bits.to_int !(o.rx_word) :: !words;
    prev_ppc := ppc;
    let u = bit (Bits.to_int !(o.phys_pins_out)) uart_tx in
    if u <> !prev_uart then (uart := (t, u) :: !uart; prev_uart := u)
  done;
  { pins = Bits.to_int !(o.protocol_pins_out)
  ; samples = List.rev !samples
  ; words = List.rev !words
  ; uart = List.rev !uart }

let dedup cycles =
  let rec go prev = function
    | [] -> []
    | x :: r -> if x = prev + 1 then go x r else x :: go x r
  in
  go (-10) cycles

(* Measure the loop's fixed overheads on a real packet, then solve for the
   first-sample wait t0 and the loop wait t_wait (as test_usb_rx.ml). *)
let calibrate ~b =
  let probe = line_of (data_bits [ 0x01; 0x02 ]) in
  let phys = rx_loop ~t0:1 ~t_wait:1 @ [ Engine.wait_edge ~pin:7 ~falling:true ~payload:0 ] in
  let r = simulate ~b ~cfg:(profile 0 usb16) ~phys ~proto:[ Protocol_engine.fifo_pop_instr; Protocol_engine.branch_word ~bit:15 ~branch_if_one:false ~target:0 ] probe in
  match dedup r.samples with
  | s1 :: s2 :: _ ->
    let c0 = s1 - lead - 1 and c_loop = s2 - s1 - 1 in
    max 1 ((b / 2) - c0), b - c_loop
  | _ -> failwith "calibration: no samples"

let () =
  Printf.printf "=== USB transaction and bridge: what runtime profiles make possible ===\n";
  let b = 33 in
  let t0, t_wait = calibrate ~b in
  Printf.printf "  calibration @ %d cycles/bit: t0=%d, t_wait=%d\n" b t0 t_wait;
  let phys = rx_loop ~t0 ~t_wait @ [ Engine.branch_cond ~pin:7 ~branch_if_high:false ~target:0 ] in
  let cfg = profile 0 usb5 @ profile 1 usb16 in
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let traffic = line_of (token_bits ~addr:0 ~ep:0) @ line_of (data_bits gd) in
  let proto ~switch =
    packet_block ~base:0 ~flag:tok_ok ~switch @ packet_block ~base:12 ~flag:data_ok ~switch
    @ [ Protocol_engine.fifo_pop_instr ]
  in
  let flags_of r = (bit r.pins tok_ok, bit r.pins data_ok) in

  (* 1. switching *)
  let r = simulate ~b ~cfg ~phys ~proto:(proto ~switch:true) traffic in
  check "SETUP token (CRC5) then DATA0 (CRC16), one run: both accepted" (flags_of r = (1, 1));

  (* 2. controls: no switching; the RX pointer stays on profile 0, which
     holds the CRC5 profile in one run and the CRC16 profile in the other *)
  let r5 = simulate ~b ~cfg:(profile 0 usb5) ~phys ~proto:(proto ~switch:false) traffic in
  let r16 = simulate ~b ~cfg:(profile 0 usb16) ~phys ~proto:(proto ~switch:false) traffic in
  check "control, RX pinned to CRC5: token accepted, data packet rejected" (flags_of r5 = (1, 0));
  check "control, RX pinned to CRC16: token rejected, data packet accepted" (flags_of r16 = (0, 1));

  (* random addresses / endpoints and payloads *)
  Random.init 11;
  let ok = ref 0 in
  for _ = 1 to 20 do
    let addr = Random.int 128 and ep = Random.int 16 in
    let p = List.init (Random.int 9) (fun _ -> if Random.bool () then 0xFF else Random.int 256) in
    let traffic = line_of (token_bits ~addr ~ep) @ line_of (data_bits p) in
    if flags_of (simulate ~b ~cfg ~phys ~proto:(proto ~switch:true) traffic) = (1, 1) then incr ok
  done;
  check "20 random token+data transactions: every packet accepted" (!ok = 20);

  (* corrupt one bit of the token's CRC5: the token must be rejected, the
     data packet still accepted (the switch re-arms per packet) *)
  let tb = Array.of_list (token_bits ~addr:5 ~ep:1) in
  let k = Array.length tb - 2 in
  tb.(k) <- 1 - tb.(k);
  let traffic = line_of (Array.to_list tb) @ line_of (data_bits gd) in
  let r = simulate ~b ~cfg ~phys ~proto:(proto ~switch:true) traffic in
  check "corrupted token CRC5: token rejected, following DATA0 still accepted" (flags_of r = (0, 1));

  (* 3. bridge: USB in (RX profile 0) -> UART out (TX profile 1) *)
  let payload = [ 0x48; 0x69 ] in
  let c = crc_reflected ~poly:0xA001 ~init:0xFFFF ~width:16 (List.concat_map bits_lsb payload) in
  let relayed = payload @ [ lo c; hi c ] in
  let ut = 20 in
  let frame =
    Engine.([ emit_state ~pin:uart_tx ~level:false; wait_edge ~pin:7 ~falling:true ~payload:ut ])
    @ List.concat (List.init 8 (fun _ -> Engine.[ emit_tx ~pin:uart_tx (); wait_edge ~pin:7 ~falling:true ~payload:ut ]))
    @ Engine.[ emit_state ~pin:uart_tx ~level:true; wait_edge ~pin:7 ~falling:true ~payload:ut ]
  in
  let bridge_phys =
    rx_loop ~t0 ~t_wait
    @ Engine.[ pipe_ctrl_ext ~tx_reset:true ~sel_tx:true ~profile:1 (); emit_state ~pin:uart_tx ~level:true ]
    @ List.concat (List.init 4 (fun _ -> frame))
    @ [ Engine.wait_edge ~pin:7 ~falling:true ~payload:0 ]
  in
  let bridge_proto =
    Protocol_engine.
      ([ fifo_pop_instr; fifo_pop_instr ]
       @ List.concat (List.init 4 (fun _ -> [ fifo_pop_instr; tx_echo () ]))
       @ [ fifo_pop_instr (* status *)
         ; branch_word ~bit:0 ~branch_if_one:false ~target:15
         ; branch_word ~bit:1 ~branch_if_one:true ~target:15
         ; emit_state ~pin:data_ok ~level:true
         ; fifo_pop_instr ])
  in
  let r =
    simulate ~b ~cfg:(profile 0 usb16) ~phys:bridge_phys ~proto:bridge_proto ~tail:(4 * 10 * (ut + 2) + 200)
      (line_of (data_bits payload))
  in
  (* decode the UART pin: frames start at each falling edge after idle *)
  let cell = ut + 2 in
  let level_at t = List.fold_left (fun acc (tc, v) -> if tc <= t then v else acc) 1 r.uart in
  let rec frames from acc =
    match List.find_opt (fun (tc, v) -> tc > from && v = 0) r.uart with
    | None -> List.rev acc
    | Some (ts, _) ->
      let byte = List.fold_left (fun a k -> a lor (level_at (ts + (cell * (k + 1)) + (cell / 2)) lsl k)) 0 (List.init 8 Fun.id) in
      let stop = level_at (ts + (cell * 9) + (cell / 2)) in
      frames (ts + (cell * 10) - (cell / 2)) ((byte, stop) :: acc)
  in
  let got = frames 0 [] in
  check "bridge: USB DATA0 payload + CRC relayed out as UART frames 48 69 + CRC"
    (List.map fst got = relayed && List.for_all (fun (_, s) -> s = 1) got);
  check "bridge: µE1 reports the USB CRC check good on its flag pin" (bit r.pins data_ok = 1);

  if !failures = 0 then print_endline "RESULT: PASS"
  else (Printf.printf "RESULT: FAIL (%d)\n" !failures; exit 1)
