open Hardcaml
open Tt_core

(* Emits formal/shadow_fifo.v: the Verilog of the REAL Shadow_fifo RTL, for
   the SymbiYosys proof in formal/ (run_formal_fifo.sh). Generated from the
   same Hardcaml source the tape-out uses; nothing is re-implemented. *)

module C = Circuit.With_interface (Shadow_fifo.I) (Shadow_fifo.O)

let () =
  let circuit = C.create_exn ~name:"shadow_fifo" Shadow_fifo.create in
  Rtl.print Verilog circuit
