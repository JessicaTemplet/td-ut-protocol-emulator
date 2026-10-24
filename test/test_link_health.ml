open Hardcaml
open Tt_core

(* Link-health reporting: the receive path says how well it is coping, not
   only whether a packet's CRC came out right.

   Unit (clock_recovery.ml alone):
   1. The margin is exact: after a clean lock, one edge displaced by k
      cycles reports floor(64 |k| / P), early or late; the worst of several
      is kept; `arm` clears it.

   Dual-engine core, USB low-speed receive with clock recovery:
   2. The margin in the status word rises with the sender's clock offset
      and with edge jitter (mean over several packets at each step), and is
      small on a clean link.
   3. CRC syndrome: for EVERY single-bit error in a DATA0 packet's data and
      CRC (80 positions), the CRC register µE1 reads with PIPE_STATUS crc_lo,
      XORed with the good-packet residue, equals an independent host model
      of that error's syndrome, and no two positions share a syndrome: the
      host can say which bit was wrong. Reported, never corrected.
   4. The learned bit period µE1 reads back (PIPE_STATUS period) is the
      sender's, for a 1.5%-fast one.
   5. A µE1 program branching on status bit 7 (margin >= 16/64: an edge a
      quarter bit or more off) flags a degrading link at a jitter where the
      CRC still passes: warning before the packets start failing. *)

module Rec = Cyclesim.With_interface (Clock_recovery.I) (Clock_recovery.O)
module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let bit x n = (x lsr n) land 1
let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF
let p = 33.0

let rec_bytes ~gain ~fshift ~window ~pin =
  let fixed = int_of_float (p *. 256.0) in
  [ 1 lor (pin lsl 1) lor (gain lsl 4); fixed land 0xFF; (fixed lsr 8) land 0xFF; (fixed lsr 16) land 0x0F; window
  ; (match fshift with Some f -> 1 lor (f lsl 1) | None -> 0) ]

let cfg_bits bytes =
  let bytes = bytes @ List.init (Bitpipe.cfg_bytes - List.length bytes) (fun _ -> 0) in
  Bits.concat_msb (List.rev_map (fun b -> Bits.of_int ~width:8 b) bytes)

(* ---------------- 1. unit: the margin is exact ---------------- *)
let unit_margin displacements =
  (* exact 33-cycle cells, snap correction, no window, no learning; edges
     every cell (alternating levels) except that cell [k]'s leading edge is
     moved by the given whole number of cycles *)
  let sim = Rec.create Clock_recovery.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  i.rst_n := Bits.gnd;
  Cyclesim.cycle sim;
  i.rst_n := Bits.vdd;
  i.cfg := cfg_bits (List.init 16 (fun _ -> 0) @ rec_bytes ~gain:7 ~fshift:None ~window:0 ~pin:0);
  i.pins_in := Bits.of_int ~width:8 1;
  i.arm := Bits.vdd;
  Cyclesim.cycle sim;
  i.arm := Bits.gnd;
  let n = 40 in
  let bound k = 20 + (k * 33) + (match List.assoc_opt k displacements with Some d -> d | None -> 0) in
  for t = 0 to bound n + 40 do
    let k = ref 0 in
    while !k < n && bound (!k + 1) <= t do incr k done;
    let level = if t < bound 0 then 1 else !k land 1 in
    i.pins_in := Bits.of_int ~width:8 level;
    i.consume := !(o.pending);
    Cyclesim.cycle sim
  done;
  for _ = 1 to 10 do Cyclesim.cycle sim done;
  Bits.to_int !(o.margin)

(* ---------------- Dual-engine harness ---------------- *)
let dm = 0
let dp = 1

let usb16 = [ 0b011011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]
let profile = usb16 @ List.init 7 (fun _ -> 0) @ rec_bytes ~gain:1 ~fshift:(Some 4) ~window:8 ~pin:dm

(* the receive loop of test_usb_rx_recovery.ml, then the extra words *)
let phys extra =
  Engine.
    [ branch_cond ~pin:dm ~branch_if_high:false ~target:0
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
    ]
  @ extra
  @ [ Engine.wait_edge ~pin:7 ~falling:true ~payload:0 ]

(* µE1: pop every word; [pop_pc] is where each popped word is recorded *)
let recorder = Protocol_engine.[ fifo_pop_instr; branch_word ~bit:15 ~branch_if_one:false ~target:0; branch_word ~bit:15 ~branch_if_one:true ~target:0 ]

let bits_lsb b = List.init 8 (fun i -> bit b i)

let crc16_bits ?(init = 0xFFFF) bits =
  let crc = ref init in
  List.iter (fun b -> let fb = (!crc land 1) lxor b in crc := !crc lsr 1; if fb = 1 then crc := !crc lxor 0xA001) bits;
  !crc

