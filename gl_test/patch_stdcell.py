#!/usr/bin/env python3
"""Write a copy of the CMOS5L std-cell model that stock iverilog can simulate.

The vendor flop/latch models get their `delayed_X` nets from $setuphold /
$recrem timing checks. Stock iverilog (12.x) does not drive those nets, so
every flop stays X. Tiny Tapeout's CI installs its own iverilog 13 fork that
does, so CI needs no patch; this is only for running the gate-level bench
locally with a distro iverilog. Zero-delay functional behaviour is identical:
each `delayed_X` is simply tied to `X`.

usage: patch_stdcell.py <in stdcell.v> <out stdcell.v>
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()


def tie(m):
    names = [n.strip() for n in m.group(1).split(",")]
    if not all(n.startswith("delayed_") for n in names):
        return m.group(0)
    return "wire " + ", ".join(f"{n} = {n[len('delayed_'):]}" for n in names) + ";"


out, count = re.subn(r"wire\s+((?:delayed_\w+\s*,?\s*)+);", tie, text)
open(dst, "w").write(out)
print(f"patched {count} delayed-net declarations -> {dst}")
