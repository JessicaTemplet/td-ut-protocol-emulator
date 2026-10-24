open Hardcaml
open Tt_core

(* 10 Mbit Ethernet (10BASE-T) receive on the dual-engine core.

   A bit is 100 ns: 5 clocks at 50 MHz, 7 at 70 MHz. No instruction loop
   keeps up with that, so µE0 runs one instruction per frame:

      0 wait for the idle (high) line      1 PIPE_CTRL reset (arms)
      2 PIPE_BIT run: the clock recovery's Manchester decoder steps the
        receive pipe on every bit until the frame ends
      3 lost-byte check                     5 PIPE_STATUS, halt

   The receive profile does the rest: Manchester decoding, a sync-word hunt
   for the start-of-frame delimiter (0xD5), and CRC-32 over the frame (the
   FCS check: reflected 0xEDB88320, init 0xFFFFFFFF, good residue
   0xDEBB20E3). µE1 pops every byte.

   References here, independent of the hardware: a CRC-32 checked against
   the standard check value (CRC-32 of "123456789" = 0xCBF43926), Ethernet
   frames with a correct FCS, and a Manchester encoder (IEEE 802.3: a 1 is
   low then high) with per-transition jitter and sender clock offset.

   Checks:
   1. Minimum-size and random-length frames are received byte for byte,
      FCS good, at 5 and at 7 cycles a bit.
   2. Tolerance, measured and reported, not assumed: offset (the standard
      allows +-0.01%; swept to +-1%) against jitter, at both clock rates.
   3. A receiver that locks late (only 3 of the 7 preamble bytes) still
      aligns on the delimiter.
   4. One flipped data bit: FCS fails. A frame cut short: rejected.
   5. µE1 not reading: bytes are lost, and the lost-byte flag says so.
   6. Dribble bits (extra bits after the last octet, which IEEE 802.3 has a
      receiver truncate): accepted with the profile's octet CRC on, failed
      with it off.

   Measurement tools (not part of the pass/fail run):
     ETH_SWEEP=1   frames received per (phase gain, period gain), to choose them
     ETH_BITERR=1  the decoder alone on long streams: bit errors and where
                   they fall (ETH_POINTS="P:jitter,..."), to tell acquisition
                   errors from steady-state slips *)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let bit x n = (x lsr n) land 1
let rx = 0
let lost_pin = 5

(* ---- references ---- *)
let crc32_update crc bits =
  List.fold_left
    (fun c b -> let fb = (c land 1) lxor b in let c = c lsr 1 in if fb = 1 then c lxor 0xEDB88320 else c)
    crc bits

let bits_lsb b = List.init 8 (fun i -> bit b i)
let crc32 bytes = (crc32_update 0xFFFFFFFF (List.concat_map bits_lsb bytes)) lxor 0xFFFFFFFF

let frame body =
  let fcs = crc32 body in
  body @ List.init 4 (fun k -> (fcs lsr (8 * k)) land 0xFF)

let preamble n = List.init n (fun _ -> 0x55) @ [ 0xD5 ]

(* Manchester line: half-cell m of bit k has level (not b) for m even, b
   for m odd; every half-cell edge gets jitter; idle high around it *)
let manchester ?(extra = []) ~p ~off ~j ~seed bytes =
  Random.init seed;
  (* [extra]: bits sent after the last byte (dribble bits) *)
  let bits = Array.of_list (List.concat_map bits_lsb bytes @ extra) in
  let n = Array.length bits in
  let half = p *. (1.0 +. off) /. 2.0 in
  let t0 = 40.0 in
  let edge m = t0 +. (float_of_int m *. half) +. (if j > 0.0 && m > 0 then Random.float (2.0 *. j) -. j else 0.0) in
  let h = Array.init ((2 * n) + 1) edge in
  let level m = if m >= 2 * n then 1 else (let b = bits.(m / 2) in if m land 1 = 0 then 1 - b else b) in
  let total = int_of_float h.(2 * n) + 200 in
  let m = ref 0 in
  List.init total (fun t ->
    let tf = float_of_int t in
    if tf < h.(0) then 1
    else begin
      while !m < 2 * n && h.(!m + 1) <= tf do incr m done;
      level !m
    end)

