open Hardcaml
open Tt_core

(* Shadow mode (shadow.ml) on the dual-engine core.

   Two cores, A and B, share one wire per pin (a pull-up wire: high unless a
   core drives it). A runs a program in Drive; B runs a program in Shadow, so
   B drives nothing and checks the wire against its own claims. Cases:

   - Round trip: B runs A's exact program. Zero records, B never drives a
     pad, and both cores' pcs agree on every cycle (Shadow changes nothing
     about when an instruction runs).
   - Injection: B's program differs from A's in one EMIT. Exactly one
     mismatch record, with that EMIT's pc, the mismatching pin, the level the
     wire actually had, and a timestamp computed here independently (the
     cycle the EMIT ran + 1 + settle), then one episode-end record.
   - Storm: a claim that stays wrong across many compares gives one record,
     not one per compare.
   - Overflow: more records than the FIFO holds, nothing read: four kept, the
     rest dropped and counted, and the next record pushed carries the count.
   - µE1: the same, for µE1's EMIT_STATE pins.
   - Check mode (one core, still driving): contention is caught, and the
     settle boundary is exact (a level the core drives is seen by its own
     compare at settle = Dual.sync_latency, not one cycle earlier). *)

module Sim = Cyclesim.With_interface (Dual.I) (Dual.O)

let settle = 4
let prescale = 0
let failures = ref 0

let check name ok =
  Printf.printf "  %-74s %s\n" name (if ok then "ok" else "FAIL");
  if not ok then incr failures

type core = {
  sim : (Bits.t ref Dual.I.t, Bits.t ref Dual.O.t) Cyclesim.t;
  i : Bits.t ref Dual.I.t;
  o : Bits.t ref Dual.O.t;
}

let b = Bits.of_int
let get r = Bits.to_int !r

let make ?(settle = settle) ~mode ~phys ~proto () =
  let sim = Sim.create Dual.create in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  let c = { sim; i; o } in
  i.rst_n := Bits.gnd;
  i.pins_in := b ~width:8 0xFF;
  i.prescale := b ~width:8 prescale;
  Cyclesim.cycle sim;
  i.rst_n := Bits.vdd;
  let cfg k v =
    i.cfg_addr := b ~width:7 k;
    i.cfg_data := b ~width:8 v;
    i.cfg_we := Bits.vdd;
    Cyclesim.cycle sim
  in
  cfg Profile_table.shadow_mode_index mode;
  cfg Profile_table.e0_settle_index (settle land 0xFF);
  cfg (Profile_table.e0_settle_index + 1) (settle lsr 8);
  cfg Profile_table.e1_settle_index (settle land 0xFF);
  cfg (Profile_table.e1_settle_index + 1) (settle lsr 8);
  i.cfg_we := Bits.gnd;
  let load we addr data prog =
    List.iteri
      (fun k w ->
        addr := b ~width:9 k;
        data := b ~width:16 w;
        we := Bits.vdd;
        Cyclesim.cycle sim)
      prog;
    we := Bits.gnd
  in
  load i.phys_write_enable i.phys_write_addr i.phys_write_data phys;
  load i.protocol_write_enable i.protocol_write_addr i.protocol_write_data proto;
  c

(* what a core puts on the wire: µE1 wins a pin both drive, as in tt_core *)
let drive c =
  let p_oe = get c.o.protocol_pins_oe and p_out = get c.o.protocol_pins_out in
  let e_oe = get c.o.phys_pins_oe and e_out = get c.o.phys_pins_out in
  let oe = p_oe lor e_oe in
  let v = (p_oe land p_out) lor (lnot p_oe land e_out) in
  (oe, v)

let wire_of cores =
  List.fold_left
    (fun w c ->
      let oe, v = drive c in
      (w land lnot oe) lor (v land oe))
    0xFF cores

type record = { end_ : bool; pc : int; body : int; dropped : int; ts : int }

let decode (r : Bits.t) =
  let f hi lo = Bits.to_int (Bits.select r hi lo) in
  { end_ = f 63 63 = 1; pc = f 62 54; body = f 53 38; dropped = f 37 32; ts = f 31 0 }

(* Run cores in lockstep on a shared wire for n cycles after run rises.
   Records are popped as they appear (unless ~drain:false), so a test sees
   them all in order. Returns per-core records and per-cycle pcs. *)
