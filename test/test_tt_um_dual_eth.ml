open Hardcaml
open Tt_core

(* The Cyclesim twin of gl_test/test.py's ethernet_receive: it replays the
   COMMITTED gl_test/eth_vectors.json (program words, the Ethernet profile,
   and the per-cycle line of a 64-byte frame with +-0.25 cycle of jitter at
   5 clocks a bit, plus a copy with one data bit flipped) through
   tt_um_dual's real pins, as cocotb drives the shipped Verilog. *)

module Sim = Cyclesim.With_interface (I) (O)

(* the int list after "key": in the vectors file (flat, ours) *)
let int_list json key =
  let pat = Printf.sprintf "\"%s\": [" key in
  let plen = String.length pat in
  let rec find i = if String.sub json i plen = pat then i + plen else find (i + 1) in
  let start = find 0 in
  let stop = String.index_from json start ']' in
  String.sub json start (stop - start)
  |> String.split_on_char ','
  |> List.filter_map (fun s -> match String.trim s with "" -> None | t -> Some (int_of_string t))

let pin json key =
  let pat = Printf.sprintf "\"%s\": " key in
  let plen = String.length pat in
  let rec find i = if String.sub json i plen = pat then i + plen else find (i + 1) in
  int_of_string (String.trim (String.sub json (find 0) 1))

let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF
let bit x k = (x lsr k) land 1

let uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
  (cfg_sel lsl 4) lor (engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe

let run json line =
  let rx = pin json "rx" in
  let sim = Sim.create tt_um_dual in
  let inputs = Cyclesim.inputs sim and outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in
  let set ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
    inputs.uio_in := Bits.of_int ~width:8 (uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe)
  in
  inputs.ena := Bits.vdd;
  inputs.rst_n := Bits.gnd;
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
  pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:0 ~data:0;
  List.iter (fun data -> pulse ~cfg_sel:1 ~engine_sel:0 ~byte_sel:0 ~data) (int_list json "cfg");
  List.iter (fun w -> pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:0 ~data:(lo w); pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:1 ~data:(hi w)) (int_list json "phys");
  List.iter (fun w -> pulse ~cfg_sel:0 ~engine_sel:1 ~byte_sel:0 ~data:(lo w); pulse ~cfg_sel:0 ~engine_sel:1 ~byte_sel:1 ~data:(hi w)) (int_list json "protocol");
  set ~cfg_sel:0 ~engine_sel:0 ~go:1 ~byte_sel:0 ~strobe:0;
  settle ();
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  settle ();
  List.iter (fun s -> inputs.uio_in := Bits.of_int ~width:8 (s lsl rx); cycle ()) line;
  let out = Bits.to_int !(outputs.uio_out) and oe = Bits.to_int !(outputs.uio_oe) in
  let flag k = bit oe (pin json k) = 1 && bit out (pin json k) = 1 in
  (flag "flag_ok", flag "flag_done", flag "flag_lost")

let () =
  Printf.printf "=== 10 Mbit Ethernet RX through tt_um_dual's REAL pins (the committed vector) ===\n";
  let json = In_channel.with_open_text "gl_test/eth_vectors.json" In_channel.input_all in
  let ok, dn, lost = run json (int_list json "good_line") in
  Printf.printf "  64-byte frame, +-0.25 cycle jitter: ok=%b done=%b lost=%b (expected true,true,false)\n" ok dn lost;
  let ok2, dn2, _ = run json (int_list json "bad_line") in
  Printf.printf "  one data bit flipped: ok=%b done=%b (expected false,true)\n" ok2 dn2;
  let passed = ok && dn && (not lost) && (not ok2) && dn2 in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
