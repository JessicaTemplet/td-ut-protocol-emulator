open Hardcaml
open Tt_core

(* End-to-end proof that the program-load protocol actually makes
   the core reprogrammable: load the SAME UART RX microcode used in
   test_engine.ml, but over loader.ml's real byte-serial pins (no
   direct RAM-port shortcut this time), pulse GO, then check it
   reproduces the identical pulse timing/bits already validated
   there. If this test and test_engine.ml ever disagree, the bug is
   in the load path (loader.ml or its wiring in system.ml), not in
   the engine itself -- that's already covered separately. *)
let uart_rx_prog ~bit_time =
  let half_time = bit_time / 2 in
  Engine.[
    wait_edge ~pin:0 ~falling:true ~payload:0;
    wait_edge ~pin:0 ~falling:true ~payload:half_time;
    shift_in ~pin:0;
  ]
  @ List.concat
      (List.init 8 (fun _ ->
           Engine.[ wait_edge ~pin:0 ~falling:true ~payload:bit_time; shift_in ~pin:0 ]))

module Sim = Cyclesim.With_interface (System.I) (System.O)

let () =
  let prescale = 0 in
  let raw_bit_time = 50 in
  let payload_bit_time = 50 in
  let data = 0b1011_0010 in
  let prog = uart_rx_prog ~bit_time:payload_bit_time in

  let sim = Sim.create System.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in

  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 1;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();

  (* Load prescale, then the program, over the real host-facing pins,
     exactly as a Tiny Tapeout host would: byte-serial,
     strobe/byte_sel/go, no address bus. The very first strobe after
     reset always loads prescale (loader.ml), not a program byte. *)
  let pulse_byte ~byte_sel ~data =
    inputs.byte_sel := Bits.of_int ~width:1 byte_sel;
    inputs.data_in := Bits.of_int ~width:8 data;
    settle ();
    inputs.strobe := Bits.vdd;
    settle ();
    inputs.strobe := Bits.gnd;
    settle ()
  in
  pulse_byte ~byte_sel:0 ~data:prescale;
  List.iter
    (fun w ->
      pulse_byte ~byte_sel:0 ~data:(w land 0xFF);
      pulse_byte ~byte_sel:1 ~data:((w lsr 8) land 0xFF))
    prog;

  let expected_checksum =
    List.fold_left (fun acc w -> acc lxor (w land 0xFF) lxor ((w lsr 8) land 0xFF)) 0 prog
  in
  let checksum = Bits.to_int !(outputs.checksum) in
  Printf.printf "Load checksum: 0x%02x (expected 0x%02x)\n" checksum expected_checksum;
  let checksum_ok = checksum = expected_checksum in

  let run_before = Bits.to_int !(outputs.run) in
  Printf.printf "Run before GO: %d (expected 0)\n" run_before;

  inputs.go := Bits.vdd;
  settle ();
  inputs.go := Bits.gnd;
  settle ();
  let run_after = Bits.to_int !(outputs.run) in
  Printf.printf "Run after GO: %d (expected 1)\n" run_after;

  (* Same UART RX stimulus/checks as test_engine.ml. *)
  let bits = (0 :: List.init 8 (fun i -> (data lsr i) land 1)) @ [ 1 ] in
  let cycle_count = ref 0 in
  let pulses = ref [] in
  let sampled_bits = ref [] in
  List.iter
    (fun b ->
      for _ = 1 to raw_bit_time do
        inputs.pins_in := Bits.of_int ~width:8 b;
        cycle ();
        incr cycle_count;
        if Bits.to_int !(outputs.sample_pulse) = 1 then begin
          pulses := !cycle_count :: !pulses;
          sampled_bits := Bits.to_int !(outputs.sampled_bit) :: !sampled_bits
        end
      done)
    bits;
  let pulses = List.rev !pulses in
  let sampled_bits = List.rev !sampled_bits in
  Printf.printf "Sample pulses at cycles: [%s]\n"
    (String.concat "; " (List.map string_of_int pulses));
  Printf.printf "Sampled bits: [%s]\n"
    (String.concat "; " (List.map string_of_int sampled_bits));

  let expected_bits = List.filteri (fun i _ -> i < 9) bits in
  let bits_match = sampled_bits = expected_bits in
  let count_ok = List.length pulses = 9 in
  let spacings =
    let rec diffs = function
      | a :: (b :: _ as rest) -> (b - a) :: diffs rest
      | _ -> []
    in
    diffs pulses
  in
  let spacing_ok =
    match spacings with
    | [] -> false
    | d0 :: _ -> List.for_all (fun d -> d = d0) spacings
  in

  let passed = checksum_ok && run_before = 0 && run_after = 1 && bits_match && count_ok && spacing_ok in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
