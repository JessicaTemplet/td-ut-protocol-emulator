open Hardcaml
open Tt_core

(* USB low-speed packet RECEIVE on the dual-engine core, using the bit pipe
   (NRZI decode, un-stuffing, CRC16) and the glitch filter. This is the
   "demonstrate one fast protocol" item: the point is what the program is NOT
   doing. Per bit, uE0 runs a four-instruction loop (wait, branch on line
   state, PIPE_BIT, loop); the NRZI compare, stuff-run counter and CRC LFSR
   update that a software bit-banger spends ~10 instructions on are hardware.

   uE0 (per-bit loop, J and K paths deliberately equal length so the sample
   point does not drift with the data):
      0 PIPE_CTRL reset (idle level J)      1 wait for SYNC's J->K edge
      2 wait ~half a bit                    3 (line is K: jump to the state check)
      4 L0: wait one bit - loop overhead
      5 K? -> 8     6 J? -> 11     7 else SE0 (end of packet) -> 13
      8 nop (pads the K path)   9 PIPE_BIT   10 loop
     11 PIPE_BIT               12 loop
     13 PIPE_STATUS (pushes the status word)   14 halt
   uE1 pops every byte until the status word (bit 15 set), then drives
   flag_ok = (crc ok && no stuff error && whole bytes) and flag_done.

   The bit period B and the loop wait are CALIBRATED by measurement (first
   sample must land mid-bit, loop period must equal B), not assumed.

   Scenarios: the real GET_DESCRIPTOR data packet; 60 random packets with
   stuffing-heavy payloads; a corrupted bit; a stuffing violation; a glitch
   that corrupts a bit without the filter and is absorbed with it; and a
   bit-rate sweep showing how fast the same program keeps up. *)

let dm = 0 (* D-, the NRZI line: J = 1, K = 0 for low speed *)
let dp = 1
let flag_ok = 2
let flag_done = 3

let program ~t0 ~t_wait =
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

(* ---- bit pipe configuration: USB low speed ---- *)
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF

