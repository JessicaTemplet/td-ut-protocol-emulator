# Generates a Magic abstract (.mag) view of RM_IHPSG13_1P_512x8_c3_bm_bist
# from its LEF, for use with MAGIC_DRC_MAGLEFS to blackbox the macro's
# interior during DRC (see docs/design/design_rationale.txt "DRC macro-blackbox gap").
drc off
lef read $::env(MACRO_LEF)
load RM_IHPSG13_1P_512x8_c3_bm_bist
save $::env(MAGLEF_OUT)/RM_IHPSG13_1P_512x8_c3_bm_bist.mag
puts "\[INFO\] DONE GENERATING MAGLEF VIEW"
quit -noprompt