(* ---- profile ---- *)
(* Loop settings, measured (ETH_SWEEP / the table below): period learning
   OFF (the standard allows the sender +-0.01%, so learning only adds noise
   from quantized edges), phase gain shift 2 at 5 clocks a bit and 3 at 7.
   ETH_GAIN / ETH_FSHIFT (-1 = off) override them while measuring. *)
let env_int name default = match Sys.getenv_opt name with Some v -> int_of_string v | None -> default
let gain_shift p = env_int "ETH_GAIN" (if p < 6.0 then 2 else 3)
let freq_shift () = env_int "ETH_FSHIFT" (-1)

let eth_profile ?(octet_crc = true) ~p ~window () =
  let fixed = int_of_float (Float.round (p *. 256.0)) in
  [ 0x58 (* crc on, reflected, width bit 4 *); 0; 15 (* width 32, no skip *)
  ; 0x20; 0x83 (* poly lo *); 0xFF; 0xFF (* init lo *); 0xE3; 0x20 (* residue lo *)
  ; 0xB8; 0xED (* poly hi *); 0xFF; 0xFF (* init hi *); 0xBB; 0xDE (* residue hi *); 0
  ; 1 lor (rx lsl 1) lor (gain_shift p lsl 4) lor 0x80 (* recovery, Manchester *)
  ; fixed land 0xFF; (fixed lsr 8) land 0xFF; (fixed lsr 16) land 0x0F
  ; window; (if freq_shift () < 0 then 0 else 1 lor (freq_shift () lsl 1)) (* learn the period? *)
  ; 0xD5; 1 lor (if octet_crc then 2 else 0) (* hunt for the delimiter; CRC judged at the last whole byte *) ]

let phys =
  Engine.
    [ branch_cond ~pin:rx ~branch_if_high:false ~target:0
    ; pipe_ctrl ~reset:true ~prev_level:false ~crc_init:false
    ; pipe_run ~pin:rx
      (* the lost-byte check comes first: with the FIFO full, PIPE_STATUS
         would wait for room forever *)
    ; branch_flag ~flag:flag_rx_lost ~branch_if_set:false ~target:5
    ; emit_state ~pin:lost_pin ~level:true
    ; pipe_status
    ; wait_edge ~pin:7 ~falling:true ~payload:0 ]

let recorder = Protocol_engine.[ fifo_pop_instr; branch_word ~bit:15 ~branch_if_one:false ~target:0; branch_word ~bit:15 ~branch_if_one:true ~target:0 ]
let deaf = Protocol_engine.[ emit_state ~pin:6 ~level:false; branch_pin ~pin:7 ~branch_if_high:false ~target:1 ]

type result = { bytes : int list; status : int option; lost : bool }

let receive ?(proto = recorder) ?octet_crc ~p ~window line =
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.pins_in := Bits.of_int ~width:8 1;
  cycle ();
  i.rst_n := Bits.vdd;
  List.iteri (fun k v -> i.cfg_addr := Bits.of_int ~width:7 k; i.cfg_data := Bits.of_int ~width:8 v; i.cfg_we := Bits.vdd; cycle ()) (eth_profile ?octet_crc ~p ~window ());
  i.cfg_we := Bits.gnd;
  let load we addr data prog =
    List.iteri (fun k w -> addr := Bits.of_int ~width:9 k; data := Bits.of_int ~width:16 w; we := Bits.vdd; cycle ()) prog;
    we := Bits.gnd
  in
  load i.phys_write_enable i.phys_write_addr i.phys_write_data phys;
  load i.protocol_write_enable i.protocol_write_addr i.protocol_write_data proto;
  i.run := Bits.vdd;
  i.protocol_run := Bits.vdd;
  let words = ref [] and prev = ref 0 in
  List.iter
    (fun v ->
      i.pins_in := Bits.of_int ~width:8 v;
      cycle ();
      let pc = Bits.to_int !(o.protocol_pc) in
      if pc <> !prev && !prev = 0 then words := Bits.to_int !(o.rx_word) :: !words;
      prev := pc)
    (line @ List.init 60 (fun _ -> 1));
  let words = List.rev !words in
  { bytes = List.filter (fun w -> w land 0x8000 = 0) words
  ; status = List.find_opt (fun w -> w land 0x8000 <> 0) words
  ; lost = bit (Bits.to_int !(o.phys_pins_out)) lost_pin = 1 }

