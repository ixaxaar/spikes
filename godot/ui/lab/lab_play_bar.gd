class_name LabPlayBar
extends RefCounted
## The lab's play controls (the controller is godot/ui/screens/lab.gd; the buttons sit on the top bar and in the More menu, LabLayout): difficulty mode
## and challenge variant, the hint ladder and its button, the verdict highlight (the part of the circuit a failed score is about), the instant headless
## Check, and Skip to the next scripted event.
var lab: LabScreen
var hint_panel: HintPanel = null
var hint_open := false
var _check_task = null             # instant check: the task handle that owns the async job
var _check_job := 0
var checks_done := 0                # results shown so far (the tutorial's Check step counts them: a quick check can finish within one slow frame)
var _check_t0 := 0
var _check_worlds := 1             # how many worlds the running check covers (5, or 1 for a challenge variant)
var _check_snap := {}              # the bench as it was when Check was pressed: {fp, ref, n}
var _check_toast: PanelContainer = null
var _check_lbl: Label = null

func set_mode(m: String) -> void:
	if m == lab.mode: return
	lab.mode = m; Progress.set_mode(m)
	hint_btn_sync(); if hint_open: hint_render()
	lab._reload(); lab._build_inspector(); lab.layout.refresh_bar.call_deferred()

func set_variant(v: String) -> void:
	if v == lab.variant: return
	lab.variant = v; lab._surprise_done.clear(); lab._reload(); lab._build_inspector()
	if lab.task_id != "": Playlog.event("variant", {"task": lab.task_id, "variant": lab.variant})

## The hint button on the bar: shown once hints are open (Guided, or Standard after HintPanel.UNLOCK_FAILS missed runs), never in Researcher mode.
## Before that the end-of-episode card and the More menu say how many missed runs are left.
func hint_btn_sync() -> void:
	var b := lab.layout.hint_btn
	if b == null or not is_instance_valid(b): return
	var tid := lab.task_id
	var fails := int(LabScreen._fails.get(tid, 0)); var shown := int(LabScreen._hint_tier.get(tid, 0))
	b.visible = lab.mode != "researcher" and HintPanel.available(lab.mode, fails)
	b.text = Kit.label_case(HintPanel.button_text(lab.mode, fails, shown))
	Kit.skin(b, "amber" if HintPanel.available(lab.mode, fails) else "ghost", 12)
	if lab.mode == "researcher" and hint_open: hint_close()

func task_hints() -> Array:
	var out := []; var tele := lab.tele
	if tele != null and tele.task != null and tele.task.has_method("hints"):
		for h in tele.task.hints(): out.append({"tier": int(h.get("tier", 0)), "text": str(h.get("text", "")), "target": str(h.get("target", ""))})
	if out.is_empty() and OS.get_environment("SP_FAKEHINTS") != "" and not (lab.circuit.get("populations", []) as Array).is_empty():   # dev hook: hints for tasks the engine has none for yet
		var pid := str(lab.circuit["populations"][0].get("id", ""))
		out = [{"tier": 1, "text": "This needs inhibition between the two sides: when one side fires, the other must be held quiet.", "target": ""},
			{"tier": 2, "text": "Look at the group %s: what drives it, and what should hold it back?" % pid, "target": pid},
			{"tier": 3, "text": "Add an inhibitory neuron after %s and connect it back onto the opposite side." % pid, "target": pid}]
	return out

func hint_toggle() -> void:
	if hint_open: hint_close(); return
	if lab.mode == "researcher": return
	hint_open = true
	var live := task_hints()
	if not live.is_empty(): lab._hints_cache = live
	hint_render()

func hint_close() -> void:
	hint_open = false
	if hint_panel != null and is_instance_valid(hint_panel): hint_panel.queue_free()
	hint_panel = null

func hint_render() -> void:
	var tid := lab.task_id
	if hint_panel == null or not is_instance_valid(hint_panel):
		hint_panel = HintPanel.new()
		hint_panel.next_pressed.connect(hint_next); hint_panel.close_pressed.connect(hint_close)
		if Layout.phone:
			var ov := lab.ov
			ov.add_child(hint_panel); hint_panel.set_anchors_preset(Control.PRESET_TOP_LEFT); hint_panel.offset_left = 14.0; hint_panel.offset_top = 52.0; hint_panel.custom_minimum_size.x = 400.0
			hint_panel.max_h = maxf((ov.size.y if ov.size.y > 100.0 else lab.get_viewport_rect().size.y) - 52.0 - 8.0, 120.0)   # the tiers scroll inside the card so tier 3 is reachable on a short screen
		else:
			lab.panels["circuit"].add_child(hint_panel); lab.panels["circuit"].move_child(hint_panel, 1)
	hint_panel.show_state(lab.mode, lab._hints_cache, int(LabScreen._hint_tier.get(tid, 0)), int(LabScreen._fails.get(tid, 0)))
	hint_btn_sync()

