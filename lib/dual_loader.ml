open Hardcaml
open Signal

(* ============================================================
   Program-load protocol for the DUAL-ENGINE core -- extends
   loader.ml (which only ever addressed one RAM) to route committed
   words to EITHER µE0's (engine.ml) or µE1's (protocol_engine.ml)
   instruction memory, each its own independent single-port macro
   (see design_rationale.txt's "Deviations From Original Design",
   deviation 1: separate single-port 512x8-pair memories per engine,
   not one shared dual-port 512x16 macro -- this loader's two
   independent write ports/address counters are the direct
   consequence of that decision. If the two engines DID share one
   physical dual-port macro, this loader would look different: one
   address space, two read ports, no engine_sel bit at all).

   loader.ml stays exactly as-is (still what tt_um_system uses) --
   same "add the new path next to the working one" pattern already
   established for tt_um_logic/tt_um_system and system.ml/dual.ml.

   Pin roles while state=Load (before GO is asserted) -- one new bit
   versus loader.ml, everything else identical:
     ui_in[7:0]  = data_in     (one byte)
     uio_in[0]   = strobe      (rising edge commits data_in)
     uio_in[1]   = byte_sel    (0 = low byte of word, 1 = high byte)
     uio_in[2]   = go          (rising edge: lock both RAMs, latch run)
     uio_in[3]   = engine_sel  (0 = word targets µE0/phys, 1 = µE1/protocol)

   Protocol: identical prescale-first phase to loader.ml (the very
   first strobe pulse after reset is the prescale byte, feeding only
   µE0's Engine.I.prescale -- µE1/protocol_engine.ml has no WAIT-style
   opcode and no Timer, so it needs no prescale at all). `engine_sel`
   is don't-care during the prescale pulse; host convention is to
   drive it low. Every strobe after that follows the word protocol:
   byte_sel=0 latches the low byte into a SHARED holding register
   (engine_sel-independent -- only one word is ever mid-flight at a
   time, so there is nothing to disambiguate yet), byte_sel=1 latches
   the high byte, commits the full word, and routes that commit to
   whichever engine's write port `engine_sel` currently selects --
   that engine's OWN address counter then auto-increments, the
   other's does not. This is what lets the host load two
   independent-length programs back to back (or interleaved -- the
   RTL doesn't care) without a shared address space.

   Host-side contract (not enforced in hardware, same class of
   contract loader.ml already documents for byte_sel/go timing):
   hold `engine_sel` stable across a word's low- and high-byte
   strobes. Nothing stops a host from changing it mid-word; doing so
   would commit to whichever engine engine_sel indicates AT the
   high-byte strobe, silently disagreeing with where the low byte
   thought it was going. Not guarded in RTL, same posture as the
   existing go-mid-word gap in loader.ml.

   `run` is a SINGLE latch driving BOTH Dual.I.run and
   Dual.I.protocol_run once `go` fires -- unlike dual.ml's own two
   independent enables (which exist specifically so a testbench can
   pause one engine to prove backpressure, see dual.ml's header
   comment), a real host has no reason to start the two engines at
   different times: both programs are already fully loaded by the
   time `go` is meaningful, and the backpressure story is about
   µE0/µE1's relative *execution* speed once both are running, not
   about staggering when they start. One `go`, one `run`, matching
   the single-engine loader.ml's own contract.

   `checksum` is one running XOR across BOTH engines' committed words
   (not two separate checksums) -- simplest verification story for
   the host: one number to compare against, covering the entire load
   regardless of which engine each word went to. Same formula as
   loader.ml, just gated on `commit` (either engine) instead of one
   engine's commit alone.
   ============================================================ *)

let addr_width = Loader.addr_width

module I = struct
  type 'a t = {
    clk        : 'a;
    rst_n      : 'a;
    data_in    : 'a; [@bits 8]
    strobe     : 'a;
    byte_sel   : 'a;
    go         : 'a;
    engine_sel : 'a;
    cfg_sel    : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    phys_write_enable     : 'a;
    phys_write_addr       : 'a; [@bits 9]
    protocol_write_enable : 'a;
    protocol_write_addr   : 'a; [@bits 9]
    write_data            : 'a; [@bits 16]
    checksum              : 'a; [@bits 8]
    run                   : 'a;
    prescale               : 'a; [@bits 8]
    bp_cfg                : 'a; [@bits 72]
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

  (* Optional configuration path (bit pipe + glitch filter, see bitpipe.ml):
     while `cfg_sel` is high a strobe writes the next of 9 config bytes
     instead of a prescale byte or program word. Hosts that never raise
     cfg_sel (every existing test and program) see no change at all. *)
  let cfg_sel = inputs.cfg_sel in
  let cfg_write = strobe_edge &&: not_run &&: cfg_sel in
  let cfg_idx = wire 4 in
  cfg_idx
  <== reg_fb ~enable:(one 1) spec ~width:4 ~f:(fun cur ->
        mux2 (cfg_write &&: (cur <>:. 15)) (cur +:. 1) cur);
  let cfg_byte k =
    let r = wire 8 in
    r
    <== reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
          mux2 (cfg_write &&: (cfg_idx ==:. k)) inputs.data_in cur);
    r
  in
  let bp_cfg = concat_msb (List.rev (List.init Bitpipe.cfg_bytes cfg_byte)) in

  let prescale_loaded = wire 1 in
  let load_prescale = strobe_edge &&: not_run &&: (~:cfg_sel) &&: (~:prescale_loaded) in

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
          (strobe_edge &&: (~:(inputs.byte_sel)) &&: not_run &&: prescale_loaded &&: (~:cfg_sel))
          inputs.data_in cur);

  let commit = strobe_edge &&: inputs.byte_sel &&: not_run &&: prescale_loaded &&: (~:cfg_sel) in
  let commit_phys = commit &&: (~:(inputs.engine_sel)) in
  let commit_protocol = commit &&: inputs.engine_sel in
  let word = concat_msb [ inputs.data_in; byte_lo ] in

  let addr_phys = wire addr_width in
  addr_phys
  <== reg_fb ~enable:(one 1) spec ~width:addr_width ~f:(fun cur ->
        mux2 commit_phys (cur +:. 1) cur);

  let addr_protocol = wire addr_width in
  addr_protocol
  <== reg_fb ~enable:(one 1) spec ~width:addr_width ~f:(fun cur ->
        mux2 commit_protocol (cur +:. 1) cur);

  let checksum = wire 8 in
  checksum
  <== reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
        mux2 commit (cur ^: select word 15 8 ^: select word 7 0)
          (mux2 cfg_write (cur ^: inputs.data_in) cur));

  run <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur -> cur |: go_edge);

  { O.phys_write_enable = commit_phys
  ; phys_write_addr = addr_phys
  ; protocol_write_enable = commit_protocol
  ; protocol_write_addr = addr_protocol
  ; write_data = word
  ; checksum
  ; run
  ; prescale
  ; bp_cfg
  }
