# SRAM macro -> PDN bridge for CMOS5L Tiny Tapeout tiles.
#
# Why this exists: the tile may only route up to Metal4 (RT_MAX_LAYER), the
# PDN is Metal4 vertical stripes only (FP_PDN_MULTILAYER=0), and the SRAM
# macro's VDD!/VSS!/VDDARRAY! pins are ALSO Metal4 bars inside the macro
# footprint. pdngen cuts every stripe around a macro (PDN_*_HALO), and no
# higher layer exists to drop a via from, so with stock pdngen the macro pins
# are always islands (PSM-0038/0039/0069 -- see docs/design/design_rationale.txt).
#
# Fix: macros are placed FS (flipped) in one row near the core bottom, which
# puts their power edge (original top edge: VSS!, the 4 full-height VDD!, and
# all VDDARRAY! reach it; no signal pins there) facing down into a small
# channel. This script, run right after pdngen, draws in that channel:
#   * one horizontal Metal3 strap per net (VPWR lower, VGND upper, each
#     centred on a same-net standard-cell rail -- see macro_pdn_bridge)
#     spanning the core width, so it crosses the full-height Metal4 stripes
#     in the gaps between/beside the macros;
#   * a Metal4 stub under every power-edge pin, from the macro edge down into
#     its net's strap (VPWR stubs cross the VGND strap, no via there);
#   * Via3 arrays wherever a same-net Metal4 shape (stub or stripe) covers a
#     strap.
# All shapes are special wires on VPWR/VGND, so routing treats them as
# obstructions and PSM/LVS see them like any other PDN shape.

proc _mb_um {x} { return [expr {round($x * 1000)}] }

proc _mb_via {block tech cols rows} {
    set name "mbridge_via3_${cols}x${rows}"
    set v [$block findVia $name]
    if {$v != "NULL"} { return $v }
    set v [odb::dbVia_create $block $name]
    set p [$v getViaParams]
    $p setBottomLayer [$tech findLayer Metal3]
    $p setCutLayer    [$tech findLayer Via3]
    $p setTopLayer    [$tech findLayer Metal4]
    $p setXCutSize 190
    $p setYCutSize 190
    # 0.29um: the Via3 ADJACENTCUTS 3 spacing, needed inside 2-D arrays
    $p setXCutSpacing 290
    $p setYCutSpacing 290
    foreach s {setXBottomEnclosure setYBottomEnclosure setXTopEnclosure setYTopEnclosure} {
        $p $s 50
    }
    $p setNumCutCols $cols
    $p setNumCutRows $rows
    $v setViaParams $p
    return $v
}

# Largest cut count that fits in `span` (dbu) with 0.05um enclosure each side
proc _mb_ncuts {span} {
    set n [expr {int(($span - 100 + 290) / 480)}]
    return [expr {$n < 1 ? 1 : $n}]
}

proc _mb_add_via {block tech swire x1 x2 y1 y2} {
    set cols [_mb_ncuts [expr {$x2 - $x1}]]
    set rows [_mb_ncuts [expr {$y2 - $y1}]]
    if {$cols * $rows < 2} { return 0 }
    set v [_mb_via $block $tech $cols $rows]
    odb::dbSBox_create $swire $v [expr {($x1 + $x2) / 2}] [expr {($y1 + $y2) / 2}] "STRIPE"
    return 1
}

