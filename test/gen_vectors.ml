open Tt_core

(* Emits gl_test/spi_vectors.json: the SPI-master microcode words that
   test_tt_um_dual_spi.ml runs through the Cyclesim model, in a form the
   cocotb testbench (gl_test/test.py) can replay against the REAL shipped
   Verilog (RTL with the hard SRAM macro model, and the post-hardening
   gate-level netlist). Regenerate with run_gen_vectors.sh; the committed
   JSON is what cocotb reads, so cocotb needs no OCaml toolchain.

   The program definitions are the same ones test_tt_um_dual_spi.ml uses
   (each test exe is self-contained by project convention); if you change
   the microcode there, change it here and regenerate. *)

let half_period = 4
let master_tx_byte = 0xA5
let slave_tx_byte = 0x96
let sclk = 0
let mosi = 1
let miso = 2
let cs_n = 3
let data_flag = 4

let spi_master_prog tx_byte =
  let bits = List.init 8 (fun i -> (tx_byte lsr (7 - i)) land 1 = 1) in
  Engine.[ emit_state ~pin:cs_n ~level:false
         ; wait_edge ~pin:0 ~falling:true ~payload:half_period
         ]
  @ List.concat
      (List.mapi
         (fun i bit ->
           let last = i = 7 in
           Engine.
             [ emit_state ~pin:mosi ~level:bit
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; emit_state ~pin:sclk ~level:true
             ; (if last then shift_in_push ~pin:miso else shift_in ~pin:miso)
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; emit_state ~pin:sclk ~level:false
             ])
         bits)
  @ Engine.[ emit_state ~pin:cs_n ~level:true
           (* HALT: an edge-only wait (payload 0) on a pin nothing ever
              toggles. Programs must not fall off the end: unwritten SRAM
              is arbitrary on silicon (X in simulation), and Cyclesim's
              zero-filled RAM is what hides that. *)
           ; wait_edge ~pin:7 ~falling:true ~payload:0
           ]

let protocol_prog =
  Protocol_engine.
    [ fifo_pop_instr
    ; branch_word ~bit:7 ~branch_if_one:true ~target:4
    ; emit_state ~pin:data_flag ~level:false
    ; branch_word ~bit:7 ~branch_if_one:false ~target:5
    ; emit_state ~pin:data_flag ~level:true
    ; fifo_pop_instr
    ]

let json_list l = "[" ^ String.concat ", " (List.map string_of_int l) ^ "]"

(* ---- I2C master READ (same microcode as test_tt_um_dual_i2c.ml) ---- *)
let sda = 0
let scl = 1
let i2c_addr_rw_byte = 0xB5
let i2c_slave_data_byte = 0x6C (* MSB=0 -> DATA_FLAG ends up low *)
let i2c_data_flag = 2
let stop_addr = 105

let i2c_master_read_prog =
  let addr_bits = List.init 8 (fun i -> (i2c_addr_rw_byte lsr (7 - i)) land 1 = 1) in
  let drive_bit ~pin ~bit = if bit then Engine.release_pin ~pin else Engine.emit_state ~pin ~level:false in
  Engine.
    [ release_pin ~pin:sda
    ; release_pin ~pin:scl
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; emit_state ~pin:sda ~level:false
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; emit_state ~pin:scl ~level:false
    ]
  @ List.concat_map
      (fun bit ->
        Engine.
          [ drive_bit ~pin:sda ~bit
          ; wait_edge ~pin:0 ~falling:true ~payload:half_period
          ; release_pin ~pin:scl
          ; wait_edge ~pin:0 ~falling:true ~payload:half_period
          ; emit_state ~pin:scl ~level:false
          ])
      addr_bits
  @ Engine.
      [ release_pin ~pin:sda
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; release_pin ~pin:scl
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; branch_cond ~pin:sda ~branch_if_high:true ~target:stop_addr
      ; emit_state ~pin:scl ~level:false
      ]
  @ List.concat
      (List.init 8 (fun i ->
           let last = i = 7 in
           Engine.
             [ release_pin ~pin:sda
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; release_pin ~pin:scl
             ; (if last then shift_in_push ~pin:sda else shift_in ~pin:sda)
             ; wait_edge ~pin:0 ~falling:true ~payload:half_period
             ; emit_state ~pin:scl ~level:false
             ]))
  @ Engine.
      [ release_pin ~pin:sda
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; release_pin ~pin:scl
      ; wait_edge ~pin:0 ~falling:true ~payload:half_period
      ; emit_state ~pin:scl ~level:false
      ]
  @ (* stop_addr: *)
  Engine.
    [ emit_state ~pin:sda ~level:false
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; release_pin ~pin:scl
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    ; release_pin ~pin:sda
    ; wait_edge ~pin:0 ~falling:true ~payload:half_period
    (* HALT (see the SPI program): stops the engine falling into unwritten SRAM *)
    ; wait_edge ~pin:7 ~falling:true ~payload:0
    ]

