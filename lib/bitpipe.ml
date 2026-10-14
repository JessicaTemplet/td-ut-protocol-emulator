open Hardcaml
open Signal

(* ============================================================
   Bit pipe: generic serial-framing primitives, treated as ALU-style
   operators (not a USB or CAN block). One sampled line level goes in per
   `step`; per step the unit does, in hardware, what a software
   bit-banger spends ~10 instructions on:

     1. NRZI decode   data = (line == prev_line)   [optional]
     2. un-stuff      after `stuff_limit` consecutive bits of the run
                      polarity, the NEXT bit is a stuffed bit: it is
                      dropped (not delivered, not CRC'd) and must be the
                      opposite polarity, else the sticky `stuff_err` sets
     3. CRC           serial LFSR over the DELIVERED bits only
     4. byte assembly 8 delivered bits -> one byte (LSB- or MSB-first)

   Everything protocol-specific is configuration, loaded once (like the
   prescale) through the loader's config path -- UART/SPI/I2C programs
   simply never use the unit. USB low-speed and CAN are just two
   configurations of the same hardware:

     USB:  nrzi on, stuff after 6 ONES (zeros do not count),
           CRC16 poly 0x8005 reflected (host loads 0xA001), init 0xFFFF,
           residue 0xB001, LSB-first.
     CAN:  nrzi off, stuff after 5 identical bits (either polarity;
           the stuffed bit starts the next run), CRC15 poly 0x4599,
           not reflected, init 0, residue 0, MSB-first.

   Configuration, 9 bytes (index = byte number; the loader packs them into
   `cfg`, byte 0 in bits [7:0]):
     0: flags  [0] nrzi_en  [1] stuff_en  [2] stuff_count_both
               [3] crc_en   [4] crc_reflected  [5] msb_first
     1: [2:0] stuff_limit N (1..7)   [7:4] glitch-filter N (used by Dual,
               not by this unit)
     2: [3:0] CRC width - 1 (width 1..16)
        [7:4] crc_skip_bytes: the CRC stays at its init value until this
              many bytes have been delivered (USB: 2 = SYNC + PID, since
              the CRC covers the data stage only). 0 = CRC from the first bit.
     3,4: CRC polynomial (lo, hi). For reflected CRCs supply the already
               bit-reversed polynomial (USB CRC16: 0xA001).
     5,6: CRC init value (lo, hi)
     7,8: CRC residue: what the CRC register holds after a good packet
               (data + transmitted CRC) -- `crc_ok` compares against it, so
               no final inversion step is needed.
   All-zero configuration = every stage off: the unit degenerates to a
   plain byte assembler.

   `step` is one sample. `ctrl_reset` clears the stream state (run counter,
   bit/byte counters, stuff_err, CRC := init) and sets the NRZI history to
   `prev_init` (the idle line level). `ctrl_crc_init` reloads only the CRC
   (USB: the CRC covers the data stage, not SYNC/PID).

   `would_push` is true when a step right now would complete a byte; the
   engine stalls the instruction while the FIFO is full, exactly as for a
   pushing SHIFT_IO. It depends only on registered state, so the engine
   can use it to gate `step` without a combinational loop.
   ============================================================ *)

let cfg_bytes = 9
let cfg_bits = 8 * cfg_bytes

module I = struct
  type 'a t = {
    clk           : 'a;
    rst_n         : 'a;
    cfg           : 'a; [@bits 72]
    step          : 'a;
    line          : 'a;
    ctrl_reset    : 'a;
    ctrl_crc_init : 'a;
    prev_init     : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    byte_done  : 'a;
    byte_data  : 'a; [@bits 8]
    would_push : 'a;
    status     : 'a; [@bits 16]
    crc        : 'a; [@bits 16]
    crc_ok     : 'a;
    stuff_err  : 'a;
  } [@@deriving sexp_of, hardcaml]
end