func hint_next() -> void:
	var tid := lab.task_id
	var live := task_hints()
	if not live.is_empty(): lab._hints_cache = live
	var by := {}
	for h in lab._hints_cache:
		if not by.has(int(h["tier"])): by[int(h["tier"])] = h
	var nxt := int(LabScreen._hint_tier.get(tid, 0)) + 1
	while nxt <= 3 and not by.has(nxt): nxt += 1
	if by.is_empty() or nxt > 3: hint_render(); return
	LabScreen._hint_tier[tid] = nxt; Progress.record_hint(tid, nxt); GameAudio.event("hint")
	var tgt := str(by[nxt].get("target", ""))
	if tgt != "" and nxt >= 2: lab.editor.hint_target = tgt; lab.editor.queue_redraw()
	hint_render()

## An episode (or a check, or a TEST) ended without a pass: count it toward the Standard hint ladder, cache the task's hints for this score state, light up the guilty part.
func note_fail() -> void:
	var tid := lab.task_id
	if tid == "" or lab._is_reference() or Circuits.neuron_count(lab.circuit) == 0 or lab._is_dx(): return
	var before := int(LabScreen._fails.get(tid, 0)); var was := HintPanel.available(lab.mode, before)
	# One miss per circuit: the run that ended and a CHECK of the very same circuit are one missed attempt, not two (the ladder opens after UNLOCK_FAILS different attempts).
	var fp := Circuits.fingerprint(lab.circuit) + "|" + lab.mode + "|" + lab.variant
	if str(LabScreen._fail_fp.get(tid, "")) != fp: LabScreen._fails[tid] = before + 1
	LabScreen._fail_fp[tid] = fp
	var h := task_hints()
	if not h.is_empty(): lab._hints_cache = h
	verdict_show()
	GameAudio.event("fail")
	if lab.mode == "standard" and not was and HintPanel.available(lab.mode, int(LabScreen._fails.get(tid, 0))) and lab.celebration != null:
		lab.celebration.toast("Hints unlocked", "Two runs have missed. The “Hint” button on the bar now gives a nudge: first the idea, then the place, then a partial recipe.", Kit.AMBER, 6.0)
	hint_btn_sync(); if hint_open: hint_render()

# ----- verdict highlight -----
## The element of the circuit a failed score is about: {target, part}. The task's own tier-2 hint target is the authority; failing that, a score part that names a channel
## or population; failing that, the motor channel that fires least (a silent output) or, for a part that counts false triggers, the one that fires most.
func guilty() -> Dictionary:
	var out := {"target": "", "part": ""}
	var tele := lab.tele; var circuit := lab.circuit
	var sc: Dictionary = tele.score if tele != null else {}
	var parts: Dictionary = sc.get("parts", {})
	for h in lab._hints_cache:
		var t := str(h.get("target", ""))
		if int(h.get("tier", 0)) == 2 and t != "" and lab.editor._element_exists(t): out["target"] = t; break
	var pops: Array = circuit.get("populations", [])
	for k in parts:
		var low := str(k).to_lower()
		for ch in circuit.get("outputs", []) + circuit.get("inputs", []):
			var nm := str(ch.get("name", "")).to_lower()
			if nm != "" and nm in low:
				if out["part"] == "": out["part"] = str(k)
				if out["target"] == "": out["target"] = ("out:" if circuit.get("outputs", []).has(ch) else "in:") + str(ch["name"])
		for p in pops:
			var id := str(p.get("id", "")).to_lower()
			if id.length() >= 2 and id in low:
				if out["part"] == "": out["part"] = str(k)
				if out["target"] == "": out["target"] = str(p["id"])
	if out["target"] == "" and tele != null and tele.sim != null:
		var act := Circuits.pop_activity(circuit, tele.count)
		var over := false
		for k in parts:
			var low := str(k).to_lower()
			if ("false" in low or "spurious" in low or "extra" in low) and not (parts[k] is String) and float(parts[k]) > 0.0: over = true; if out["part"] == "": out["part"] = str(k)
		var best_ch := ""; var best_v := 1.0e12 if not over else -1.0
		for ch in circuit.get("outputs", []):
			var v := 0.0
			for x in ch.get("neurons", []): v += float(act.get(Circuits.proj_pop(x), 0))
			if (over and v > best_v) or (not over and v < best_v): best_v = v; best_ch = str(ch.get("name", ""))
		if best_ch != "": out["target"] = "out:" + best_ch
		if out["part"] == "":   # name the worst-looking part chip: the first numeric one
			for k in parts:
				if not (parts[k] is String): out["part"] = str(k); break
	return out

