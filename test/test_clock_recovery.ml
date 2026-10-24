open Hardcaml
open Tt_core

(* Bit-clock recovery (clock_recovery.ml), first on its own, then doing its
   job: USB low-speed receive from a sender whose clock is off.

   Unit level (the strobe against a line with known bit boundaries):
   1. Exact period, and a fractional one (46.67 cycles: USB low speed at
      70 MHz): one strobe per bit, every one well inside its bit, for
      thousands of bits.
   2. Sender clock offset and edge jitter, USB-like data (at most 7 bit
      cells between edges): the second-order loop (period learning on)
      passes at every gain shift 0..3. The first-order loop with a gentle
      gain does not: at gain shift 1 and -2% its phase error outgrows the
      window and it loses lock, which is why the period estimate exists.
   3. The pass/fail boundary against a model. A sample k cells after the
      last edge lands at (k + 1/2)(1 - o) of the true cell, so with snap
      correction (gain 0) the last cell before an edge fails once
      (R - 1/2)|o| > 1/2 - (J + L)/P (R: longest run of cells without an
      edge, J: jitter, L: detection latency, P: period). The measured
      boundary must sit where the model puts it.
   4. Control: a window of 1 cycle rejects almost every edge, which turns
      the unit into the free-running sampler it replaces; it fails at an
      offset the tracking one passes.
   5. A glitch mid-bit: a window of P/4 rejects its edges and the samples
      stay put; with every edge accepted the same glitch drags the phase.
   6. Overrun: an unconsumed strobe followed by another sets `overrun`.

   The same unit receiving real USB packets on the dual-engine core is
   test_usb_rx_recovery.ml. *)

