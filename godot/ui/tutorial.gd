class_name Tutorial
extends Control
## The tutorial, the mode picker and the one-step pointers. One overlay that lives above the screens (main.gd keeps it as
## `app.tutorial`) and follows the lab it is bound to (the lab calls lab_opened / lab_closed from build() and _exit_tree()).
##
## MODAL (the tutorial itself, `active`): everything is dimmed except the highlighted control(s); only those take clicks (_has_point). A banner holds the step text and
## "Back a step", "Do it for me" (performs the step's action, so no step can trap the player), "Next" (steps with nothing to do) and "Skip tutorial". Esc and the pad's
## B skip (main.gd back()). A step advances when the player has DONE its action: the state of the bench and of the live run is polled, nothing is trusted from clicks.
## Nothing in it runs by itself: the run starts when the player presses Run (step 5), as it does in every level.
## PAD: with a gamepad (Kit.pad_mode) the dimmed controls take no focus (_gate_focus), the focus starts on the control the step is about, and every button of the banner and
## every lit control can be reached with the D-pad. The step text names the pad buttons (the step's "pad" text). The wiring steps use the bench's own pad flow
## (cursor, X starts a wire, A finishes it).
## AMBIENT (not modal): a pulsing ring on m_threshold's first wired sensor card until it has been opened once, and a one-step pointer the first time the player
## opens m_inhibition, reflex, m_adaptation or m_tonic. They never take clicks except their own "Got it".
## PICKER: the one-screen difficulty choice (Guided / Standard / Researcher) over the campaign map, at the end of the tutorial and on the first Play if it was skipped.
## The "seen" flags live in progress.cfg [meta] (Progress.meta_get / meta_put): tutorial ("" | "done" | "skipped"), mode_picked, sensor_opened, tip_<task>.
## Reduced motion: no pulsing and no moving ghost, a static ring and a static arrow.
const TASK := "m_threshold"
const STEP_COUNT := 12   # the lab steps; the thirteenth, the mode picker, is shown over the campaign map
const TIPS := {
	"m_inhibition": {"text": "An inhibitory cell pushes other cells down, not up. Select a cell. Then press E / I to switch it.", "pad": "An inhibitory cell pushes other cells down, not up. Select a cell with A. Then move to E / I and press A.", "ids": ["BtnEI", "BtnInhibitory"]},
	"reflex": {"text": "One disc can stand for many cells. Select a cell. Then set the number in “neurons in group”.", "row": "neurons in group", "ids": []},
	"m_adaptation": {"text": "A cell has more settings than you see. Select a cell. Then press Advanced to open them.", "ids": ["BtnAdvanced"]},
	"m_tonic": {"text": "A bias current is a steady push that needs no input. Select a cell. Open Advanced and look for it.", "ids": ["BtnAdvanced"]},
}

var app
var lab: LabScreen = null
var active := false           # the modal tutorial is running
var step := 0                 # 1..STEP_COUNT while active
var picker_open := false
var tip_task := ""            # the pointer on screen ("" = none)
var _begin_pending := false   # begin() was called: the next lab_opened(TASK) starts step 1
var _prev_mode := ""
var _revisit := false         # this step was reached with Back: it waits for Next (its condition may already hold)
var _extra := ""              # the second cell step 11 added (removed again when the tutorial ends)
var _t := 0.0                 # seconds since the step started
var _idle := 0.0
var _check_seen := false
var _checks0 := 0             # lab.play.checks_done when the Check step began
var _gated := {}              # Control -> its focus mode before the pad gate took the focus off it (dimmed controls are not reachable)
var _gate_t := 0.0
var _focus_t := 0.0
var _pref_done := false       # the pad's focus has been on the control the step is about (it may only appear a moment after the step starts: the inspector is rebuilt)
var _spikes_seen := false
var _built_kind := ""
var _banner: PanelContainer
var _lbl_step: Label
var _lbl_text: Label
var _btn_back: Button
var _btn_do: Button
var _btn_next: Button
var _btn_skip: Button
var _tip: PanelContainer
var _tip_lbl: Label
var _picker: PanelContainer
var _spots: Array = []        # global Rect2s lit this frame
var _allow: Array = []        # global Rect2s that take clicks
var _ghost: Array = []        # [from, to] global points of the animated drag, or []
var _keep: Array = []         # global Rect2s the banner must stay off (what must be clicked)
var _ring := Rect2()          # the ambient ring (global), size 0 = none
var _fresh_lab := true
var _auto_did := 0
var _sel_done := false
var _shot_done := 0

## SP_TUT_SHOTS=<dir>: a picture of every step (and the picker) for the documentation; the dev walk (SP_TUT_STEP) goes on after each.
func _dev_shot(name: String) -> void:
	var dir := OS.get_environment("SP_TUT_SHOTS")
	DirAccess.make_dir_recursive_absolute(dir)
	get_viewport().get_texture().get_image().save_png(dir.path_join(name + ".png"))
	print("TUT shot ", name)

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT); mouse_filter = Control.MOUSE_FILTER_IGNORE; visible = false
	Kit.ident(self, "Tutorial"); z_index = 50

