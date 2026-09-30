open Hardcaml
open Signal

(* ============================================================
   Program-load protocol (open decision #1 from the project log).

   Post-tapeout there is no APB/AHB bus -- the only way in is the 8
   ui_in + 8 uio_in pins. This is a byte-serial loader: no address
   bus at all. Write address auto-increments from 0 on reset, so the
   host just streams the program's 16-bit words in order, 8 bits at
   a time.

   Pin roles while state=Load (before GO is asserted):
     ui_in[7:0]  = data_in   (one byte)
     uio_in[0]   = strobe    (rising edge commits data_in)
     uio_in[1]   = byte_sel  (0 = low byte of word, 1 = high byte)
     uio_in[2]   = go        (rising edge: lock RAM, latch Run)

   Protocol: the very FIRST strobe pulse after reset is always the
   prescale byte (a single byte on data_in, byte_sel don't-care --
   Timer's prescale is "set once, not per-instruction", so it gets
   one byte, not a full 16-bit word). Every strobe after that follows
   the original word protocol: byte_sel=0 latches the low byte into a
   holding register, byte_sel=1 latches the high byte AND commits the
   full word to RAM[addr], then addr auto-increments. After the last
   word, host pulses go. Run is sticky until the next reset -- once
   latched, further strobe/byte_sel/go activity is ignored, so these
   same physical pins are free for the loaded microcode to
   reinterpret as ordinary protocol I/O.

   This prescale-first phase exists because Engine.I.prescale had no
   path onto a real pin otherwise: ui_in doubles as data_in pre-run
   and pins_in post-run, uio_in's 3 load-control bits leave only 5
   spare bits (not enough for an 8-bit value), and hardcoding it at
   synthesis time would fix the chip's timing base at fab time. This
   costs zero new pins -- it's purely a state-machine addition, same
   "reuse what's already there" spirit as the rest of the loader.

   Host-side contract (not enforced in hardware): pulse the prescale
   byte first, always; assert `go` only after a word's high-byte
   strobe has completed, never mid-word.

   `checksum` is a running XOR of every committed word (hi byte XOR
   lo byte folded into 8 bits) -- meant to be muxed onto uo_out during
   Load so the host can verify the load before committing to `go`,
   per Jane Street's stated interest in verification methodology.
   Cheap: one 8-bit XOR + register, no protocol-specific logic.

   `strobe`/`go` are synchronized with a 2-FF chain since they're
   host-driven and not guaranteed edge-aligned to this clock domain.

   Address width is 9 bits (512 entries) to match the OpenRAM macro
   size named in the project log as the still-unverified assumption
   (open decision #5) -- if that macro turns out to be a different
   depth, this width is the one place to change.

   NOT done here: wiring this into engine.ml's fetch stage (engine.ml
   still reads a compile-time literal ROM, not a real RAM) or onto
   real ui_in/uio_in/uo_out pins in main.ml. This module is a
   standalone, independently-testable slice of the protocol, in the
   same spirit as timer.ml before engine.ml consumed it.
   ============================================================ *)

let addr_width = 9

module I = struct
  type 'a t = {
    clk      : 'a;
    rst_n    : 'a;
    data_in  : 'a; [@bits 8]
    strobe   : 'a;
    byte_sel : 'a;
    go       : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    write_enable : 'a;
    write_addr   : 'a; [@bits 9]
    write_data   : 'a; [@bits 16]
    checksum     : 'a; [@bits 8]
    run          : 'a;
    prescale     : 'a; [@bits 8]
  } [@@deriving sexp_of, hardcaml]
end

let create (inputs : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:inputs.clk ~clear:((~:) inputs.rst_n) () in
  let sync2 s = reg spec (reg spec s) in

  let strobe_sync = sync2 inputs.strobe in
  let strobe_d = reg spec strobe_sync in
  let strobe_edge = strobe_sync &&: (~:strobe_d) in

  let go_sync = sync2 inputs.go in
  let go_d = reg spec go_sync in
  let go_edge = go_sync &&: (~:go_d) in

  let run = wire 1 in
  let not_run = ~:run in

  (* Prescale phase: the first strobe pulse after reset (and only
     that one) latches data_in as the prescale byte instead of a
     program-word byte. Sticky like `run` -- once loaded, every
     later strobe falls through to the normal word protocol below. *)
  let prescale_loaded = wire 1 in
  let load_prescale = strobe_edge &&: not_run &&: (~:prescale_loaded) in

  prescale_loaded
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur -> cur |: load_prescale);

  let prescale = wire 8 in
  prescale
  <== reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
        mux2 load_prescale inputs.data_in cur);

  let byte_lo = wire 8 in
  byte_lo
  <== reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
        mux2
          (strobe_edge &&: (~:(inputs.byte_sel)) &&: not_run &&: prescale_loaded)
          inputs.data_in cur);

  let commit = strobe_edge &&: inputs.byte_sel &&: not_run &&: prescale_loaded in
  let word = concat_msb [ inputs.data_in; byte_lo ] in

  let addr = wire addr_width in
  addr
  <== reg_fb ~enable:(one 1) spec ~width:addr_width ~f:(fun cur ->
        mux2 commit (cur +:. 1) cur);

  let checksum = wire 8 in
  checksum
  <== reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
        mux2 commit (cur ^: select word 15 8 ^: select word 7 0) cur);

  run <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur -> cur |: go_edge);

  { O.write_enable = commit; write_addr = addr; write_data = word; checksum; run; prescale }
