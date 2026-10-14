open Hardcaml
open Tt_core

(* Standalone proof of glitch_filter.ml.
   - n=0 is an exact combinational bypass (every existing program).
   - With n=3: a pulse shorter than 3 clocks never appears; a pulse of
     3 or more passes, delayed; a real level passes after exactly n
     clocks; a glitch interrupting an accepted change restarts the count.
   - While run=0 the filter follows the raw pin (no startup false edge). *)

module Sim = Cyclesim.With_interface (Glitch_filter.I) (Glitch_filter.O)

let failures = ref 0
let check name ok =
  Printf.printf "  %-70s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

let new_sim ~n ~run =
  let sim = Sim.create Glitch_filter.create in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  i.rst_n := Bits.gnd;
  i.run := Bits.gnd;
  i.pins_in := Bits.of_int ~width:8 0;
  i.n := Bits.of_int ~width:4 n;
  cycle (); cycle ();
  i.rst_n := Bits.vdd;
  cycle ();
  if run then i.run := Bits.vdd;
  (i, o, cycle)

(* drive pin 0 through [levels] (one per clock), return filtered pin 0 after each clock *)
let trace ~n levels =
  let i, o, cycle = new_sim ~n ~run:true in
  List.map
    (fun l ->
      i.pins_in := Bits.of_int ~width:8 l;
      cycle ();
      Bits.to_int !(o.pins_out) land 1)
    levels

let () =
  Printf.printf "=== glitch_filter ===\n";
  (* bypass: combinational, identical to raw with no latency (read the
     outputs as they are BEFORE the clock edge, for the current inputs) *)
  let same = ref true in
  let sim = Sim.create Glitch_filter.create in
  let si = Cyclesim.inputs sim and so = Cyclesim.outputs ~clock_edge:Before sim in
  si.rst_n := Bits.vdd; si.run := Bits.vdd; si.n := Bits.of_int ~width:4 0;
  List.iter
    (fun v ->
      si.pins_in := Bits.of_int ~width:8 v;
      Cyclesim.cycle sim;
      if Bits.to_int !(so.pins_out) <> v then same := false)
    [ 0x00; 0xFF; 0xA5; 0x5A; 0x01; 0x80; 0x00 ];
  check "n=0: output equals input in the same cycle (pure bypass)" !same;

  let t = trace ~n:3 [ 0; 0; 0; 1; 0; 0; 0; 0 ] in
  check "n=3: a 1-clock pulse is invisible" (List.for_all (( = ) 0) t);
  let t = trace ~n:3 [ 0; 0; 1; 1; 0; 0; 0; 0 ] in
  check "n=3: a 2-clock pulse is invisible" (List.for_all (( = ) 0) t);
  let t = trace ~n:3 [ 0; 0; 1; 1; 1; 0; 0; 0; 0; 0 ] in
  check "n=3: a 3-clock pulse passes (delayed)" (List.exists (( = ) 1) t);
  let t = trace ~n:3 (List.init 4 (fun _ -> 0) @ List.init 8 (fun _ -> 1)) in
  (* the raw pin first reads 1 at clock 4; the filtered level flips on the
     clock edge that takes in the 3rd consecutive 1 (clock 6), so it reads 1
     from clock index 6 *)
  let first_one = List.length (List.filter (( = ) 0) t) in
  check "n=3: a real change is accepted on the 3rd consecutive sample" (first_one = 4 + 2);
  (* 1 1 0 1 1 1: the 0 restarts the count, so the 3rd consecutive 1 is at clock 9 *)
  let t = trace ~n:3 (List.init 4 (fun _ -> 0) @ [ 1; 1; 0; 1; 1; 1; 1; 1; 1 ]) in
  let first_one = List.length (List.filter (( = ) 0) t) in
  check "n=3: a glitch mid-change restarts the count" (first_one = 4 + 2 + 1 + 2);
  (* before run the filter follows the raw pin, so starting with pin high is not an edge *)
  let sim = Sim.create Glitch_filter.create in
  let si = Cyclesim.inputs sim and so = Cyclesim.outputs sim in
  si.rst_n := Bits.gnd; si.run := Bits.gnd; si.n := Bits.of_int ~width:4 3;
  si.pins_in := Bits.of_int ~width:8 0xFF;
  Cyclesim.cycle sim; Cyclesim.cycle sim;
  si.rst_n := Bits.vdd;
  Cyclesim.cycle sim; Cyclesim.cycle sim;
  check "run=0: follows the raw pin (no false edge at start)" (Bits.to_int !(so.pins_out) = 0xFF);
  si.run := Bits.vdd;
  Cyclesim.cycle sim; Cyclesim.cycle sim;
  check "and stays put once running" (Bits.to_int !(so.pins_out) = 0xFF);
  Printf.printf "RESULT: %s\n" (if !failures = 0 then "PASS" else "FAIL");
  if !failures > 0 then exit 1
