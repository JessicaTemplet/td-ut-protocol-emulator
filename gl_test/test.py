"""SPI, I2C and USB through tt_um_dual's real pins, on the shipped Verilog.

Replays the same microcode and checks as test/test_tt_um_dual_spi.ml and
test/test_tt_um_dual_i2c.ml (Cyclesim) against the actual netlist (RTL with the
vendor SRAM model, or the hardened gate-level netlist): load both engines over
the byte-serial pins, check the load checksum on uo_out, `go`, then play the
external device on uio.

  * SPI: act as a slave; check the byte the master shifts out on MOSI and the
    DATA_FLAG uE1 derives from the byte the slave returned on MISO.
  * I2C: act as an open-drain slave on a wired-AND SDA/SCL (the master only
    ever pulls low or releases, so this exercises the per-pin output-enable
    path through the SRAM-backed netlist); check the address byte the slave
    captured, the SCL edge count, and DATA_FLAG.

  * USB low speed: receive a packet through the bit pipe (good and corrupted),
    and transmit one through the transmit pipe (data decided at run time by
    uE1), compared cell by cell with the reference encoder's line.

Microcode comes from {spi,i2c,usb,usb_tx}_vectors.json (regenerate:
run_gen_vectors.sh).
Written to run under cocotb 1.8 and 2.x.
"""

import json
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


def vectors(name):
    with open(os.path.join(os.path.dirname(__file__), name)) as f:
        return json.load(f)


def uio(strobe=0, byte_sel=0, go=0, engine_sel=0, cfg_sel=0):
    return (cfg_sel << 4) | (engine_sel << 3) | (go << 2) | (byte_sel << 1) | strobe


async def pulse_byte(dut, engine_sel, byte_sel, data, cfg_sel=0):
    dut.ui_in.value = data
    dut.uio_in.value = uio(0, byte_sel, 0, engine_sel, cfg_sel)
    await ClockCycles(dut.clk, 3)
    dut.uio_in.value = uio(1, byte_sel, 0, engine_sel, cfg_sel)
    await ClockCycles(dut.clk, 3)
    dut.uio_in.value = uio(0, byte_sel, 0, engine_sel, cfg_sel)
    await ClockCycles(dut.clk, 3)


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 20, "ns").start())  # 50 MHz
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


async def load_and_go(dut, vec):
    """Load both programs over the pins, check the checksum, pulse go."""
    await reset(dut)
    await pulse_byte(dut, 0, 0, vec["prescale"])  # first strobe after reset = prescale
    # optional bit-pipe / glitch-filter configuration (uio[4] = cfg_sel)
    for byte in vec.get("cfg", []):
        await pulse_byte(dut, 0, 0, byte, cfg_sel=1)
    for engine_sel, prog in ((0, vec["phys"]), (1, vec["protocol"])):
        for w in prog:
            await pulse_byte(dut, engine_sel, 0, w & 0xFF)
            await pulse_byte(dut, engine_sel, 1, (w >> 8) & 0xFF)
    expected = 0
    for byte in vec.get("cfg", []):
        expected ^= byte
    for w in vec["phys"] + vec["protocol"]:
        expected ^= (w & 0xFF) ^ ((w >> 8) & 0xFF)
    await Timer(1, "ns")
    got = int(dut.uo_out.value)
    assert got == expected, f"load checksum {got:#x} != {expected:#x}"

    dut.uio_in.value = uio(0, 0, 1, 0)  # go
    await ClockCycles(dut.clk, 3)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 3)


def resolved(dut, cyc, total):
    assert dut.uio_out.value.is_resolvable and dut.uio_oe.value.is_resolvable, (
        f"uio_out={dut.uio_out.value} oe={dut.uio_oe.value} unresolved at run cycle {cyc}/{total}"
    )


@cocotb.test()
async def spi_master_through_real_pins(dut):
    vec = vectors("spi_vectors.json")
    pin = vec["pins"]
    await load_and_go(dut, vec)

    hp = vec["half_period"]
    total = 1 + hp + 8 * (2 * hp + 4) + 20
    slave_shift = vec["slave_tx_byte"]
    prev_sclk = 0
    mosi_bits = []
    for cyc in range(total):
        dut.uio_in.value = ((slave_shift >> 7) & 1) << pin["miso"]
        await RisingEdge(dut.clk)
        await Timer(1, "ns")
        resolved(dut, cyc, total)
        out = int(dut.uio_out.value)
        sclk = (out >> pin["sclk"]) & 1
        if sclk and not prev_sclk:
            mosi_bits.append((out >> pin["mosi"]) & 1)
        if not sclk and prev_sclk:
            slave_shift = (slave_shift << 1) & 0xFF
        prev_sclk = sclk

    got = 0
    for b in mosi_bits:
        got = (got << 1) | b
    assert len(mosi_bits) == 8, f"slave saw {len(mosi_bits)} SCLK rising edges, expected 8"
    assert got == vec["master_tx_byte"], f"MOSI byte {got:#04x} != {vec['master_tx_byte']:#04x}"

    out, oe = int(dut.uio_out.value), int(dut.uio_oe.value)
    flag_pin = pin["data_flag"]
    expected_flag = (vec["slave_tx_byte"] >> 7) & 1
    assert (oe >> flag_pin) & 1 == 1, "DATA_FLAG pin is not driven"
    assert (out >> flag_pin) & 1 == expected_flag, "DATA_FLAG level wrong"