# ---------------------------------------------------------------------------------------------------- persistent state (static, so a test needs no node)
## A fresh save: the tutorial was never run or skipped and nothing has been played. Play then starts it.
static func pending() -> bool: return str(Progress.meta_get("tutorial", "")) == "" and Progress.is_fresh()
## The mode picker is owed: the tutorial is over (finished or skipped) and the player never chose a mode, on a save with nothing played.
static func picker_pending() -> bool: return str(Progress.meta_get("tutorial", "")) != "" and not bool(Progress.meta_get("mode_picked", false)) and Progress.is_fresh()
## The test walk's worlds: "fresh" (tutorial never seen), "skipped" (skipped, no mode chosen yet), "seen" (the default: done, mode chosen, every pointer seen), "tips" (seen, but the pointers are due).
static func test_world(kind: String) -> void:
	Progress._load()
	var keep := {}
	Progress._meta = keep
	if kind != "fresh":
		keep["tutorial"] = "done" if kind != "skipped" else "skipped"
		if kind != "skipped": keep["sensor_opened"] = true   # (a skipped tutorial keeps the sensor ring)
		if kind != "skipped": keep["mode_picked"] = true
		if kind != "tips":
			for t in TIPS: keep["tip_" + t] = true

## The test walk starts every world from nothing: no tutorial running, no picker, no pointer (the world's flags come from test_world).
func reset_for_test() -> void:
	active = false; step = 0; _begin_pending = false; _extra = ""; _prev_mode = ""; _revisit = false; lab = null
	close_picker(); _clear_tip(); _ring = Rect2(); _sync_visible()

# ---------------------------------------------------------------------------------------------------- entry points (main.gd, title.gd, tasks.gd, lab.gd)
## Title > Play: a fresh save starts the tutorial; a save that skipped it and never chose a mode gets the picker over the map; otherwise the map.
func on_play() -> void:
	if pending(): begin()
	else:
		app.show_screen("tasks")
		if picker_pending(): show_picker()

## Start (or replay) Plate 0: the lab opens on m_threshold in Guided mode with an empty bench (the bench that was there is kept in the history).
func begin() -> void:
	if app == null or app.cur == "lab" and lab != null and active: return
	_prev_mode = Progress.mode()
	if _prev_mode != "guided": Progress.set_mode("guided")
	var tid := TASK
	if app.lab_keep.has(tid): app.lab_keep.erase(tid)
	LabScreen._ref_loaded.erase(tid)
	if SaveIO.enabled():
		var path := Circuits.user_dir().path_join("last_%s.json" % tid)
		if FileAccess.file_exists(path):
			Circuits.history_push_file(tid, path); DirAccess.remove_absolute(SaveIO.g(path))
	close_picker(); _clear_tip()
	_begin_pending = true
	app.open_lab(tid)

## The lab built its screen (also after a relayout): bind to it; a pending begin() starts step 1; a first visit to a level with a pointer shows it.
func lab_opened(l: LabScreen) -> void:
	var was: LabScreen = lab
	lab = l
	if _begin_pending and l.task_id == TASK:
		_begin_pending = false; active = true; step = 0; _extra = ""
		Playlog.event("tutorial", {"what": "start"})
		_goto(1)
	elif was != l:
		_clear_tip(); _fresh_lab = true
	_sync_visible()

## The lab was freed. An unfinished tutorial ends (skipped) so nothing waits for a screen that is gone.
func lab_closed(l: LabScreen) -> void:
	if lab != l: return
	if tip_task != "": Progress.meta_put("tip_" + tip_task, true)
	if active: _finish("skipped", false)
	lab = null; _clear_tip(); _ring = Rect2(); _sync_visible()

## Esc / B (main.gd back()). The tutorial and the picker never trap the player: Esc skips the tutorial, or keeps the current mode.
func on_back() -> bool:
	if picker_open: _pick(Progress.mode()); return true
	if active: _finish("skipped", true); return true
	return false


func step_id() -> String:
	if picker_open: return "picker"
	if active: return "s%d" % step
	if tip_task != "" and _tip != null and _tip.visible: return "tip"
	return ""

## True while the overlay has controls on screen (the walk scans them).
func ui_visible() -> bool: return visible and (active or picker_open or (_tip != null and _tip.visible))

# ---------------------------------------------------------------------------------------------------- the steps
var _defs: Array = []
func _steps() -> Array:
	if _defs.is_empty(): _defs = _build_steps()
	return _defs

