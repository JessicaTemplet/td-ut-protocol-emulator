# tdasm: assembler and loader for TD-µT

`tdasm` turns a readable `.tds` source file into the program words for both engines of `tt_um_dual`, then writes out the exact pin sequence a host uses to load them onto the chip. It's written in [Axiom](https://github.com/chrispaig3/Axiom), and is pinned to Axiom 0.7.8 (trunk commit `a3448340`). Axiom is pre-1.0 and changes quickly, so build with that version. A newer compiler may need small source changes.

```
tdasm prog.tds                      print a listing (address, word, source line)
tdasm prog.tds --json out.json      vectors JSON in gl_test's format (cocotb can replay it)
tdasm prog.tds --load out.load      byte-serial load script for a host
tdasm prog.tds --quiet ...          skip the listing
```

If the source has any errors, they're reported with line numbers and nothing is written.

## Build and test

You need the Axiom compiler plus `llc` and a C compiler (Linux or macOS). Build the pinned compiler from its bootstrap seed, which needs nothing else:

```bash
git clone https://github.com/chrispaig3/Axiom.git && cd Axiom
git checkout a3448340
./scripts/bootstrap-from-seed.sh --install .axiom-bin
```

Then, from this folder:

```bash
AXIOM=/path/to/Axiom/.axiom-bin/axiom ./test.sh
```

`test.sh` builds `tdasm` and checks two things:

- The seven examples assemble to exactly the prescale, config bytes and program words that `test/gen_vectors.ml` produces (`gl_test/*_vectors.json` in this repo). Those are the same vectors cocotb replays against the shipped Verilog and the gate-level netlist.
- Every file in `tests/bad/` is refused with the expected error message.
- `.profile` bytes land at config index 32N + k, and the `.loopback` mask at index 24.

## Source syntax

Comments start with `;` or `#`. Operands are separated by spaces or commas. Numbers can be decimal or `0x` hex. A label is `name:` at the start of a line. Branch targets can be a label or a number, and labels belong to one engine.

### Directives

