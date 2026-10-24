## How it works

TD-uT is a reprogrammable, event-driven protocol emulator: two small
microcode engines (uE0 physical layer, uE1 protocol layer) coupled by
a 4-entry hardware FIFO with backpressure, instead of a fixed
UART/SPI/I2C block. Programs (16-bit microcode words) are loaded over
a byte-serial protocol using `ui_in`/`uio_in`, then the core is
released to run against real pins.

For framed, fast protocols uE0 has two generic hardware primitives (not
protocol blocks), both off unless a program configures them:

* **Bit pipe**: one `PIPE_BIT` instruction per bit performs NRZI decode,
  bit un-stuffing, a configurable CRC (width, polynomial, reflection,
  residue) and byte assembly. USB low speed and CAN are two
  configurations of the same hardware. Completed bytes go to uE1 through
  the FIFO, followed by a status word (CRC ok, stuffing error, alignment).
* **Glitch filter**: a pin change is accepted only after N consecutive
  stable samples (N from the config; 0 = bypass).

This `tt_um_dual` target is the dual-engine core wired onto real
`tt_um` pins. See `README.md` and `ROADMAP.md` in the repository for the
architecture, verification and design rationale (`docs/design/`).

## How to test

Load a program via the byte-serial loader protocol: one prescale byte, then
optionally the 9 bit-pipe/glitch-filter config bytes (raise `uio_in[4]`
`cfg_sel` while strobing them), then each 16-bit word low-byte/high-byte,
selecting `uE0`/`uE1` via `uio_in[3]`. Pulse `go`, then drive/observe
`uio_in`/`uio_out`/`uio_oe` as the shared protocol pin bus. `uo_out` shows a
running XOR checksum of everything loaded (config bytes included) until
`go`. See `lib/dual_loader.ml`, `test/test_tt_um_dual.ml` and
`test/test_tt_um_dual_usb.ml` for the exact bit-level protocol and worked
examples (SPI, I2C and USB low-speed receive run through these pins).

### Self-test (nothing attached)

The configuration byte at index 24 (the 25th strobed with `cfg_sel`) is a
loopback mask: on a masked `uio` pin the chip reads its own output and does
not drive the pad. `gl_test/selftest_vectors.json` is a complete program
that sends a USB packet out through the transmit pipe and back in through
the receive pipe on `uio[0]`, then raises PASS on `uio[4]` and DONE on
`uio[5]`. DONE without PASS means the check failed. Inputs pass a 2-flop
synchronizer, and a program that runs past its last loaded word halts.

## External hardware

None required for basic bring-up; an external pull-up is needed on
any pin used as an open-drain protocol line (e.g. I2C SDA/SCL). For the
USB low-speed receive demo, D- and D+ go on `uio[0]` and `uio[1]` (a
real USB connection also needs the usual series resistors and level
handling, which this chip does not provide).