func _build_steps() -> Array:
	return [
		{"text": "This is the bench. On the left is a sensor. It sends a signal in. On the right is a motor. It shows what comes out. You build the cells in between.",
			"info": true, "kind": "next", "spot": func(): return [_card("in:pulse"), _card("out:spike")]},
		{"text": "Add a cell. Press + Excitatory.", "pad": "Add a cell. Move to + Excitatory and press A.",
			"kind": "act", "focus": "ctl:BtnExcitatory", "spot": func(): return _ctl_rects(["BtnExcitatory"]), "done": func(): return Circuits.neuron_count(lab.circuit) >= 1, "do": func(): lab._add_neuron("E")},
		{"text": "Connect the sensor to the cell. Drag from the right edge of the sensor onto the cell.",
			"pad": "Connect the sensor to the cell. Move the cursor to the sensor and press X. Then move to the cell and press A.",
			"kind": "act", "focus": "editor", "spot": func(): return [_card("in:pulse"), _pop_rect(_first_pop())], "allow": func(): return [_editor_rect()], "ghost": "in",
			"done": func(): return not _targets("inputs", "pulse").is_empty(), "do": func(): lab.editor._make_link({"t": "in", "name": "pulse"}, {"t": "pop", "id": _first_pop()})},
		{"text": "Connect the cell to the motor. Drag from the edge of the cell onto the motor.",
			"pad": "Connect the cell to the motor. Move the cursor to the cell and press X. Then move to the motor and press A.",
			"kind": "act", "focus": "editor", "spot": func(): return [_pop_rect(_first_pop()), _card("out:spike")], "allow": func(): return [_editor_rect()], "ghost": "out",
			"done": func(): return not _targets("outputs", "spike").is_empty(), "do": func(): lab.editor._make_link({"t": "pop", "id": _first_pop()}, {"t": "out", "name": "spike"})},
		{"text": "Press Run. Nothing runs until you press it.", "pad": "Press Run. Nothing runs until you press it. Move to Run and press A, or press Start.",
			"kind": "act", "focus": "ctl:BtnRun", "spot": func(): return _ctl_rects(["BtnRun"]), "done": func(): return _run_started(), "do": func(): _run_now()},
		{"text": "Top plot: each tick is one spike. A spike is the cell firing. Bottom line: the cell's voltage. It went up, but not far enough to fire. So there are no spikes yet.",
			"info": true, "kind": "next", "scopes": true, "spot": func(): return [_rect_of(lab.raster), _rect_of(lab.traces)] + _tab_rects()},
		{"text": "Make the signal stronger. Click the sensor. Drag the weight slider up. Press Run. Repeat until the cell fires.",
			"pad": "Make the signal stronger. Move the cursor to the sensor and press A. Press Y. Move the weight slider up. Press Start to run. Repeat until the cell fires.",
			"kind": "act", "focus": "editor", "spot": func(): return _weight_spot() + _ctl_rects(["BtnRun"]), "allow": func(): return [_editor_rect(), _rect_of(lab.inspector)] + _ctl_rects(["BtnRun"]) + _tab_rects(),
			"done": func(): return _spikes_seen, "do": func(): _set_weight(470.0); _run_now()},
		{"text": "The goal: fire on the big step, not on the small blip. Too strong and it fires on both. Change the weight, press Run, and read the score on the right. Repeat until it says passed.",
			"pad": "The goal: fire on the big step, not on the small blip. Too strong and it fires on both. Change the weight. Press Start to run. Read the score on the right. Repeat until it says passed.",
			"kind": "act", "focus": "ctl:BtnRun", "tab": "world", "spot": func(): return [_rect_of(lab.score_card), _rect_of(lab.inspector)] + _ctl_rects(["BtnRun"]) + _tab_rects(),
			"allow": func(): return [_editor_rect(), _rect_of(lab.inspector), _rect_of(lab.score_card), _rect_of(lab.raster)] + _ctl_rects(["BtnRun"]) + _tab_rects(),
			"done": func(): return lab.tele != null and bool(lab.tele.score.get("passed", false)), "do": func(): _set_weight(470.0); _run_now()},
		{"text": "Press Check. It tests your circuit five times, each with different noise.", "pad": "Move to Check and press A. It tests your circuit five times, each with different noise.",
			"kind": "act", "focus": "ctl:BtnCheck", "spot": func(): return _ctl_rects(["BtnCheck"]), "done": func(): return _check_seen, "do": func(): lab.play.check_start()},
		{"text": "The result is on the right. A pass earns a star. Passing all five tests and using few cells earns more.",
			"info": true, "kind": "next", "tab": "world", "spot": func(): return [_rect_of(lab.score_card)]},
		{"text": "I added a second cell. Select it and press E / I. Now it is inhibitory: it pushes other cells down instead of up.",
			"pad": "I added a second cell. Select it with A. Then move to E / I and press A. Now it is inhibitory: it pushes other cells down instead of up.",
			"kind": "act", "focus": "ctl:BtnEI", "spot": func(): return _ctl_rects(["BtnEI"]) if not _ctl_rects(["BtnEI"]).is_empty() else [_pop_rect(_extra)],
			"allow": func(): return [_editor_rect(), _rect_of(lab.inspector)], "done": func(): return Circuits.kinds(lab.circuit).get(_extra, "E") == "I", "do": func(): lab.insp.flip_kind(_extra)},
		{"text": "Stuck? Hint gives a nudge. Brief says what the level wants. Press Finish.",
			"kind": "next", "spot": func(): return _hint_spot()},
	]

## The text of a step: the pad's version while a gamepad is in use and the step has one.
func _text_of(st: Dictionary) -> String:
	return str(st["pad"]) if Kit.pad_mode and st.has("pad") else str(st["text"])

## The player started a run (the Run button, Space or Start): it plays or has played.
func _run_started() -> bool: return lab != null and lab.tele != null and lab.tele.sim != null and (lab.tele.running or lab.tele.t_ms > 0.0)

## Start (or restart) the run for the player, on the bench as it is now.
func _run_now() -> void:
	if lab == null or lab.tele == null or lab.tele.sim == null: return
	if lab._dirty >= 0.0 or lab.tele.finished or not lab.tele.running: lab._toggle_run()

func _goto(n: int) -> void:
	if OS.get_environment("SP_TUT_LOG") != "": print("TUT step %d -> %d" % [step, n])
	_sel_done = false
	step = clampi(n, 1, STEP_COUNT); _t = 0.0; _idle = 0.0; _check_seen = false; _spikes_seen = false; _revisit = false; _focus_t = 0.0; _pref_done = false
	if lab == null: return
	if lab.celebration != null: lab.celebration.dismiss_note()   # the notebook card of the pass that just happened must not follow the player into the next step
	var st: Dictionary = _steps()[step - 1]
	if bool(st.get("scopes", false)): _show_tab("scopes_only")
	elif st.has("tab"): _show_tab(str(st["tab"]))
	elif lab.layout.compact: _show_tab("circuit")
	if step == 9: _check_seen = false; _checks0 = lab.play.checks_done
	if step == 11 and (lab.circuit.get("populations", []) as Array).size() < 2 and _extra == "":
		lab._add_neuron("E"); _extra = str(((lab.circuit["populations"] as Array).back() as Dictionary).get("id", ""))
	elif step == 11 and _extra != "": lab.editor.select({"t": "pop", "id": _extra})
	if step == 12: lab.layout.show_brief()
	if lab.editor != null and is_instance_valid(lab.editor): _update_rects(st)   # the new step's lit areas now, so the pad's focus can start on its control
	_focus.call_deferred()
	_refresh_text()