| Directive | Meaning |
|---|---|
| `.prescale N` | Timer prescale byte (0–255). Required. It's the first byte sent after reset. |
| `.cfg B ...` | Bytes of bit-pipe profile 0 (also the glitch filter), up to 24 in total across lines (layout in `bitpipe.ml`). Sent with `cfg_sel`. |
| `.profile N B ...` | Bytes of profile N (0–3), up to 24. Profile N byte k is config index 32N + k (`profile_table.ml`); the loader's index counts up from 0, so every profile up to the last one used is sent, padded to 32 bytes. |
| `.loopback M` | Loopback mask (0–255), config index 24 (`Profile_table.loopback_index`, right after profile 0's 24 bytes). Each set bit makes that uio pin read the chip's own output, and its pad is never driven. Profile 0 is padded to 24 bytes and the mask sent after it; when later profiles are used too, the mask takes the place of the padding byte at index 24. Without it the config bytes are exactly as before. |
| `.phys` | The lines that follow belong to µE0, the physical-layer engine. |
| `.protocol` | The lines that follow belong to µE1, the protocol engine. |
| `.word N` | A raw 16-bit word, in either engine. |

### µE0 (`.phys`), from `engine.ml`

| Instruction | Encodes |
|---|---|
| `wait_fall P [T]` / `wait_rise P [T]` | WAIT_EDGE. With T = 0 or omitted, it waits for the edge on pin P. With T from 1 to 1023, it's a timed wait of T ticks. |
| `halt` | `wait_fall 7 0`: parks the engine for good (pin 7 is never toggled). |
| `emit P L` | EMIT_STATE: drive pin P to level L. |
| `release P` | EMIT_STATE with release: tri-state pin P (open-drain high). |
| `shift P` / `shift_push P` | SHIFT_IO: sample pin P into the byte accumulator. The `_push` form also hands the byte to µE1. |
| `capture P` | Timestamped trace record of pin P into the FIFO. |
| `pipe_bit P [sync]` | Bit pipe: one sample of pin P through NRZI, un-stuffing and CRC. With `sync` it first waits for the bit-clock recovery's sample strobe. |
| `pipe_run P` | Wait for the end of a Manchester frame on pin P while the clock recovery's decoded bits step the receive pipe (10 Mbit Ethernet: one instruction per frame). |
| `pipe_sync` | Wait for the bit-clock recovery's sample strobe without sampling (check the line, then `pipe_bit`). |
| `pipe_status` | Push the bit-pipe status word: bit 15 set, bytes, the clock recovery's timing margin (bits 7..3, 64ths of a bit), byte-aligned, stuffing error, CRC ok. |
| `pipe_crc_lo` / `pipe_crc_hi` | Push the receive CRC register's low / high half: XORed with the residue, a bad packet's syndrome. |
| `pipe_period` | Push the clock recovery's learned bit period (1/16ths of a cycle). |
| `pipe_ctrl [reset] [idle_high] [crc_init] [tx_reset] [tx_crc] [sel_rx] [sel_tx] [p0..p3]` | Bit-pipe controls: receive-pipe reset / idle level / CRC reload, transmit-pipe reset and CRC append, and pointing the receive or transmit pipe at profile `pN`. |
| `emit_tx P [open_drain] [diff]` | EMIT_TX: drive pin P with the transmit pipe's next line bit. `open_drain` drives the 0s and releases the 1s; `diff` also drives pin P xor 1 with the complement. |
| `br_high P T` / `br_low P T` | BRANCH_COND on the current level of pin P. |
| `br_flag F T` / `br_noflag F T` | BRANCH_COND on internal flag F (0–7, `tx_more` = 0: the transmit pipe still has data, CRC or a stuff bit to send, `rec_overrun` = 1: the clock recovery's sample strobe was missed, `rx_lost` = 2: `pipe_run` found the FIFO full and lost a byte). |

### µE1 (`.protocol`), from `protocol_engine.ml`

| Instruction | Encodes |
|---|---|
| `pop` | FIFO_POP: wait for a word from µE0. |
| `emit P L` / `release P` | Same as on µE0, applied to µE1's own pins. |
| `br_bit1 B T` / `br_bit0 B T` | BRANCH_COND_WORD on bit B (0–15) of the last popped word. |
| `br_high P T` / `br_low P T` | BRANCH_PIN on the level of pin P. |
| `tx_push B [last]` | Push byte B into the TX FIFO for µE0's transmit pipe (waits while it is full). `last` marks a packet's final byte. |
| `tx_echo [last]` | Push the low byte of the last popped word. |
| `cfg_wr I [hi]` | Write the low (or with `hi`, the high) byte of the last popped word into profile-table index I (0–127). |
| `profile N [rx] [tx] [crc_init]` | Point the receive and/or transmit pipe at profile N (0–3); `crc_init` reloads the receive CRC from the new profile. |

## Load script (`--load`)

The script is plain text with one strobe per line, written as `<ui_in> <uio_in>` in hex. The strobe bit is left out of `uio_in`. To load the chip:

1. Hold `rst_n` low, then release it.
2. For each line, drive `ui_in` and `uio_in`, raise `uio_in` bit 0 (strobe), then lower it. Waiting a few clocks at each step is enough.
3. Read `uo_out`. It must equal the `checksum` line.
4. Pulse `uio_in` bit 2 (`go`).

The order and checksum follow `dual_loader.ml`: the prescale byte, then the config bytes, then µE0's words, then µE1's words. Each word goes low byte first, then high byte. The checksum is the XOR of every committed byte.

## Examples

| File | What it does |
|---|---|
| `examples/spi_master.tds` | SPI master: sends 0xA5, reads a byte back, flags its MSB. |
| `examples/i2c_master_read.tds` | I2C master read with an ACK check and STOP. |
| `examples/usb_rx.tds` | USB low-speed receive through the bit pipe, with the CRC result on a flag pin. |
| `examples/usb_rx_rec.tds` | USB low-speed receive sampling from the bit-clock recovery: no calibrated waits, tolerates a sender off by 1.5%. |
| `examples/eth_rx.tds` | 10 Mbit Ethernet receive at 50 MHz: Manchester decoding, delimiter hunt and CRC-32 in hardware, one µE0 instruction per frame. |
| `examples/usb_tx.tds` | USB low-speed transmit: µE1 pushes a DATA0 packet, µE0 sends it through the transmit pipe on differential D-/D+ with the CRC appended, then the EOP. |
| `examples/selftest.tds` | On-chip loopback self-test with nothing attached: `.loopback` loops pin 0 back, a USB packet goes out through the transmit pipe and back in through the receive pipe, and µE1 raises PASS (pin 4) and DONE (pin 5). |

## Notes

- The instruction encodings follow `lib/engine.ml`, `lib/protocol_engine.ml` and `lib/dual_loader.ml`. If the ISA changes, update `tdasm.ax` and regenerate the vectors; `test.sh` fails until they agree.
- The generated JSON and load scripts are plain data, so nothing else in this repo needs Axiom installed.
- `tdasm` was first written against Axiom 0.7.5, then ported to 0.7.8. The port needed three changes: `cond` was replaced by a multi-branch `if`, `for` loops became `(for i in 0..n ...)`, and `strConcat`/`vecNewRef` were renamed or removed. The ported version produces byte-identical listings, JSON and load scripts for all three examples.