let stuff bits =
  let out = ref [] and ones = ref 0 in
  List.iter (fun b -> out := b :: !out; if b = 1 then incr ones else ones := 0; if !ones = 6 then (out := 0 :: !out; ones := 0)) bits;
  List.rev !out

let nrzi bits =
  let level = ref 1 in
  List.map (fun b -> if b = 0 then level := 1 - !level; !level) bits

(* the data+CRC bits after SYNC and PID (what the CRC covers), and the line *)
let data_bits payload =
  let c = lnot (crc16_bits (List.concat_map bits_lsb payload)) land 0xFFFF in
  List.concat_map bits_lsb (payload @ [ lo c; hi c ])

let line_of body = nrzi (stuff (bits_lsb 0x80 @ bits_lsb 0xC3 @ body)) @ [ 2; 2; 1 ]

let simulate ?(proto = recorder) ?(pop_pcs = [ 0 ]) ~extra ~off ~j ~seed syms =
  Random.init seed;
  let syms = Array.of_list syms in
  let n = Array.length syms in
  let pt = p *. (1.0 +. off) in
  let b = Array.init (n + 1) (fun k -> 60.0 +. (float_of_int k *. pt) +. (if j > 0.0 && k > 0 && k < n then Random.float (2.0 *. j) -. j else 0.0)) in
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.pins_in := Bits.of_int ~width:8 (1 lsl dm);
  cycle ();
  i.rst_n := Bits.vdd;
  List.iteri (fun k v -> i.cfg_addr := Bits.of_int ~width:7 k; i.cfg_data := Bits.of_int ~width:8 v; i.cfg_we := Bits.vdd; cycle ()) profile;
  i.cfg_we := Bits.gnd;
  let load we addr data prog =
    List.iteri (fun k w -> addr := Bits.of_int ~width:9 k; data := Bits.of_int ~width:16 w; we := Bits.vdd; cycle ()) prog;
    we := Bits.gnd
  in
  load i.phys_write_enable i.phys_write_addr i.phys_write_data (phys extra);
  load i.protocol_write_enable i.protocol_write_addr i.protocol_write_data proto;
  i.run := Bits.vdd;
  i.protocol_run := Bits.vdd;
  let words = ref [] and prev = ref 0 and k = ref 0 in
  for t = 0 to int_of_float b.(n) + 400 do
    let tf = float_of_int t in
    while !k < n && b.(!k + 1) <= tf do incr k done;
    let s = if tf < b.(0) || !k >= n then 1 else syms.(!k) in
    i.pins_in := Bits.of_int ~width:8 (((if s = 1 then 1 else 0) lsl dm) lor ((if s = 0 then 1 else 0) lsl dp));
    cycle ();
    let pc = Bits.to_int !(o.protocol_pc) in
    if pc <> !prev && List.mem !prev pop_pcs then words := Bits.to_int !(o.rx_word) :: !words;
    prev := pc
  done;
  (List.rev !words, Bits.to_int !(o.protocol_pins_out))

(* the words after the data bytes: [status; extra...] *)
let tail_words words = List.filter (fun w -> w land 0x8000 <> 0) words |> function s :: _ ->
  let rec after = function [] -> [] | x :: r -> if x = s then r else after r in
  s :: after words | [] -> []

let margin_of status = (status lsr 3) land 31
let crc_ok status = status land 1 = 1

let gd = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ]