func _next() -> void:
	if not active: return
	if step >= STEP_COUNT: _finish("done", true)
	else: _goto(step + 1)

func _back() -> void:
	if active and step > 1: _goto(step - 1); _revisit = true; _refresh_text()

func _do() -> void:
	if not active or lab == null: return
	var st: Dictionary = _steps()[step - 1]
	if st.has("do"): (st["do"] as Callable).call()
	if st.get("kind", "") == "act": _t = 0.0   # the polled condition fires on the next frames

## End the tutorial: `skipped` or `done`. The helper cell goes, the mode comes back (the picker or the player sets the final one), the map opens.
func _finish(how: String, go_map: bool) -> void:
	if not active: return
	active = false
	if lab != null and is_instance_valid(lab) and _extra != "":
		var id := _extra
		if Circuits.pop_index(lab.circuit, id) >= 0 and Circuits.neuron_count(lab.circuit) > 1:
			var wired := false
			for pr in lab.circuit.get("projections", []): wired = wired or Circuits.proj_pop(pr.get("pre", "")) == id or Circuits.proj_pop(pr.get("post", "")) == id
			if not wired: Circuits.remove_population(lab.circuit, id); lab.editor.select({}); lab._on_structure()
	_extra = ""
	Progress.meta_put("tutorial", how)
	if _prev_mode != "" and _prev_mode != Progress.mode(): Progress.set_mode(_prev_mode)
	_prev_mode = ""
	Playlog.event("tutorial", {"what": how, "step": step})
	if go_map:
		app.show_screen("tasks")
		if how == "done" or not bool(Progress.meta_get("mode_picked", false)): show_picker()
	_sync_visible()

# ---------------------------------------------------------------------------------------------------- geometry helpers (all in global coordinates)
## The lab's toast on screen (the Check verdict that step 9 talks about): the banner keeps off it as it keeps off the lit controls.
func _toast_rects() -> Array:
	var out := []
	if lab == null or lab.celebration == null: return out
	for t in lab.celebration._toasts:
		var r := _rect_of(t["node"] as Control)
		if r.size != Vector2.ZERO: out.append(r)
	return out

func _rect_of(c: Control) -> Rect2:
	if c == null or not is_instance_valid(c) or not c.is_visible_in_tree(): return Rect2()
	return c.get_global_rect()

func _ctl(id: String) -> Control:
	if lab == null or not is_instance_valid(lab): return null
	var c := lab.find_child(id, true, false) as Control
	return c if c != null and c.is_visible_in_tree() else null

func _ctl_rects(ids: Array) -> Array:
	var out := []
	for id in ids:
		var c := _ctl(str(id))
		if c != null: out.append(c.get_global_rect())
	return out

func _editor_rect() -> Rect2: return _rect_of(lab.editor) if lab != null and lab.editor != null else Rect2()

## The editor's sensor / motor card ("in:<name>" / "out:<name>") in global coordinates; empty before it was drawn.
func _card(key: String) -> Rect2:
	if lab == null or lab.editor == null: return Rect2()
	var cards: Dictionary = lab.editor._cards
	if not cards.has(key): return Rect2()
	var r: Rect2 = cards[key]
	return Rect2(lab.editor.get_global_rect().position + r.position, r.size)

func _pop_center(id: String) -> Vector2:
	var pi := Circuits.pop_index(lab.circuit, id) if lab != null else -1
	if pi < 0: return Vector2.INF
	var q: Array = lab.circuit["populations"][pi]["pos"][0]
	return lab.editor.get_global_rect().position + lab.editor.to_screen(Vector2(float(q[0]), float(q[1])))

func _pop_rect(id: String) -> Rect2:
	var c := _pop_center(id)
	if c == Vector2.INF: return Rect2()
	var r: float = lab.editor._r
	return Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0)

func _first_pop() -> String:
	var ps: Array = lab.circuit.get("populations", []) if lab != null else []
	return str((ps[0] as Dictionary).get("id", "")) if not ps.is_empty() else ""

func _targets(key: String, name: String) -> Array:
	if lab == null: return []
	for ch in lab.circuit.get(key, []):
		if str(ch.get("name", "")) == name: return ch.get("targets" if key == "inputs" else "neurons", [])
	return []

func _tab_rects() -> Array:
	var out := []
	if lab != null and lab.layout.compact:
		for k in lab.tab_btns: out.append(_rect_of(lab.tab_btns[k]))
	return out

func _show_tab(t: String) -> void:
	if lab == null or not lab.layout.compact: return
	lab.tab = t; lab.layout.apply_tab()

func _weight_row() -> Control:
	if lab == null or lab.insp_body == null or not is_instance_valid(lab.insp_body): return null
	if str(lab.insp_body.get_meta("sp_view", "")) != "in": return null
	var ss := lab.insp_body.find_children("*", "HSlider", true, false)
	return (ss[0] as Control).get_parent() as Control if not ss.is_empty() else null

## The sensor card until the player clicked it, then its weight row.
func _weight_spot() -> Array:
	var row := _weight_row()
	if row != null and row.is_visible_in_tree(): return [row.get_global_rect()]
	return [_card("in:pulse")]

func _set_weight(w: float) -> void:
	for ch in lab.circuit.get("inputs", []):
		if str(ch.get("name", "")) == "pulse": ch["weight"] = w
	lab.editor.select({"t": "in", "name": "pulse"}); lab._on_structure(); lab._build_inspector()

func _hint_spot() -> Array:
	var out := _ctl_rects(["BtnHint", "BtnBrief"])
	if out.is_empty(): out = _ctl_rects(["BtnMore"])
	out.append(_rect_of(lab.inspector))
	return out