async def usb_packet(dut, symbols):
    """Load the USB receive program + bit-pipe config over the pins (cfg_sel),
    play `symbols` (1 = J, 0 = K, 2 = SE0, one per bit period) on D-/D+
    (uio[0], uio[1]) and return (flag_ok, flag_done) read off uio_out."""
    vec = vectors("usb_vectors.json")
    pin = vec["pins"]
    await load_and_go(dut, vec)
    b, lead = vec["b"], vec["lead"]
    total = lead + len(symbols) * b + 400
    for cyc in range(total):
        if cyc < lead:
            s = 1
        else:
            k = (cyc - lead) // b
            s = symbols[k] if k < len(symbols) else 1
        dm = 1 if s == 1 else 0
        dp = 1 if s == 0 else 0
        dut.uio_in.value = (dm << pin["dm"]) | (dp << pin["dp"])
        await RisingEdge(dut.clk)
        await Timer(1, "ns")
        resolved(dut, cyc, total)
    out, oe = int(dut.uio_out.value), int(dut.uio_oe.value)
    flag = lambda p: ((oe >> p) & 1 == 1, (out >> p) & 1 == 1)
    return flag(pin["flag_ok"]), flag(pin["flag_done"])


@cocotb.test()
async def usb_low_speed_receive_good_packet(dut):
    vec = vectors("usb_vectors.json")
    ok, done = await usb_packet(dut, vec["good_symbols"])
    assert done == (True, True), f"flag_done not driven high: {done}"
    assert ok == (True, True), f"good USB packet (bit pipe: NRZI, unstuff, CRC16) not accepted: {ok}"


@cocotb.test()
async def usb_low_speed_receive_corrupted_packet(dut):
    vec = vectors("usb_vectors.json")
    ok, done = await usb_packet(dut, vec["bad_symbols"])
    assert done == (True, True), f"flag_done not driven high: {done}"
    assert ok == (True, False), f"corrupted USB packet was not rejected: {ok}"


async def usb_recovered(dut, line):
    """USB receive with bit-clock recovery: the sender's clock is 1.5% fast
    with edge jitter; `line` is one symbol per clock cycle (1 = J, 0 = K,
    2 = SE0). Returns (flag_ok, flag_done)."""
    vec = vectors("usb_rec_vectors.json")
    pin = vec["pins"]
    await load_and_go(dut, vec)
    for cyc, s in enumerate(line):
        dm = 1 if s == 1 else 0
        dp = 1 if s == 0 else 0
        dut.uio_in.value = (dm << pin["dm"]) | (dp << pin["dp"])
        await RisingEdge(dut.clk)
        await Timer(1, "ns")
        resolved(dut, cyc, len(line))
    out, oe = int(dut.uio_out.value), int(dut.uio_oe.value)
    flag = lambda p: ((oe >> p) & 1 == 1, (out >> p) & 1 == 1)
    return flag(pin["flag_ok"]), flag(pin["flag_done"]), flag(pin["flag_degraded"])


@cocotb.test()
async def usb_receive_with_clock_recovery(dut):
    vec = vectors("usb_rec_vectors.json")
    ok, done, degraded = await usb_recovered(dut, vec["good_line"])
    assert done == (True, True), f"flag_done not driven high: {done}"
    assert ok == (True, True), f"packet from a 1.5%-fast sender not accepted: {ok}"
    assert degraded[1] is False, "link flagged degraded on a 1.5%-fast, lightly jittered sender"
    ok, done, _ = await usb_recovered(dut, vec["bad_line"])
    assert done == (True, True), f"flag_done not driven high (corrupted): {done}"
    assert ok == (True, False), f"corrupted packet was not rejected: {ok}"
    # heavy jitter: the CRC still passes, the status word's margin warns
    ok, done, degraded = await usb_recovered(dut, vec["jittery_line"])
    assert done == (True, True), f"flag_done not driven high (jittery): {done}"
    assert ok == (True, True), f"jittery packet not accepted: {ok}"
    assert degraded == (True, True), f"heavy jitter not flagged degraded: {degraded}"


