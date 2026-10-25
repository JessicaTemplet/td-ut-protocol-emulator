open Hardcaml
open Signal

(* ============================================================
   Profile table: the bit-pipe configuration store, shared by the
   receive pipe (bitpipe.ml, driven by µE0's PIPE_BIT) and the transmit
   pipe (txpipe.ml, driven by µE0's EMIT_TX).

   A profile is one complete pipe configuration (framing, stuffing, CRC
   up to 32 bits; see bitpipe.ml for the byte layout). The table holds
   `n_profiles` of them. The receive and transmit pipes each read the
   profile their own pointer selects, so the two directions can run
   different protocols at the same time (protocol bridging), and a
   program can switch a direction to another profile in one instruction
   (USB: CRC5 tokens and CRC16 data packets on the same link).

   Address map (7-bit byte index, the loader's auto-incrementing
   cfg_sel index and µE1's CFG_WR target):
     profile p, byte k  ->  index 32*p + k
   Only bytes 0..profile_bytes-1 of each 32-byte slot are stored;
   writes to the rest are ignored. Profile 0 byte k is index k, so a
   host that loads the original 9 configuration bytes still configures
   exactly what it did before (and both pointers reset to profile 0).

   Two write ports, which never collide in practice: the loader's
   (pre-run only) and µE1's CFG_WR (post-run only). If both fire in the
   same cycle µE1 wins, the same "protocol layer wins" rule tt_core.ml
   uses for pins. A write reaches the pipes two cycles later (the byte
   register, then the registered profile output).

   Pointer writes come from µE0 (PIPE_CTRL) and µE1 (PROFILE). Same
   rule: on a same-cycle conflict for one direction, µE1 wins.

   The glitch filter is a pin-level setting shared by both engines, so
   it always comes from profile 0 (byte 1 bits [7:4]), whichever profile
   is active.

   One more pin-level byte sits right after profile 0, at index 24
   (`loopback_index`): the loopback mask. A set bit k routes the chip's own
   output for uio pin k back into its input and stops driving the pad
   (tt_core.ml), so a program can transmit and receive on the same pin
   with nothing attached. Written like any table byte: by the loader (the
   25th configuration byte) or by µE1's CFG_WR at run time. Resets to 0.
   ============================================================ *)

let n_profiles = 4
let id_width = 2
let stride = 32
let index_width = 7
let profile_bytes = Bitpipe.cfg_bytes
let profile_bits = 8 * profile_bytes
let loopback_index = profile_bytes

(* Shadow mode (shadow.ml), more pin-level bytes after the loopback mask:
   the mode byte (bit 0 / 1: µE0 / µE1 in Shadow, pads released and every
   drive checked instead; bit 3 / 4: µE0 / µE1 check their own drives while
   still driving; bit 2: trace readout on ui_in/uo_out, tt_core.ml), then
   each engine's settle delay, 16 bits little-endian. *)
let shadow_mode_index = loopback_index + 1
let e0_settle_index = loopback_index + 2
let e1_settle_index = loopback_index + 4
let mode_e0_shadow = 0x01
let mode_e1_shadow = 0x02
let mode_trace_readout = 0x04
let mode_e0_check = 0x08
let mode_e1_check = 0x10

(* Cycles from a pointer write (µE0's PIPE_CTRL, µE1's PROFILE) to the new
   profile reaching the pipes: the pointer register, then the registered
   profile output (registered for timing: the 4:1 x 192-bit select fed the
   clock recovery's arithmetic and the CRC in the same cycle). A control
   that has to act on the NEW profile, such as a CRC reload, a stream reset
   or the NRZI idle level, is delayed by exactly this much (`after_select`). *)
let select_latency = 2

let after_select spec s =
  let rec go n s = if n = 0 then s else go (n - 1) (Signal.reg spec s) in
  go select_latency s

(* High for the select_latency cycles after a pointer write: the cycles on
   which the pipes still see the old profile, and the cycle on which a
   control delayed by `after_select` (a stream reset, a CRC reload) lands.
   µE0 holds any pipe instruction while it is high, so a PIPE_BIT or EMIT_TX
   issued right after a switch runs on the new profile and after the reset,
   never before or into it: instruction order, not cycle count, decides. *)
let settling spec sel =
  let rec go n s acc = if n = 0 then acc else
      let s = Signal.reg spec s in go (n - 1) s Signal.(acc |: s) in
  go select_latency sel Signal.gnd

module I = struct
  type 'a t = {
    clk         : 'a;
    rst_n       : 'a;
    load_we     : 'a;
    load_addr   : 'a; [@bits 7]
    load_data   : 'a; [@bits 8]
    rt_we       : 'a;
    rt_addr     : 'a; [@bits 7]
    rt_data     : 'a; [@bits 8]
    e0_sel_rx   : 'a;
    e0_sel_tx   : 'a;
    e0_sel_id   : 'a; [@bits 2]
    e1_sel_rx   : 'a;
    e1_sel_tx   : 'a;
    e1_sel_id   : 'a; [@bits 2]
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    rx_cfg   : 'a; [@bits 192]
    tx_cfg   : 'a; [@bits 192]
    rx_id    : 'a; [@bits 2]
    tx_id    : 'a; [@bits 2]
    glitch_n : 'a; [@bits 4]
    loopback : 'a; [@bits 8]
    shadow_mode : 'a; [@bits 8]
    e0_settle : 'a; [@bits 16]
    e1_settle : 'a; [@bits 16]
  } [@@deriving sexp_of, hardcaml]
end

let create (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clk ~clear:((~:) i.rst_n) () in
  let we = i.load_we |: i.rt_we in
  let addr = mux2 i.rt_we i.rt_addr i.load_addr in
  let data = mux2 i.rt_we i.rt_data i.load_data in
  let byte_reg p k =
    reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
      mux2 (we &&: (addr ==:. (stride * p) + k)) data cur)
  in
  (* profile p as a flat vector, byte 0 in bits [7:0] *)
  let profiles =
    List.init n_profiles (fun p ->
      concat_msb (List.rev (List.init profile_bytes (fun k -> byte_reg p k))))
  in
  let pointer ~e0 ~e1 =
    reg_fb ~enable:(one 1) spec ~width:id_width ~f:(fun cur ->
      mux2 e1 i.e1_sel_id (mux2 e0 i.e0_sel_id cur))
  in
  let rx_id = pointer ~e0:i.e0_sel_rx ~e1:i.e1_sel_rx in
  let tx_id = pointer ~e0:i.e0_sel_tx ~e1:i.e1_sel_tx in
  let profile0 = List.hd profiles in
  let pin_byte index =
    reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur -> mux2 (we &&: (addr ==:. index)) data cur)
  in
  let loopback = pin_byte loopback_index in
  let settle index = concat_msb [ pin_byte (index + 1); pin_byte index ] in
  { O.rx_cfg = reg spec (mux rx_id profiles)
  ; tx_cfg = reg spec (mux tx_id profiles)
  ; rx_id
  ; tx_id
  ; glitch_n = select profile0 15 12
  ; loopback
  ; shadow_mode = pin_byte shadow_mode_index
  ; e0_settle = settle e0_settle_index
  ; e1_settle = settle e1_settle_index
  }
