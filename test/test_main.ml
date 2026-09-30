open Hardcaml
open Tt_core

module Sim = Cyclesim.With_interface (I) (O)

let run ~name ~bit_time ~data =
  Printf.printf "=== %s (bit_time=%d cycles) ===\n" name bit_time;
  let sim = Sim.create tt_um_logic in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in

  let cycle () = Cyclesim.cycle sim in
  let set_ui_in b = inputs.ui_in := Bits.of_int ~width:8 b in

  (* Reset, RX idle high *)
  inputs.rst_n := Bits.gnd;
  set_ui_in 1;
  inputs.uio_in := Bits.of_int ~width:8 bit_time;
  for _ = 1 to 4 do
    cycle ()
  done;
  inputs.rst_n := Bits.vdd;
  cycle ();

  (* 8N1 frame: start(0), 8 data bits LSB-first, stop(1) *)
  let bits = (0 :: List.init 8 (fun i -> (data lsr i) land 1)) @ [ 1 ] in

  let cycle_count = ref 0 in
  let pulses = ref [] in
  let sampled_bits = ref [] in

  List.iter
    (fun b ->
      for _ = 1 to bit_time do
        set_ui_in b;
        cycle ();
        incr cycle_count;
        let uo = Bits.to_int !(outputs.uo_out) in
        if uo land 1 = 1 then begin
          pulses := !cycle_count :: !pulses;
          sampled_bits := b :: !sampled_bits
        end
      done)
    bits;

  let pulses = List.rev !pulses in
  let sampled_bits = List.rev !sampled_bits in

  Printf.printf "Frame bits sent : [%s]\n"
    (String.concat "; " (List.map string_of_int bits));
  Printf.printf "Sample pulses at cycles: [%s]\n"
    (String.concat "; " (List.map string_of_int pulses));
  (match pulses with
   | [] -> Printf.printf "First pulse offset: NONE FIRED\n"
   | first :: _ ->
     Printf.printf "First pulse offset from frame start: %d cycles (expected ~%d = 0.5 * bit_time, mid of start bit)\n"
       first (bit_time / 2));
  let spacings =
    let rec diffs = function
      | a :: (b :: _ as rest) -> (b - a) :: diffs rest
      | _ -> []
    in
    diffs pulses
  in
  Printf.printf "Pulse spacing: [%s] (expected all = %d)\n"
    (String.concat "; " (List.map string_of_int spacings))
    bit_time;
  (* Design only samples start(1) + 8 data bits (9 total); the stop
     bit is framing-only and is never sampled by construction. *)
  Printf.printf "Pulse count: %d (expected 9 = start + 8 data bits)\n" (List.length pulses);
  Printf.printf "Bits captured at pulses: [%s]\n"
    (String.concat "; " (List.map string_of_int sampled_bits));
  let expected_bits = List.filteri (fun i _ -> i < 9) bits in
  let bits_match = sampled_bits = expected_bits in
  let count_ok = List.length pulses = 9 in
  let spacing_ok = List.for_all (fun d -> d = bit_time) spacings in
  let passed = bits_match && count_ok && spacing_ok in
  Printf.printf "Captured bits match transmitted start+data bits: %b\n" bits_match;
  Printf.printf "RESULT: %s\n\n" (if passed then "PASS" else "FAIL");
  passed

let () =
  let results =
    [ run ~name:"Primary: 1 Mbit/s @ 50 MHz" ~bit_time:50 ~data:0b1011_0010
    ; run
        ~name:
          "Secondary: 9600 baud (test clock scaled to 2 MHz -- 8-bit \
           uio_in can't hold bit_time=5208 needed at real 50 MHz)"
        ~bit_time:208 ~data:0b0110_1101
    ; run
        ~name:
          "Secondary: 115200 baud (test clock scaled to 2 MHz -- 8-bit \
           uio_in can't hold bit_time=434 needed at real 50 MHz)"
        ~bit_time:17 ~data:0b1100_0101
    ]
  in
  let all_pass = List.for_all Fun.id results in
  Printf.printf "==================\nSuite: %d/%d passed\n"
    (List.length (List.filter Fun.id results))
    (List.length results);
  if not all_pass then exit 1
