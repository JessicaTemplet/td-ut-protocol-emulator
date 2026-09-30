# Strips all internal geometry and sub-cell instances from the
# RM_IHPSG13_1P_512x8_c3_bm_bist macro cell in a COPY of the signoff GDS,
# so KLayout's DRC runset (which has no built-in macro-exclusion knob,
# unlike LibreLane's MAGIC_DRC_MAGLEFS for Magic) can't see -- and
# therefore can't flag -- the vendor-verified macro's own internals
# (e.g. sub-cell QT_RM_IHPSG13_1P_COLDRV13_FILL4, source of all 1,830
# KLayout DRC violations, confirmed from drc.klayout.lyrdb's <cell> field).
#
# NOT used for the actual tapeout submission GDS -- that must keep the
# real macro geometry for fabrication. This is a separate copy, used
# only to verify our own design's DRC correctness independent of the
# macro's (separately vendor-signed-off) internals.
import pya
import os

in_gds = os.environ["IN_GDS"]
out_gds = os.environ["OUT_GDS"]
macro_name = os.environ["MACRO_NAME"]

layout = pya.Layout()
layout.read(in_gds)

cell_index = layout.cell_by_name(macro_name)
cell = layout.cell(cell_index)

shape_count_before = sum(cell.shapes(li).size() for li in layout.layer_indexes())
inst_count_before = cell.child_instances()

for li in layout.layer_indexes():
    cell.shapes(li).clear()
cell.clear_insts()

shape_count_after = sum(cell.shapes(li).size() for li in layout.layer_indexes())
inst_count_after = cell.child_instances()

print(f"[INFO] Cell '{macro_name}': shapes {shape_count_before} -> {shape_count_after}, "
      f"child instances {inst_count_before} -> {inst_count_after}")

layout.write(out_gds)
print(f"[INFO] Wrote blackboxed copy to {out_gds}")