(* profile 0, written through the profile table's load port *)
let cfg ~glitch =
  [ 0b011011 (* nrzi, stuff, crc, reflected; ones-only stuffing; LSB-first *)
  ; 6 lor (glitch lsl 4)
  ; (2 lsl 4) lor 15 (* crc_skip = 2 (SYNC, PID), 16-bit *)
  ; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

(* ---- reference transmitter (independent of the hardware) ---- *)
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

(* symbols: 1 = J, 0 = K, 2 = SE0 *)
let packet_symbols ?(stuff_it = true) payload =
  let c = usb_crc16 payload in
  let bits =
    bits_of_byte_lsb 0x80 @ bits_of_byte_lsb 0xC3
    @ List.concat_map bits_of_byte_lsb (payload @ [ lo c; hi c ])
  in
  nrzi (if stuff_it then stuff bits else bits) @ [ 2; 2; 1 ]

let expected_bytes payload =
  let c = usb_crc16 payload in
  (0x80 :: 0xC3 :: payload) @ [ lo c; hi c ]

(* ---- simulation harness ---- *)
module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

type outcome =
  { bytes : int list
  ; status : int
  ; ok : bool
  ; done_ : bool
  ; sample_cycles : int list  (* cycles at which PIPE_BIT executed *)
  }

let lead = 40

(* [glitches]: (start_cycle, length, pin) -- inverts that pin for a few cycles *)
let simulate ~b ~glitch_n ~t0 ~t_wait ?(glitches = []) symbols =
  let sim = Sim.create Dual.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 (1 lsl dm);
  inputs.prescale := Bits.of_int ~width:8 0;
  inputs.run := Bits.gnd;
  inputs.protocol_run := Bits.gnd;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();
  List.iteri
    (fun k b ->
      inputs.cfg_addr := Bits.of_int ~width:7 k;
      inputs.cfg_data := Bits.of_int ~width:8 b;
      inputs.cfg_we := Bits.vdd;
      cycle ())
    (cfg ~glitch:glitch_n);
  inputs.cfg_we := Bits.gnd;
  List.iteri
    (fun i w ->
      inputs.phys_write_addr := Bits.of_int ~width:9 i;
      inputs.phys_write_data := Bits.of_int ~width:16 w;
      inputs.phys_write_enable := Bits.vdd;
      cycle ())
    (program ~t0 ~t_wait);
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
  let n_sym = List.length symbols in
  let syms = Array.of_list symbols in
  let total = lead + (n_sym * b) + 400 in
  let bytes = ref [] and prev_pc = ref 0 and samples = ref [] in
  for t = 0 to total - 1 do
    let s = if t < lead then 1 else (let k = (t - lead) / b in if k < n_sym then syms.(k) else 1) in
    let dmv = if s = 1 then 1 else 0 and dpv = if s = 0 then 1 else 0 in
    let flip pin v =
      if List.exists (fun (st, len, p) -> p = pin && t >= st && t < st + len) glitches then 1 - v else v
    in
    inputs.pins_in := Bits.of_int ~width:8 ((flip dm dmv lsl dm) lor (flip dp dpv lsl dp));
    cycle ();
    let pc = Bits.to_int !(outputs.protocol_pc) in
    if pc = 1 && !prev_pc = 0 then bytes := Bits.to_int !(outputs.rx_word) :: !bytes;
    prev_pc := pc;
    let ppc = Bits.to_int !(outputs.phys_pc) in
    if ppc = 9 || ppc = 11 then samples := t :: !samples
  done;
  let pout = Bits.to_int !(outputs.protocol_pins_out) in
  let bytes = List.rev !bytes in
  let status = match List.rev bytes with s :: _ -> s | [] -> 0 in
  { bytes = (match List.rev bytes with _ :: r -> List.rev r | [] -> [])
  ; status
  ; ok = (pout lsr flag_ok) land 1 = 1
  ; done_ = (pout lsr flag_done) land 1 = 1
  ; sample_cycles = List.rev !samples
  }

(* distinct PIPE_BIT executions (pc stays on the instruction for one cycle) *)
let dedup cycles =
  let rec go prev = function
    | [] -> []
    | x :: r -> if x = prev + 1 then go x r else x :: go x r
  in
  go (-10) cycles

(* Calibrate against the real packet: measure the fixed overhead of the first
   sample and of one loop iteration, then solve for t0 and t_wait. *)
let calibrate ~b ~glitch_n =
  let probe = packet_symbols [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let r = simulate ~b ~glitch_n ~t0:1 ~t_wait:1 probe in
  match dedup r.sample_cycles with
  | s1 :: s2 :: _ ->
    let c0 = s1 - lead - 1 in
    let c_loop = s2 - s1 - 1 in
    let t0 = max 1 ((b / 2) - c0) and t_wait = b - c_loop in
    (t0, t_wait, c0, c_loop)
  | _ -> failwith "calibration: no samples seen"

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let good r expect =
  r.done_ && r.ok && r.bytes = expect && r.status land 0x7 = 0x5 (* aligned, no stuff err, crc ok *)

let () =
  Printf.printf "=== USB low-speed receive on the dual-engine core (bit pipe + glitch filter) ===\n";
  let b = 32 in
  let t0, t_wait, c0, c_loop = calibrate ~b ~glitch_n:0 in
  Printf.printf "  calibration @ %d cycles/bit: first-sample overhead %d, loop overhead %d -> t0=%d, t_wait=%d\n"
    b c0 c_loop t0 t_wait;
  let run ?(glitch_n = 0) ?glitches ?(b = b) ?(t0 = t0) ?(t_wait = t_wait) symbols =
    simulate ~b ~glitch_n ~t0 ~t_wait ?glitches symbols
  in

  (* 1. the real GET_DESCRIPTOR data stage *)
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let r = run (packet_symbols gd) in
  check "GET_DESCRIPTOR packet: uE1 sees exact bytes, CRC ok, flag_ok" (good r (expected_bytes gd));
  let r0 = run (packet_symbols []) in
  check "zero-length DATA0 packet accepted" (good r0 (expected_bytes []));

  (* 2. random packets, stuffing-heavy *)
  let seed = ref 4242 in
  let rnd n = seed := ((!seed * 1103515245) + 12345) land 0x7FFFFFFF; (!seed lsr 8) mod n in
  let n_ok = ref 0 and n_tot = 60 in
  for _ = 1 to n_tot do
    let len = 1 + rnd 8 in
    let payload = List.init len (fun _ -> match rnd 4 with 0 -> 0xFF | 1 -> 0x7F | _ -> rnd 256) in
    if good (run (packet_symbols payload)) (expected_bytes payload) then incr n_ok
  done;
  check (Printf.sprintf "%d random packets (forced bit stuffing) all received exactly" n_tot) (!n_ok = n_tot);

  (* 3. corruption and stuffing violation must be rejected, flag_done still set *)
  let c = usb_crc16 gd in
  ignore c;
  let syms = Array.of_list (packet_symbols gd) in
  let bad = Array.copy syms in
  let k = 8 + 8 + 20 in (* a data bit well inside the packet *)
  bad.(k) <- (if bad.(k) = 1 then 0 else 1);
  let r = run (Array.to_list bad) in
  check "one flipped line bit: packet rejected (flag_ok low, flag_done high)" (r.done_ && not r.ok);
  let r = run (packet_symbols ~stuff_it:false (List.init 4 (fun _ -> 0xFF))) in
  check "unstuffed 1s (stuffing violation): rejected" (r.done_ && not r.ok && r.status land 2 = 2);

  (* 4. glitch at the sample instant of one bit *)
  let probe = run (packet_symbols gd) in
  let samples = Array.of_list (dedup probe.sample_cycles) in
  let mid = samples.(30) in
  let glitches = [ (mid - 1, 3, dm) ] in
  let r = run ~glitches (packet_symbols gd) in
  check "3-cycle glitch on the sample instant, filter OFF: packet corrupted" (r.done_ && not r.ok);
  (* with the filter on, the same glitch vanishes; re-calibrate for its fixed latency *)
  let gt0, gtw, _, _ = calibrate ~b ~glitch_n:4 in
  let r = run ~glitch_n:4 ~t0:gt0 ~t_wait:gtw ~glitches (packet_symbols gd) in
  check "same glitch, glitch filter n=4: packet received exactly" (good r (expected_bytes gd));

  (* 5. how fast does this same four-instruction loop keep up? *)
  Printf.printf "  bit-rate sweep (clock cycles per bit -> Mbit/s at 50 MHz), same program:\n";
  let fastest = ref 0 in
  List.iter
    (fun bb ->
      match (try Some (calibrate ~b:bb ~glitch_n:0) with _ -> None) with
      | Some (ct0, ctw, _, cl) when ctw >= 1 && bb - cl >= 1 ->
        let okc = ref 0 in
        let cases = [ gd; [ 0xFF; 0xFF; 0x7F ]; [ 0x01; 0x02; 0x03 ] ] in
        List.iter
          (fun p ->
            if good (run ~b:bb ~t0:ct0 ~t_wait:ctw (packet_symbols p)) (expected_bytes p) then incr okc)
          cases;
        Printf.printf "    %2d cycles/bit  %5.2f Mbit/s   %d/%d packets ok\n" bb (50.0 /. float_of_int bb)
          !okc (List.length cases);
        if !okc = List.length cases && (!fastest = 0 || bb < !fastest) then fastest := bb
      | _ -> Printf.printf "    %2d cycles/bit  %5.2f Mbit/s   loop cannot fit\n" bb (50.0 /. float_of_int bb))
    [ 32; 24; 16; 12; 10; 9; 8; 7; 6 ];
  Printf.printf "  fastest bit period that decoded all test packets: %d cycles/bit\n" !fastest;
  check "keeps up at 12 cycles/bit or faster (USB low speed needs 33)" (!fastest > 0 && !fastest <= 12);

  Printf.printf "RESULT: %s\n" (if !failures = 0 then "PASS" else "FAIL");
  if !failures > 0 then exit 1
