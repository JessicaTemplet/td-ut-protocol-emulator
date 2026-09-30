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

let () =
  match Array.to_list Sys.argv with
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