(* same uE1 program as [protocol_prog] but DATA_FLAG is pin 2 here *)
let i2c_protocol_prog =
  Protocol_engine.
    [ fifo_pop_instr
    ; branch_word ~bit:7 ~branch_if_one:true ~target:4
    ; emit_state ~pin:i2c_data_flag ~level:false
    ; branch_word ~bit:7 ~branch_if_one:false ~target:5
    ; emit_state ~pin:i2c_data_flag ~level:true
    ; fifo_pop_instr
    ]

(* ---- USB low-speed receive (same programs/config/timing as test_usb_rx.ml;
   B = 32 cycles/bit, t0 = 12, t_wait = 27 from its calibration) ---- *)
let usb_b = 32
let usb_t0 = 12
let usb_t_wait = 27
let usb_dm = 0
let usb_dp = 1
let usb_flag_ok = 2
let usb_flag_done = 3

let usb_program =
  Engine.
    [ pipe_ctrl ~reset:true ~prev_level:true ~crc_init:false
    ; wait_edge ~pin:usb_dm ~falling:true ~payload:0
    ; wait_edge ~pin:usb_dm ~falling:true ~payload:usb_t0
    ; branch_cond ~pin:usb_dm ~branch_if_high:false ~target:5
    ; wait_edge ~pin:usb_dm ~falling:true ~payload:usb_t_wait
    ; branch_cond ~pin:usb_dp ~branch_if_high:true ~target:8
    ; branch_cond ~pin:usb_dm ~branch_if_high:true ~target:11
    ; branch_cond ~pin:usb_dm ~branch_if_high:false ~target:13
    ; release_pin ~pin:7
    ; pipe_bit ~pin:usb_dm
    ; branch_cond ~pin:usb_dm ~branch_if_high:false ~target:4
    ; pipe_bit ~pin:usb_dm
    ; branch_cond ~pin:usb_dm ~branch_if_high:true ~target:4
    ; pipe_status
    ; wait_edge ~pin:7 ~falling:true ~payload:0
    ]

let usb_protocol_prog =
  Protocol_engine.
    [ fifo_pop_instr
    ; branch_word ~bit:15 ~branch_if_one:true ~target:3
    ; branch_word ~bit:15 ~branch_if_one:false ~target:0
    ; branch_word ~bit:0 ~branch_if_one:false ~target:8
    ; branch_word ~bit:1 ~branch_if_one:true ~target:8
    ; branch_word ~bit:2 ~branch_if_one:false ~target:8
    ; emit_state ~pin:usb_flag_ok ~level:true
    ; branch_word ~bit:15 ~branch_if_one:true ~target:9
    ; emit_state ~pin:usb_flag_ok ~level:false
    ; emit_state ~pin:usb_flag_done ~level:true
    ; fifo_pop_instr
    ]

