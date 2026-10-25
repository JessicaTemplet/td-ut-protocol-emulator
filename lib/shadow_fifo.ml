open Hardcaml
open Signal

(* ============================================================
   4-entry shadow ring-buffer FIFO coupling the two micro-engines --
   this is the actual "dual-engine" novelty claim from the design
   blueprint (Core-0 physical layer streams deserialized words into
   Core-1's protocol layer through this, with hardware backpressure).
   Kept generic and engine-agnostic on purpose: this module knows
   nothing about pins, opcodes, or which side is "physical" vs
   "protocol" -- it's a plain synchronous FIFO. `dual.ml` is what
   wires Engine (physical) and Protocol_engine (protocol) to it and
   gives the coupling its actual meaning.

   Semantics: `push`/`pop` are requests, silently ignored (no
   overflow/underflow corruption) when `full`/`empty` respectively --
   same "producer must check before acting" contract Engine's own
   `run` gating already uses elsewhere. `pop_data` is a combinational
   peek at the current head slot, valid whenever `empty` is low,
   whether or not `pop` is asserted this cycle -- the consumer reads
   it, then asserts `pop` to advance. Simultaneous push+pop in the
   same cycle is supported (steady-state streaming): count stays flat,
   both pointers advance.

   Depth-4 ring buffer: 2-bit write/read pointers wrapping mod 4, a
   3-bit `count` (0..4) tracks fill level directly rather than being
   derived from pointer comparison (avoids the classic "empty vs full
   look identical when ptrs are equal" ambiguity some ring-buffer
   designs have to solve with an extra bit).
   ============================================================ *)

let depth = 4
let ptr_width = 2

module I = struct
  type 'a t = {
    clk       : 'a;
    rst_n     : 'a;
    push      : 'a;
    push_data : 'a; [@bits 16]
    pop       : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    pop_data : 'a; [@bits 16]
    empty    : 'a;
    full     : 'a;
  } [@@deriving sexp_of, hardcaml]
end

(* The FIFO at any power-of-two depth and any width. `create` below is the
   4 x 16 instance both inter-engine FIFOs use, unchanged; Shadow's trace
   FIFOs (shadow.ml) use 4 x 64, one trace record per entry. Also returns the
   fill count (the trace readout reports it). *)
let create_sized ~depth ~ptr_width ~clk ~rst_n ~push ~push_data ~pop =
  assert (depth = 1 lsl ptr_width);
  let width = Signal.width push_data in
  let spec = Reg_spec.create ~clock:clk ~clear:((~:) rst_n) () in

  let count = wire (ptr_width + 1) in
  let empty = count ==:. 0 in
  let full = count ==:. depth in

  let do_push = push &&: (~:full) in
  let do_pop = pop &&: (~:empty) in

  let wr_ptr = wire ptr_width in
  let rd_ptr = wire ptr_width in
  wr_ptr <==
    reg_fb ~enable:(one 1) spec ~width:ptr_width ~f:(fun cur -> mux2 do_push (cur +:. 1) cur);
  rd_ptr <==
    reg_fb ~enable:(one 1) spec ~width:ptr_width ~f:(fun cur -> mux2 do_pop (cur +:. 1) cur);

  count <==
    reg_fb ~enable:(one 1) spec ~width:(ptr_width + 1) ~f:(fun cur ->
      mux2 (do_push &&: (~:do_pop)) (cur +:. 1) (mux2 (do_pop &&: (~:do_push)) (cur -:. 1) cur));

  (* One sticky register per slot, latched only when this push targets
     it -- same demux pattern engine.ml's pins_out/pins_oe already use. *)
  let mem_regs =
    Array.init depth (fun slot ->
      reg_fb ~enable:(one 1) spec ~width ~f:(fun cur ->
        mux2 (do_push &&: (wr_ptr ==:. slot)) push_data cur))
  in
  let pop_data = mux rd_ptr (Array.to_list mem_regs) in
  (pop_data, empty, full, count)

let create (i : Signal.t I.t) =
  let pop_data, empty, full, _ =
    create_sized ~depth ~ptr_width ~clk:i.clk ~rst_n:i.rst_n ~push:i.push ~push_data:i.push_data
      ~pop:i.pop
  in
  { O.pop_data; empty; full }