func verdict_show() -> void:
	var g := guilty()
	lab.editor.verdict_target = str(g["target"]); lab.score_card.guilty = str(g["part"]); lab.editor.queue_redraw()

# ----- instant check -----
func check_start() -> void:
	var tid := lab.task_id; var tele := lab.tele
	if tid == "" or tele == null or tele.task == null or _check_job != 0: return
	if Circuits.neuron_count(lab.circuit) == 0 or tele.wiring_issue() != "": lab._banner_raw(tele.wiring_issue() if tele != null and tele.wiring_issue() != "" else "Add a neuron first."); return
	# CHECK runs the task's quick episode (Task::quick_duration_ms, the same rules on a shorter run; tasks without one run their full episode). Older extensions fall back to the full run.
	var quick := ClassDB.class_has_method("SpikeTask", "score_headless_quick_async")
	if not quick and not ClassDB.class_has_method("SpikeTask", "score_headless_async"):
		lab.celebration.toast("Instant check is not in this build", "Rebuild the extension (scripts/build-gd.sh) to get headless scoring.", Kit.RED, 4.0); return
	_check_task = Campaign.make(tid)
	if _check_task == null: return
	# CHECK runs the five worlds of the TEST (seeds 101-105, the circuit reseeded with each world, as the lab's TEST and the engine tests do): star 2 is "all five pass"
	# (Standard and Researcher; Guided stops at two stars). A challenge variant is judged on the live circuit's own seed, one world.
	var cseed := int(lab.circuit.get("seed", 1)); var cj := Circuits.to_json(Telemetry.sanitized(lab._live_circuit()))
	_check_worlds = 1 if lab.variant != "" else (lab.TEST_SEEDS as Array).size()
	var seeds := PackedInt64Array(lab.TEST_SEEDS) if _check_worlds > 1 else PackedInt64Array([cseed])
	var pin := -1 if _check_worlds > 1 else cseed
	_check_job = int(_check_task.score_headless_quick_async(cj, seeds, lab.mode, lab.variant, pin)) if quick \
		else int(_check_task.score_headless_async(cj, seeds, lab.mode, lab.variant, pin))
	_check_t0 = Time.get_ticks_msec()
	_check_snap = {"fp": Circuits.fingerprint(lab.circuit), "ref": lab._is_reference(), "n": Circuits.neuron_count(lab.circuit)}   # what was checked: a result for another bench is dropped
	if _check_job == 0: _check_task = null; lab.celebration.toast("Check could not start", "The headless scorer refused the circuit.", Kit.RED, 4.0); return
	var cb := lab.layout.check_btn
	if cb != null and is_instance_valid(cb): cb.text = "Checking..."; cb.disabled = true
	Playlog.event("check", {"task": tid})

## Stop a running instant check (leaving the lab, or a new check): the worker process is killed when the extension can, else the result is just dropped.
func check_cancel() -> void:
	if _check_job != 0 and _check_task != null:
		if _check_task.has_method("headless_cancel") or ClassDB.class_has_method("SpikeTask", "headless_cancel"): _check_task.call("headless_cancel", _check_job)
	_check_job = 0; _check_task = null; _check_snap = {}
	_check_button_reset()

func _check_button_reset() -> void:
	check_progress(false)
	var cb := lab.layout.check_btn if lab != null and lab.layout != null else null
	if cb != null and is_instance_valid(cb): cb.text = "Check"; cb.disabled = false

## A check that has not answered after this long is killed (a stalled model never finishes; the button must not stay disabled for ever).
const CHECK_TIMEOUT_MS := 60000

## While the async check runs: a card under the header with the seed count and the elapsed time (the worker reports no finer progress than done / not done).
func check_progress(on: bool) -> void:
	if not on:
		if _check_toast != null and is_instance_valid(_check_toast): _check_toast.queue_free()
		_check_toast = null; _check_lbl = null; return
	if _check_toast == null or not is_instance_valid(_check_toast):
		_check_toast = PanelContainer.new(); Kit.ident(_check_toast, "CheckToast"); _check_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_check_toast.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL_HI, Kit.TEXT, 2, 12, 12 if Layout.phone else 16, true))
		_check_lbl = Kit.label("", 17 if not Layout.phone else 15, Kit.TEXT, true); _check_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE; _check_toast.add_child(_check_lbl)
		lab.ov.add_child(_check_toast); _check_toast.z_index = 61
		_check_toast.set_anchors_preset(Control.PRESET_TOP_LEFT); _check_toast.offset_left = 240.0; _check_toast.offset_top = 56.0; _check_lbl.custom_minimum_size.x = 380.0
	_check_lbl.text = "Check running... %d world%s, %.1f s" % [_check_worlds, "" if _check_worlds == 1 else "s", (Time.get_ticks_msec() - _check_t0) * 0.001]

