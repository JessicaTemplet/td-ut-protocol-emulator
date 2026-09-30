open Hardcaml
open Tt_core

let () =
  let module Circuit = Circuit.With_interface (I) (O) in
  let circuit = Circuit.create_exn ~name:"tt_um_template" tt_um_logic in
  Rtl.output ~output_mode:(To_file "tt_um_template.v") Verilog circuit;
  print_endline "Success: Generated clean tt_um_template.v";
  (* The reprogrammable core (System), wrapped onto real tt_um pins.
     Generated alongside tt_um_template.v, not in place of it -- which
     of the two is the actual tapeout submission is still an open
     call, not decided by this file.

     Uses tt_um_system_asic (real IHP SRAM hard macro), not plain
     tt_um_system (behavioral RAM, what test_tt_um_system.ml
     simulates) -- module/file name stay "tt_um_system" either way, so
     info.yaml/tt_tool.py need no changes. This is the actual fix for
     the "16,076 sequential cells, ~5x over budget" finding in
     docs/design/design_rationale.txt: plain tt_um_system's Ram.create synthesized as
     flip-flops with no path to real SRAM. See engine.ml's module
     header for why the behavioral/hard-macro split exists as two
     functions instead of one (Cyclesim can't simulate the hard-macro
     path). *)
  let system_circuit = Circuit.create_exn ~name:"tt_um_system" tt_um_system_asic in
  Rtl.output ~output_mode:(To_file "tt_um_system.v") Verilog system_circuit;
  print_endline "Success: Generated clean tt_um_system.v";
  (* The dual-engine core (Dual: uE0 + shadow FIFO + uE1), wrapped
     onto real tt_um pins via dual_loader.ml -- roadmap item #2.
     Generated alongside the other two, not in place of them; which
     of the three is the actual tapeout submission is still open.

     Uses tt_um_dual_asic (real IHP SRAM hard macro pair) for the same
     reason as tt_um_system_asic above -- this is the module that
     actually went through LibreLane hardening and hit "THE FINDING"
     in docs/design/design_rationale.txt. *)
  let dual_circuit = Circuit.create_exn ~name:"tt_um_dual" tt_um_dual_asic in
  Rtl.output ~output_mode:(To_file "tt_um_dual.v") Verilog dual_circuit;
  print_endline "Success: Generated clean tt_um_dual.v"