func _union(rs: Array) -> Rect2:
	var u := Rect2(); var first := true
	for r in rs:
		if (r as Rect2).size == Vector2.ZERO: continue
		u = r if first else u.merge(r); first = false
	return u

func _vp() -> Vector2: return get_viewport_rect().size

# ---------------------------------------------------------------------------------------------------- per-frame
func _process(dt: float) -> void:
	_t += dt
	if lab != null and not is_instance_valid(lab): lab = null
	_spots = []; _allow = []; _ghost = []; _ring = Rect2(); _keep = []
	if active and lab != null and lab.editor != null and is_instance_valid(lab.editor): _tick_step(dt)
	elif lab != null and not picker_open: _tick_ambient()
	if picker_open and Kit.pad_mode:
		_gate_t -= dt
		if _gate_t <= 0.0: _gate_t = 0.15; _gate_focus()
	elif not _gated.is_empty() and not wants_focus(): _ungate_focus()
	_sync_visible(); _layout_ui(); queue_redraw()

## The lit areas of the step and the areas that take clicks (global rectangles), as the controls are laid out now.
func _update_rects(st: Dictionary) -> void:
	_spots = (st["spot"] as Callable).call().filter(func(r): return (r as Rect2).size != Vector2.ZERO)
	_allow = (st["allow"] as Callable).call().filter(func(r): return (r as Rect2).size != Vector2.ZERO) if st.has("allow") else _spots.duplicate()

func _tick_step(dt: float) -> void:
	var st: Dictionary = _steps()[step - 1]
	# step 7 is done when a run shows spikes (the run is the player's: nothing here starts, restarts or keeps one going)
	if step == 7 and lab.tele != null and lab.tele.sim != null and lab.tele.total_spikes > 0 and not _targets("inputs", "pulse").is_empty() and not _targets("outputs", "spike").is_empty(): _spikes_seen = true
	if step == 9:
		if lab.play._check_job != 0: _check_seen = false; _idle = -1.0   # a check is running
		elif (_idle < 0.0 or lab.play.checks_done > _checks0) and lab.score_card != null and lab.score_card.check_text != "": _check_seen = true
	_update_rects(st)
	if step == 11 and _extra != "" and not _sel_done and lab._dirty < 0.0 and _t > 0.4:   # the engine reload after adding the cell clears the selection: select the cell once more so the E / I button is there
		_sel_done = true; lab.editor.select({"t": "pop", "id": _extra})
	if str(lab.editor.sel.get("t", "")) == "in" and step >= 7: Progress.meta_put("sensor_opened", true)   # the sensor card was opened: its ring is done (a skipped tutorial keeps the ring)
	_keep = _tab_rects() + ([] if bool(st.get("info", false)) else _spots) + _toast_rects()
	if str(st.get("ghost", "")) != "" and not Kit.pad_mode: _ghost = _ghost_points(str(st["ghost"]))
	if Kit.pad_mode:
		_gate_t -= dt; _focus_t -= dt
		if _gate_t <= 0.0: _gate_t = 0.15; _gate_focus()
		if _focus_t <= 0.0:   # the focus is somewhere it may be: else it goes back to the step's own control (a rebuilt inspector drops it)
			_focus_t = 0.3
			var fo := get_viewport().gui_get_focus_owner()
			if fo == null or not focus_ok(fo) or (not _pref_done and _t < 2.5): _focus()
	if st.get("kind", "") == "act" and st.has("done") and not _revisit and _t > 0.15 and (st["done"] as Callable).call(): _next(); return
	if OS.get_environment("SP_TUT_SHOTS") != "" and _t > 1.2 and _shot_done != step: _shot_done = step; _dev_shot("step_%02d" % step)
	if OS.get_environment("SP_TUT_SHOTS") != "" and _shot_done != step: return   # the dev walk waits for the picture of this step
	if OS.get_environment("SP_TUT_STEP") != "" and step < int(OS.get_environment("SP_TUT_STEP")) and _t > 0.8:   # dev walk (screenshots): do each step for the player
		_t = 0.0
		if str(st.get("kind", "")) != "act": _next()
		elif _auto_did != step: _auto_did = step; _do()

func _ghost_points(which: String) -> Array:
	if which == "in":
		var c := _card("in:pulse"); var p := _pop_center(_first_pop())
		if c.size == Vector2.ZERO or p == Vector2.INF: return []
		return [Vector2(c.end.x - 12.0, c.get_center().y), p]
	var p2 := _pop_center(_first_pop()); var m := _card("out:spike")
	if m.size == Vector2.ZERO or p2 == Vector2.INF: return []
	var r: float = lab.editor._r
	return [p2 + Vector2(r * 0.85, 0.0), Vector2(m.position.x + 8.0, m.get_center().y)]

func _tick_ambient() -> void:
	if lab.editor == null or not is_instance_valid(lab.editor): return
	var seen_ring := bool(Progress.meta_get("sensor_opened", false))
	if lab.task_id == TASK and not seen_ring:
		if str(lab.editor.sel.get("t", "")) == "in": Progress.meta_put("sensor_opened", true)
		elif not _targets("inputs", "pulse").is_empty(): _ring = _card("in:pulse")
	if tip_task == "" and _fresh_lab:
		_fresh_lab = false
		var tid := lab.task_id
		if TIPS.has(tid) and not bool(Progress.meta_get("tip_" + tid, false)) and (tid != "m_tonic" or Campaign.order().has("m_tonic")) and not lab._is_dx() and OS.get_environment("SP_SHOT") == "":   # (not in screenshots: a pointer card over the bench)
			tip_task = tid; _build_tip()
	if tip_task != "" and _tip != null:
		var tgt := _tip_target()
		if tgt.size != Vector2.ZERO: _spots = [tgt]
		_place_tip(tgt)

