open Hardcaml
open Signal

(* ============================================================
   Prescaled Wait Timer (ISA v0.2 building block)
   ============================================================
   `tick` pulses once every (prescale+1) clk cycles
   (prescale=0 => tick every cycle, i.e. no scaling / passthrough).

   On `load`, the main counter arms for `payload` TICKS (not raw
   cycles); `expired` pulses exactly `payload` ticks later. This is
   what lets a 10-bit payload represent slow baud rates (e.g. 9600 @
   50 MHz needs 5208 raw cycles -- too big for 10 bits directly, but
   fits easily once cycles are pre-scaled into ticks).

   Reload-on-expiry happens on the SAME cycle a stage expires, not the
   cycle after -- same self-consistent down-counter pattern already
   validated (and bug-fixed) in the UART core, specifically to avoid
   the extra +1 dwell-cycle class of bug found there.
   ============================================================ *)
module I = struct
  type 'a t = {
    clk      : 'a;
    rst_n    : 'a;
    load     : 'a;
    prescale : 'a; [@bits 8]
    payload  : 'a; [@bits 10]
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    expired : 'a;
    tick    : 'a; (* debug tap: prescaled tick pulse *)
  } [@@deriving sexp_of, hardcaml]
end

let create (inputs : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:inputs.clk ~clear:((~:) inputs.rst_n) () in

  (* ---- Prescaler: free-running tick generator ---- *)
  let presc_cnt = wire 8 in
  let presc_zero = presc_cnt ==: zero 8 in
  presc_cnt <==
    reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun c ->
      mux2 presc_zero inputs.prescale (c -:. 1));
  let tick = presc_zero in

  (* ---- Busy flag: gates `expired` so a stale/idle counter can't
     spuriously fire before the first `load` ---- *)
  let busy = wire 1 in

  (* ---- Main down-counter: decrements only on a tick ---- *)
  let main_cnt = wire 10 in
  let main_zero = main_cnt ==: zero 10 in
  (* Never on a `load` cycle: the engine re-arms the timer after EVERY
     instruction (load = reg advance) with that instruction's payload, so
     the counter a WAIT inherits on its first cycle belongs to the
     instruction before it. When that payload was 1 (release_pin,
     shift_in_push, ...) the inherited counter is already 0 and the WAIT
     used to expire on its first cycle instead of after its own payload
     (found by test_dual_tx.ml: a timed WAIT after a release_pin nop). *)
  let expired = busy &&: tick &&: main_zero &&: (~:(inputs.load)) in

  busy <==
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun b ->
      mux2 inputs.load (one 1) (mux2 expired (zero 1) b));

  main_cnt <==
    reg_fb ~enable:(one 1) spec ~width:10 ~f:(fun c ->
      mux2 inputs.load (inputs.payload -:. 1)
        (mux2 tick (mux2 main_zero c (c -:. 1)) c));

  { O.expired; tick }