proc macro_pdn_bridge {} {
    set block [ord::get_db_block]
    set tech  [ord::get_db_tech]
    set m3 [$tech findLayer Metal3]
    set m4 [$tech findLayer Metal4]
    set core [$block getCoreArea]

    # strap y-ranges (dbu), keyed by net name. Each strap is centred over a
    # standard-cell rail OF ITS OWN NET (rows: VGND y=3.78, VPWR 7.56, VGND
    # 11.34, VPWR 15.12): pdngen drops a Metal1->Metal4 via stack, with a
    # Metal3 landing pad, wherever a rail crosses a stripe, so a strap
    # covering the other net's rail shorts VPWR to VGND (the first version of
    # this bridge did exactly that -- LVS merged the nets). Spacing to the
    # other net's pads: >= 0.6um everywhere; to the macro edge (y=14): 1.3um.
    set straps [dict create \
        VPWR [list [_mb_um 6.1] [_mb_um 9.7]] \
        VGND [list [_mb_um 10.3] [_mb_um 12.7]]]
    set sx1 [$core xMin]
    set sx2 [$core xMax]

    set swires [dict create]
    foreach n [dict keys $straps] {
        set net [$block findNet $n]
        dict set swires $n [odb::dbSWire_create $net "ROUTED"]
        lassign [dict get $straps $n] y1 y2
        odb::dbSBox_create [dict get $swires $n] $m3 $sx1 $y1 $sx2 $y2 "STRIPE"
    }

    # stubs: every Metal4 PG pin rect touching the macro's power edge
    set stubs [dict create VPWR {} VGND {}]
    set nstub 0
    foreach inst [$block getInsts] {
        set master [$inst getMaster]
        if {![$master isBlock]} { continue }
        set orient [$inst getOrient]
        if {$orient != "MX"} {
            puts "\[WARNING\] macro_pdn_bridge: [$inst getName] is $orient, not FS/MX -- skipped"
            continue
        }
        set bb [$inst getBBox]
        set bx [$bb xMin]
        set by [$bb yMin]
        set H  [$master getHeight]
        foreach it [$inst getITerms] {
            set st [$it getSigType]
            if {$st != "POWER" && $st != "GROUND"} { continue }
            set net [$it getNet]
            if {$net == "NULL"} { continue }
            set n [$net getName]
            if {![dict exists $straps $n]} { continue }
            lassign [dict get $straps $n] sy1 sy2
            foreach mp [[$it getMTerm] getMPins] {
                foreach box [$mp getGeometry] {
                    if {[$box getTechLayer] != $m4} { continue }
                    # FS: master-top edge (y == H) lands on the instance bottom
                    if {[$box yMax] != $H} { continue }
                    set x1 [expr {$bx + [$box xMin]}]
                    set x2 [expr {$bx + [$box xMax]}]
                    # 0.5um overlap into the pin itself
                    odb::dbSBox_create [dict get $swires $n] $m4 $x1 $sy1 $x2 [expr {$by + 500}] "STRIPE"
                    dict lappend stubs $n [list $x1 $x2]
                    incr nstub
                }
            }
        }
    }

    # vias. Stubs sit where rows were cut (under the macros), so they get the
    # full strap height. Stripes crossing a strap already carry a pdngen
    # rail via stack inside it (same net, by construction above), so their
    # Via3 array goes in the largest part of the strap clear of that stack.
    set nvia 0
    foreach n [dict keys $straps] {
        lassign [dict get $straps $n] sy1 sy2
        set sw [dict get $swires $n]
        foreach x [lsort -unique [dict get $stubs $n]] {
            lassign $x x1 x2
            incr nvia [_mb_add_via $block $tech $sw $x1 $x2 $sy1 $sy2]
        }
        set stripes {}
        set blocked {}
        foreach w [[$block findNet $n] getSWires] {
            if {$w == $sw} { continue }
            foreach b [$w getWires] {
                if {[$b isVia]} {
                    lassign [$b getViaXY] cx cy
                    if {$cy > $sy1 - 1000 && $cy < $sy2 + 1000} { lappend blocked [list $cx $cy] }
                    continue
                }
                if {[$b getTechLayer] != $m4} { continue }
                if {[$b yMin] <= $sy1 && [$b yMax] >= $sy2 && [$b xMax] > $sx1 && [$b xMin] < $sx2} {
                    lappend stripes [list [$b xMin] [$b xMax]]
                }
            }
        }
        foreach x [lsort -unique $stripes] {
            lassign $x x1 x2
            # y-intervals inside the strap taken by existing vias on this stripe (+0.5um keepout)
            set segs [list [list $sy1 $sy2]]
            foreach v $blocked {
                lassign $v cx cy
                if {$cx < $x1 || $cx > $x2} { continue }
                set new {}
                foreach s $segs {
                    lassign $s a b
                    set lo [expr {$cy - 600}]; set hi [expr {$cy + 600}]
                    if {$hi <= $a || $lo >= $b} { lappend new $s; continue }
                    if {$lo > $a} { lappend new [list $a $lo] }
                    if {$hi < $b} { lappend new [list $hi $b] }
                }
                set segs $new
            }
            set best {}; set bl 0
            foreach s $segs {
                lassign $s a b
                if {$b - $a > $bl} { set bl [expr {$b - $a}]; set best $s }
            }
            if {$best != {}} {
                lassign $best a b
                incr nvia [_mb_add_via $block $tech $sw $x1 $x2 $a $b]
            }
        }
    }
    puts "\[INFO\] macro_pdn_bridge: $nstub Metal4 stubs, $nvia Via3 arrays, 2 Metal3 straps"
}

# Run the bridge right after pdngen, before the PDN step writes views and
# runs check_power_grid.
if {[info commands _mb_orig_pdngen] == ""} {
    rename pdngen _mb_orig_pdngen
    proc pdngen {args} {
        _mb_orig_pdngen {*}$args
        macro_pdn_bridge
    }
}