func _tip_target() -> Rect2:
	var t: Dictionary = TIPS[tip_task]
	if t.has("row") and lab.insp_body != null:
		for l in lab.insp_body.find_children("*", "Label", true, false):
			if (l as Label).text == str(t["row"]) and (l as Label).is_visible_in_tree(): return ((l as Label).get_parent() as Control).get_global_rect()
	var rs := _ctl_rects(t["ids"])
	if not rs.is_empty(): return rs[0]
	var p := _pop_rect(_first_pop())
	return p

# ---------------------------------------------------------------------------------------------------- drawing and hit testing
func _has_point(p: Vector2) -> bool:
	if picker_open: return true
	if not active: return false
	var gp := get_global_transform() * p
	for r in _allow:
		if (r as Rect2).grow(8.0).has_point(gp): return false
	return true

func _pulse() -> float: return (0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)) if Kit.motion() else 0.6

func _draw() -> void:
	var vp := _vp()
	var dim := Color(Kit.INK, 0.62)
	if picker_open: draw_rect(Rect2(Vector2.ZERO, vp), Color(Kit.INK, 0.55)); return
	if active:
		for r in _dim_rects(_spots, vp): draw_rect(r, dim)
	var pulse := _pulse()
	for r in _spots:
		_ring_at(r, pulse)
	if _ring.size != Vector2.ZERO and not active: _ring_at(_ring, pulse)
	if _ghost.size() == 2: _draw_ghost(_ghost[0], _ghost[1])

func _ring_at(r: Rect2, pulse: float) -> void:
	var rr := r.grow(6.0 + 3.0 * pulse)
	Gfx.rounded_rect(self, rr, Color(Kit.GAMBOGE, 0.10 + 0.08 * pulse), Color(Kit.GAMBOGE, 0.75 + 0.25 * pulse), 10.0, 3.0)

## The dim, as rectangles around the lit areas (so nothing is drawn over them): bands between the lit rectangles' edges, the gaps in each band filled.
func _dim_rects(spots: Array, vp: Vector2) -> Array:
	var holes := []
	for s in spots: holes.append((s as Rect2).grow(6.0).intersection(Rect2(Vector2.ZERO, vp)))
	if holes.is_empty(): return [Rect2(Vector2.ZERO, vp)]
	var ys := [0.0, vp.y]
	for h in holes: ys.append(h.position.y); ys.append(h.end.y)
	ys.sort()
	var out := []
	for i in ys.size() - 1:
		var y0: float = ys[i]; var y1: float = ys[i + 1]
		if y1 - y0 < 0.5: continue
		var iv := []
		for h in holes:
			if h.position.y <= y0 + 0.01 and h.end.y >= y1 - 0.01: iv.append([h.position.x, h.end.x])
		iv.sort_custom(func(a, b): return a[0] < b[0])
		var x := 0.0
		for seg in iv:
			if seg[0] > x: out.append(Rect2(x, y0, seg[0] - x, y1 - y0))
			x = maxf(x, seg[1])
		if x < vp.x: out.append(Rect2(x, y0, vp.x - x, y1 - y0))
	return out

## An arrow from `a` to `b` with a dot that travels along it (still, at the midpoint, with reduced motion).
func _draw_ghost(a: Vector2, b: Vector2) -> void:
	var col := Kit.GAMBOGE
	draw_line(a, b, Color(col, 0.55), 4.0, true)
	var dir := (b - a).normalized(); var n := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([b, b - dir * 20.0 + n * 10.0, b - dir * 20.0 - n * 10.0]), Color(col, 0.85))
	var u := fmod(Time.get_ticks_msec() * 0.00055, 1.0) if Kit.motion() else 0.5
	var p := a.lerp(b, u)
	draw_circle(p, 15.0, Color(Kit.INK, 0.9)); draw_circle(p, 11.0, Color(Kit.PANEL, 1.0)); draw_circle(p, 5.0, Color(col, 1.0))

# ---------------------------------------------------------------------------------------------------- the banner, the pointer card, the picker
func _sync_visible() -> void:
	var v := active or picker_open or (tip_task != "" and _tip != null and _tip.visible) or _ring.size != Vector2.ZERO
	if visible != v: visible = v
	mouse_filter = Control.MOUSE_FILTER_STOP if (active or picker_open) else Control.MOUSE_FILTER_IGNORE
	if _banner != null: _banner.visible = active and not picker_open

func _ensure_ui() -> void:
	if _banner != null and _built_kind == Layout.kind and is_instance_valid(_banner): return
	for n in [_banner, _tip]:
		if n != null and is_instance_valid(n): n.queue_free()
	_built_kind = Layout.kind
	var phone := Layout.phone; var f := Kit.f()
	_banner = PanelContainer.new(); Kit.ident(_banner, "TutBanner")
	_banner.add_theme_stylebox_override("panel", Kit.plate_sb(Kit.PANEL_HI, 16 if not phone else 10))
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 8 if not phone else 4); _banner.add_child(v)
	_lbl_step = Kit.small_caps("", 15 if not phone else 12, Kit.TEXT_SOFT); v.add_child(_lbl_step)
	_lbl_text = Kit.label("", int(22 * f) if not phone else 15, Kit.TEXT, true); v.add_child(_lbl_text)
	var row := HFlowContainer.new(); row.add_theme_constant_override("h_separation", 8); row.add_theme_constant_override("v_separation", 4); v.add_child(row)
	var bs := 18 if not phone else 14
	_btn_back = _mk("Back a step", _back, "panel", bs, "TutBack"); row.add_child(_btn_back)
	_btn_do = _mk("Do it for me", _do, "ghost", bs, "TutDo"); row.add_child(_btn_do)
	_btn_next = _mk("Next", _next, "amber", bs, "TutNext"); row.add_child(_btn_next)
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sp.mouse_filter = Control.MOUSE_FILTER_IGNORE; row.add_child(sp)
	_btn_skip = _mk("Skip tutorial", func(): _finish("skipped", true), "panel", bs, "TutSkip"); row.add_child(_btn_skip)
	add_child(_banner); _banner.visible = false; _banner.z_index = 70   # above the lab's toasts (z 61)
	if tip_task != "": _build_tip()
	_refresh_text()

