open Hardcaml
open Tt_core.Timer

module Sim = Cyclesim.With_interface (I) (O)

(* Drives `repeats` back-to-back loads (each issued the cycle right
   after the previous one expires) and checks the spacing between
   consecutive `expired` pulses is exactly payload*(prescale+1) with
   zero drift. Also prints the raw offset of the first expiry for
   inspection rather than assuming its exact value up front. *)
let run ~name ~prescale ~payload ~repeats =
  Printf.printf "=== %s ===\n" name;
  Printf.printf "prescale=%d payload=%d (=> effective wait = %d cycles)\n"
    prescale payload (payload * (prescale + 1));
  let sim = Sim.create create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in

  inputs.rst_n := Bits.gnd;
  inputs.load := Bits.gnd;
  inputs.prescale := Bits.of_int ~width:8 prescale;
  inputs.payload := Bits.of_int ~width:10 payload;
  for _ = 1 to 4 do
    cycle ()
  done;
  inputs.rst_n := Bits.vdd;
  cycle ();

  let cycle_count = ref 0 in
  let expire_cycles = ref [] in

  for _ = 1 to repeats do
    inputs.load := Bits.vdd;
    cycle ();
    incr cycle_count;
    inputs.load := Bits.gnd;
    let expired = ref false in
    let guard = ref 0 in
    while (not !expired) && !guard < 200_000 do
      cycle ();
      incr cycle_count;
      incr guard;
      if Bits.to_int !(outputs.expired) = 1 then expired := true
    done;
    if not !expired then Printf.printf "  !! TIMED OUT waiting for expire !!\n";
    expire_cycles := !cycle_count :: !expire_cycles
  done;

  let expire_cycles = List.rev !expire_cycles in
  Printf.printf "Expire at cycles: [%s]\n"
    (String.concat "; " (List.map string_of_int expire_cycles));
  (match expire_cycles with
   | first :: _ -> Printf.printf "First expiry offset from first load: %d cycles\n" first
   | [] -> ());
  let spacings =
    let rec diffs = function
      | a :: (b :: _ as rest) -> (b - a) :: diffs rest
      | _ -> []
    in
    diffs expire_cycles
  in
  let expected_period = payload * (prescale + 1) in
  Printf.printf "Spacing between expiries: [%s] (expected all = %d)\n"
    (String.concat "; " (List.map string_of_int spacings))
    expected_period;
  let spacing_ok = spacings <> [] && List.for_all (fun d -> d = expected_period) spacings in
  Printf.printf "RESULT: %s\n\n" (if spacing_ok then "PASS" else "FAIL");
  spacing_ok

let () =
  let r1 =
    run
      ~name:"Sanity: prescale=0 (passthrough) -- should match raw-cycle behaviour"
      ~prescale:0 ~payload:50 ~repeats:9
  in
  let r2 =
    run
      ~name:
        "9600 baud @ 50 MHz via prescaler -- needs 5208 raw cycles, \
         previously impossible in a 10-bit field"
      ~prescale:5 ~payload:868 ~repeats:9
  in
  let r3 =
    run ~name:"Back-to-back drift check, odd prescale/payload"
      ~prescale:3 ~payload:37 ~repeats:12
  in
  let all_pass = r1 && r2 && r3 in
  Printf.printf "==================\nTimer suite: %s\n"
    (if all_pass then "ALL PASS" else "FAILURES PRESENT");
  if not all_pass then exit 1
