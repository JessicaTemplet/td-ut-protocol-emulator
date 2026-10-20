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
   uses for pins. A write takes effect the next cycle.

   Pointer writes come from µE0 (PIPE_CTRL) and µE1 (PROFILE). Same
   rule: on a same-cycle conflict for one direction, µE1 wins.

   The glitch filter is a pin-level setting shared by both engines, so
   it always comes from profile 0 (byte 1 bits [7:4]), whichever profile
   is active.
   ============================================================ *)

let n_profiles = 4
let id_width = 2
let stride = 32
let index_width = 7
let profile_bytes = Bitpipe.cfg_bytes
let profile_bits = 8 * profile_bytes

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
    rx_cfg   : 'a; [@bits 128]
    tx_cfg   : 'a; [@bits 128]
    rx_id    : 'a; [@bits 2]
    tx_id    : 'a; [@bits 2]
    glitch_n : 'a; [@bits 4]
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
  { O.rx_cfg = mux rx_id profiles
  ; tx_cfg = mux tx_id profiles
  ; rx_id
  ; tx_id
  ; glitch_n = select profile0 15 12
  }