func _mk(text: String, cb: Callable, kind: String, size: int, id: String) -> Button:
	var b: Button = Kit.ident(Kit.btn(text, cb, kind, size), id)
	b.focus_mode = Control.FOCUS_ALL; b.mouse_filter = Control.MOUSE_FILTER_STOP
	return b

func _refresh_text() -> void:
	_ensure_ui()
	if not active or step < 1: return
	var st: Dictionary = _steps()[step - 1]
	_lbl_step.text = "Tutorial · step %d of %d" % [step, STEP_COUNT + 1]
	_lbl_text.text = _text_of(st)
	var act := str(st.get("kind", "next")) == "act"
	_btn_next.visible = (not act) or _revisit
	_btn_next.text = "Next" if step < STEP_COUNT else "Finish"
	_btn_do.visible = act
	_btn_back.visible = step > 1

func _layout_ui() -> void:
	_ensure_ui()
	if active and (_lbl_text.text != _text_of(_steps()[step - 1] as Dictionary) or _btn_next.visible != ((str((_steps()[step - 1] as Dictionary).get("kind", "")) != "act") or _revisit)): _refresh_text()
	var vp := _vp(); var phone := Layout.phone; var m := 12.0 if phone else 24.0
	if _banner.visible:
		var w := minf(vp.x - 2.0 * m, 880.0 * Kit.f() if not phone else vp.x)
		_lbl_text.custom_minimum_size.x = w - 44.0
		_banner.custom_minimum_size.x = w; _banner.size = Vector2(w, 0); _banner.reset_size()
		var h := _banner.size.y
		var u := _union(_spots + ([Rect2(_ghost[0], Vector2.ZERO)] if _ghost.size() == 2 else []))
		var top := Rect2(Vector2((vp.x - w) * 0.5, m), Vector2(w, h)); var bot := Rect2(Vector2((vp.x - w) * 0.5, vp.y - h - m), Vector2(w, h))
		var first_top := u.size == Vector2.ZERO or u.get_center().y > vp.y * 0.5
		var a: Rect2 = top if first_top else bot; var b: Rect2 = bot if first_top else top
		# the banner never covers what the player must click (the lit controls, the tabs); informational areas (scopes) may be partly covered
		_banner.position = (a if _overlap(a, _keep) <= _overlap(b, _keep) else b).position
	if _picker != null and _picker.visible: _place_center(_picker, vp)

func _overlap(r: Rect2, rs: Array) -> float:
	var t := 0.0
	for x in rs:
		var i := r.intersection(x as Rect2)
		if i.size.x > 0.0 and i.size.y > 0.0: t += i.get_area()
	return t

func _place_center(c: Control, vp: Vector2) -> void: c.position = ((vp - c.size) * 0.5).max(Vector2(8, 8))

## True when the pad may rest on `c`: the tutorial's own buttons, or a control inside a lit area (a dimmed control takes no focus while a gamepad is in use).
func focus_ok(c: Control) -> bool:
	if c == null or not Kit.pad_mode: return true
	if c == self or is_ancestor_of(c): return true
	if picker_open: return false
	if not active: return true
	var gp := c.get_global_rect().get_center()
	for r in _allow:
		if (r as Rect2).grow(8.0).has_point(gp): return true
	return false

## The pad is in use (or has just come on) and the tutorial or the picker is up: the focus goes to the step's own control.
func wants_focus() -> bool: return Kit.pad_mode and (active or picker_open)

func focus_now() -> void:
	_gate_focus()
	if picker_open:
		if _picker != null and is_instance_valid(_picker):
			var cur := _picker.find_child("Mode_" + Progress.mode(), true, false) as Control
			if cur != null and cur.is_visible_in_tree(): cur.grab_focus()
	elif active and lab != null: _focus()

## While a gamepad is in use, every control outside the lit areas (and everything under the mode picker) gets no focus, so the D-pad can only land where the step allows.
func _gate_focus() -> void:
	if app == null or not wants_focus():
		_ungate_focus(); return
	var root: Node = app.get("root") if app.get("root") != null else null
	if root == null: return
	for c in root.find_children("*", "Control", true, false):
		var ctl := c as Control
		if ctl == self or is_ancestor_of(ctl): continue
		if _gated.has(ctl):
			if focus_ok(ctl) and not picker_open: ctl.focus_mode = int(_gated[ctl]) as Control.FocusMode; _gated.erase(ctl)
			continue
		if ctl.focus_mode != Control.FOCUS_NONE and not focus_ok(ctl):
			_gated[ctl] = int(ctl.focus_mode); ctl.focus_mode = Control.FOCUS_NONE
	for k in _gated.keys():
		if not is_instance_valid(k): _gated.erase(k)

func _ungate_focus() -> void:
	for k in _gated:
		if is_instance_valid(k): (k as Control).focus_mode = int(_gated[k]) as Control.FocusMode
	_gated = {}

