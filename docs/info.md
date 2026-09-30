## How it works

TD-uT is a reprogrammable, event-driven protocol emulator: two small
microcode engines (uE0 physical layer, uE1 protocol layer) coupled by
a 4-entry hardware FIFO with backpressure, instead of a fixed
UART/SPI/I2C block. Programs (16-bit microcode words) are loaded over
a byte-serial protocol using `ui_in`/`uio_in`, then the core is
released to run against real pins.

This `tt_um_dual` target is the dual-engine core wired onto real
`tt_um` pins. See `docs/design/design_rationale.txt` in the repository root for full
architecture and verification detail.

## How to test

Load a program via the byte-serial loader protocol (prescale byte,
then each 16-bit word low-byte/high-byte, selecting `uE0`/`uE1` via
`uio_in[3]`), pulse `go`, then drive/observe `uio_in`/`uio_out`/
`uio_oe` as the shared protocol pin bus. See `dual_loader.ml` and
`test_tt_um_dual.ml` in the repository for the exact bit-level
protocol and a worked example.

## External hardware

None required for basic bring-up; an external pull-up is needed on
any pin used as an open-drain protocol line (e.g. I2C SDA/SCL).
