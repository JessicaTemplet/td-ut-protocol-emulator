open Hardcaml
open Signal

(* ============================================================
   Bit-clock recovery: a small digital PLL that keeps a model of the
   sender's bit clock and tells µE0 when to sample.

   Without it, a receive program samples on its own timer started at the
   first edge, so the line's bit period must be an exact number of clocks:
   USB low speed allows the sender +-1.5%, which walks a free-running
   sample point off the bit inside one packet.

   The phase `ph` counts clock cycles since the last bit boundary, in
   12.8 fixed point, wrapping at the configured period P (also 12.8, so
   32.5 or 46.67 cycles a bit both work). Each cycle it advances by 1.0.
   Crossing P/2 raises `strobe` (mid-bit: sample now).

   Every edge on the tracked pin is evidence of where a boundary really
   is. Its error is the phase at the edge, folded to (-P/2, P/2]:
   positive = the edge came late, negative = early. An edge inside the
   acceptance window moves the phase by (error >> gain_shift): shift 0
   snaps to the edge, larger shifts follow the sender's clock while
   barely moving for a single misplaced edge. An edge outside the window
   is ignored (a glitch, or noise mid-bit) and reported as rejected.

   With freq_en the loop is second order (proportional + integral): each
   accepted edge also moves a period ESTIMATE by (error >> freq_shift),
   so the unit learns the sender's actual bit period and the phase
   correction only has to remove jitter. A proportional-only loop cannot
   do that: against a sender off by o, its phase error settles near
   2^gain_shift times the drift between edges, so a gentle gain plus a
   window loses lock (measured: gain shift 1, -2%, 7-cell runs). The
   estimate starts at the configured P on `arm` and is clamped to
   P +- P/16, so noise cannot run it away.

   Choosing the gains (measured, test_clock_recovery.ml's REC_SWEEP: USB-
   like data with up to 7 cells between edges, +-2 cycles of jitter,
   offsets up to +-2%, window P/4): freq_shift 4 holds lock at every
   offset for gain_shift 0..3. freq_shift 0..2 is unstable, because an
   edge after a long run carries that whole run's drift, so one step is
   up to 7x the nominal gain. Beyond +-2% the window, not the loop, limits
   lock: a 7-cell run drifts past P/4 before the next edge arrives. A
   wider window buys range and gives up glitch rejection.

   `arm` (µE0's receive-pipe reset) parks the unit: phase frozen, no
   strobes, until the next edge, which it takes as a bit boundary
   exactly. That is how a packet's first edge (USB: SYNC's first K)
   starts the clock.

   `pending` is the strobe made sticky, so µE0 never misses a sample
   point it reaches a little late: PIPE_BIT's sync form waits for it and
   clears it (`consume`). A strobe that finds `pending` still set means
   the program fell a whole bit behind; `overrun` is set until `arm`.

   Manchester mode (profile byte 16 bit 7; 10BASE-T): every bit has a
   transition at its middle, low-to-high for a 1 (IEEE 802.3), and a cell
   boundary has one only between two equal bits. The phase is locked to
   the MID-BIT edges: an edge within P/4 of where one is due is one, and
   corrects the phase; an edge further off is a boundary transition and is
   masked (not a reject, not in the margin). The bit itself is the line
   level a quarter cell after the mid-bit point (a Manchester bit equals
   its second half), so an edge misjudged under jitter costs a little
   phase, not a bit. Two mid-bit edges missing in a row mean the frame has
   ended (`frame_end`, sticky until arm); bits are handed out one slot
   late (`bit_valid`, `bit_value`) so the sample taken where the first of
   those edges was missing, idle line rather than data, is never
   delivered. (The first version took the bit from the edge and ended the
   frame at the first missing edge: one edge pushed past P/4 by jitter
   while the loop was still acquiring ended the frame in its preamble.)
   Arming snaps on a RISING edge only: a frame's preamble starts with a 1,
   whose leading boundary edge (idle high to low) falls and whose mid-bit
   edge rises. There is no sample strobe in this mode; µE0's `PIPE_BIT
   run` lets these bits step the receive pipe directly, because at 5 to 7
   clocks a bit no instruction loop keeps up.

   Configuration (profile bytes 16-20, see bitpipe.ml): rec_en, the pin,
   the gain shift, P, and the window in whole cycles (0 = accept all).
   Keep the window under P/4: a correction near mid-bit could otherwise
   move the phase across P/2 and skip or repeat a sample.
   ============================================================ *)

let frac_bits = 8
let ph_width = 20 (* 12 integer + 8 fraction bits *)

module I = struct
  type 'a t = {
    clk     : 'a;
    rst_n   : 'a;
    cfg     : 'a; [@bits 192]
    pins_in : 'a; [@bits 8]
    arm     : 'a;
    consume : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    strobe      : 'a;
    pending     : 'a;
    overrun     : 'a;
    edge_ok     : 'a; (* an edge was accepted this cycle *)
    edge_reject : 'a; (* an edge fell outside the window this cycle *)
    error       : 'a; [@bits 21] (* signed phase error of this cycle's edge *)
    armed       : 'a;
    period      : 'a; [@bits 21] (* the bit period in use, 12.8 fixed point *)
    margin      : 'a; [@bits 5] (* worst edge error since arm, 64ths of a bit *)
    margin_busy : 'a; (* the margin is being recomputed *)
    bit_valid   : 'a; (* Manchester: a bit was decoded this cycle *)
    bit_value   : 'a;
    frame_end   : 'a; (* Manchester: a mid-bit edge was missing (sticky) *)
  } [@@deriving sexp_of, hardcaml]
end

let create (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clk ~clear:((~:) i.rst_n) () in
  let c = Bitpipe.decode_cfg i.cfg in
  let w = ph_width + 1 in (* signed working width *)
  let one_cycle = of_int ~width:w (1 lsl frac_bits) in
  let p_cfg = uresize c.rec_period w in
  (* the period in use: the configured one, or the learned estimate *)
  let p_est = wire w in
  let p = mux2 c.rec_freq_en p_est p_cfg in
  let half = srl p 1 in

  let line = mux c.rec_pin (List.init 8 (fun k -> select i.pins_in k k)) in
  let line_d = reg spec line in
  let edge = c.rec_en &&: (line ^: line_d) in

  let ph = wire ph_width in
  let armed = wire 1 in
  let phw = uresize ph w in

  (* signed error, folded into (-P/2, P/2] *)
  let error = mux2 (phw <: half) phw (phw -: p) in
  let neg = msb error in
  let mag = mux2 neg (negate error) error in
  let window = concat_msb [ zero (w - 8 - frac_bits); c.rec_window; zero frac_bits ] in
  (* Manchester: a mid-bit edge is expected at error 0 and a cell boundary at
     P/2, so the best classifier is the midpoint, P/4, at full fixed-point
     resolution. A whole-cycle window cannot do that at 5 clocks a bit:
     with a learned (fractional) phase a genuine mid-bit edge at 1.2 cycles
     fell outside a window of 1 and the frame "ended" (measured: frames
     lost at 0.25 cycle of jitter); a window of 2 would let boundary edges,
     2 to 3 cycles off, in. *)
  let quarter = srl p 2 in
  let within =
    mux2 c.manchester (mag <: quarter) ((c.rec_window ==:. 0) |: (mag <=: window))
  in
  (* error >> s rounded toward zero: shift the magnitude, restore the sign.
     A plain arithmetic shift rounds toward minus infinity, so a small early
     edge counts as -1/256 cycle and a small late one as 0. The closed loop
     mostly cancels that (measured over 3000 bits with symmetric jitter:
     the learned period ends 0.02 cycle lower with the plain shift), so
     this is the symmetric choice rather than a fix for a visible fault. *)
  let shift_toward_zero s = mux2 neg (negate (srl mag s)) (srl mag s) in
  let shifted = mux c.rec_gain (List.init 8 shift_toward_zero) in

  let manch = c.manchester in
  let running = c.rec_en &&: (~:armed) in
  let accept = running &&: edge &&: within in
  let corr = mux2 accept shifted (zero w) in
  let v = phw +: one_cycle -: corr in
  let v_wrapped = mux2 (v >=: p) (v -: p) v in
  let strobe = running &&: (~:manch) &&: (phw <: half) &&: (v_wrapped >=: half) in
  (* the edge that ends `armed`: any edge, or in Manchester mode a rising one *)
  let snap = armed &&: edge &&: ((~:manch) |: line) in

  ph
  <== reg_fb ~enable:(one 1) spec ~width:ph_width ~f:(fun cur ->
        mux2 (i.arm |: (~:(c.rec_en))) (zero ph_width)
          (mux2 armed
             (mux2 snap (uresize one_cycle ph_width) cur)
             (uresize v_wrapped ph_width)));
  armed
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.arm vdd (mux2 snap gnd cur));

  (* Manchester frame end: once the phase is past the acceptance zone
     around a mid-bit (P/4), that bit's edge must have come *)
  let zone_end = quarter in
  let check = running &&: manch &&: (phw <: zone_end) &&: (v_wrapped >=: zone_end) in
  let zone_hit = wire 1 in
  zone_hit
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 (i.arm |: snap |: accept) (~:(i.arm)) (mux2 check gnd cur));
  let hit = zone_hit |: accept in
  (* consecutive missing mid-bit edges; the second ends the frame *)
  let missed = wire 1 in
  missed
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.arm gnd (mux2 check (~:hit) cur));
  let ending = check &: (~:hit) &: missed in
  let frame_end =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur -> mux2 i.arm gnd (cur |: ending))
  in
  (* the bit sampled at this check is handed out at the next one *)
  let held_valid =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur -> mux2 i.arm gnd (mux2 check (~:ending) cur))
  in
  (* The bit is the line level when the zone closes, a quarter cell after
     the mid-bit point. Measured alternatives: taking the bit from the
     direction of the mid-bit edge when one was seen did no better (and the
     mutation check could not tell them apart), and sampling earlier did
     worse, since it can fire before a late but still accepted mid-bit
     edge. *)
  let held_value = reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur -> mux2 check line cur) in
  let bit_valid = check &: held_valid &: (~:ending) &: (~:frame_end) in

  (* integral path: learn the period, within P +- P/16 *)
  let fstep = mux c.rec_fshift (List.init 8 shift_toward_zero) in
  let p_lo = p_cfg -: srl p_cfg 4 and p_hi = p_cfg +: srl p_cfg 4 in
  p_est
  <== reg_fb ~enable:(one 1) spec ~width:w ~f:(fun cur ->
        let next = cur +: fstep in
        let clamped = mux2 (next <: p_lo) p_lo (mux2 (next >: p_hi) p_hi next) in
        mux2 (i.arm |: (~:(c.rec_en))) p_cfg (mux2 accept clamped cur));

  let pending =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
      mux2 i.arm gnd (strobe |: (cur &: (~:(i.consume)))))
  in
  let overrun =
    reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
      mux2 i.arm gnd (cur |: (strobe &: pending &: (~:(i.consume)))))
  in
  (* ---- link health: timing margin ----
     `worst` is the largest |error| of any edge since `arm`, accepted or
     rejected (a rejected edge is the worst news of all). The reported
     margin is that error as a fraction of the bit period,
     floor(64 * worst / P) saturated at 31, so one threshold means the same
     for every protocol: bit 4 (16) = an edge a quarter bit or more off.
     The division runs on a small sequential divider, one quotient bit per
     cycle (6 cycles), restarted whenever `worst` grows; `margin_busy`
     holds PIPE_STATUS until it has finished, which after a packet's last
     edge it always has (USB: the EOP is two bit cells long). *)
  let dw = w + 6 in
  let worst = wire w in
  (* in Manchester mode boundary transitions are expected, not errors *)
  let measured = running &&: edge &&: ((~:manch) |: within) in
  let bigger = measured &&: (mag >: worst) in
  worst
  <== reg_fb ~enable:(one 1) spec ~width:w ~f:(fun cur ->
        mux2 i.arm (zero w) (mux2 bigger mag cur));
  let start = reg spec (bigger &: (~:(i.arm))) in
  let busy = wire 1 and idx = wire 3 and rem = wire dw and q = wire 6 in
  let pd = uresize p dw in
  let d = mux idx (List.init 6 (fun s -> sll pd s)) in
  let ge = rem >=: d in
  let bit_now = mux idx (List.init 6 (fun s -> of_int ~width:6 (1 lsl s))) in
  let q_next = mux2 ge (q |: bit_now) q in
  let last = busy &: (idx ==:. 0) in
  rem
  <== reg_fb ~enable:(one 1) spec ~width:dw ~f:(fun cur ->
        mux2 start (sll (uresize worst dw) 6) (mux2 (busy &: ge) (cur -: d) cur));
  idx
  <== reg_fb ~enable:(one 1) spec ~width:3 ~f:(fun cur ->
        mux2 start (of_int ~width:3 5) (mux2 busy (cur -:. 1) cur));
  q
  <== reg_fb ~enable:(one 1) spec ~width:6 ~f:(fun cur ->
        mux2 start (zero 6) (mux2 busy q_next cur));
  busy
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 (i.arm |: start) start (mux2 last gnd cur));
  let margin =
    reg_fb ~enable:(one 1) spec ~width:5 ~f:(fun cur ->
      mux2 i.arm (zero 5)
        (mux2 last (mux2 (msb q_next) (of_int ~width:5 31) (select q_next 4 0)) cur))
  in
  { O.strobe
  ; pending
  ; overrun
  ; edge_ok = accept
  ; edge_reject = running &&: edge &&: (~:within) &&: (~:manch)
  ; error
  ; armed
  ; period = p
  ; margin
  ; margin_busy = bigger |: start |: busy
  ; bit_valid
  ; bit_value = held_value
  ; frame_end
  }