## The control the step is about takes the focus: its own lit control, else Next, else Do it for me.
func _focus() -> void:
	if not Kit.pad_mode or not active or lab == null or not is_instance_valid(lab): return
	_gate_focus()
	var st: Dictionary = _steps()[step - 1]
	var want: Control = null
	var f := str(st.get("focus", ""))
	if f == "editor": want = lab.editor
	elif f.begins_with("ctl:"): want = _ctl(f.substr(4))
	if want == null or want.focus_mode != Control.FOCUS_ALL or not want.is_visible_in_tree() or not focus_ok(want):
		want = _btn_next if _btn_next.visible else _btn_do
	else: _pref_done = true
	if want != null and want.is_visible_in_tree(): want.grab_focus()

# ----- the one-step pointer -----
func _build_tip() -> void:
	if _tip != null and is_instance_valid(_tip): _tip.queue_free()
	var phone := Layout.phone
	_tip = PanelContainer.new(); Kit.ident(_tip, "TutTip")
	_tip.add_theme_stylebox_override("panel", Kit.plate_sb(Kit.PANEL_HI, 12 if not phone else 8))
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 6); _tip.add_child(v)
	_tip_lbl = Kit.label(str(TIPS[tip_task]["text"]), 18 if not phone else 14, Kit.TEXT, true); _tip_lbl.custom_minimum_size.x = (420.0 if not phone else 280.0); v.add_child(_tip_lbl)
	var r := HBoxContainer.new(); v.add_child(r)
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sp.mouse_filter = Control.MOUSE_FILTER_IGNORE; r.add_child(sp)
	r.add_child(_mk("Got it", _clear_tip_seen, "amber", 16 if not phone else 13, "TutGotIt"))
	add_child(_tip); _tip.z_index = 5

func _clear_tip_seen() -> void:
	if tip_task != "": Progress.meta_put("tip_" + tip_task, true)
	_clear_tip()

func _clear_tip() -> void:
	tip_task = ""
	if _tip != null and is_instance_valid(_tip): _tip.queue_free()
	_tip = null; _tip_lbl = null

func _place_tip(target: Rect2) -> void:
	if _tip == null: return
	var vp := _vp(); _tip.reset_size()
	var s := _tip.size; var p: Vector2
	if target.size == Vector2.ZERO: p = Vector2(vp.x - s.x - 24.0, 96.0)
	else:
		p = Vector2(target.position.x, target.end.y + 14.0)
		if p.y + s.y > vp.y - 8.0: p.y = target.position.y - s.y - 14.0
	_tip.position = Vector2(clampf(p.x, 8.0, maxf(8.0, vp.x - s.x - 8.0)), clampf(p.y, 8.0, maxf(8.0, vp.y - s.y - 8.0)))
	_tip.visible = true

# ----- the mode picker -----
func show_picker() -> void:
	close_picker()
	picker_open = true
	var phone := Layout.phone; var f := Kit.f()
	_picker = PanelContainer.new(); Kit.ident(_picker, "TutPicker")
	_picker.add_theme_stylebox_override("panel", Kit.plate_sb(Kit.PANEL, 24 if not phone else 12))
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 10 if not phone else 6); _picker.add_child(v)
	v.add_child(Kit.small_caps("Tutorial · step %d of %d" % [STEP_COUNT + 1, STEP_COUNT + 1], 14 if not phone else 11, Kit.TEXT_SOFT))
	v.add_child(Kit.shout("How much help do you want?", int(40 * f) if not phone else 24, Kit.TEXT))
	var wide := minf(_vp().x - 32.0, 760.0 * f if not phone else _vp().x)
	var intro := Kit.label("Pick one to go to the map. You can change it later with the mode switch on the map.", int(20 * f) if not phone else 14, Kit.TEXT_SOFT, true); intro.custom_minimum_size.x = wide - 60.0; v.add_child(intro)
	var lines := {"guided": "The brief tells you how to build it. Hints are free. It is easier to pass.",
		"standard": "The how-to is behind a button, and using it costs a star. Hints open after two missed runs.",
		"researcher": "No how-to and no hints. To pass, all five test runs must pass. The noise is realistic."}
	for m in Progress.MODES:
		var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 14); v.add_child(row)
		var b := _mk(Progress.MODE_NAMES[m], func(): _pick(m), "amber" if m == Progress.mode() else "panel", int(24 * f) if not phone else 16, "Mode_" + m)
		b.custom_minimum_size.x = 190.0 * f if not phone else 110.0; row.add_child(b)
		var l := Kit.label(lines[m], int(19 * f) if not phone else 13, Kit.TEXT, true); l.size_flags_vertical = Control.SIZE_SHRINK_CENTER; l.custom_minimum_size.x = wide - (270.0 * f if not phone else 160.0); row.add_child(l)
	add_child(_picker); _picker.z_index = 6
	_sync_visible()
	if OS.get_environment("SP_TUT_SHOTS") != "": get_tree().create_timer(1.0).timeout.connect(func(): _dev_shot("step_12_picker"); if OS.get_environment("SP_TUT_STEP") != "": get_tree().quit())
	(func():
		if _picker != null and is_instance_valid(_picker):
			_picker.reset_size(); _place_center(_picker, _vp())
			var cur := _picker.find_child("Mode_" + Progress.mode(), true, false) as Control
			if cur != null and Kit.pad_mode: _gate_focus(); cur.grab_focus()).call_deferred()

func close_picker() -> void:
	picker_open = false
	if _picker != null and is_instance_valid(_picker): _picker.queue_free()
	_picker = null
	_sync_visible()

func _pick(m: String) -> void:
	if not picker_open: return
	Progress.set_mode(m); Progress.meta_put("mode_picked", true)
	close_picker()
	if app != null and app.cur != "tasks": app.show_screen("tasks")
	elif app != null and app.screen != null: app.screen.refresh()   # the map's mode switch shows the new mode
	if Kit.pad_mode and app != null: app.pad.ensure_focus.call_deferred(true)