let usb_cfg_bytes =
  let lo x = x land 0xFF and hi x = (x lsr 8) land 0xFF in
  [ 0b011011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

let bits_of_byte_lsb x = List.init 8 (fun i -> (x lsr i) land 1)

let usb_crc16 bytes =
  let crc = ref 0xFFFF in
  List.iter
    (fun by ->
      List.iter
        (fun bit ->
          let fb = (!crc land 1) lxor bit in
          crc := !crc lsr 1;
          if fb = 1 then crc := !crc lxor 0xA001)
        (bits_of_byte_lsb by))
    bytes;
  lnot !crc land 0xFFFF

let usb_stuff bits =
  let out = ref [] and ones = ref 0 in
  List.iter
    (fun x ->
      out := x :: !out;
      if x = 1 then incr ones else ones := 0;
      if !ones = 6 then (out := 0 :: !out; ones := 0))
    bits;
  List.rev !out

let usb_nrzi bits =
  let level = ref 1 in
  List.map (fun x -> if x = 0 then level := 1 - !level; !level) bits

(* symbols: 1 = J, 0 = K, 2 = SE0; ends with EOP (SE0 SE0 J) *)
let usb_packet_symbols payload =
  let c = usb_crc16 payload in
  let bits =
    bits_of_byte_lsb 0x80 @ bits_of_byte_lsb 0xC3
    @ List.concat_map bits_of_byte_lsb (payload @ [ c land 0xFF; (c lsr 8) land 0xFF ])
  in
  usb_nrzi (usb_stuff bits) @ [ 2; 2; 1 ]

let usb_payload = [ 0x80; 0x06; 0x00; 0x01; 0x00; 0x00; 0x40; 0x00 ] (* GET_DESCRIPTOR *)

(* ---- USB low-speed TRANSMIT (same program and profile as
   test_tt_um_dual_usb_tx.ml; 33 cycles a bit, i.e. 1.5 Mbit/s at 50 MHz).
   µE1 decides the packet at run time (TX_PUSH, last byte flagged); µE0
   sends it with one EMIT_TX per line bit, D+ the complement of D- in the
   same cycle, appends the CRC, then the EOP. ---- *)
let usb_tx_t = 30 (* WAIT payload; a bit cell is t + 3 cycles *)
let usb_tx_cell = usb_tx_t + 3

(* USB profile with crc_out_invert (bit 7): the CRC goes out complemented *)
let usb_tx_cfg_bytes =
  let lo x = x land 0xFF and hi x = (x lsr 8) land 0xFF in
  [ 0b1001_1011; 6; (2 lsl 4) lor 15; lo 0xA001; hi 0xA001; lo 0xFFFF; hi 0xFFFF; lo 0xB001; hi 0xB001 ]

let usb_tx_program =
  let t = usb_tx_t in
  let wait n = Engine.wait_edge ~pin:7 ~falling:true ~payload:n in
  Engine.
    [ pipe_ctrl_ext ~tx_reset:true ~prev_level:true ()
    ; emit_state ~pin:usb_dm ~level:true (* J *)
    ; emit_state ~pin:usb_dp ~level:false
    ; wait t (* 3: data loop *)
    ; emit_tx ~differential:true ~pin:usb_dm ()
    ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:3
    ; pipe_ctrl_ext ~tx_crc:true ()
    ; wait (t - 1) (* the pipe_ctrl costs the cycle *)
    ; emit_tx ~differential:true ~pin:usb_dm ()
    ; release_pin ~pin:7 (* no-op standing in for the branch *)
    ; wait t (* 10: CRC loop *)
    ; emit_tx ~differential:true ~pin:usb_dm ()
    ; branch_flag ~flag:flag_tx_more ~branch_if_set:true ~target:10
    ; wait t
    ; emit_state ~pin:usb_dm ~level:false (* SE0 *)
    ; emit_state ~pin:usb_dp ~level:false
    ; wait ((2 * t) + 4) (* two cells of SE0 *)
    ; emit_state ~pin:usb_dm ~level:true (* J *)
    ; wait t
    ; release_pin ~pin:usb_dm
    ; release_pin ~pin:usb_dp
    ; wait_edge ~pin:7 ~falling:true ~payload:0 (* halt *)
    ]

let usb_tx_packet = 0x80 :: 0xC3 :: usb_payload (* SYNC, DATA0, GET_DESCRIPTOR *)

let usb_tx_protocol_prog =
  let n = List.length usb_tx_packet in
  List.mapi (fun k b -> Protocol_engine.tx_push ~last:(k = n - 1) b) usb_tx_packet
  @ [ Protocol_engine.fifo_pop_instr (* halt *) ]

(* the expected line, one symbol per bit cell: 1 = J, 0 = K, 2 = SE0 *)
let usb_tx_symbols =
  let c = usb_crc16 usb_payload in
  usb_nrzi (usb_stuff (List.concat_map bits_of_byte_lsb (usb_tx_packet @ [ c land 0xFF; (c lsr 8) land 0xFF ])))
  @ [ 2; 2; 1 ]

let () =
  match Array.to_list Sys.argv with
  | [ _; "usb_tx" ] ->
    Printf.printf
      "{\n  \"prescale\": 0,\n  \"cell\": %d,\n  \"cfg\": %s,\n  \"pins\": {\"dm\": %d, \"dp\": %d},\n  \"phys\": %s,\n  \"protocol\": %s,\n  \"symbols\": %s\n}\n"
      usb_tx_cell (json_list usb_tx_cfg_bytes) usb_dm usb_dp (json_list usb_tx_program)
      (json_list usb_tx_protocol_prog) (json_list usb_tx_symbols)
  | [ _; "usb" ] ->
    let good = usb_packet_symbols usb_payload in
    let bad = List.mapi (fun i s -> if i = 36 then 1 - s else s) good in
    Printf.printf
      "{\n  \"prescale\": 0,\n  \"b\": %d,\n  \"lead\": 40,\n  \"cfg\": %s,\n  \"pins\": {\"dm\": %d, \"dp\": %d, \"flag_ok\": %d, \"flag_done\": %d},\n  \"phys\": %s,\n  \"protocol\": %s,\n  \"good_symbols\": %s,\n  \"bad_symbols\": %s\n}\n"
      usb_b (json_list usb_cfg_bytes) usb_dm usb_dp usb_flag_ok usb_flag_done
      (json_list usb_program) (json_list usb_protocol_prog) (json_list good) (json_list bad)
  | [ _; "i2c" ] ->
    (* the halt is appended after stop_addr's code, so stop_addr is unchanged *)
    assert (List.length i2c_master_read_prog - 7 = stop_addr);
    Printf.printf
      "{\n  \"prescale\": 0,\n  \"half_period\": %d,\n  \"addr_rw_byte\": %d,\n  \"slave_data_byte\": %d,\n  \"pins\": {\"sda\": %d, \"scl\": %d, \"data_flag\": %d},\n  \"phys\": %s,\n  \"protocol\": %s\n}\n"
      half_period i2c_addr_rw_byte i2c_slave_data_byte sda scl i2c_data_flag
      (json_list i2c_master_read_prog)
      (json_list i2c_protocol_prog)
  | _ ->
    Printf.printf
      "{\n  \"prescale\": 0,\n  \"half_period\": %d,\n  \"master_tx_byte\": %d,\n  \"slave_tx_byte\": %d,\n  \"pins\": {\"sclk\": %d, \"mosi\": %d, \"miso\": %d, \"cs_n\": %d, \"data_flag\": %d},\n  \"phys\": %s,\n  \"protocol\": %s\n}\n"
      half_period master_tx_byte slave_tx_byte sclk mosi miso cs_n data_flag
      (json_list (spi_master_prog master_tx_byte))
      (json_list protocol_prog)
