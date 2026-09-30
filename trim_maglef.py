#!/usr/bin/env python3
"""Make the SRAM's Magic DRC abstract (MAGIC_DRC_MAGLEFS) stop producing
false Magic DRC errors at the macro's signal-pin edge.

The abstract comes from `gen_maglef.tcl` (Magic `lef read` of the vendor
LEF), which turns the LEF OBS into solid obsm2/obsm3 blocks covering the
whole macro, starting 0-0.52um from the signal edge, plus obsm2 strips
filling the gaps between pins. Magic's deck treats those as >10um-wide
metal, so every routed wire landing on a pin trips the wide-metal spacing
rules (M2.f/M3.f), and an unused pin -- a bare 0.26x0.26um Metal2 square in
the abstract -- trips Metal2 min area (M2.d). None of that exists in the
real GDS: the precheck's KLayout ihp-sg13cmos5l.drc deck on the shipped
GDS (real macro) is clean. Magic DRC on the real macro GDS instead of this
abstract is not an option (120,951 SRAM-interior errors).

This keeps the abstract's job (blackbox the interior) and only changes the
geometry Magic sees within PULLBACK of the signal edge (master y=0):
  * obsm2 / obsm3 rects are clipped to start at y >= PULLBACK (rects lying
    entirely inside the band are dropped);
  * each Metal2 pin rect touching y=0 is extended inward to PIN_DEPTH so it
    meets Metal2 min area (0.144um^2) on its own, as the real pin does via
    the macro's internal metal.
Routing is unaffected (OpenROAD uses the vendor LEF); only Magic DRC reads
this file.

usage: trim_maglef.py <in.mag> <out.mag>
"""
import sys

UNIT = 0.005            # magscale 1 2 -> 5nm per unit
PULLBACK = 1.5          # um; > M2.f/M3.f wide-metal spacing (0.6um)
PIN_DEPTH = 0.6         # um; 0.26 x 0.6 = 0.156um^2 >= 0.144um^2
CLIP_LAYERS = {"obsm2", "obsm3"}

pb = round(PULLBACK / UNIT)
pd = round(PIN_DEPTH / UNIT)

src, dst = sys.argv[1], sys.argv[2]
out, layer = [], None
stats = {"clipped": 0, "dropped": 0, "pins": 0}
for line in open(src):
    if line.startswith("<< "):
        layer = line.split()[1]
    elif line.startswith("rect ") and layer in CLIP_LAYERS:
        x1, y1, x2, y2 = map(int, line.split()[1:5])
        if y2 <= pb:
            stats["dropped"] += 1
            continue
        if y1 < pb:
            y1 = pb
            stats["clipped"] += 1
            line = f"rect {x1} {y1} {x2} {y2}\n"
    elif line.startswith("rect ") and layer == "metal2":
        x1, y1, x2, y2 = map(int, line.split()[1:5])
        if y1 == 0 and y2 < pd:
            y2 = pd
            stats["pins"] += 1
            line = f"rect {x1} {y1} {x2} {y2}\n"
    out.append(line)
open(dst, "w").writelines(out)
print(f"[INFO] trim_maglef: {stats}")
