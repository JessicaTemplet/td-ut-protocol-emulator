open Hardcaml
open Tt_core

(* Verilog generation. Run from the repository root (scripts/run_main.sh does).

   src/tt_um_dual.v is the tape-out top: the dual-engine core (Dual: uE0 +
   shadow FIFO + uE1) on real tt_um pins via dual_loader.ml. It is what
   info.yaml names, what LibreLane hardens and what CI builds, so it is
   written straight into src/ and committed.

   The two earlier tops, tt_um_template (the hardwired proof-of-concept core)
   and tt_um_system (the single reprogrammable engine), are kept as tested
   fallbacks. They are written to build/ (not committed) so they can still
   be hardened if ever needed.

   The *_asic variants use the real IHP SRAM hard macros, not the behavioral
   Ram.create the Cyclesim suites simulate: Ram.create synthesizes as
   flip-flops with no path to real SRAM (the "16,076 sequential cells, ~5x
   over budget" finding in docs/design/design_rationale.txt). See engine.ml's
   module header for why the two backends are separate functions. *)
let () =
  let module Circuit = Circuit.With_interface (I) (O) in
  if not (Sys.file_exists "build") then Sys.mkdir "build" 0o755;
  let emit name create file =
    Rtl.output ~output_mode:(To_file file) Verilog (Circuit.create_exn ~name create);
    print_endline ("Success: Generated clean " ^ file)
  in
  emit "tt_um_template" tt_um_logic "build/tt_um_template.v";
  emit "tt_um_system" tt_um_system_asic "build/tt_um_system.v";
  emit "tt_um_dual" tt_um_dual_asic "src/tt_um_dual.v"
