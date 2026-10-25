open Hardcaml
open Signal

(* ============================================================
   Shadow mode: one comparator per engine.

   Drive and Shadow run the SAME program with the same instruction timing.
   In Drive an engine's EMIT_STATE / EMIT_TX latch its pins_out / pins_oe
   registers and the pads follow. In Shadow the same registers latch exactly
   the same values, but the engine's pads are released (dual.ml masks its
   output enables), so the registers become a claim: "the wire should now
   show pins_out on every pin where pins_oe is set". Something else drives
   the wire (the device under test, or the other engine), and this module
   checks it. Since Shadow only masks output enables, it cannot change when
   anything executes: `advance` has no Shadow term, which is what makes
   Shadow(Drive(P)) = no mismatches hold by construction, and it never stalls
   the engine it watches (a full trace FIFO drops and counts).

   A released pin (release_pin, an open-drain 1) is not a claim, the same
   pins Drive would not drive.

   When it compares. A claim holds from its EMIT to the next one, and the
   engine has no fixed sample strobe, so the compare happens `settle` cycles
   after the most recent claim, checking every claimed pin at once:
     mismatch = (pins_in ^ pins_out) & pins_oe
   Every new claim restarts the countdown, so back-to-back claims (SPI's MOSI
   then SCK) are checked together. `claim` is a REGISTERED copy of the
   engine's emit-advance, high on the first cycle the registers hold the new
   claim; the compare fires on cycle claim + settle (settle = 0: that cycle).
   A pin change reaches `pins_in` Dual.sync_latency + glitch_n cycles after
   the pad, so settle must exceed that, and stay below the shortest gap
   between claims. A program sets it to half a bit cell for a mid-cell check.

   Check mode (no pad release): the same comparator while the engine still
   drives catches contention, a pin the engine drives that the wire does not
   follow.

   Records (one 64-bit trace FIFO entry each, so a record is never partial):
     [63]    0 = mismatch, opens an episode; 1 = episode end
     [62:54] pc of the claim the compare followed
     [53:38] type 0: {mismatch mask, actual pin levels}  (expected = actual ^ mask)
             type 1: mismatching compares suppressed since the episode opened
     [37:32] records dropped (trace FIFO full) since the last one pushed, saturating
     [31:0]  timestamp of the compare, cycles since the shared epoch (run's rise)
   The wire time of the compared sample is timestamp - sync_latency - glitch_n.

   Storms: once an episode is open, further mismatching compares only count,
   so a design that stays wrong produces two records (where it went wrong,
   where it came back, and how many compares failed in between) instead of
   burying the first divergence under copies.
   ============================================================ *)

let record_bits = 64
let type_end = 1 lsl 63

module I = struct
  type 'a t = {
    clk       : 'a;
    rst_n     : 'a;
    enable    : 'a; (* Shadow or check mode on for this engine *)
    settle    : 'a; [@bits 16]
    claim     : 'a; (* registered: the claim registers changed last edge *)
    claim_pc  : 'a; [@bits 9]
    pins_in   : 'a; [@bits 8]
    pins_out  : 'a; [@bits 8]
    pins_oe   : 'a; [@bits 8]
    timestamp : 'a; [@bits 32]
    full      : 'a; (* this engine's trace FIFO *)
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    push   : 'a;
    record : 'a; [@bits 64]
  } [@@deriving sexp_of, hardcaml]
end

let create (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clk ~clear:((~:) i.rst_n) () in
  let claim = i.enable &: i.claim in
  let pc = reg_fb ~enable:(one 1) spec ~width:9 ~f:(fun cur -> mux2 claim i.claim_pc cur) in
  (* countdown to the compare; `pending` while it runs *)
  let count = wire 16 and pending = wire 1 in
  let compare_now = mux2 claim (i.settle ==:. 0) (pending &: (count ==:. 0)) in
  count
  <== reg_fb ~enable:(one 1) spec ~width:16 ~f:(fun cur ->
        mux2 claim (i.settle -:. 1) (mux2 (cur ==:. 0) cur (cur -:. 1)));
  pending
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        (i.enable &: mux2 claim (i.settle <>:. 0) (cur &: (count <>:. 0))));
  let mask = (i.pins_in ^: i.pins_out) &: i.pins_oe in
  let bad = compare_now &: (mask <>:. 0) in
  let good = compare_now &: (mask ==:. 0) in
  let in_episode = wire 1 and suppressed = wire 16 and dropped = wire 6 in
  let opens = bad &: (~:in_episode) in
  let closes = good &: in_episode in
  let want = opens |: closes in
  let pushed = want &: (~:(i.full)) in
  in_episode
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        i.enable &: mux2 opens vdd (mux2 closes gnd cur));
  suppressed
  <== reg_fb ~enable:(one 1) spec ~width:16 ~f:(fun cur ->
        mux2 opens (zero 16)
          (mux2 (bad &: in_episode &: (cur <>:. 0xFFFF)) (cur +:. 1) cur));
  dropped
  <== reg_fb ~enable:(one 1) spec ~width:6 ~f:(fun cur ->
        mux2 pushed (zero 6) (mux2 (want &: i.full &: (cur <>:. 63)) (cur +:. 1) cur));
  let body = mux2 opens (concat_msb [ mask; i.pins_in ]) suppressed in
  let record = concat_msb [ closes; pc; body; dropped; i.timestamp ] in
  (* pushed in the compare cycle itself (not registered), so `full` is never
     stale: two records on consecutive cycles see each other's fill *)
  { O.push = pushed; record }
