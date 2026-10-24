open Hardcaml
open Signal

(* ============================================================
   Transmit pipe: the receive pipe (bitpipe.ml) run backwards, from the
   same profile layout, so one profile describes a protocol in both
   directions. One `step` (one µE0 EMIT_TX) produces one LINE bit:

     1. byte shift-out  the next bit of the current byte (LSB- or
                        MSB-first). When the byte is used up the next one
                        is taken from the TX FIFO in the same step
                        (auto-load), so a program never counts bits to
                        know when to fetch.
     2. CRC             the LFSR runs over the data bits, after
                        `crc_skip_bytes` bytes. After `ctrl_crc_append`
                        the bit source switches to the CRC register itself
                        for crc_width bits (complemented if the profile's
                        crc_out_invert is set).
     3. stuff insert    once the run reaches `stuff_limit`, the next step
                        sends the stuff bit (the opposite of the run) and
                        takes nothing from the byte or the CRC. The
                        program still issues exactly one EMIT_TX per line
                        bit; it never needs to know where stuffing landed.
     4. NRZI encode     a 1 holds the line, a 0 toggles it   [optional]

   All-zero profile: a plain LSB-first shift register (UART). Set
   msb_first alone for SPI. That is what the existing protocols use.

   Packet end: each FIFO word carries a `last` flag (bit 8). `more` is low
   once the last byte's final bit has gone out, nothing is being appended
   and no stuff bit is owed -- µE0 loops `EMIT_TX` while `more` (its flag
   branch, engine.ml), appends the CRC, loops again, then sends the
   protocol's end-of-packet with EMIT_STATE. A stream without `last` flags
   (UART, SPI) keeps `more` high and the program counts bits itself.

   `would_stall` (registered state and the FIFO's `empty` only): a step now
   needs a new byte and the FIFO is empty. µE0 holds the EMIT_TX at its pc
   until µE1 has pushed one, the same contract as a pushing SHIFT_IO on a
   full receive FIFO. For a protocol with strict bit timing that is an
   underrun, which the program prevents by letting µE1 run ahead (4 FIFO
   entries plus the byte in flight).
   ============================================================ *)

module I = struct
  type 'a t = {
    clk              : 'a;
    rst_n            : 'a;
    cfg              : 'a; [@bits 192]
    step             : 'a;
    ctrl_reset       : 'a;
    ctrl_crc_append  : 'a;
    prev_init        : 'a;
    fifo_data        : 'a; [@bits 16]
    fifo_empty       : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    line        : 'a;
    would_stall : 'a;
    fifo_pop    : 'a;
    more        : 'a;
    crc         : 'a; [@bits 32]
  } [@@deriving sexp_of, hardcaml]
end

let crc_bits = Bitpipe.crc_bits

let create (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clk ~clear:((~:) i.rst_n) () in
  let c = Bitpipe.decode_cfg i.cfg in

  let sreg = wire 8 in
  let bits_left = wire 4 in
  let cur_last = wire 1 in
  let nbytes = wire 7 in
  let crc = wire crc_bits in
  let crc_mode = wire 1 in
  let crc_left = wire 6 in
  let run_cnt = wire 3 in
  let run_bit = wire 1 in
  let prev = wire 1 in

  (* which source this step's bit comes from *)
  let stuff_due, _, _ = Bitpipe.stuff_rule c ~run_cnt ~run_bit ~data:gnd in
  let need_byte = (bits_left ==:. 0) &&: (~:crc_mode) &&: (~:stuff_due) in
  let would_stall = need_byte &&: i.fifo_empty in
  let fifo_pop = i.step &&: need_byte in

  let byte_src = mux2 need_byte (select i.fifo_data 7 0) sreg in
  let byte_bit = mux2 c.msb_first (select byte_src 7 7) (select byte_src 0 0) in
  let crc_out = mux2 c.crc_refl (select crc 0 0) (Bitpipe.crc_top c crc) ^: c.crc_out_invert in
  (* the stuff bit is the opposite of the run: a 0 after a run of 1s (USB,
     where run_bit is always 1), the other polarity for CAN *)
  let data = mux2 stuff_due (~:run_bit) (mux2 crc_mode crc_out byte_bit) in
  let line = mux2 c.nrzi_en (mux2 data prev (~:prev)) data in

  let _, (next_cnt_data, next_bit_data), (next_cnt_stuff, next_bit_stuff) =
    Bitpipe.stuff_rule c ~run_cnt ~run_bit ~data
  in
  let step_byte = i.step &&: (~:stuff_due) &&: (~:crc_mode) in
  let step_crc = i.step &&: (~:stuff_due) &&: crc_mode in
  let bits_now = mux2 need_byte (of_int ~width:4 8) bits_left in
  let byte_done = step_byte &&: (bits_now ==:. 1) in

  prev
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.ctrl_reset i.prev_init (mux2 i.step line cur));
  run_cnt
  <== reg_fb ~enable:(one 1) spec ~width:3 ~f:(fun cur ->
        mux2 i.ctrl_reset (zero 3)
          (mux2 i.step (mux2 stuff_due next_cnt_stuff next_cnt_data) cur));
  run_bit
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.ctrl_reset vdd
          (mux2 i.step (mux2 stuff_due next_bit_stuff next_bit_data) cur));

  sreg
  <== reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur ->
        mux2 step_byte (mux2 c.msb_first (sll byte_src 1) (srl byte_src 1)) cur);
  bits_left
  <== reg_fb ~enable:(one 1) spec ~width:4 ~f:(fun cur ->
        mux2 i.ctrl_reset (zero 4) (mux2 step_byte (bits_now -:. 1) cur));
  cur_last
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.ctrl_reset gnd (mux2 fifo_pop (select i.fifo_data 8 8) cur));
  nbytes
  <== reg_fb ~enable:(one 1) spec ~width:7 ~f:(fun cur ->
        mux2 i.ctrl_reset (zero 7)
          (mux2 (byte_done &&: (cur <>:. 127)) (cur +:. 1) cur));

  (* CRC: runs over data bits once `crc_skip` bytes have gone out; during
     append it shifts its own contents out instead *)
  let crc_started = nbytes >=: uresize c.crc_skip 7 in
  let crc_shift = mux2 c.crc_refl (srl crc 1) (sll crc 1 &: Bitpipe.crc_mask c) in
  crc
  <== reg_fb ~enable:(one 1) spec ~width:crc_bits ~f:(fun cur ->
        mux2 i.ctrl_reset c.init
          (mux2 step_crc crc_shift
             (mux2 (step_byte &&: c.crc_en &&: crc_started) (Bitpipe.crc_step c ~crc ~data) cur)));
  crc_left
  <== reg_fb ~enable:(one 1) spec ~width:6 ~f:(fun cur ->
        mux2 i.ctrl_reset (zero 6)
          (mux2 i.ctrl_crc_append (uresize c.crc_w1 6 +:. 1) (mux2 step_crc (cur -:. 1) cur)));
  crc_mode
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.ctrl_reset gnd
          (mux2 i.ctrl_crc_append vdd (mux2 (step_crc &&: (crc_left ==:. 1)) gnd cur)));

  let more = stuff_due |: crc_mode |: (bits_left <>:. 0) |: (~:cur_last) in
  { O.line; would_stall; fifo_pop; more; crc }
