open Hardcaml
open Tt_core

(* Standalone proof of dual_loader.ml's own semantics, same isolation
   discipline test_loader.ml already established for loader.ml:
   engine_sel correctly routes a committed word to one engine's write
   port/address counter and NOT the other's, the two address counters
   advance independently (interleaving phys/protocol words doesn't
   perturb either counter), the shared checksum covers both engines'
   words, and run/write-lockout behave exactly like loader.ml's. *)

module Sim = Cyclesim.With_interface (Dual_loader.I) (Dual_loader.O)

let () =
  let sim = Sim.create Dual_loader.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in
  let settle () = for _ = 1 to 3 do cycle () done in

  inputs.rst_n := Bits.gnd;
  for _ = 1 to 4 do cycle () done;
  inputs.rst_n := Bits.vdd;
  cycle ();

  let pulse_byte ~engine_sel ~byte_sel ~data =
    inputs.engine_sel := Bits.of_int ~width:1 engine_sel;
    inputs.byte_sel := Bits.of_int ~width:1 byte_sel;
    inputs.data_in := Bits.of_int ~width:8 data;
    settle ();
    inputs.strobe := Bits.vdd;
    let sample = ref None in
    for _ = 1 to 4 do
      cycle ();
      let phys_we = Bits.to_int !(outputs.phys_write_enable) = 1 in
      let protocol_we = Bits.to_int !(outputs.protocol_write_enable) = 1 in
      if (phys_we || protocol_we) && !sample = None then
        sample :=
          Some
            ( phys_we
            , (if phys_we then Bits.to_int !(outputs.phys_write_addr)
               else Bits.to_int !(outputs.protocol_write_addr))
            , Bits.to_int !(outputs.write_data) )
    done;
    inputs.strobe := Bits.gnd;
    settle ();
    !sample
  in

  let pulse_prescale ~value =
    inputs.engine_sel := Bits.of_int ~width:1 0;
    inputs.byte_sel := Bits.of_int ~width:1 0;
    inputs.data_in := Bits.of_int ~width:8 value;
    settle ();
    inputs.strobe := Bits.vdd;
    settle ();
    inputs.strobe := Bits.gnd;
    settle ()
  in
  pulse_prescale ~value:0x2B;
  let prescale_got = Bits.to_int !(outputs.prescale) in
  Printf.printf "Prescale loaded: 0x%02x (expected 0x2b)\n" prescale_got;
  let prescale_ok = prescale_got = 0x2B in

  (* Interleaved: phys word 0, phys word 1, protocol word 0, phys word
     2 -- proves the two address counters are genuinely independent,
     not a shared counter with an engine tag. *)
  let commit ~engine_sel ~lo ~hi =
    ignore (pulse_byte ~engine_sel ~byte_sel:0 ~data:lo);
    pulse_byte ~engine_sel ~byte_sel:1 ~data:hi
  in
  let phys0 = commit ~engine_sel:0 ~lo:0x11 ~hi:0x11 in
  let phys1 = commit ~engine_sel:0 ~lo:0x22 ~hi:0x22 in
  let protocol0 = commit ~engine_sel:1 ~lo:0x33 ~hi:0x33 in
  let phys2 = commit ~engine_sel:0 ~lo:0x44 ~hi:0x44 in
  let protocol1 = commit ~engine_sel:1 ~lo:0x55 ~hi:0x55 in

  let check name got ~expect_phys ~expect_addr ~expect_data =
    match got with
    | Some (is_phys, addr, data) ->
      let ok = is_phys = expect_phys && addr = expect_addr && data = expect_data in
      Printf.printf "  %s: is_phys=%b addr=%d data=0x%04x (expected is_phys=%b addr=%d data=0x%04x) %s\n"
        name is_phys addr data expect_phys expect_addr expect_data (if ok then "ok" else "BUG");
      ok
    | None ->
      Printf.printf "  %s: MISSED COMMIT\n" name;
      false
  in
  let ok0 = check "phys word 0" phys0 ~expect_phys:true ~expect_addr:0 ~expect_data:0x1111 in
  let ok1 = check "phys word 1" phys1 ~expect_phys:true ~expect_addr:1 ~expect_data:0x2222 in
  let ok2 = check "protocol word 0" protocol0 ~expect_phys:false ~expect_addr:0 ~expect_data:0x3333 in
  let ok3 = check "phys word 2 (after interleaved protocol write)" phys2 ~expect_phys:true ~expect_addr:2
      ~expect_data:0x4444 in
  let ok4 = check "protocol word 1" protocol1 ~expect_phys:false ~expect_addr:1 ~expect_data:0x5555 in
  let routing_ok = ok0 && ok1 && ok2 && ok3 && ok4 in

  let checksum = Bits.to_int !(outputs.checksum) in
  let expected_checksum =
    List.fold_left (fun acc b -> acc lxor b lxor b) 0 [ 0x11; 0x22; 0x33; 0x44; 0x55 ]
  in
  Printf.printf "Combined checksum: 0x%02x (expected 0x%02x)\n" checksum expected_checksum;
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

  let post_run = pulse_byte ~engine_sel:0 ~byte_sel:1 ~data:0xEE in
  let checksum_after_lock = Bits.to_int !(outputs.checksum) in
  let locked_ok = post_run = None && checksum_after_lock = checksum in
  Printf.printf "Writes locked out after Run: %s\n" (if locked_ok then "yes" else "NO -- BUG");

  let passed =
    prescale_ok && routing_ok && checksum_ok && run_before_ok && run_after_ok && locked_ok
  in
  Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
  if not passed then exit 1
