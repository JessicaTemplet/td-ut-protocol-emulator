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

   This is the RECEIVE pipe. txpipe.ml is the transmit pipe: the same
   stages run backwards (byte shift-out, CRC append, stuff insertion,
   NRZI encode) from the same profile layout, using the shared helpers
   below, so one profile describes a protocol in both directions.

   Everything protocol-specific is configuration: a PROFILE in the
   profile table (profile_table.ml), loaded through the loader's config
   path or written at run time by µE1's CFG_WR. UART/SPI/I2C programs
   simply never use the unit. USB low-speed and CAN are just two
   configurations of the same hardware:

     USB:  nrzi on, stuff after 6 ONES (zeros do not count),
           CRC16 poly 0x8005 reflected (host loads 0xA001), init 0xFFFF,
           residue 0xB001, LSB-first.
     CAN:  nrzi off, stuff after 5 identical bits (either polarity;
           the stuffed bit starts the next run), CRC15 poly 0x4599,
           not reflected, init 0, residue 0, MSB-first.

   Profile layout, 24 bytes (byte k in bits [8k+7:8k]):
     0: flags  [0] nrzi_en  [1] stuff_en  [2] stuff_count_both
               [3] crc_en   [4] crc_reflected  [5] msb_first
               [6] CRC width - 1, bit 4 (widths 17..32)
               [7] crc_out_invert: the transmit pipe sends the CRC
                   complemented (USB, Ethernet); receive ignores it
     1: [2:0] stuff_limit N (1..7)   [7:4] glitch-filter N (profile 0
               only; used by Dual, not by this unit)
     2: [3:0] CRC width - 1, bits 3..0
        [7:4] crc_skip_bytes: the CRC stays at its init value until this
              many bytes have been delivered (USB: 2 = SYNC + PID, since
              the CRC covers the data stage only). 0 = CRC from the first bit.
     3,4:   CRC polynomial bits 15..0 (lo, hi). For reflected CRCs supply
            the already bit-reversed polynomial (USB CRC16: 0xA001).
     5,6:   CRC init bits 15..0
     7,8:   CRC residue bits 15..0: what the CRC register holds after a
            good packet (data + transmitted CRC) -- `crc_ok` compares
            against it, so no final inversion step is needed.
     9,10:  CRC polynomial bits 31..16
     11,12: CRC init bits 31..16
     13,14: CRC residue bits 31..16
     15:    reserved (0)
     Bit-clock recovery (clock_recovery.ml; receive only):
     16: [0] rec_en  [3:1] the pin it tracks  [6:4] gain shift: an edge
               moves the phase by (error >> shift), 0 = snap to the edge
               [7] reserved (0)
     17:    bit period, fractional part (1/256 cycle)
     18,19: bit period, integer cycles (12 bits; [15:12] reserved, 0)
     20:    acceptance window in whole cycles: an edge further than this
            from where a bit boundary is expected is ignored. 0 = accept
            every edge.
     21: [0] freq_en: also learn the sender's bit period  [3:1] its gain
            shift: an edge moves the period estimate by (error >> shift)
            [7:4] reserved (0)
     22..23: reserved (0)
   Bytes 0..8 are the original 9-byte configuration, unchanged, so every
   configuration written before the profile table still means the same
   thing (bytes 9..15 zero = a CRC of at most 16 bits; byte 16 zero = no
   clock recovery).
   All-zero profile = every stage off: the unit degenerates to a plain
   byte assembler (and the transmit pipe to a plain LSB-first shifter).

   `step` is one sample. `ctrl_reset` clears the stream state (run counter,
   bit/byte counters, stuff_err, CRC := init) and sets the NRZI history to
   `prev_init` (the idle line level). `ctrl_crc_init` reloads only the CRC
   (USB: the CRC covers the data stage, not SYNC/PID).

   `would_push` is true when a step right now would complete a byte; the
   engine stalls the instruction while the FIFO is full, exactly as for a
   pushing SHIFT_IO. It depends only on registered state, so the engine
   can use it to gate `step` without a combinational loop.
   ============================================================ *)