module Sim = Cyclesim.With_interface (Clock_recovery.I) (Clock_recovery.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

(* profile bytes 0..15 then the recovery bytes *)
let rec_bytes ?(pad = []) ?fshift ~gain ~period ~window ~pin () =
  let fixed = int_of_float (Float.round (period *. 256.0)) in
  let base = pad @ List.init (16 - List.length pad) (fun _ -> 0) in
  base
  @ [ 1 lor (pin lsl 1) lor (gain lsl 4); fixed land 0xFF; (fixed lsr 8) land 0xFF; (fixed lsr 16) land 0x0F; window
    ; (match fshift with Some f -> 1 lor (f lsl 1) | None -> 0) ]

let cfg_of_bytes bytes =
  let bytes = bytes @ List.init (Bitpipe.cfg_bytes - List.length bytes) (fun _ -> 0) in
  Bits.concat_msb (List.rev_map (fun b -> Bits.of_int ~width:8 (b land 0xFF)) bytes)

(* A line: bit k occupies [b.(k), b.(k+1)). Boundaries at t0 + k*pt plus
   uniform jitter in [-j, j]. *)
type line = { bits : int array; b : float array }

let make_line ~pt ~j ~bits =
  let n = Array.length bits in
  let b = Array.init (n + 1) (fun k ->
    let jit = if j > 0.0 && k > 0 then (Random.float (2.0 *. j)) -. j else 0.0 in
    40.0 +. (float_of_int k *. pt) +. jit)
  in
  { bits; b }

let level_at l t ~idle =
  let tf = float_of_int t in
  if tf < l.b.(0) then idle
  else begin
    let n = Array.length l.bits in
    let k = ref 0 in
    while !k < n && l.b.(!k + 1) <= tf do incr k done;
    if !k >= n then idle else l.bits.(!k)
  end

(* the period estimate at the end of the last run_unit *)
let last_period = ref 0.0

(* where in its bit (0..1) each strobe fell; None if bits were skipped or
   repeated *)
let run_unit ?(consume = true) ?(glitch = None) ~cfg ~idle l =
  let sim = Sim.create Clock_recovery.create in
  let i = Cyclesim.inputs sim and ob = Cyclesim.outputs ~clock_edge:Before sim in
  let oa = Cyclesim.outputs sim in
  i.rst_n := Bits.gnd;
  Cyclesim.cycle sim;
  i.rst_n := Bits.vdd;
  i.cfg := cfg;
  i.pins_in := Bits.of_int ~width:8 idle;
  i.arm := Bits.vdd;
  Cyclesim.cycle sim;
  i.arm := Bits.gnd;
  let n = Array.length l.bits in
  let last = int_of_float l.b.(n) + 5 in
  let strobes = ref [] and rejects = ref 0 and overrun = ref false in
  for t = 0 to last do
    let v = level_at l t ~idle in
    let v = match glitch with Some (g0, g1) when t >= g0 && t < g1 -> 1 - v | _ -> v in
    i.pins_in := Bits.of_int ~width:8 v;
    i.consume := if consume then !(oa.pending) else Bits.gnd;
    Cyclesim.cycle sim;
    if Bits.to_int !(ob.strobe) = 1 then strobes := t :: !strobes;
    if Bits.to_int !(ob.edge_reject) = 1 then incr rejects;
    if Bits.to_int !(oa.overrun) = 1 then overrun := true
  done;
  last_period := float_of_int (Bits.to_int !(oa.period)) /. 256.0;
  let strobes = List.rev !strobes in
  let pos =
    List.map
      (fun s ->
        let tf = float_of_int s in
        let k = ref 0 in
        while !k < n && l.b.(!k + 1) <= tf do incr k done;
        (* a strobe after the last bit is an extra sample: index n *)
        if !k >= n then (n, -1.0) else (!k, (tf -. l.b.(!k)) /. (l.b.(!k + 1) -. l.b.(!k))))
      strobes
  in
  let consecutive = List.mapi (fun idx (k, _) -> idx = k) pos |> List.for_all Fun.id in
  ((if consecutive && List.length pos = n then Some (List.map snd pos) else None), !rejects, !overrun)

let inside lo hi = function Some ps -> List.for_all (fun p -> p > lo && p < hi) ps | None -> false

(* USB-like data: NRZI of bit-stuffed random bits, so at most 7 cells
   between edges; [ones] biases toward long runs *)
let usb_like_levels ~n ~ones =
  let raw = List.init n (fun _ -> if Random.float 1.0 < ones then 1 else Random.int 2) in
  let out = ref [] and run = ref 0 in
  List.iter (fun x -> out := x :: !out; if x = 1 then incr run else run := 0; if !run = 6 then (out := 0 :: !out; run := 0)) raw;
  let lvl = ref 1 in
  (* first cell a K (0) so the first boundary is an edge *)
  Array.of_list (0 :: List.map (fun x -> if x = 0 then lvl := 1 - !lvl; !lvl) (List.rev !out))

(* the worst case for drift: six 1s then a stuffed 0, repeated (7 cells
   between edges every time) *)
let worst_levels ~n =
  let lvl = ref 0 in
  Array.init n (fun k -> if k > 0 && k mod 7 = 0 then lvl := 1 - !lvl; !lvl)

(* REC_SWEEP=1: print which (gain shift, period shift) pairs hold lock over
   the offsets, to choose the documented rule of thumb *)
let sweep p =
  let offs = match Sys.getenv_opt "REC_WIDE" with Some _ -> [ -0.05; -0.03; 0.03; 0.05 ] | None -> [ -0.02; -0.015; -0.01; -0.005; 0.005; 0.01; 0.015; 0.02 ] in
  Printf.printf "    gain\\fshift  0 1 2 3 4 5 6 7   (count of %d offsets x 3 seeds that hold lock)\n" (List.length offs);
  for gain = 0 to 4 do
    Printf.printf "    %d           " gain;
    for fs = 0 to 7 do
      let ok = ref 0 in
      List.iter
        (fun off ->
          for seed = 1 to 3 do
            Random.init (seed * 77);
            let l = make_line ~pt:(p *. (1.0 +. off)) ~j:2.0 ~bits:(usb_like_levels ~n:600 ~ones:0.7) in
            let r, _, _ =
              run_unit ~cfg:(cfg_of_bytes (rec_bytes ~fshift:fs ~gain ~period:p ~window:8 ~pin:0 ())) ~idle:1 l
            in
            if inside 0.05 0.95 r then incr ok
          done)
        offs;
      Printf.printf "%3d" !ok
    done;
    print_newline ()
  done

let () =
  Random.init 1234;
  Printf.printf "=== clock_recovery: sample strobe against the sender's clock ===\n";
  let p = 33.0 in
  if Sys.getenv_opt "REC_SWEEP" <> None then (sweep p; exit 0);

  (* 1. exact and fractional periods *)
  let l = make_line ~pt:p ~j:0.0 ~bits:(usb_like_levels ~n:2000 ~ones:0.5) in
  let r, _, _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~gain:2 ~period:p ~window:8 ~pin:0 ())) ~idle:1 l in
  check "33 cycles/bit, 2000+ bits: one strobe per bit, each in the middle half" (inside 0.25 0.75 r);
  let pf = 70.0 /. 1.5 in
  let l = make_line ~pt:pf ~j:0.0 ~bits:(usb_like_levels ~n:2000 ~ones:0.5) in
  let r, _, _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~gain:2 ~period:pf ~window:11 ~pin:0 ())) ~idle:1 l in
  check "46.67 cycles/bit (fractional period): same" (inside 0.25 0.75 r);

  (* 2. offset and jitter, every gain, second-order loop *)
  let all_gains =
    List.for_all
      (fun gain ->
        List.for_all
          (fun off ->
            let l = make_line ~pt:(p *. (1.0 +. off)) ~j:2.0 ~bits:(usb_like_levels ~n:600 ~ones:0.7) in
            let r, _, _ =
              run_unit ~cfg:(cfg_of_bytes (rec_bytes ~fshift:4 ~gain ~period:p ~window:8 ~pin:0 ())) ~idle:1 l
            in
            let ok = inside 0.15 0.85 r in
            if (not ok) && Sys.getenv_opt "REC_DEBUG" <> None then
              Printf.printf "    fail: gain %d offset %+.1f%% %s\n" gain (100.0 *. off)
                (match r with
                 | None -> "(bits skipped or repeated)"
                 | Some ps -> Printf.sprintf "(worst %.2f)" (List.fold_left (fun a x -> if Float.abs (x -. 0.5) > Float.abs (a -. 0.5) then x else a) 0.5 ps));
            ok)
          [ -0.02; -0.015; -0.005; 0.005; 0.015; 0.02 ])
      [ 0; 1; 2; 3 ]
  in
  check "+-0.5/1.5/2% offset, +-2 cycle jitter, period learning: gain shift 0..3 pass" all_gains;
  let first_order_loses =
    let l = make_line ~pt:(p *. 0.98) ~j:2.0 ~bits:(usb_like_levels ~n:600 ~ones:0.7) in
    let r, _, _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~gain:1 ~period:p ~window:8 ~pin:0 ())) ~idle:1 l in
    not (inside 0.15 0.85 r)
  in
  check "without period learning, gain shift 1 at -2% loses lock (the reason for it)" first_order_loses;
  (* the estimate must be unbiased: exact sender clock, symmetric jitter *)
  let l = make_line ~pt:p ~j:1.5 ~bits:(usb_like_levels ~n:3000 ~ones:0.5) in
  let _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~fshift:6 ~gain:1 ~period:p ~window:8 ~pin:0 ())) ~idle:1 l in
  let learned_exact = !last_period in
  let l = make_line ~pt:(p *. 1.015) ~j:1.5 ~bits:(usb_like_levels ~n:3000 ~ones:0.5) in
  let _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~fshift:6 ~gain:1 ~period:p ~window:8 ~pin:0 ())) ~idle:1 l in
  let learned_fast = !last_period in
  Printf.printf "    learned period: %.3f for an exact 33.000 sender, %.3f for a +1.5%% one (%.3f)\n"
    learned_exact learned_fast (p *. 1.015);
  check "learned period unbiased (within 0.25 cycle) and tracks a +1.5% sender"
    (Float.abs (learned_exact -. p) < 0.25 && Float.abs (learned_fast -. (p *. 1.015)) < 0.25);

  (* 3. boundary against the model (snap, no jitter, worst-case runs) *)
  let passes off ~window =
    let l = make_line ~pt:(p *. (1.0 +. off)) ~j:0.0 ~bits:(worst_levels ~n:400) in
    let r, _, _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~gain:0 ~period:p ~window ~pin:0 ())) ~idle:1 l in
    inside 0.0 1.0 r
  in
  let measured sign ~window =
    let rec go o = if o > 0.30 || not (passes (sign *. o) ~window) then o -. 0.0025 else go (o +. 0.0025) in
    go 0.0025
  in
  let r_run = 7.0 and lat = 1.5 in
  let model = (0.5 -. (lat /. p)) /. (r_run -. 0.5) in
  let m_pos = measured 1.0 ~window:0 and m_neg = measured (-1.0) ~window:0 in
  Printf.printf "    snap, 7-cell runs: model says |offset| < %.1f%%; measured +%.2f%% / -%.2f%%\n"
    (100.0 *. model) (100.0 *. m_pos) (100.0 *. m_neg);
  check "measured pass/fail boundary within 1% of the model, both signs"
    (Float.abs (m_pos -. model) < 0.01 && Float.abs (m_neg -. model) < 0.01);

  (* 4. control: almost every edge rejected = the free-running sampler *)
  let n_bits = 100 in
  let ctrl off =
    let l = make_line ~pt:(p *. (1.0 +. off)) ~j:0.0 ~bits:(usb_like_levels ~n:n_bits ~ones:0.5) in
    let tracked, _, _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~gain:1 ~period:p ~window:8 ~pin:0 ())) ~idle:1 l in
    let free, _, _ = run_unit ~cfg:(cfg_of_bytes (rec_bytes ~gain:1 ~period:p ~window:1 ~pin:0 ())) ~idle:1 l in
    inside 0.0 1.0 tracked, inside 0.0 1.0 free
  in
  let t15, f15 = ctrl 0.015 and t03, f03 = ctrl 0.003 in
  Printf.printf "    free-running model: a %d-bit packet fails beyond %.2f%%\n" n_bits (100.0 *. 0.5 /. (float_of_int n_bits -. 0.5));
  check "0.3% offset: tracking and free-running both pass" (t03 && f03);
  check "1.5% offset (USB's tolerance): tracking passes, free-running fails" (t15 && not f15);

  (* 5. glitch mid-bit *)
  let bits = usb_like_levels ~n:200 ~ones:0.5 in
  let l = make_line ~pt:p ~j:0.0 ~bits in
  let g0 = int_of_float l.b.(60) + 14 in
  let glitch = Some (g0, g0 + 3) in
  let windowed, rejects, _ = run_unit ~glitch ~cfg:(cfg_of_bytes (rec_bytes ~gain:0 ~period:p ~window:8 ~pin:0 ())) ~idle:1 l in
  let open_, _, _ = run_unit ~glitch ~cfg:(cfg_of_bytes (rec_bytes ~gain:0 ~period:p ~window:0 ~pin:0 ())) ~idle:1 l in
  check (Printf.sprintf "3-cycle glitch mid-bit, window P/4: %d edges rejected, samples stay put" rejects)
    (rejects = 2 && inside 0.25 0.75 windowed);
  check "same glitch, every edge accepted (gain 0): a sample is pulled off-centre" (not (inside 0.25 0.75 open_));

  (* 6. overrun *)
  let l = make_line ~pt:p ~j:0.0 ~bits:(usb_like_levels ~n:10 ~ones:0.5) in
  let _, _, ov = run_unit ~consume:false ~cfg:(cfg_of_bytes (rec_bytes ~gain:0 ~period:p ~window:0 ~pin:0 ())) ~idle:1 l in
  let _, _, ov_ok = run_unit ~consume:true ~cfg:(cfg_of_bytes (rec_bytes ~gain:0 ~period:p ~window:0 ~pin:0 ())) ~idle:1 l in
  check "strobes never consumed: overrun set; consumed every bit: never set" (ov && not ov_ok);

  if !failures = 0 then print_endline "RESULT: PASS"
  else (Printf.printf "RESULT: FAIL (%d)\n" !failures; exit 1)