let good r expected =
  r.bytes = expected
  (* FCS good, no stuffing error, whole bytes counted; `aligned` is not
     required, as a receiver truncates dribble bits *)
  && match r.status with Some s -> s land 0x3 = 0x1 && (s lsr 8) land 0x7F = List.length expected land 0x7F | None -> false

let random_body len =
  [ 0xFF; 0xFF; 0xFF; 0xFF; 0xFF; 0xFF (* broadcast *); 0x02; 0x00; 0x5E; 0x10; 0x00; 0x01; 0x08; 0x00 ]
  @ List.init len (fun _ -> Random.int 256)

let () =
  Printf.printf "=== 10 Mbit Ethernet receive: Manchester, delimiter hunt, CRC-32 ===\n";
  (* references *)
  let digits = List.init 9 (fun k -> Char.code '1' + k) in
  check "reference CRC-32 of \"123456789\" is the standard 0xCBF43926" (crc32 digits = 0xCBF43926);
  let f = frame (random_body 46) in
  check "register after a frame and its FCS is the residue 0xDEBB20E3"
    (crc32_update 0xFFFFFFFF (List.concat_map bits_lsb f) = 0xDEBB20E3);

  let configs = [ (5.0, 1, "50 MHz (5 clocks a bit)"); (7.0, 2, "70 MHz (7 clocks a bit)") ] in

  (* ETH_BITERR=1: decoder alone, long random streams; where do bit errors
     fall (bit index after lock), to tell acquisition from steady state *)
  if Sys.getenv_opt "ETH_BITERR" <> None then begin
    let module R = Cyclesim.With_interface (Clock_recovery.I) (Clock_recovery.O) in
    List.iter
      (fun (p, j) ->
        let hist = Array.make 8 0 and total = ref 0 in
        for s = 1 to 20 do
          Random.init (s * 7);
          let bytes = preamble 7 @ List.init 120 (fun _ -> Random.int 256) in
          let bits = List.concat_map bits_lsb bytes in
          let line = manchester ~p ~off:0.0 ~j ~seed:s bytes in
          let sim = R.create Clock_recovery.create in
          let i = Cyclesim.inputs sim and o = Cyclesim.outputs ~clock_edge:Before sim in
          i.rst_n := Bits.gnd; Cyclesim.cycle sim; i.rst_n := Bits.vdd;
          i.cfg := Bits.concat_msb (List.rev_map (fun b -> Bits.of_int ~width:8 b) (eth_profile ~p ~window:1 ()));
          i.arm := Bits.vdd; i.pins_in := Bits.of_int ~width:8 1; Cyclesim.cycle sim; i.arm := Bits.gnd;
          let got = ref [] in
          List.iter (fun v -> i.pins_in := Bits.of_int ~width:8 v; Cyclesim.cycle sim;
            if Bits.to_int !(o.bit_valid) = 1 then got := Bits.to_int !(o.bit_value) :: !got) line;
          let got = Array.of_list (List.rev !got) in
          (* align: the decoder starts at the first preamble bit it locked to *)
          let exp = Array.of_list bits in
          let best = ref (0, max_int) in
          for sh = 0 to 6 do
            let e = ref 0 in
            Array.iteri (fun k g -> if k + sh < Array.length exp && exp.(k + sh) <> g then incr e) got;
            if !e < snd !best then best := (sh, !e)
          done;
          let sh = fst !best in
          Array.iteri (fun k g -> if k + sh < Array.length exp && exp.(k + sh) <> g then begin
            incr total; hist.(min 7 (k / 16)) <- hist.(min 7 (k / 16)) + 1 end) got
        done;
        Printf.printf "    P=%.0f jitter %.2f: %d bit errors in 20 streams; by bit index /16: %s\n" p j !total
          (String.concat " " (Array.to_list (Array.map string_of_int hist))))
      (match Sys.getenv_opt "ETH_POINTS" with
       | Some s ->
         String.split_on_char ',' s
         |> List.map (fun pj -> match String.split_on_char ':' pj with [ a; b ] -> (float_of_string a, float_of_string b) | _ -> failwith pj)
       | None -> [ (5.0, 0.5); (5.0, 0.6); (5.0, 0.75); (7.0, 0.75); (7.0, 1.0) ]);
    exit 0
  end;

  (* ETH_SWEEP=1: frames received (of 9: 3 offsets x 3 seeds) at the
     standard's offsets for each (gain shift, freq shift), to choose them *)
  if Sys.getenv_opt "ETH_SWEEP" <> None then begin
    List.iter
      (fun (p, window, name) ->
        let j = if p = 5.0 then 0.6 else 1.0 in
        Printf.printf "    %s, jitter %.1f: gain\\fshift  3  4  5  6  7\n" name j;
        for g = 0 to 4 do
          Printf.printf "                                       %d    " g;
          for fs = 3 to 7 do
            Unix.putenv "ETH_GAIN" (string_of_int g);
            Unix.putenv "ETH_FSHIFT" (string_of_int fs);
            let ok = ref 0 in
            List.iter
              (fun off ->
                for s = 1 to 3 do
                  Random.init (s * 31);
                  let fr = frame (random_body 46) in
                  if good (receive ~p ~window (manchester ~p ~off ~j ~seed:s (preamble 7 @ fr))) fr then incr ok
                done)
              [ -0.0001; 0.0; 0.0001 ];
            Printf.printf "%3d" !ok
          done;
          print_newline ()
        done)
      configs;
    exit 0
  end;

  (* 1. minimum-size and random frames *)
  List.iter
    (fun (p, window, name) ->
      Random.init 99;
      let ok = ref 0 and n = 8 in
      for s = 1 to n do
        let body = random_body (if s = 1 then 46 else 46 + Random.int 60) in
        let fr = frame body in
        let r = receive ~p ~window (manchester ~p ~off:0.0 ~j:0.0 ~seed:s (preamble 7 @ fr)) in
        if good r fr then incr ok
      done;
      check (Printf.sprintf "%s: %d frames (64 to 124 bytes) received exactly, FCS good" name n) (!ok = n))
    configs;

  (* 2. tolerance: offset x jitter *)
  let offs = [ -0.01; -0.001; -0.0001; 0.0; 0.0001; 0.001; 0.01 ] and jits = [ 0.0; 0.25; 0.5; 0.75; 1.0; 1.5 ] in
  let table = Hashtbl.create 64 in
  List.iter
    (fun (p, window, name) ->
      Printf.printf "    %s: frames received of 3 (rows: jitter in cycles, cols: offset)\n" name;
      Printf.printf "      jitter  %s\n" (String.concat " " (List.map (fun o -> Printf.sprintf "%+6.2f%%" (100.0 *. o)) offs));
      List.iter
        (fun j ->
          Printf.printf "      %5.2f   " j;
          List.iter
            (fun off ->
              let ok = ref 0 in
              for s = 1 to 3 do
                Random.init (s * 31);
                let fr = frame (random_body 46) in
                if good (receive ~p ~window (manchester ~p ~off ~j ~seed:s (preamble 7 @ fr))) fr then incr ok
              done;
              Hashtbl.replace table (p, j, off) !ok;
              Printf.printf "   %d/3  " !ok)
            offs;
          print_newline ())
        jits)
    configs;
  ignore table;
  (* the claims, on 10 frames per point at the standard's offsets *)
  let solid ~p ~window j =
    List.for_all
      (fun off ->
        List.for_all
          (fun s ->
            Random.init (s * 131);
            let fr = frame (random_body 46) in
            good (receive ~p ~window (manchester ~p ~off ~j ~seed:(100 + s) (preamble 7 @ fr))) fr)
          (List.init 10 Fun.id))
      [ -0.0001; 0.0; 0.0001 ]
  in
  check "50 MHz, +-0.01%: 30 of 30 frames at 0, 0.25 and 0.5 cycle (10 ns) of jitter"
    (solid ~p:5.0 ~window:1 0.0 && solid ~p:5.0 ~window:1 0.25 && solid ~p:5.0 ~window:1 0.5);
  check "70 MHz, +-0.01%: 30 of 30 frames at 0, 0.5 and 0.75 cycle (10.7 ns) of jitter"
    (solid ~p:7.0 ~window:2 0.0 && solid ~p:7.0 ~window:2 0.5 && solid ~p:7.0 ~window:2 0.75);

  (* 3. late lock *)
  let fr = frame (random_body 50) in
  let r = receive ~p:5.0 ~window:1 (manchester ~p:5.0 ~off:0.0 ~j:0.25 ~seed:4 (preamble 3 @ fr)) in
  check "only 3 preamble bytes before the delimiter: still aligned, received exactly" (good r fr);

  (* 4. corruption and truncation *)
  let fr = frame (random_body 46) in
  let bad = List.mapi (fun k b -> if k = 20 then b lxor 0x10 else b) fr in
  let r = receive ~p:5.0 ~window:1 (manchester ~p:5.0 ~off:0.0 ~j:0.0 ~seed:5 (preamble 7 @ bad)) in
  check "one flipped data bit: FCS check fails" (match r.status with Some s -> s land 1 = 0 | None -> false);
  let cut = List.filteri (fun k _ -> k < 40) fr in
  let r = receive ~p:5.0 ~window:1 (manchester ~p:5.0 ~off:0.0 ~j:0.0 ~seed:5 (preamble 7 @ cut)) in
  check "frame cut after 40 bytes: the run ends, FCS check fails"
    (match r.status with Some s -> s land 1 = 0 && (s lsr 8) land 0x7F = 40 | None -> false);

  (* dribble bits: three extra bits after the FCS *)
  let fr = frame (random_body 46) in
  let line = manchester ~extra:[ 1; 0; 1 ] ~p:5.0 ~off:0.0 ~j:0.0 ~seed:8 (preamble 7 @ fr) in
  let r = receive ~p:5.0 ~window:1 line in
  check "3 dribble bits after the FCS, octet CRC on: frame accepted, `aligned` low"
    (good r fr && match r.status with Some s -> s land 4 = 0 | None -> false);
  let r = receive ~octet_crc:false ~p:5.0 ~window:1 line in
  check "...and with octet CRC off the same frame fails its CRC"
    (match r.status with Some s -> s land 1 = 0 | None -> false);

  (* 5. lost bytes *)
  let fr = frame (random_body 46) in
  let r = receive ~proto:deaf ~p:5.0 ~window:1 (manchester ~p:5.0 ~off:0.0 ~j:0.0 ~seed:6 (preamble 7 @ fr)) in
  check "µE1 not reading: the lost-byte flag is raised" r.lost;
  let r = receive ~p:5.0 ~window:1 (manchester ~p:5.0 ~off:0.0 ~j:0.0 ~seed:6 (preamble 7 @ fr)) in
  check "µE1 reading: no byte lost" (not r.lost);

  if !failures = 0 then print_endline "RESULT: PASS"
  else (Printf.printf "RESULT: FAIL (%d)\n" !failures; exit 1)