let () =
  Printf.printf "=== link health: timing margin, CRC syndrome, learned period ===\n";

  (* 1 *)
  let exact = List.for_all (fun d -> unit_margin [ (20, d) ] = 64 * abs d / 33) [ 1; 2; 3; 5; 8; -2; -5; -8 ] in
  check "one edge k cycles off: margin = floor(64|k|/33) for k = 1,2,3,5,8,-2,-5,-8" exact;
  check "the worst of several edges is kept (2, -6, 4 -> floor(64*6/33) = 11)"
    (unit_margin [ (10, 2); (20, -6); (30, 4) ] = 11);
  check "clean line: margin 0" (unit_margin [] = 0);

  (* 2: margin vs offset and jitter *)
  let mean_margin ~off ~j =
    let ms = List.init 6 (fun s ->
      let words, _ = simulate ~extra:[] ~off ~j ~seed:(s + 1) (line_of (data_bits gd)) in
      match tail_words words with st :: _ -> margin_of st | [] -> 99) in
    float_of_int (List.fold_left ( + ) 0 ms) /. 6.0
  in
  let offs = [ 0.0; 0.005; 0.01; 0.015; 0.02 ] and jits = [ 0.0; 1.0; 2.0; 3.0; 4.0 ] in
  let by_off = List.map (fun off -> mean_margin ~off ~j:0.0) offs in
  let by_jit = List.map (fun j -> mean_margin ~off:0.0 ~j) jits in
  Printf.printf "    mean margin (64ths of a bit) by offset 0..2%%: %s\n" (String.concat " " (List.map (Printf.sprintf "%.1f") by_off));
  Printf.printf "    mean margin by jitter 0..4 cycles:          %s\n" (String.concat " " (List.map (Printf.sprintf "%.1f") by_jit));
  let rec nondecreasing = function a :: (b :: _ as r) -> a <= b +. 0.01 && nondecreasing r | _ -> true in
  check "margin never falls as the offset grows, and rises overall" (nondecreasing by_off && List.nth by_off 4 > List.hd by_off);
  check "margin never falls as the jitter grows, and rises overall" (nondecreasing by_jit && List.nth by_jit 4 > List.hd by_jit);
  check "clean link (0%, no jitter): margin at most 4/64 of a bit" (List.hd by_off <= 4.0);

  (* 3: syndromes *)
  let body = data_bits gd in
  let nb = List.length body in
  let model i = crc16_bits ~init:0 (List.init nb (fun k -> if k = i then 1 else 0)) in
  let table = Array.init nb model in
  let distinct = Array.length table = List.length (List.sort_uniq compare (Array.to_list table)) && Array.for_all (( <> ) 0) table in
  let located = ref 0 in
  for i = 0 to nb - 1 do
    let bad = List.mapi (fun k b -> if k = i then 1 - b else b) body in
    let words, _ = simulate ~extra:[ Engine.pipe_crc_lo ] ~off:0.0 ~j:0.0 ~seed:1 (line_of bad) in
    match tail_words words with
    | st :: crc :: _ when not (crc_ok st) ->
      let s = crc lxor 0xB001 in
      let hits = Array.to_list table |> List.mapi (fun k e -> (k, e)) |> List.filter (fun (_, e) -> e = s) in
      if hits = [ (i, table.(i)) ] then incr located
    | _ -> ()
  done;
  Printf.printf "    %d single-bit error positions; host model syndromes all distinct and nonzero: %b\n" nb distinct;
  check (Printf.sprintf "every one of the %d errors: hardware syndrome = model, pointing at that bit" nb)
    (distinct && !located = nb);
  let words, _ = simulate ~extra:[ Engine.pipe_crc_lo ] ~off:0.0 ~j:0.0 ~seed:1 (line_of body) in
  check "good packet: CRC register = residue 0xB001 (syndrome 0)"
    (match tail_words words with st :: crc :: _ -> crc_ok st && crc = 0xB001 | _ -> false);

  (* 4: learned period *)
  let words, _ = simulate ~extra:[ Engine.pipe_period ] ~off:0.015 ~j:1.0 ~seed:3 (line_of body) in
  let learned = match tail_words words with _ :: pw :: _ -> float_of_int pw /. 16.0 | _ -> 0.0 in
  Printf.printf "    learned period read back by µE1: %.3f cycles (sender: %.3f)\n" learned (p *. 1.015);
  check "the period µE1 reads back is the 1.5%-fast sender's (within 0.25 cycle)" (Float.abs (learned -. (p *. 1.015)) < 0.25);

  (* 5: degraded-link flag *)
  let flag_degraded = 4 and flag_ok = 2 in
  let proto =
    Protocol_engine.
      [ fifo_pop_instr
      ; branch_word ~bit:15 ~branch_if_one:false ~target:0 (* skip data bytes *)
      ; branch_word ~bit:7 ~branch_if_one:false ~target:4 (* margin < 16: fine *)
      ; emit_state ~pin:flag_degraded ~level:true
      ; branch_word ~bit:0 ~branch_if_one:false ~target:6 (* crc bad *)
      ; emit_state ~pin:flag_ok ~level:true
      ; fifo_pop_instr ]
  in
  Printf.printf "    jitter  crc_ok  degraded  (one packet each, same seed)\n";
  let rows =
    List.map
      (fun j ->
        let _, pins = simulate ~proto ~pop_pcs:[] ~extra:[] ~off:0.0 ~j ~seed:7 (line_of body) in
        let ok = bit pins flag_ok = 1 and dg = bit pins flag_degraded = 1 in
        Printf.printf "    %4.0f    %-6b  %b\n" j ok dg;
        (j, ok, dg))
      [ 0.0; 2.0; 4.0; 6.0; 8.0; 10.0 ]
  in
  check "no jitter: not flagged" (match rows with (_, true, false) :: _ -> true | _ -> false);
  check "some jitter level is flagged degraded while its CRC still passes"
    (List.exists (fun (_, ok, dg) -> ok && dg) rows);

  if !failures = 0 then print_endline "RESULT: PASS"
  else (Printf.printf "RESULT: FAIL (%d)\n" !failures; exit 1)
