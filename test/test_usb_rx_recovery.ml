open Hardcaml
open Tt_core

(* USB low-speed receive from a sender whose clock is off, on the
   dual-engine core. The clock-recovery loop replaces the timed waits:

      0 wait until D- is high (idle J)
      1 PIPE_CTRL reset (idle J; also arms the recovery)
      2 L: pipe_sync          wait for the sample strobe
      3    D+ high? -> 6 (K)
      4    D- high? -> 8 (J)
      5    else SE0 -> 10
      6 K: PIPE_BIT, 7 jump L
      8 J: PIPE_BIT, 9 jump L
     10 PIPE_STATUS, 11 halt

   Step 0 matters: armed, the recovery takes the next edge as a bit
   boundary, so it must be armed on an idle line, where the next edge is
   SYNC's first J->K. Armed while the line was still low (power-up SE0, or
   a bench driving 0 before the packet), the line rising to idle J was
   taken as the first boundary and idle cells were sampled as data
   (found by the tt_um_dual and cocotb benches, whose pins read 0 for a
   few cycles after `go`).

   No calibration and no timed waits: the strobe comes from the profile's
   bit period and the edges on D-. µE1 is test_usb_rx.ml's (flag_ok =
   CRC ok, no stuffing error, whole bytes).

   Senders off by -2% .. +2% (USB low speed allows 1.5%) with +-2 cycles of
   edge jitter, GET_DESCRIPTOR plus random stuffing-heavy packets: every
   packet must be received exactly. The control is test_usb_rx.ml's
   free-running timed loop, calibrated for the exact period: it must pass
   at 0% and fail where the model says a packet this long drifts off. *)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let dm = 0
let dp = 1
let flag_ok = 2
let flag_done = 3
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF
let bit x n = (x lsr n) land 1
let p = 33.0