let cfg_bytes = 24
let cfg_bits = 8 * cfg_bytes
let crc_bits = 32

(* ---- profile decoding, shared with txpipe.ml ---- *)
type cfg =
  { nrzi_en : Signal.t
  ; stuff_en : Signal.t
  ; stuff_both : Signal.t
  ; crc_en : Signal.t
  ; crc_refl : Signal.t
  ; msb_first : Signal.t
  ; crc_out_invert : Signal.t
  ; limit : Signal.t (* 3 bits *)
  ; crc_w1 : Signal.t (* 5 bits: CRC width - 1 *)
  ; crc_skip : Signal.t (* 4 bits *)
  ; poly : Signal.t (* 32 bits *)
  ; init : Signal.t
  ; residue : Signal.t
  ; rec_en : Signal.t
  ; rec_pin : Signal.t (* 3 bits *)
  ; rec_gain : Signal.t (* 3 bits *)
  ; rec_period : Signal.t (* 20 bits, 12.8 fixed point *)
  ; rec_window : Signal.t (* 8 bits, whole cycles *)
  ; rec_freq_en : Signal.t
  ; rec_fshift : Signal.t (* 3 bits *)
  }

let decode_cfg cfg =
  let byte k = select cfg ((8 * k) + 7) (8 * k) in
  let bit s n = select s n n in
  let b0 = byte 0 and b1 = byte 1 and b2 = byte 2 in
  let word16 lo = concat_msb [ byte (lo + 1); byte lo ] in
  { nrzi_en = bit b0 0
  ; stuff_en = bit b0 1
  ; stuff_both = bit b0 2
  ; crc_en = bit b0 3
  ; crc_refl = bit b0 4
  ; msb_first = bit b0 5
  ; crc_out_invert = bit b0 7
  ; limit = select b1 2 0
  ; crc_w1 = concat_msb [ bit b0 6; select b2 3 0 ]
  ; crc_skip = select b2 7 4
  ; poly = concat_msb [ word16 9; word16 3 ]
  ; init = concat_msb [ word16 11; word16 5 ]
  ; residue = concat_msb [ word16 13; word16 7 ]
  ; rec_en = bit (byte 16) 0
  ; rec_pin = select (byte 16) 3 1
  ; rec_gain = select (byte 16) 6 4
  ; rec_period = concat_msb [ select (byte 19) 3 0; byte 18; byte 17 ]
  ; rec_window = byte 20
  ; rec_freq_en = bit (byte 21) 0
  ; rec_fshift = select (byte 21) 3 1
  }

(* The run-length rule both directions share. A stuff bit is due when the
   run has reached `limit`. For a delivered data bit `data` the run either
   grows or restarts; a stuff bit restarts it (USB: a stuffed 0 is not a 1;
   CAN: the stuffed bit starts the next run). Returns (stuff_due,
   next count/bit after a data bit, next count/bit after a stuff bit). *)
let stuff_rule c ~run_cnt ~run_bit ~data =
  let stuff_due = c.stuff_en &&: (c.limit <>:. 0) &&: (run_cnt ==: c.limit) in
  let cnt_inc = run_cnt +:. 1 in
  let same = (run_cnt <>:. 0) &&: (data ==: run_bit) in
  let next_cnt_data =
    mux2 c.stuff_both (mux2 same cnt_inc (of_int ~width:3 1)) (mux2 data cnt_inc (zero 3))
  in
  let next_bit_data = mux2 c.stuff_both (mux2 same run_bit data) vdd in
  let next_cnt_stuff = mux2 c.stuff_both (of_int ~width:3 1) (zero 3) in
  let next_bit_stuff = mux2 c.stuff_both data vdd in
  stuff_due, (next_cnt_data, next_bit_data), (next_cnt_stuff, next_bit_stuff)