let run ?(drain = true) ?(on_cycle = fun _ -> ()) ?(force = fun _ w -> w) cores n =
  let recs = List.map (fun _ -> (ref [], ref [])) cores in
  let pcs = List.map (fun _ -> ref []) cores in
  List.iter (fun c -> c.i.run := Bits.vdd; c.i.protocol_run := Bits.vdd) cores;
  for t = 0 to n - 1 do
    on_cycle t;
    let w = force t (wire_of cores) in
    List.iter2
      (fun c ((r0, r1), pcl) ->
        c.i.pins_in := b ~width:8 w;
        pcl := get c.o.phys_pc :: !pcl;
        let take cnt head pop acc =
          pop := Bits.gnd;
          if drain && get cnt > 0 then begin
            acc := decode !head :: !acc;
            pop := Bits.vdd
          end
        in
        take c.o.trace0_count c.o.trace0_head c.i.trace_pop0 r0;
        take c.o.trace1_count c.o.trace1_head c.i.trace_pop1 r1)
      cores (List.combine recs pcs);
    List.iter (fun c -> Cyclesim.cycle c.sim) cores
  done;
  ( List.map (fun (r0, r1) -> (List.rev !r0, List.rev !r1)) recs,
    List.map (fun p -> Array.of_list (List.rev !p)) pcs )

