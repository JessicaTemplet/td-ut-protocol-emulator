open Hardcaml
open Signal

(* ============================================================
   Program-overrun guard, shared by µE0 (engine.ml) and µE1
   (protocol_engine.ml).

   Instruction SRAM is not cleared at reset, so a program that runs past
   its last loaded word -- by falling through, or by branching to an
   address it never loaded -- would fetch and execute whatever bits the
   SRAM powered up with. Cyclesim's zero-filled RAM hides this (zero
   decodes as a harmless wait/pop), real silicon would not.

   The guard tracks `loaded` = (highest address written) + 1 from the
   engine's own write port, and reports `halted` once pc reaches an
   address at or past it. The engine ANDs `halted` out of its `run`, so
   the overrun word is fetched but never executed: no pin, FIFO, timer or
   pipe side effect, and pc stops (pc only moves on `advance`, which needs
   `run`). Output pins keep their last levels, since they are sticky
   registers. Programs that end with an explicit halt never reach it, so
   every existing program behaves exactly as before.

   `loaded` = 0 (nothing written) disables the guard, and `loaded` is one
   bit wider than pc so a full 512-word program is representable.
   ============================================================ *)

let create ~spec ~write_enable ~write_addr ~pc =
  let width = Signal.width write_addr + 1 in
  let addr = uresize write_addr width in
  let loaded =
    reg_fb ~enable:(one 1) spec ~width ~f:(fun cur ->
      mux2 (write_enable &&: (addr >=: cur)) (addr +:. 1) cur)
  in
  (loaded <>:. 0) &&: (uresize pc width >=: loaded)