let usb16 = [ 0b011011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

(* recovery on D- (pin 0), gain shift 1, period learning shift 4, window P/4 *)
let rec_profile =
  let fixed = int_of_float (p *. 256.0) in
  usb16 @ List.init 7 (fun _ -> 0)
  @ [ 1 lor (dm lsl 1) lor (1 lsl 4); fixed land 0xFF; (fixed lsr 8) land 0xFF; (fixed lsr 16) land 0x0F; 8; 1 lor (4 lsl 1) ]

let recovered_prog =
  Engine.
    [ branch_cond ~pin:dm ~branch_if_high:false ~target:0 (* wait for idle J *)
    ; pipe_ctrl ~reset:true ~prev_level:true ~crc_init:false
    ; pipe_sync
    ; branch_cond ~pin:dp ~branch_if_high:true ~target:6
    ; branch_cond ~pin:dm ~branch_if_high:true ~target:8
    ; branch_cond ~pin:dm ~branch_if_high:false ~target:10
    ; pipe_bit ~pin:dm
    ; branch_cond ~pin:7 ~branch_if_high:false ~target:2
    ; pipe_bit ~pin:dm
    ; branch_cond ~pin:7 ~branch_if_high:false ~target:2
    ; pipe_status
    ; wait_edge ~pin:7 ~falling:true ~payload:0
    ]

(* test_usb_rx.ml's timed loop *)
let timed_prog ~t0 ~t_wait =
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

(* ---- reference transmitter ---- *)
let bits_lsb b = List.init 8 (fun i -> bit b i)

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
let symbols payload =
  let c = crc16 payload in
  nrzi (stuff (List.concat_map bits_lsb ((0x80 :: 0xC3 :: payload) @ [ lo c; hi c ]))) @ [ 2; 2; 1 ]

(* Drive [syms] with the sender's cell [pt] and +-[j] cycles of jitter on
   every boundary. Returns (flag_ok, flag_done, PIPE_BIT cycles). *)
let lead = 60.0

let simulate ?(pre_low = 0) ~phys ~cfg ~pt ~j ?(seed = 1) syms =
  Random.init seed;
  let syms = Array.of_list syms in
  let n = Array.length syms in
  let b = Array.init (n + 1) (fun k ->
    lead +. (float_of_int k *. pt) +. (if j > 0.0 && k > 0 && k < n then Random.float (2.0 *. j) -. j else 0.0))
  in
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.pins_in := Bits.of_int ~width:8 (1 lsl dm);
  cycle ();
  i.rst_n := Bits.vdd;
  List.iteri
    (fun k v ->
      i.cfg_addr := Bits.of_int ~width:7 k;
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
  load i.protocol_write_enable i.protocol_write_addr i.protocol_write_data protocol_prog;
  i.run := Bits.vdd;
  i.protocol_run := Bits.vdd;
  let total = int_of_float b.(n) + 400 in
  let k = ref 0 and samples = ref [] in
  for t = 0 to total - 1 do
    let tf = float_of_int t in
    while !k < n && b.(!k + 1) <= tf do incr k done;
    let s = if t < pre_low then 2 else if tf < b.(0) || !k >= n then 1 else syms.(!k) in
    let dmv = if s = 1 then 1 else 0 and dpv = if s = 0 then 1 else 0 in
    i.pins_in := Bits.of_int ~width:8 ((dmv lsl dm) lor (dpv lsl dp));
    cycle ();
    let pc = Bits.to_int !(o.phys_pc) in
    samples := pc :: !samples
  done;
  let pout = Bits.to_int !(o.protocol_pins_out) in
  (bit pout flag_ok = 1, bit pout flag_done = 1, List.rev !samples)

(* calibrate the timed loop for the exact period, as test_usb_rx.ml does *)
let calibrate () =
  let probe = symbols [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let _, _, pcs = simulate ~phys:(timed_prog ~t0:1 ~t_wait:1) ~cfg:usb16 ~pt:p ~j:0.0 probe in
  let at = List.mapi (fun t pc -> (t, pc)) pcs |> List.filter (fun (_, pc) -> pc = 9 || pc = 11) |> List.map fst in
  let rec dedup prev = function [] -> [] | x :: r -> if x = prev + 1 then dedup x r else x :: dedup x r in
  match dedup (-10) at with
  | s1 :: s2 :: _ ->
    let c0 = s1 - int_of_float lead - 1 and c_loop = s2 - s1 - 1 in
    (max 1 ((int_of_float p / 2) - c0), int_of_float p - c_loop)
  | _ -> failwith "calibration: no samples"

let () =
  Printf.printf "=== USB low-speed receive with bit-clock recovery (sender clock offset + jitter) ===\n";
  let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] in
  let t0, t_wait = calibrate () in
  let timed = timed_prog ~t0 ~t_wait in
  let rec_ok ?(j = 2.0) ?seed off payload =
    let ok, dn, _ = simulate ~phys:recovered_prog ~cfg:rec_profile ~pt:(p *. (1.0 +. off)) ~j ?seed (symbols payload) in
    ok && dn
  in
  let timed_ok off payload =
    let ok, dn, _ = simulate ~phys:timed ~cfg:usb16 ~pt:(p *. (1.0 +. off)) ~j:0.0 (symbols payload) in
    ok && dn
  in
  let offs = [ -0.02; -0.015; -0.01; -0.005; 0.0; 0.005; 0.01; 0.015; 0.02 ] in
  Printf.printf "    offset   recovered (+-2 cyc jitter)   timed loop (no jitter)\n";
  let rows = List.map (fun off -> (off, rec_ok off gd, timed_ok off gd)) offs in
  List.iter
    (fun (off, r, t) -> Printf.printf "    %+5.1f%%   %-28s %s\n" (100.0 *. off) (if r then "ok" else "FAIL") (if t then "ok" else "FAIL"))
    rows;
  check "GET_DESCRIPTOR: recovered loop accepts at every offset from -2% to +2%"
    (List.for_all (fun (_, r, _) -> r) rows);
  let n_bits = List.length (symbols gd) - 3 in
  let model = 0.5 /. (float_of_int n_bits -. 0.5) in
  Printf.printf "    free-running model: a %d-bit packet drifts off beyond about %.2f%%\n" n_bits (100.0 *. model);
  check "timed loop: passes at 0%, fails at +-1.5% (USB's tolerance)"
    (List.exists (fun (o, _, t) -> o = 0.0 && t) rows
     && List.for_all (fun (o, _, t) -> Float.abs o < 0.014 || not t) rows);

  (* random stuffing-heavy packets at the USB limit, both signs *)
  Random.init 5;
  let payloads = List.init 15 (fun _ -> List.init (1 + Random.int 8) (fun _ -> if Random.bool () then 0xFF else Random.int 256)) in
  let all = List.for_all (fun off -> List.for_all (fun pl -> rec_ok ~seed:(Random.int 1000) off pl) payloads) [ -0.015; 0.015 ] in
  check "15 random packets at -1.5% and +1.5% with jitter: all received exactly" all;
  (* a corrupted packet is still rejected *)
  let syms = Array.of_list (symbols gd) in
  syms.(40) <- 1 - syms.(40);
  let ok, dn, _ = simulate ~phys:recovered_prog ~cfg:rec_profile ~pt:(p *. 1.01) ~j:2.0 (Array.to_list syms) in
  check "one flipped line bit at +1%: rejected (flag_ok low, flag_done high)" ((not ok) && dn);

  (* arming on an idle line: SE0 for 10 cycles before the idle J, as on a
     bus at power-up (or the pin-level benches right after `go`) *)
  let pre_low_ok prog =
    let ok, dn, _ = simulate ~pre_low:10 ~phys:prog ~cfg:rec_profile ~pt:(p *. 1.01) ~j:2.0 (symbols gd) in
    ok && dn
  in
  let no_wait = List.tl recovered_prog |> List.map (fun w ->
    (* the same loop without step 0: every branch target moves down by one *)
    let opcode = (w lsr 14) land 3 in
    if opcode = 3 && (w land 0x200) = 0 && (w land 0x1FF) > 0 then w - 1 else w)
  in
  check "line low before the packet: waiting for idle J before arming receives it" (pre_low_ok recovered_prog);
  check "...and arming straight away takes the rise to J as a boundary and fails" (not (pre_low_ok no_wait));
  if !failures = 0 then print_endline "RESULT: PASS"
  else (Printf.printf "RESULT: FAIL (%d)\n" !failures; exit 1)
