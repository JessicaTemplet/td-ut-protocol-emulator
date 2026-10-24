open Hardcaml
open Tt_core

(* The Cyclesim twin of gl_test/test.py's usb_receive_with_clock_recovery:
   it replays the COMMITTED gl_test/usb_rec_vectors.json (program words,
   profile bytes and the per-cycle D-/D+ line of a 1.5%-fast, jittery
   sender) through tt_um_dual's real pins, exactly as cocotb drives the
   shipped Verilog. Reading the file rather than regenerating the line
   means both simulators see byte-identical input, so a disagreement
   between them points at the RTL path, not at the stimulus. *)

module Sim = Cyclesim.With_interface (I) (O)

(* the int list after "key": in the vectors file (the file is ours and
   flat, so a full JSON parser is not needed) *)
let int_list json key =
  let pat = Printf.sprintf "\"%s\": [" key in
  let plen = String.length pat in
  let rec find i =
    if i + plen > String.length json then failwith ("missing key " ^ key)
    else if String.sub json i plen = pat then i + plen
    else find (i + 1)
  in
  let start = find 0 in
  let stop = String.index_from json start ']' in
  String.sub json start (stop - start)
  |> String.split_on_char ','
  |> List.filter_map (fun s -> match String.trim s with "" -> None | t -> Some (int_of_string t))

let pin json key =
  let pat = Printf.sprintf "\"%s\": " key in
  let plen = String.length pat in
  let rec find i = if String.sub json i plen = pat then i + plen else find (i + 1) in
  let i = find 0 in
  int_of_string (String.trim (String.sub json i 1))

let lo x = x land 0xFF
let hi x = (x lsr 8) land 0xFF
let bit x k = (x lsr k) land 1

let uio ~cfg_sel ~engine_sel ~go ~byte_sel ~strobe =
  (cfg_sel lsl 4) lor (engine_sel lsl 3) lor (go lsl 2) lor (byte_sel lsl 1) lor strobe

let run json line =
  let cfg = int_list json "cfg" and phys = int_list json "phys" and proto = int_list json "protocol" in
  let dm = pin json "dm" and dp = pin json "dp" in
  let flag_ok = pin json "flag_ok" and flag_done = pin json "flag_done" in
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
  List.iter (fun data -> pulse ~cfg_sel:1 ~engine_sel:0 ~byte_sel:0 ~data) cfg;
  List.iter (fun w -> pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:0 ~data:(lo w); pulse ~cfg_sel:0 ~engine_sel:0 ~byte_sel:1 ~data:(hi w)) phys;
  List.iter (fun w -> pulse ~cfg_sel:0 ~engine_sel:1 ~byte_sel:0 ~data:(lo w); pulse ~cfg_sel:0 ~engine_sel:1 ~byte_sel:1 ~data:(hi w)) proto;
  set ~cfg_sel:0 ~engine_sel:0 ~go:1 ~byte_sel:0 ~strobe:0;
  settle ();
  set ~cfg_sel:0 ~engine_sel:0 ~go:0 ~byte_sel:0 ~strobe:0;
  settle ();
  List.iter
    (fun s ->
      let dmv = if s = 1 then 1 else 0 and dpv = if s = 0 then 1 else 0 in
      inputs.uio_in := Bits.of_int ~width:8 ((dmv lsl dm) lor (dpv lsl dp));
      cycle ())
    line;
  let out = Bits.to_int !(outputs.uio_out) and oe = Bits.to_int !(outputs.uio_oe) in
  let flag_degraded = pin json "flag_degraded" in
  ( bit oe flag_ok = 1 && bit out flag_ok = 1
  , bit oe flag_done = 1 && bit out flag_done = 1
  , bit oe flag_degraded = 1 && bit out flag_degraded = 1 )

let () =
  Printf.printf "=== USB RX with clock recovery through tt_um_dual's REAL pins (the committed vector) ===\n";
  let json = In_channel.with_open_text "gl_test/usb_rec_vectors.json" In_channel.input_all in
  let ok, dn, dg = run json (int_list json "good_line") in
  Printf.printf "  1.5%%-fast jittery sender: flag_ok=%b flag_done=%b degraded=%b (expected true,true,false)\n" ok dn dg;
  let ok2, dn2, _ = run json (int_list json "bad_line") in
  Printf.printf "  corrupted packet: flag_ok=%b flag_done=%b (expected false,true)\n" ok2 dn2;
  let ok3, dn3, dg3 = run json (int_list json "jittery_line") in
  Printf.printf "  +-7 cycles of jitter: flag_ok=%b flag_done=%b degraded=%b (expected true,true,true)\n" ok3 dn3 dg3;
  let passed = ok && dn && (not dg) && (not ok2) && dn2 && ok3 && dn3 && dg3 in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