let create (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clk ~clear:((~:) i.rst_n) () in
  let byte k = select i.cfg ((8 * k) + 7) (8 * k) in
  let bit s n = select s n n in
  let b0 = byte 0 and b1 = byte 1 and b2 = byte 2 in
  let nrzi_en = bit b0 0
  and stuff_en = bit b0 1
  and stuff_both = bit b0 2
  and crc_en = bit b0 3
  and crc_refl = bit b0 4
  and msb_first = bit b0 5 in
  let limit = select b1 2 0 in
  let crc_w1 = select b2 3 0 in
  let crc_skip = select b2 7 4 in
  let poly = concat_msb [ byte 4; byte 3 ] in
  let init = concat_msb [ byte 6; byte 5 ] in
  let residue = concat_msb [ byte 8; byte 7 ] in

  let prev = wire 1 in
  let run_cnt = wire 3 in
  let run_bit = wire 1 in
  let crc = wire 16 in
  let bitcnt = wire 3 in
  let acc = wire 8 in
  let nbytes = wire 7 in
  let stuff_err = wire 1 in

  (* 1. NRZI decode: no transition = 1, transition = 0 (USB/NRZI convention) *)
  let data = mux2 nrzi_en (~:(i.line ^: prev)) i.line in

  (* 2. un-stuffing. A stuffed bit must differ from the run polarity. *)
  let is_stuff = stuff_en &&: (limit <>:. 0) &&: (run_cnt ==: limit) in
  let delivered = ~:is_stuff in
  let stuff_bad = is_stuff &&: (data ==: run_bit) in
  let step_delivered = i.step &&: delivered in

  let cnt_inc = run_cnt +:. 1 in
  let same = (run_cnt <>:. 0) &&: (data ==: run_bit) in
  let next_cnt_data =
    mux2 stuff_both (mux2 same cnt_inc (of_int ~width:3 1)) (mux2 data cnt_inc (zero 3))
  in
  let next_bit_data = mux2 stuff_both (mux2 same run_bit data) vdd in
  let next_cnt_stuff = mux2 stuff_both (of_int ~width:3 1) (zero 3) in
  let next_bit_stuff = mux2 stuff_both data vdd in

  prev
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.ctrl_reset i.prev_init (mux2 i.step i.line cur));
  run_cnt
  <== reg_fb ~enable:(one 1) spec ~width:3 ~f:(fun cur ->
        mux2 i.ctrl_reset (zero 3)
          (mux2 i.step (mux2 is_stuff next_cnt_stuff next_cnt_data) cur));
  run_bit
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.ctrl_reset vdd
          (mux2 i.step (mux2 is_stuff next_bit_stuff next_bit_data) cur));
  stuff_err
  <== reg_fb ~enable:(one 1) spec ~width:1 ~f:(fun cur ->
        mux2 i.ctrl_reset gnd (cur |: (i.step &&: stuff_bad)));

  (* 3. CRC over delivered bits. `mask` keeps a width<16 register inside
     its width when shifting left. *)
  let mask = mux crc_w1 (List.init 16 (fun k -> of_int ~width:16 ((1 lsl (k + 1)) - 1))) in
  let crc_top = mux crc_w1 (List.init 16 (fun k -> select crc k k)) in
  let fb_refl = select crc 0 0 ^: data in
  let refl_next = srl crc 1 ^: mux2 fb_refl poly (zero 16) in
  let fb_left = crc_top ^: data in
  let left_next = (sll crc 1 &: mask) ^: mux2 fb_left poly (zero 16) in
  let crc_next = mux2 crc_refl refl_next left_next in
  (* the CRC only runs once `crc_skip` bytes have been delivered *)
  let crc_started = nbytes >=: uresize crc_skip 7 in
  crc
  <== reg_fb ~enable:(one 1) spec ~width:16 ~f:(fun cur ->
        mux2 (i.ctrl_reset |: i.ctrl_crc_init) init
          (mux2 (step_delivered &&: crc_en &&: crc_started) crc_next cur));

  (* 4. byte assembly *)
  let acc_next =
    mux2 msb_first (concat_msb [ select acc 6 0; data ]) (concat_msb [ data; select acc 7 1 ])
  in
  let byte_done = step_delivered &&: (bitcnt ==:. 7) in
  acc
  <== reg_fb ~enable:(one 1) spec ~width:8 ~f:(fun cur -> mux2 step_delivered acc_next cur);
  bitcnt
  <== reg_fb ~enable:(one 1) spec ~width:3 ~f:(fun cur ->
        mux2 i.ctrl_reset (zero 3) (mux2 step_delivered (cur +:. 1) cur));
  nbytes
  <== reg_fb ~enable:(one 1) spec ~width:7 ~f:(fun cur ->
        mux2 i.ctrl_reset (zero 7) (mux2 byte_done (cur +:. 1) cur));

  let crc_ok = crc ==: residue in
  (* status record pushed by PIPE_STATUS: bit 15 marks it as a status word
     (data bytes are zero-extended, so bit 15 is 0 for them) *)
  let status =
    concat_msb [ vdd; nbytes; zero 5; bitcnt ==:. 0; stuff_err; crc_ok ]
  in
  { O.byte_done
  ; byte_data = acc_next
  ; would_push = (bitcnt ==:. 7) &&: delivered
  ; status
  ; crc
  ; crc_ok
  ; stuff_err
  }
