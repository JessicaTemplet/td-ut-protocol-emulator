open Hardcaml
open Tt_core

(* End-to-end proof that CAPTURE records flow through the REAL shared
   shadow_fifo into µE1, coexisting correctly with ordinary byte-relay
   pushes -- the actual "reuse the existing FIFO/backpressure path for
   a timestamped capture mode" claim from this session, now proven at
   the same Dual level test_dual.ml already proves byte-relay at.
   test_capture.ml proves Engine's own half of CAPTURE in isolation
   (record shape, elapsed timing, backpressure); this test proves
   dual.ml's push/push_data mux between `byte_ready`/`capture_ready`
   picks the right source, in the right order, through the real FIFO --
   not just that each source works alone. *)

let bits_of_byte n = List.init 8 (fun i -> (n lsr (7 - i)) land 1)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let decode_capture data =
  let pin_sel = (data lsr 13) land 0x7 in
  let level = (data lsr 12) land 0x1 in
  let elapsed = data land 0xFFF in
  (pin_sel, level, elapsed)

(* Two captures (back-to-back, so both read elapsed=0 -- proven exact
   timing already covered by test_capture.ml, no need to re-derive
   here) on different pins, THEN a normal byte-relay push of 0xA5 --
   deliberately mixing both push sources so ordering through the one
   shared FIFO port is actually exercised, not just one source at a
   time. *)
let byte_value = 0xA5

let phys_prog =
  Engine.(
    [ capture ~pin:2; capture ~pin:4 ]
    @ List.map (fun _ -> shift_in ~pin:0) [ (); (); (); (); (); (); () ]
    @ [ shift_in_push ~pin:0 ])

let protocol_prog = List.init 3 (fun _ -> Protocol_engine.fifo_pop_instr)

let () =
  let sim = Sim.create Dual.create in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let cycle () = Cyclesim.cycle sim in

  inputs.rst_n := Bits.gnd;
  inputs.pins_in := Bits.of_int ~width:8 0;
  inputs.prescale := Bits.of_int ~width:8 0;
  inputs.run := Bits.gnd;
  inputs.protocol_run := Bits.gnd;
  for _ = 1 to 4 do
    cycle ()
  done;
  inputs.rst_n := Bits.vdd;
  cycle ();

  List.iteri
    (fun i w ->
      inputs.phys_write_addr := Bits.of_int ~width:9 i;
      inputs.phys_write_data := Bits.of_int ~width:16 w;
      inputs.phys_write_enable := Bits.vdd;
      cycle ())
    phys_prog;
  inputs.phys_write_enable := Bits.gnd;

  List.iteri
    (fun i w ->
      inputs.protocol_write_addr := Bits.of_int ~width:9 i;
      inputs.protocol_write_data := Bits.of_int ~width:16 w;
      inputs.protocol_write_enable := Bits.vdd;
      cycle ())
    protocol_prog;
  inputs.protocol_write_enable := Bits.gnd;

  (* Both engines run together -- FIFO_POP already stalls on empty, so
     there's no need to stagger start like test_dual.ml's deliberate
     backpressure scenario; that mechanism is proven separately. *)
  inputs.run := Bits.vdd;
  inputs.protocol_run := Bits.vdd;

  (* pin2=1, pin4=0 held constant for the two CAPTURE cycles; pin0
     toggles through byte_value's bits for the shift_in/shift_in_push
     cycles that follow. Bits 2 and 4 stay fixed throughout so the two
     concerns (capture level, byte assembly) can't interfere. *)
  let capture_level_bits = 0b00000100 (* pin2=1, pin4=0 *) in
  let byte_bits = bits_of_byte byte_value in
  let drive_cycles =
    [ capture_level_bits; capture_level_bits ]
    @ List.map (fun b -> capture_level_bits lor b) byte_bits
  in

  let popped = ref [] in
  let last_protocol_pc = ref (Bits.to_int !(outputs.protocol_pc)) in
  List.iter
    (fun pins ->
      inputs.pins_in := Bits.of_int ~width:8 pins;
      cycle ();
      let pc_now = Bits.to_int !(outputs.protocol_pc) in
      if pc_now <> !last_protocol_pc then begin
        popped := Bits.to_int !(outputs.rx_word) :: !popped;
        last_protocol_pc := pc_now
      end)
    drive_cycles;
  (* Run a few extra cycles holding the last pin state so µE1 (which
     may lag µE0 by a cycle or two through the FIFO) finishes popping
     everything µE0 already pushed. *)
  for _ = 1 to 10 do
    inputs.pins_in := Bits.of_int ~width:8 (capture_level_bits lor List.nth byte_bits 7);
    cycle ();
    let pc_now = Bits.to_int !(outputs.protocol_pc) in
    if pc_now <> !last_protocol_pc then begin
      popped := Bits.to_int !(outputs.rx_word) :: !popped;
      last_protocol_pc := pc_now
    end
  done;

  let popped = List.rev !popped in
  Printf.printf "=== CAPTURE + byte-relay coexist through the real shared shadow_fifo ===\n";
  (match popped with
   | [ r0; r1; r2 ] ->
     let p0, l0, e0 = decode_capture r0 in
     let p1, l1, e1 = decode_capture r1 in
     Printf.printf
       "  pop 0 (capture): pin=%d level=%d elapsed=%d (expected pin=2 level=1 elapsed=0)\n" p0 l0 e0;
     Printf.printf
       "  pop 1 (capture): pin=%d level=%d elapsed=%d (expected pin=4 level=0 elapsed=0)\n" p1 l1 e1;
     Printf.printf "  pop 2 (byte-relay): 0x%04x (expected 0x%04x)\n" r2 byte_value;
     let passed =
       p0 = 2 && l0 = 1 && e0 = 0 && p1 = 4 && l1 = 0 && e1 = 0 && r2 = byte_value
     in
     Printf.printf "RESULT: %s\n" (if passed then "PASS" else "FAIL");
     if not passed then exit 1
   | _ ->
     Printf.printf "  expected exactly 3 popped words, got %d: [%s]\n" (List.length popped)
       (String.concat "; " (List.map (Printf.sprintf "0x%04x") popped));
     Printf.printf "RESULT: FAIL\n";
     exit 1)