(* the cycle (counted from run's rise) on which instruction k ran: pc = k and
   the next cycle's pc moved on *)
let ran_at pcs k =
  let r = ref (-1) in
  Array.iteri (fun t p -> if !r < 0 && p = k && t + 1 < Array.length pcs && pcs.(t + 1) <> k then r := t) pcs;
  !r

let gap = 12 (* timer ticks between claims: well over settle *)

let halt = Engine.wait_edge ~pin:7 ~falling:true ~payload:0
let proto_halt = [ Protocol_engine.fifo_pop_instr ]

(* a UART-ish byte on pin 0 with an SPI-ish clock and data pair on pins 1, 2 *)
let program ?(flip = -1) () =
  let levels = [ 0; 1; 0; 1; 1; 0; 0; 1; 0; 1 ] in
  let body =
    List.concat
      (List.mapi
         (fun k l ->
           [ Engine.emit_state ~pin:0 ~level:(l = 1);
             Engine.emit_state ~pin:2 ~level:(k land 1 = 0);
             Engine.emit_state ~pin:1 ~level:(k land 1 = 1);
             Engine.wait_edge ~pin:0 ~falling:false ~payload:gap ])
         levels)
  in
  let body = List.mapi (fun k w -> if k = flip then w lxor (1 lsl 10) else w) body in
  body @ [ halt ]

let n_cycles = 400

let () =
  Printf.printf "=== Shadow mode: Drive vs Shadow on a shared wire ===\n";
  (* -- round trip -- *)
  let a = make ~mode:0 ~phys:(program ()) ~proto:proto_halt () in
  let bsh = make ~mode:Profile_table.mode_e0_shadow ~phys:(program ()) ~proto:proto_halt () in
  let max_oe = ref 0 in
  let recs, pcs =
    run ~on_cycle:(fun _ -> max_oe := !max_oe lor get bsh.o.phys_pins_oe) [ a; bsh ] n_cycles
  in
  let pa = List.nth pcs 0 and pb = List.nth pcs 1 in
  check "round trip: B (Shadow) logs nothing" (fst (List.nth recs 1) = []);
  check "round trip: B never drives a pad" (!max_oe = 0);
  check "round trip: A and B pcs agree on every cycle" (pa = pb);
  check "round trip: both programs reached their halt" (pa.(n_cycles - 1) = List.length (program ()) - 1);

  (* -- injection: B's EMIT at index k claims the wrong level on pin 0 -- *)
  let k = 4 * 3 in
  let a = make ~mode:0 ~phys:(program ()) ~proto:proto_halt () in
  let bsh = make ~mode:Profile_table.mode_e0_shadow ~phys:(program ~flip:k ()) ~proto:proto_halt () in
  let recs, pcs = run [ a; bsh ] n_cycles in
  let r = fst (List.nth recs 1) in
  let pb = List.nth pcs 1 in
  check "injection: two records (mismatch, episode end)" (List.length r = 2);
  (match r with
   | [ m; e ] ->
     let mask = m.body lsr 8 and actual = m.body land 0xFF in
     let a_level = (List.nth [ 0; 1; 0; 1; 1; 0; 0; 1; 0; 1 ] 3) in
     (* a record names the claim that started the countdown: the last of
        the burst (pin 0, then pins 2 and 1), here k + 2 *)
     check "injection: mismatch record, pc of the burst's last claim (k + 2)" ((not m.end_) && m.pc = k + 2);
     check "injection: mask = pin 0 only" (mask = 1);
     check "injection: actual pin 0 = what A drove" (actual land 1 = a_level);
     let expect_ts = ran_at pb (k + 2) + 1 + settle in
     Printf.printf "    timestamp %d, computed %d\n" m.ts expect_ts;
     check "injection: timestamp = cycle the EMIT ran + 1 + settle" (m.ts = expect_ts);
     check "injection: episode end at the next burst's compare, nothing suppressed"
       (e.end_ && e.pc = k + 6 && e.body = 0 && e.ts > m.ts);
     check "injection: nothing dropped" (m.dropped = 0 && e.dropped = 0)
   | _ -> ());

  (* -- storm: B claims pin 3 high once; A never drives it, so the pull-up
        agrees ... so A drives pin 3 low first; every later compare (one per
        claim, 30 of them) still sees it wrong -- *)
  let with_pin3 l p = (Engine.emit_state ~pin:3 ~level:l) :: p in
  let a = make ~mode:0 ~phys:(with_pin3 false (program ())) ~proto:proto_halt () in
  let bsh =
    make ~mode:Profile_table.mode_e0_shadow ~phys:(with_pin3 true (program ())) ~proto:proto_halt ()
  in
  let recs, _ = run [ a; bsh ] n_cycles in
  let r = fst (List.nth recs 1) in
  check "storm: one record for a claim wrong across every compare" (List.length r = 1);
  (match r with
   | [ m ] -> check "storm: it is the opening mismatch, first burst (pc 3), pin 3" ((not m.end_) && m.pc = 3 && m.body lsr 8 = 8)
   | _ -> ());

  (* -- overflow: alternate wrong and right claims on pin 0, 6 episodes =
        12 records, nothing read until the end -- *)
  let alt flipped =
    List.concat
      (List.init 12 (fun k ->
         let l = k land 1 = 1 in
         [ Engine.emit_state ~pin:0 ~level:(if flipped && k land 1 = 0 then not l else l);
           Engine.wait_edge ~pin:0 ~falling:false ~payload:gap ]))
    @ [ halt;
        Engine.emit_state ~pin:0 ~level:(not flipped); Engine.wait_edge ~pin:0 ~falling:false ~payload:gap;
        Engine.emit_state ~pin:0 ~level:true; Engine.wait_edge ~pin:0 ~falling:false ~payload:gap;
        Engine.wait_edge ~pin:6 ~falling:true ~payload:0 ]
  in
  let a = make ~mode:0 ~phys:(alt false) ~proto:proto_halt () in
  let bsh = make ~mode:Profile_table.mode_e0_shadow ~phys:(alt true) ~proto:proto_halt () in
  let _ = run ~drain:false [ a; bsh ] n_cycles in
  check "overflow: the FIFO holds 4" (get bsh.o.trace0_count = 4);
  let first = decode !(bsh.o.trace0_head) in
  check "overflow: the oldest is the first mismatch, nothing dropped before it" ((not first.end_) && first.dropped = 0);
  (* read one, then one more episode: its record carries the drop count *)
  bsh.i.trace_pop0 := Bits.vdd;
  Cyclesim.cycle bsh.sim;
  bsh.i.trace_pop0 := Bits.gnd;
  check "overflow: 3 left after one read" (get bsh.o.trace0_count = 3);
  (* release both cores past their halt (pin 7 low): one more episode *)
  let recs, _ = run ~force:(fun t w -> if t >= 2 then w land lnot 0x80 else w) [ a; bsh ] 200 in
  let r = fst (List.nth recs 1) in
  check "overflow: then 3 old records and the new episode's two" (List.length r = 5);
  (match List.nth_opt r 3 with
   | Some m ->
     Printf.printf "    dropped carried by the next record: %d\n" m.dropped;
     check "overflow: the first record after the drops carries their count (8)" ((not m.end_) && m.dropped = 8)
   | None -> ());

  (* -- µE1: same mechanism on µE1's EMIT_STATE pins (pins 4, 5) -- *)
  let p_prog flip =
    Protocol_engine.
      [ emit_state ~pin:4 ~level:true; emit_state ~pin:5 ~level:(not flip); emit_state ~pin:4 ~level:false ]
    @ proto_halt
  in
  let a = make ~mode:0 ~phys:[ halt ] ~proto:(p_prog false) () in
  let bsh = make ~mode:Profile_table.mode_e1_shadow ~phys:[ halt ] ~proto:(p_prog false) () in
  let recs, _ = run [ a; bsh ] 60 in
  check "uE1 round trip: nothing logged" (snd (List.nth recs 1) = []);
  let a = make ~mode:0 ~phys:[ halt ] ~proto:(p_prog false) () in
  let bsh = make ~mode:Profile_table.mode_e1_shadow ~phys:[ halt ] ~proto:(p_prog true) () in
  let recs, _ = run [ a; bsh ] 60 in
  (match snd (List.nth recs 1) with
   | [ m ] ->
     check "uE1 injection: one record, pin 5, pc of the last claim (one compare after it)"
       ((not m.end_) && m.body lsr 8 = 0x20 && m.pc = 2)
   | l -> check (Printf.sprintf "uE1 injection: one record (got %d)" (List.length l)) false);

  (* -- one core: µE1 drives pin 4, µE0 shadows it (the on-chip check that
        test_tt_um_dual_shadow runs through the real pins) -- *)
  let wait n = Engine.wait_edge ~pin:7 ~falling:true ~payload:n in
  let p0 =
    (* a timed wait cannot be a program's first instruction (the timer arms
       on the advance into it), so a no-op release comes first *)
    [ Engine.release_pin ~pin:7; wait 30; Engine.emit_state ~pin:4 ~level:true; wait 20; Engine.emit_state ~pin:4 ~level:false;
      wait 20; Engine.emit_state ~pin:4 ~level:true; wait 20; Engine.wait_edge ~pin:6 ~falling:true ~payload:0 ]
  in
  let c =
    make ~mode:Profile_table.mode_e0_shadow ~phys:p0
      ~proto:Protocol_engine.[ emit_state ~pin:4 ~level:true; fifo_pop_instr ] ()
  in
  let recs, _ = run [ c ] 400 in
  let r = fst (List.hd recs) in
  check "one core, uE1 drives, uE0 shadows: mismatch (pc 4) then episode end (pc 6)"
    (match r with [ m; e ] -> (not m.end_) && m.pc = 4 && e.end_ && e.pc = 6 | _ -> false);

  (* -- check mode: one core, driving, compares its own pins -- *)
  let prog = [ Engine.emit_state ~pin:0 ~level:true; Engine.wait_edge ~pin:0 ~falling:false ~payload:gap;
               Engine.emit_state ~pin:0 ~level:false; Engine.wait_edge ~pin:0 ~falling:false ~payload:gap;
               halt ] in
  let c = make ~mode:Profile_table.mode_e0_check ~phys:prog ~proto:proto_halt () in
  let recs, _ = run [ c ] 100 in
  check "check mode: a pad that follows the drive logs nothing" (fst (List.hd recs) = []);
  check "check mode: and the core still drives it" (get c.o.phys_pins_oe land 1 = 1);
  let c = make ~mode:Profile_table.mode_e0_check ~phys:prog ~proto:proto_halt () in
  let recs, _ = run ~force:(fun _ w -> w land lnot 1) [ c ] 100 in
  (match fst (List.hd recs) with
   | m :: _ -> check "check mode: a pad held low against a high drive is caught (pc 0)" ((not m.end_) && m.pc = 0)
   | [] -> check "check mode: contention caught" false);
  (* settle boundary: the core's own level change reaches its compare
     Dual.sync_latency cycles after the claim (the pad follows at once here) *)
  let at s = make ~settle:s ~mode:Profile_table.mode_e0_check ~phys:prog ~proto:proto_halt () in
  let c = at Dual.sync_latency in
  let recs, _ = run [ c ] 100 in
  check "settle = sync_latency: the core sees its own new level" (fst (List.hd recs) = []);
  let c = at (Dual.sync_latency - 1) in
  let recs, _ = run [ c ] 100 in
  (match fst (List.hd recs) with
   | m :: _ -> check "settle = sync_latency - 1: it still sees the old one (pc 2)" ((not m.end_) && m.pc = 2)
   | [] -> check "settle = sync_latency - 1: stale level seen" false);
  Printf.printf "RESULT: %s\n" (if !failures = 0 then "PASS" else "FAIL");
  if !failures > 0 then exit 1