(* One serial CRC step over `data`. `mask` keeps a register narrower than
   32 bits inside its width when shifting left. *)
let crc_mask c = mux c.crc_w1 (List.init crc_bits (fun k -> of_int ~width:crc_bits ((1 lsl (k + 1)) - 1)))
let crc_top c crc = mux c.crc_w1 (List.init crc_bits (fun k -> select crc k k))

let crc_step c ~crc ~data =
  let fb_refl = select crc 0 0 ^: data in
  let refl_next = srl crc 1 ^: mux2 fb_refl c.poly (zero crc_bits) in
  let fb_left = crc_top c crc ^: data in
  let left_next = (sll crc 1 &: crc_mask c) ^: mux2 fb_left c.poly (zero crc_bits) in
  mux2 c.crc_refl refl_next left_next

module I = struct
  type 'a t = {
    clk           : 'a;
    rst_n         : 'a;
    cfg           : 'a; [@bits 192]
    step          : 'a;
    line          : 'a;
    ctrl_reset    : 'a;
    ctrl_crc_init : 'a;
    prev_init     : 'a;
    margin        : 'a; [@bits 5] (* clock recovery's timing margin, for the status word *)
  } [@@deriving sexp_of, hardcaml]
end

module O = struct
  type 'a t = {
    byte_done  : 'a;
    byte_data  : 'a; [@bits 8]
    would_push : 'a;
    status     : 'a; [@bits 16]
    crc        : 'a; [@bits 32]
    crc_ok     : 'a;
    stuff_err  : 'a;
  } [@@deriving sexp_of, hardcaml]
end

let create (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clk ~clear:((~:) i.rst_n) () in
  let c = decode_cfg i.cfg in

  let prev = wire 1 in
  let run_cnt = wire 3 in
  let run_bit = wire 1 in
  let crc = wire crc_bits in
  let bitcnt = wire 3 in
  let acc = wire 8 in
  let nbytes = wire 7 in
  let stuff_err = wire 1 in

  (* 1. NRZI decode: no transition = 1, transition = 0 (USB/NRZI convention) *)
  let data = mux2 c.nrzi_en (~:(i.line ^: prev)) i.line in

  (* 2. un-stuffing. A stuffed bit must differ from the run polarity. *)
  let is_stuff, (next_cnt_data, next_bit_data), (next_cnt_stuff, next_bit_stuff) =
    stuff_rule c ~run_cnt ~run_bit ~data
  in
  let delivered = ~:is_stuff in
  let stuff_bad = is_stuff &&: (data ==: run_bit) in
  let step_delivered = i.step &&: delivered in

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

  (* 3. CRC over delivered bits, once `crc_skip` bytes have been delivered *)
  let crc_started = nbytes >=: uresize c.crc_skip 7 in
  crc
  <== reg_fb ~enable:(one 1) spec ~width:crc_bits ~f:(fun cur ->
        mux2 (i.ctrl_reset |: i.ctrl_crc_init) c.init
          (mux2 (step_delivered &&: c.crc_en &&: crc_started) (crc_step c ~crc ~data) cur));

  (* 4. byte assembly *)
  let acc_next =
    mux2 c.msb_first (concat_msb [ select acc 6 0; data ]) (concat_msb [ data; select acc 7 1 ])
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

  let crc_ok = crc ==: c.residue in
  (* status record pushed by PIPE_STATUS: bit 15 marks it as a status word
     (data bytes are zero-extended, so bit 15 is 0 for them) *)
  let status =
    concat_msb [ vdd; nbytes; i.margin; bitcnt ==:. 0; stuff_err; crc_ok ]
  in
  { O.byte_done
  ; byte_data = acc_next
  ; would_push = (bitcnt ==:. 7) &&: delivered
  ; status
  ; crc
  ; crc_ok
  ; stuff_err
  }