@cocotb.test()
async def usb_low_speed_transmit(dut):
    """USB low-speed DATA0 transmit: µE1 pushes the packet at run time, µE0's
    EMIT_TX sends it through the transmit pipe (NRZI, bit stuffing, CRC16
    appended complemented) on D-, with D+ driven as its complement in the
    same cycle, then the EOP. Sampled mid-cell against the reference line."""
    vec = vectors("usb_tx_vectors.json")
    pin = vec["pins"]
    dm, dp = pin["dm"], pin["dp"]
    await load_and_go(dut, vec)
    cell, symbols = vec["cell"], vec["symbols"]
    total = 200 + (len(symbols) + 4) * cell
    trace = []
    for cyc in range(total):
        await RisingEdge(dut.clk)
        await Timer(1, "ns")
        resolved(dut, cyc, total)
        trace.append((int(dut.uio_out.value), int(dut.uio_oe.value)))
    # the packet starts with SYNC's first K: D- driven low
    start = next(
        (i for i, (o, e) in enumerate(trace) if (e >> dm) & 1 and not (o >> dm) & 1), None
    )
    assert start is not None, "D- never went to K: nothing was transmitted"
    got = []
    for k in range(len(symbols)):
        o, e = trace[start + k * cell + cell // 2]
        assert (e >> dm) & 1 and (e >> dp) & 1, f"D-/D+ not both driven in cell {k}"
        d_m, d_p = (o >> dm) & 1, (o >> dp) & 1
        got.append(2 if (d_m, d_p) == (0, 0) else d_m)
        if k < len(symbols) - 3:
            assert d_p == 1 - d_m, f"cell {k}: D+ is not the complement of D-"
    assert got == symbols, f"line symbols differ from the reference encoder:\n{got}\n{symbols}"


@cocotb.test()
async def i2c_master_read_through_real_pins(dut):
    vec = vectors("i2c_vectors.json")
    pin = vec["pins"]
    sda, scl = pin["sda"], pin["scl"]
    await load_and_go(dut, vec)

    # a half period costs its WAIT (payload + 1 cycles) plus up to two
    # single-cycle pin instructions (see test/test_i2c_master.ml)
    hp = vec["half_period"] + 3
    total = (
        3 + 2 * hp + 8 * (2 * hp) + 2 * hp + 8 * (2 * hp) + 2 * hp + 3 * hp + 30
    )
    edge_index = 0
    slave_data_shift = vec["slave_data_byte"]
    slave_drive = 1
    addr_captured = 0
    prev_scl = 1
    for cyc in range(total):
        # wired-AND: the master only pulls low (oe=1, out=0) or releases;
        # an undriven line floats high (external pull-up)
        await Timer(1, "ns")
        resolved(dut, cyc, total)
        out, oe = int(dut.uio_out.value), int(dut.uio_oe.value)
        master_pulls_sda = ((oe >> sda) & 1) and not ((out >> sda) & 1)
        sda_net = 0 if (master_pulls_sda or slave_drive == 0) else 1
        scl_net = ((out >> scl) & 1) if (oe >> scl) & 1 else 1
        dut.uio_in.value = (sda_net << sda) | (scl_net << scl)
        await RisingEdge(dut.clk)
        if scl_net == 1 and prev_scl == 0:
            if edge_index < 8:
                addr_captured = (addr_captured << 1) | sda_net
            edge_index += 1
        if scl_net == 0 and prev_scl == 1:
            if edge_index < 8:
                slave_drive = 1
            elif edge_index == 8:
                slave_drive = 0  # ACK the address
            elif edge_index == 9:
                slave_drive = (slave_data_shift >> 7) & 1
            elif edge_index <= 16:
                slave_data_shift = (slave_data_shift << 1) & 0xFF
                slave_drive = (slave_data_shift >> 7) & 1
            else:
                slave_drive = 1
        prev_scl = scl_net
    await Timer(1, "ns")
    resolved(dut, total, total)

    assert edge_index == 19, (
        f"SCL rising edges {edge_index} != 19 (8 addr + 1 ack + 8 data + 1 master-nack + 1 STOP release)"
    )
    assert addr_captured == vec["addr_rw_byte"], (
        f"slave captured {addr_captured:#04x}, expected {vec['addr_rw_byte']:#04x}"
    )
    out, oe = int(dut.uio_out.value), int(dut.uio_oe.value)
    flag_pin = pin["data_flag"]
    expected_flag = (vec["slave_data_byte"] >> 7) & 1
    assert (oe >> flag_pin) & 1 == 1, "DATA_FLAG pin is not driven"
    assert (out >> flag_pin) & 1 == expected_flag, "DATA_FLAG level wrong"