func check_poll() -> void:
	if _check_job == 0 or _check_task == null: return
	if Time.get_ticks_msec() - _check_t0 > CHECK_TIMEOUT_MS:
		check_cancel()
		lab.celebration.toast("Check timed out", "The check ran for %d s without finishing and was stopped. A cell model may be stuck: look for a huge weight or current, or press Run to watch the live circuit." % (CHECK_TIMEOUT_MS / 1000), Kit.RED, 8.0)
		return
	var r: Dictionary = _check_task.score_headless_poll(_check_job)
	if not bool(r.get("done", false)): check_progress(true); return
	check_progress(false)
	var snap := _check_snap; _check_snap = {}
	_check_job = 0; _check_task = null
	_check_button_reset()
	if not snap.is_empty() and (str(snap["fp"]) != Circuits.fingerprint(lab.circuit) or bool(snap["ref"]) != lab._is_reference()):   # the bench changed while it ran
		lab.celebration.toast("Check dropped", "The circuit changed while the check ran, so its result belongs to a bench you no longer have. Press Check again.", Kit.AMBER, 5.0); return
	if not bool(r.get("ok", false)): lab.celebration.toast("Check failed", str(r.get("error", "the headless run did not finish")), Kit.RED, 5.0); return
	var worlds := int(r.get("seeds", 1)); var wins := int(r.get("passes", 0)); var five := worlds >= 5 and wins == worlds
	var passed := bool(r.get("passed", false)) if worlds <= 1 else wins >= 1   # one world passing is the first star; all five is the second
	var val := int(roundf(float(r.get("value", 0.0))))
	var runs: Array = r.get("runs", []); var verdict := ""
	for rr in runs:   # the verdict of the first world that failed, else of the first
		if not bool((rr as Dictionary).get("passed", false)): verdict = str((rr as Dictionary).get("verdict", "")); break
	if verdict == "" and not runs.is_empty(): verdict = str((runs[0] as Dictionary).get("verdict", ""))
	verdict = Circuits.cap_verdict(verdict, lab.circuit, lab.task_id)
	var was_ref := bool(snap.get("ref", lab._is_reference()))
	var head := ("Check: passed, score %d" if five or (worlds <= 1 and passed) else "Check: not passed, score %d") % val
	if worlds > 1: head = "Check: %d of %d worlds passed, score %d" % [wins, worlds, val]
	GameAudio.event("pass" if passed else "fail")
	checks_done += 1
	if lab.score_card != null:   # the result is written on the score card (no toast): its first rows, until the bench changes or a run starts
		lab.score_card.check_text = head + "."; lab.score_card.check_verdict = verdict; lab.score_card.check_ok = five or (worlds <= 1 and passed)
	if not passed and not was_ref: note_fail()
	elif passed and not lab.lesion_on: _record_check(val, was_ref, five)

## A passing check counts as a pass (it ran the task's own seed), but not as the end-of-episode five-seed record. `was_ref`: the bench was the reference when the check started.
func _record_check(val: int, was_ref: bool, five := false) -> void:
	if was_ref or lab._is_reference() or lab.variant != "": return
	if lab._rec_pass and not five: return   # the live run already recorded this pass; only the five-world result adds something
	lab._record(true, five, float(val), -1.0)
	lab.layout.refresh_bar()

# ----- skip to the next scripted event -----
func skip_event() -> void:
	var tele := lab.tele
	if tele == null or tele.task == null or tele.sim == null or tele.finished: return
	var nx := -1.0
	if tele.task.has_method("next_event_ms"): nx = float(tele.task.next_event_ms(tele.t_ms))
	if nx < 0.0: lab.celebration.toast("No more events", "Nothing else is scripted in this episode: it just runs to the end. Raise the speed (More) to get there sooner.", Kit.TEXT_SOFT, 3.0); return
	var label := ""
	for e in tele.task.timeline():
		if absf(float(e.get("t_ms", -1.0)) - nx) < 1.5: label = str(e.get("label", ""))
	tele.skip_until(maxf(nx - 150.0, tele.t_ms + 1.0)); lab._sync_run_btn()
	lab.celebration.toast("Skipping to %s" % (label if label != "" else "the next event"), "t = %.1f s" % (nx * 0.001), Kit.CYAN, 2.0)
