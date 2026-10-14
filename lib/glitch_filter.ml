open Hardcaml
open Signal

(* ============================================================
   Per-pin digital glitch filter. A pin's filtered level only changes
   after the raw level has differed from it for `n` CONSECUTIVE samples;
   a shorter excursion is discarded and the counter restarts. So a
   pulse of width < n clocks is invisible to everything downstream
   (edge detection, bit sampling, CAPTURE), and a real transition is
   delayed by n clocks.

   n = 0 is a pure combinational bypass (zero latency, zero behaviour
   change), so the filter is invisible to every program that does not
   configure it. While `run` is low the filter just follows the raw pin,
   so there is no false edge when the core starts.

   Out of scope (blueprint's second stage): windowed interval validation
   (rejecting edge-to-edge deltas below a minimum). This is the
   stability filter only.
   ============================================================ *)
module I = struct
  type 'a t = {
    clk     : 'a;
    rst_n   : 'a;
    run     : 'a;
    pins_in : 'a; [@bits 8]
    n       : 'a; [@bits 4]
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = { pins_out : 'a; [@bits 8] } [@@deriving sexp_of, hardcaml]
end

let create (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clk ~clear:((~:) i.rst_n) () in
  let bypass = i.n ==:. 0 in
  let pin k =
    let raw = select i.pins_in k k in
    let filt = wire 1 in
    let cnt = wire 4 in
    let differs = raw ^: filt in
    let cnt_inc = cnt +:. 1 in
    let accept = differs &&: (cnt_inc >=: i.n) in
    filt
    <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
          mux2 (~:(i.run)) raw (mux2 accept raw cur));
    cnt
    <== reg_fb ~enable:(one 1) spec ~width:4 ~f:(fun cur ->
          ignore cur;
          mux2 ((~:(i.run)) |: (~:differs) |: accept) (zero 4) cnt_inc);
    mux2 bypass raw filt
  in
  { O.pins_out = concat_msb (List.init 8 (fun k -> pin (7 - k))) }
