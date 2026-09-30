open Hardcaml
open Tt_core

module Sim = Cyclesim.With_interface (Loader.I) (Loader.O)

let () =
  let sim = Sim.create Loader.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in

  (* strobe/go are edge-triggered through a 2-FF synchronizer: hold
     each level for a few cycles so the rising edge is unambiguous,
     mirroring how a real host would drive slow, unsynchronized
     control pins. *)
  let settle () = for _ = 1 to 3 do cycle () done in

  inputs.rst_n := Bits.gnd;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();

  (* Drives one strobe pulse for one byte and, if this was the
     high-byte half of a word, samples the commit outputs on the
     exact cycle write_enable is high (the cycle strobe_edge lands,
     ~2 cycles into the sync chain after strobe goes high). *)
  let pulse_byte ~byte_sel ~data =
    inputs.byte_sel := Bits.of_int ~width:1 byte_sel;
    inputs.data_in := Bits.of_int ~width:8 data;
    settle ();
    inputs.strobe := Bits.vdd;
    let sample = ref None in
    for _ = 1 to 4 do
      cycle ();
      if Bits.to_int !(outputs.write_enable) = 1 && !sample = None then
        sample := Some (Bits.to_int !(outputs.write_addr), Bits.to_int !(outputs.write_data))
    done;
    inputs.strobe := Bits.gnd;
    settle ();
    !sample
  in

  (* The very first strobe after reset always loads prescale, not a
     program byte -- byte_sel is don't-care for it. *)
  let pulse_prescale ~value =
    inputs.byte_sel := Bits.of_int ~width:1 0;
    inputs.data_in := Bits.of_int ~width:8 value;
    settle ();
    inputs.strobe := Bits.vdd;
    settle ();
    inputs.strobe := Bits.gnd;
    settle ()
  in
  let prescale_value = 0x1A in
  pulse_prescale ~value:prescale_value;
  let prescale_got = Bits.to_int !(outputs.prescale) in
  Printf.printf "Prescale loaded: 0x%02x (expected 0x%02x)\n" prescale_got prescale_value;
  let prescale_ok = prescale_got = prescale_value in
  let addr_after_prescale = Bits.to_int !(outputs.write_addr) in
  Printf.printf "write_addr after prescale byte: %d (expected 0, prescale must not commit a word)\n"
    addr_after_prescale;
  let prescale_no_commit_ok = addr_after_prescale = 0 in

  (* Program: 3 made-up 16-bit words, written low-byte-then-high-byte. *)
  let words = [ (0x34, 0x12); (0xCD, 0xAB); (0x00, 0xFF) ] in

  let committed =
    List.map
      (fun (lo, hi) ->
        ignore (pulse_byte ~byte_sel:0 ~data:lo);
        pulse_byte ~byte_sel:1 ~data:hi)
      words
  in

  let expected_words = List.map (fun (lo, hi) -> (hi lsl 8) lor lo) words in
  let expected_addrs = List.mapi (fun i _ -> i) words in
  let got_words = List.map (function Some (_, d) -> d | None -> -1) committed in
  let got_addrs = List.map (function Some (a, _) -> a | None -> -1) committed in

  Printf.printf "Committed: %s\n"
    (String.concat "; "
       (List.map
          (function
            | Some (a, d) -> Printf.sprintf "addr=%d data=0x%04x" a d
            | None -> "MISSED")
          committed));

  let count_ok = List.for_all (fun c -> c <> None) committed in
  let words_ok = got_words = expected_words in
  let addrs_ok = got_addrs = expected_addrs in

  let checksum = Bits.to_int !(outputs.checksum) in
  let expected_checksum = List.fold_left (fun acc (lo, hi) -> acc lxor lo lxor hi) 0 words in
  Printf.printf "Checksum: 0x%02x (expected 0x%02x)\n" checksum expected_checksum;
  let checksum_ok = checksum = expected_checksum in

  let run_before = Bits.to_int !(outputs.run) in
  Printf.printf "Run before GO: %d (expected 0)\n" run_before;
  let run_before_ok = run_before = 0 in

  inputs.go := Bits.vdd;
  settle ();
  inputs.go := Bits.gnd;
  settle ();
  let run_after = Bits.to_int !(outputs.run) in
  Printf.printf "Run after GO: %d (expected 1)\n" run_after;
  let run_after_ok = run_after = 1 in

  (* Further strobes after Run must be ignored (no more commits, no
     address/checksum movement). *)
  let addr_before_lock = Bits.to_int !(outputs.write_addr) in
  ignore (pulse_byte ~byte_sel:0 ~data:0xFF);
  let post_run = pulse_byte ~byte_sel:1 ~data:0xEE in
  let checksum_after_lock = Bits.to_int !(outputs.checksum) in
  let locked_ok = post_run = None && checksum_after_lock = checksum in
  ignore addr_before_lock;
  Printf.printf "Writes locked out after Run: %s\n" (if locked_ok then "yes" else "NO -- BUG");

  let passed =
    prescale_ok && prescale_no_commit_ok && count_ok && words_ok && addrs_ok && checksum_ok
    && run_before_ok && run_after_ok && locked_ok
  in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
