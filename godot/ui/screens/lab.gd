class_name LabScreen
extends Screen
## The lab: circuit editor (left) and live instruments (right) around one running experiment. This file is the CONTROLLER: the state of the visit
## (the circuit, the live run, the episode record, the 5-seed test, the reference lock, diagnosis answers) and the actions that change it. The rest is in
## godot/ui/lab/:
##   lab_layout.gd     the panels, the top bar and palette, the More menu, the parts bin, the end-of-episode card and the histogram card
##   lab_inspector.gd  the inspector: brief, neuron / axon / channel editors, the lesion table, the diagnosis case card
##   lab_play_bar.gd   play controls: difficulty mode and variant, hints, verdict highlight, instant check, skip
##   lab_lesions.gd    the lesion lab (cut, silence, re-run on seeds, sweep, export)
##   lab_unlocks.gd    progressive disclosure: which tools a level shows
## The circuit Dictionary is the single source of truth; any structural edit reloads the engine (debounced) and restarts the episode.
const SPEEDS := [["0.25", "0.25x"], ["0.5", "0.5x"], ["1.0", "1x"], ["2.0", "2x"], ["5.0", "5x"], ["10.0", "10x"], ["20.0", "20x"], ["50.0", "50x"]]
const SENSOR_KIND := {"lamprey": "dc"}   # last resort when neither the task nor its reference circuit names a sensor kind
const TEST_SEEDS := [101, 102, 103, 104, 105]

var task_id := ""
var circuit := {}
var tele := Telemetry.new()
var editor: CircuitEditor
var task_view: TaskView
var score_card: ScoreCard
var raster: RasterView
var traces: TraceView
var gauges: GaugeView
var inspector: PanelContainer
var insp_body: VBoxContainer
var insp_scroll: ScrollContainer
var run_btn: Button
var back_btn: Button
var status: Label
var banner: Label
var tab_btns := {}
var panels := {}
var tab := "circuit"
var part_card := "iaf_psc_alpha"   # the parts-bin card the next added neuron is made from (a model, or a preset of one)
var timeline_view: TimelineView
var sandbox_panel: SandboxPanel
var mod_dials: ModDials
var celebration: Celebration
var ov: Control                    # overlay layer: phone inspector sheet, More menu, end-of-episode card
var ext_ok := false

## the modules (see the header)
var layout := LabLayout.new()
var insp := LabInspector.new()
var play := LabPlayBar.new()
var les := LabLesions.new()

## Lesion lab (after a pass): lesions = {"proj:<i>" | "pop:<id>" | "in:<name>": true}, rows = the lesion table, _lrun = the re-run in progress.
var lesion_on := false
var lesions := {}
var lesion_rows: Array = []
var _lrun: Lesion.Runner = null
var _lesion_open := false          # phone: the lesion sheet shows the table (else a one-line bar with Run / Sweep)
var _lesion_note := ""
var _dirty := -1.0
var _brief_forced := false
var _brief_full := false           # the brief's "More" expander is open
var _file_dlg: FileDialog
var _pending_banner := ""          # a message that arrived before the banner label existed (the first _reload runs before build)
var _fail_shown := false
var _adv_open := false             # the neuron inspector's Advanced fold
var _rec_done := false             # this episode's result has been recorded
var _rec_pass := false
var _overlay: Control = null
var _overlay_dismissed := false
var _test := {}                    # the 5-seed TEST in progress: {seeds, i, res, sim, task, t}
var _test_result := {}             # {passes, n, scores}: the last finished TEST on this circuit

## v0.3 lab play: difficulty mode and variant, hint ladder, verdict highlight, post-solve histograms, diagnosis, instant check, skip, celebration, surprise.
var mode := "standard"
var variant := ""
static var _fail_fp := {}          # task -> fingerprint of the circuit of the last counted miss (one miss per circuit)
static var _fails := {}            # task -> failed runs this session (the Standard hint ladder opens after HintPanel.UNLOCK_FAILS)
static var _hint_tier := {}        # task -> highest hint tier revealed
static var _ref_loaded := {}       # task -> the REFERENCE button filled the bench this session (an edited copy is still derived; cleared by Empty bench)
var _hints_cache: Array = []       # Task::hints() as of the last failed run
var _recipe_open := false          # Standard: Show recipe was pressed this visit (Progress.record_recipe holds it across visits)
var _last_edit_ms := -10000        # play-log edit coalescing: a slider drag is one edit
var _half_warned := false
var _surprise_done := {}
var _surprise_clock := 0.0
var _dx := {}                      # diagnosis case state {picked, tries, probes, probed, solved, gave_up, verdict, score}
var _dx_info := {}                 # Task::diagnosis()
var _ref_cache := {"n": -1, "fp": "", "v": false}
var _saved_text := ""              # the autosave as last written (an unchanged bench is not rewritten)
var _saved_ms := -100000           # when the "Saved" tick was last lit
var _stale := false                # the bench was edited since the last Run was pressed: the result on screen is out of date (the Run button is amber)
var _run_kind := ""                # the look the Run button has now ("panel" or "amber")
var _marker_on := false            # circuits/live_<task>.run exists: a live run is in progress (a stall leaves it behind; the next visit opens paused)
var _paused_open := false          # this visit opened paused because the last live run of this circuit never finished

func _init() -> void:
	super()
	layout.lab = self; insp.lab = self; play.lab = self; les.lab = self

func default_focus() -> Control: return back_btn
## Esc / B closes the topmost modal (results card, parts bin, More menu, end card or test card) before it leaves the lab.
func on_back() -> bool:
	if ConfirmCard.dismiss(): return true
	if layout.close_extra(): return true
	if layout.histo_ov != null and is_instance_valid(layout.histo_ov): layout.histo_hide(); return true
	if layout.parts_ov != null and is_instance_valid(layout.parts_ov): layout.close_parts(); return true
	if layout.menu != null and is_instance_valid(layout.menu): layout.close_menu(); return true
	if _overlay != null and is_instance_valid(_overlay):
		if not _test.is_empty(): _test_cancel()
		else: _overlay_dismissed = true; layout.overlay_hide()
		return true
	if editor != null and editor.cancel_pending(): return true   # a wire being drawn (keyboard, pad, connect tool)
	return false

func build() -> void:
	ext_ok = ClassDB.class_exists("SpikeSim") and ClassDB.class_exists("SpikeTask")
	if circuit.is_empty(): _start(app.lab_task if app != null else "")
	Circuits.sandbox = task_id == ""
	layout.build()
	if _pending_banner != "": _banner_raw(_pending_banner); _pending_banner = ""
	_attach()
	if OS.get_environment("SP_LABTAB") != "": tab = OS.get_environment("SP_LABTAB")
	if layout.compact: layout.apply_tab()
	_file_dlg = FileDialog.new(); Kit.ident(_file_dlg, "FileDlg"); _file_dlg.access = FileDialog.ACCESS_FILESYSTEM; _file_dlg.filters = PackedStringArray(["*.json ; Circuit JSON"]); _file_dlg.current_dir = ProjectSettings.globalize_path(Circuits.user_dir())
	add_child(_file_dlg)
	if _is_dx(): _brief_forced = true
	_build_inspector()
	play.hint_btn_sync()
	if OS.get_environment("SP_ADV") != "": _adv_open = true
	if app != null and app.lab_select != "":   # a cell type tapped in the Analysis wiring matrix
		if Circuits.pop_index(circuit, app.lab_select) >= 0: editor.select({"t": "pop", "id": app.lab_select})
		app.lab_select = ""
	if OS.get_environment("SP_SEL") != "": _select_env(OS.get_environment("SP_SEL"))
	if OS.get_environment("SP_MENU") != "": layout.open_menu()
	if OS.get_environment("SP_PARTS") != "": layout.open_parts()
	if OS.get_environment("SP_LESION") != "": les.env.call_deferred()
	_demo_hooks.call_deferred()
	if OS.get_environment("SP_TESTNOW") != "": _test_start.call_deferred()   # dev hook: run TEST x5 at once, print the result, quit
	if app != null and app.tutorial != null: app.tutorial.lab_opened(self)   # Plate 0, the sensor ring and the one-step pointers (ui/tutorial.gd)

## The circuit the live view runs: the player's, with the lesion set applied in the lesion lab.
func _live_circuit() -> Dictionary: return Lesion.apply(circuit, lesions) if lesion_on and not lesions.is_empty() else circuit

func _exit_tree() -> void:
	if app != null and app.tutorial != null: app.tutorial.lab_closed(self)
	play.check_cancel()
	flush_on_close()
	if task_id != "": Playlog.level_end(task_id, _rec_pass or bool(_dx.get("solved", false)))
	GameAudio.silence_body()
	if app != null and not circuit.is_empty() and not _is_dx(): app.lab_keep[task_id] = circuit
	if tele != null and tele.sim != null: tele.sim.stop()

# ---------- setup ----------
## Open `tid` ("" = free run). Starts from the task skeleton (its sensors and motors, no neurons), or the reference circuit with SP_REF=1.
func _start(tid: String) -> void:
	task_id = tid
	if OS.get_environment("SP_TASK") != "": task_id = OS.get_environment("SP_TASK")
	mode = Progress.mode(); variant = Campaign.pending_variant; Campaign.pending_variant = ""
	if OS.get_environment("SP_VARIANT") != "": variant = OS.get_environment("SP_VARIANT")
	if task_id != "": Playlog.level_start(task_id, variant)   # the only level_start of a visit (a variant switch is an event, the map sends none)
	var loaded := false
	if _is_dx() and ext_ok:   # a diagnosis case: the patient's circuit, read-only, straight from the task
		var dt = Campaign.make(task_id)
		if dt != null and dt.has_method("diagnosis"):
			_dx_info = dt.diagnosis(); _dx_info["task_id"] = task_id
			_dx = _dx_load()   # wrong picks, probes and a reveal from earlier visits (Progress)
			var dc := Circuits.parse(Circuits.read_reference(str(_dx_info.get("circuit", "")) if str(_dx_info.get("circuit", "")) != "" else _ref_path(task_id)))
			if not dc.is_empty(): circuit = dc; loaded = true
	var kept := false   # the circuit continues one from earlier in this session (so a REFERENCE taint carries over)
	if app != null and app.lab_keep.has(task_id) and OS.get_environment("SP_REF") == "" and not app.lab_reference:
		circuit = (app.lab_keep[task_id] as Dictionary).duplicate(true); loaded = true; kept = true
	if not kept: _ref_loaded.erase(task_id)
	_paused_open = not loaded and SaveIO.enabled() and FileAccess.file_exists(_marker_path())   # the last live run of this circuit never finished
	if not loaded and OS.get_environment("SP_CIRCUIT") != "":   # dev hook: open this circuit file
		loaded = _adopt(FileAccess.get_file_as_string(OS.get_environment("SP_CIRCUIT")), "The circuit file")
	if not loaded and ext_ok and task_id != "" and (OS.get_environment("SP_REF") != "" or (app != null and app.lab_reference)):
		var txt := Circuits.read_reference(_ref_path(task_id))
		var c := Circuits.parse(txt)
		if not c.is_empty():
			if SaveIO.enabled(): Circuits.history_push_file(task_id, _last_path())   # the saved bench stays reachable (More > Restore previous bench) once edits overwrite the autosave
			circuit = c; loaded = true; _set_ref_lock(true)   # stored in the circuit, so an edited copy stays locked after a restart (and after undo)
	if not loaded and SaveIO.enabled():
		var r := read_autosave(_last_path())
		if str(r["error"]) == "":
			circuit = r["circuit"]; loaded = true; _notice_repairs(int(r["repaired"]))
			if bool(r["ref_lock"]): _ref_loaded[task_id] = true   # the reference lock survives a restart
		elif str(r["error"]) != "none":   # a damaged autosave must not crash the level every time it opens: kept as .bad, the level starts on an empty bench
			_banner_raw("Your saved circuit for this level could not be opened (%s). It was kept as %s.bad and the level starts on an empty bench." % [str(r["error"]), SaveIO.g(_last_path())])
	if not loaded: circuit = _skeleton(task_id)
	_drop_old_flag()
	Circuits.ensure_pos(circuit)
	_ensure_task_weights()
	part_card = _default_part()
	_reload(true)
	if _paused_open and tele != null and tele.sim != null:   # opens paused, with a way forward
		tele.running = false; _run_marker(false)
		_banner_raw("The last live run of this circuit never finished (the game was closed or stalled while it ran). It opens paused: press Run to try again, or change the circuit first.")
	if OS.get_environment("SP_RUN") != "" and tele != null and tele.sim != null: tele.running = true   # dev hook: a run starts at once (a run is otherwise started by the player, with Run)
	if OS.get_environment("SP_SPEED") == "" and tele.task != null: tele.speed = _default_speed(float(tele.task.duration_ms()), str(Campaign.info(task_id).get("kind", "task")))

## G3 / v0.3 pacing: the default speed by episode length, from Telemetry.default_speed (it also knows what the machine measured it can deliver).
static func _default_speed(duration_ms: float, kind := "task") -> float: return Telemetry.default_speed(duration_ms, kind)

## The part the next neuron is made from at the start: the cell type the task declares (SpikeTask.default_model(): what its reference circuit and verdicts
## assume), else the first population model of the task's reference circuit (iaf_psc_alpha included), else iaf_psc_alpha. Never a guess from the name.
func _default_part() -> String:
	if task_id == "": return "iaf_psc_alpha"
	var dm := ""
	var t = Campaign.make(task_id)
	if t != null and t.has_method("default_model"): dm = str(t.call("default_model"))
	if dm != "":
		if Catalog.has_card(dm): return dm
		var cs := Catalog.cards_of(dm)
		if not cs.is_empty(): return str(cs[0]["id"])
	var ref := Circuits.parse(Circuits.read_reference(_ref_path(task_id)))
	if not (ref.get("populations", []) as Array).is_empty():
		var tc := _task_cards()
		if not tc.is_empty(): return str(tc[0])
	return "iaf_psc_alpha"

## Catalogue card ids "for this task": the cards of the models its reference circuit uses (in order of first use), then the other cards of the task's chapter.
func _task_cards() -> Array: return _cards_for(true)

## Only the cards of the models the reference circuit uses: the parts picker lets these be chosen even when their chapter is still locked (a recipe needs them).
func _reference_cards() -> Array: return _cards_for(false)

func _cards_for(with_chapter: bool) -> Array:
	var out := []
	if task_id == "": return out
	var ref := Circuits.parse(Circuits.read_reference(_ref_path(task_id)))
	var models := []
	for p in ref.get("populations", []):
		var m := str(p.get("model", ""))
		if not models.has(m): models.append(m)
	for m in models:
		var cs := Catalog.cards_of(m)
		if cs.is_empty(): continue
		var pick: Dictionary = cs[0]
		for c in cs:   # the card whose preset matches the reference's parameters, else the first of the model
			var match_all := true
			for p in ref.get("populations", []):
				if str(p.get("model", "")) == m and not (c["preset"] as Dictionary).is_empty() and (c["preset"] as Dictionary) != p.get("params", {}): match_all = false
			if match_all and not (c["preset"] as Dictionary).is_empty(): pick = c; break
		if not out.has(pick["id"]): out.append(pick["id"])
		for c in cs:   # every preset card of a used model (a reference may use two presets of one model)
			if not out.has(c["id"]) and not with_chapter: out.append(c["id"])
	if not with_chapter: return out
	var chap := str(Campaign.info(task_id).get("chapter", ""))
	for c in Catalog.cards():
		if Catalog.chapter_of(c["id"]) == chap and not out.has(c["id"]): out.append(c["id"])
	return out

## The reference lock. Reference circuits do not count for progress, and neither does anything derived from one. The game decides it, not the file:
## the circuit equals the reference exactly (Circuits.fingerprint: populations, models, sizes, projections, channels, editor positions, the file's provenance, and
## every number to a relative 1e-6), OR the REFERENCE button filled this bench in this session and it has not been emptied since (a nudged weight is still the reference).
## LOAD from disk or a copied reference file is caught by the fingerprint. A circuit the player built, even with the reference's round numbers, is not a copy.
func _is_reference() -> bool:
	if task_id == "" or _is_dx(): return false
	if bool(_ref_loaded.get(task_id, false)): return true
	var fp := Circuits.fingerprint(circuit)
	if fp != str(_ref_cache["fp"]): _ref_cache = {"fp": fp, "v": Circuits.is_reference_of(circuit, task_id)}
	return bool(_ref_cache["v"])

## 0.3 saves marked reference-derived circuits with a flag in the file; the fingerprint replaces it, so the flag is dropped on load.
func _drop_old_flag() -> void:
	var ed: Dictionary = circuit.get("meta", {}).get("editor", {})
	if ed.has("from_reference"): ed.erase("from_reference")

func _ref_path(tid: String) -> String: return Campaign.ref_path(tid)

func _last_path() -> String: return Circuits.user_dir().path_join("last_%s.json" % (task_id if task_id != "" else "free"))

## Read an autosave: {circuit, error, repaired, ref_lock}. error is "" (usable), "none" (no file) or why the file is not a usable circuit, in which case it has been
## renamed <path>.bad (a stale .bad is replaced).
static func read_autosave(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {"circuit": {}, "error": "none", "repaired": 0, "ref_lock": false}
	var r := Circuits.parse_checked(FileAccess.get_file_as_string(path))
	if str(r["error"]) != "":
		DirAccess.rename_absolute(SaveIO.g(path), SaveIO.g(path) + ".bad")
		SaveIO.log_line("circuit autosave %s rejected: %s" % [path, str(r["error"])])
		r["ref_lock"] = false; return r
	var ed: Variant = ((r["circuit"] as Dictionary).get("meta", {}) as Dictionary).get("editor", {})
	r["ref_lock"] = ed is Dictionary and bool((ed as Dictionary).get("ref_lock", false))
	return r

## Take circuit text from a file (Load, the dev hook): checked first. Returns false, with a banner, when it is not a usable circuit; true when `circuit` is now it.
func _adopt(text: String, what: String) -> bool:
	var r := Circuits.parse_checked(text)
	if str(r["error"]) != "": _banner_raw("%s could not be opened: %s." % [what, str(r["error"])]); return false
	circuit = r["circuit"]; _notice_repairs(int(r["repaired"]))
	if (circuit.get("meta", {}) as Dictionary).get("editor", {}) is Dictionary and bool((circuit["meta"]["editor"] as Dictionary).get("ref_lock", false)) and task_id != "": _ref_loaded[task_id] = true
	return true

func _notice_repairs(n: int) -> void:
	if n > 0: _banner_raw("%d neuron position%s in the file were damaged and have been laid out again; nothing else was changed." % [n, "" if n == 1 else "s"])

## The reference lock is stored in the circuit (meta.editor.ref_lock), so it survives a restart: set by REFERENCE, cleared by Empty bench or an emptied bench.
func _set_ref_lock(on: bool) -> void:
	if task_id == "": return
	if on: _ref_loaded[task_id] = true
	else: _ref_loaded.erase(task_id)
	var meta: Dictionary = circuit.get("meta", {}); var ed: Dictionary = meta.get("editor", {}) if meta.get("editor", {}) is Dictionary else {}
	if on: ed["ref_lock"] = true
	else: ed.erase("ref_lock")
	meta["editor"] = ed; circuit["meta"] = meta

## The empty bench of a task: its sensors and motors with the kinds the task reads (dc or Poisson sensors, rate or modulator motors) from the task's
## channel_kinds() or, until the extension has it, from its reference circuit.
func _skeleton(tid: String) -> Dictionary:
	if tid != "" and ext_ok:   # a locked-wiring level starts from the circuit it gives (the "empty" bench of such a level is that circuit again)
		var gc := given_circuit(tid)
		if not gc.is_empty(): return gc
	var c := Circuits.empty("My " + tid + " circuit" if tid != "" else "My circuit")
	if ext_ok and tid != "":
		var t = Campaign.make(tid)
		if t != null:
			var kinds := Circuits.task_channel_kinds(tid, t)
			for s in t.sensor_channels():
				var kind: String = str((kinds["inputs"] as Dictionary).get(str(s), SENSOR_KIND.get(tid, "poisson")))
				var tw: float = float((kinds["weights"] as Dictionary).get(str(s), 0.0))   # the task's own sensor weight (ChannelKind::weight), else the heuristic
				var inp := {"name": str(s), "kind": kind, "targets": [], "weight": tw if tw > 0.0 else Circuits.input_weight("iaf_psc_alpha", kind), "value": 0.0}
				if kind == "tuned_poisson":   # the tuning of the afferents (v0.6) is the level's: copy it from the reference circuit
					for rch in Circuits.parse(Circuits.read_reference(Campaign.ref_path(tid))).get("inputs", []):
						if str(rch.get("name", "")) == str(s):
							for k in ["rate_max", "rate_base", "kappa", "period_deg"]:
								if rch.has(k): inp[k] = rch[k]
				c["inputs"].append(inp)
			for m in t.motor_channels():
				var ch := {"name": str(m), "kind": "rate", "neurons": []}
				var ok: Dictionary = (kinds["outputs"] as Dictionary).get(str(m), {"kind": "rate"})
				Circuits.set_output_kind(ch, str(ok.get("kind", "rate")), str(ok.get("modulator", "NE")), float(ok.get("gain", Circuits.MOD_GAIN)), float(ok.get("tau_ms", Circuits.MOD_TAU)))
				c["outputs"].append(ch)
		c["meta"]["task"] = tid
		_store_task_weights(c, tid, t)
	return c

## The circuit a locked-wiring level hands the player (Task::given), a fresh copy; {} when the level gives none.
static func given_circuit(tid: String) -> Dictionary:
	var gp := Campaign.given_path(tid)
	if gp == "": return {}
	var c := Circuits.parse(Circuits.read_reference(gp))
	if c.is_empty(): return {}
	if not (c.get("meta", {}) is Dictionary): c["meta"] = {}
	c["meta"]["task"] = tid
	return c

## Remember the task-declared sensor weights in meta.editor.task_weights = {name: {kind, w}} so the first connect (editor, family wiring) uses them.
func _store_task_weights(c: Dictionary, tid: String, t: Variant = null) -> void:
	if tid == "" or not ext_ok: return
	if t == null: t = Campaign.make(tid)
	if t == null: return
	var kinds := Circuits.task_channel_kinds(tid, t); var tw := {}
	for name in kinds["weights"]:
		tw[name] = {"kind": str((kinds["inputs"] as Dictionary).get(name, "poisson")), "w": float(kinds["weights"][name])}
	var meta: Dictionary = c.get("meta", {}); var ed: Dictionary = meta.get("editor", {})
	if tw.is_empty(): ed.erase("task_weights")
	else: ed["task_weights"] = tw
	meta["editor"] = ed; c["meta"] = meta

func _ensure_task_weights() -> void:
	if task_id != "" and not _is_dx() and not (circuit.get("meta", {}).get("editor", {}) as Dictionary).has("task_weights"): _store_task_weights(circuit, task_id)

func _reload(first := false) -> void:
	var keep: Array = tele.watched.duplicate() if tele != null else []
	var sp := tele.speed if tele != null else 1.0
	if tele.sim != null: tele.sim.stop()
	var old_mods: Dictionary = tele.mods.duplicate() if tele != null else {}
	if celebration != null: celebration.abort()
	tele = Telemetry.new(); tele.running = false; tele.speed = sp; tele.mods = old_mods; tele.mode = mode; tele.variant = variant   # a reload opens at t = 0, paused: only the player starts a run (Run)
	tele.lesioned = lesion_on and not lesions.is_empty()   # the live view runs the lesioned circuit: watch the failure
	var ok := tele.setup(_live_circuit(), task_id, ext_ok)   # always makes the task, so the world and the brief show even for a half-built circuit
	if ok and not keep.is_empty() and not first:
		var valid := keep.filter(func(i): return i < tele.n)
		if not valid.is_empty(): tele.set_watched(valid)
	_fail_shown = false; _rec_done = false; _rec_pass = false; _overlay_dismissed = false; _test_result = {}
	if editor != null: editor.verdict_target = ""
	if score_card != null: score_card.guilty = ""
	layout.overlay_hide()
	if tele.error != "": _banner(tele.error)
	elif banner != null: banner.visible = false
	if first and OS.get_environment("SP_SPEED") != "": tele.speed = float(OS.get_environment("SP_SPEED"))
	if editor != null: _attach()

func _attach() -> void:
	editor.set_circuit(circuit, tele); task_view.attach(tele); timeline_view.attach(tele); score_card.attach(tele); raster.attach(tele); traces.attach(tele); gauges.attach(tele)
	gauges.custom_minimum_size = Vector2(0, 40.0 + 30.0 * maxi(1, tele.rates.size() if tele.sim != null else maxi(1, circuit.get("outputs", []).size())))
	if run_btn != null: _sync_run_btn()

func _banner(msg: String) -> void: _banner_raw("The engine rejected the circuit: " + msg)

## Show `msg` in the red banner under the lab; before build() has made the label it is kept and shown at the end of build().
func _banner_raw(msg: String) -> void:
	if banner == null: _pending_banner = msg; return
	banner.text = msg; banner.visible = true

func _on_structure() -> void:
	if task_id != "" and Time.get_ticks_msec() - _last_edit_ms > 1500: Playlog.event("edit", {"task": task_id})
	_last_edit_ms = Time.get_ticks_msec()
	_dirty = 0.0; les.reset(); _surprise_done.erase("osc")
	_stale = true; _clear_check()   # the circuit changed: a run in progress stops at t = 0 when the engine reloads (_reload); the old Check line is out of date
	if editor != null: editor.edit_pending()   # one undo step per burst of edits
	if editor != null: editor.verdict_target = ""
	if score_card != null: score_card.guilty = ""
	if Circuits.neuron_count(circuit) == 0: _set_ref_lock(false)   # an emptied bench is the player's own again; an edited reference is still derived from it

func _process(dt: float) -> void:
	if _dirty >= 0.0:
		_dirty += dt
		if _dirty > 0.3 and _lrun == null: _dirty = -1.0; _reload(); _build_inspector()
	var live := tele != null and tele.sim != null and tele.running and not tele.finished and not tele.failed and _test.is_empty()
	if live != _marker_on: _run_marker(live)   # before the step: a stall inside it leaves the marker behind
	if not _test.is_empty(): _test_step()
	elif _lrun != null: les.step()
	elif tele != null: tele.advance(dt)
	_watch_episode()
	play.check_poll(); _surprise_tick(dt)
	_sync_run_btn()
	if status != null and tele != null:
		var spd := String.num(tele.speed) + "x"
		if tele.sim != null and tele.running and tele.speed > 1.0 and tele.achieved < tele.speed * 0.85: spd = "%.1fx of %sx" % [tele.achieved, String.num(tele.speed)]
		var full := "t %.2f s    %s spikes    %s" % [tele.t_ms * 0.001, _short(tele.total_spikes), spd] if tele.sim != null else "no circuit running"
		if Time.get_ticks_msec() - _saved_ms < 2200: full += "    Saved"
		# a narrow bar (1366 wide, Large text, Undo / Redo and Test x5 on it): drop the spike count, then the speed, rather than clip a number in half
		var fnt := status.get_theme_font("font"); var fs := status.get_theme_font_size("font_size"); var room := status.size.x - 4.0
		if tele.sim != null and fnt != null and room > 0.0 and fnt.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
			full = "t %.2f s    %s" % [tele.t_ms * 0.001, spd]
			if fnt.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room: full = "t %.1f s" % (tele.t_ms * 0.001)
			if fnt.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room: full = ""
		status.text = full

static func _short(n: int) -> String: return "%.1fk" % (n / 1000.0) if n >= 10000 else str(n)

func _is_dx() -> bool: return task_id != "" and str(Campaign.info(task_id).get("kind", "")) == "diagnosis"
## A prediction bet (a_motif, a_predict): a diagnosis-kind level whose answer is committed before the run (Task::diagnosis().bet).
func _is_bet() -> bool: return _is_dx() and bool(_dx_info.get("bet", Campaign.is_bet(task_id)))

func _title() -> String:
	if task_id == "": return "Sandbox"
	return str(Campaign.info(task_id)["title"]) if ext_ok else "Lab"

# ---------- editing actions ----------
func _toggle_connect() -> void:
	editor.tool = "connect" if editor.tool == "select" else "select"; editor._connect_from = {}
	layout.sync_connect_btn(); editor.queue_redraw()

func _add_neuron(kind: String) -> void:
	if Circuits.has_locks(circuit): editor.note(Circuits.LOCK_ADD, 6.0); return
	var card := Catalog.card(part_card)
	var id := Circuits.add_card(circuit, card, editor.free_spot(), kind) if not card.is_empty() else Circuits.add_neuron(circuit, "iaf_psc_alpha", 0, editor.free_spot(), kind)
	editor.select({"t": "pop", "id": id}); editor.fit(); _on_structure()

func _add_noise() -> void:
	var name := Circuits.add_noise(circuit)
	editor.select({"t": "in", "name": name}); editor.fit(); _on_structure(); _build_inspector()

# ---------- run controls ----------
## Selecting a population makes only that population click (GameAudio.set_spike_focus); selecting anything else (or nothing) lets them all click.
func _sel_audio() -> void:
	var sel := editor.sel if editor != null else {}
	var f := -1
	if str(sel.get("t", "")) == "pop": f = Circuits.pop_index(circuit, str(sel["id"]))
	GameAudio.set_spike_focus(f)

func _toggle_run() -> void:
	if _dirty >= 0.0 and _lrun == null: _dirty = -1.0; _reload(); _build_inspector()   # an edit still waiting for its reload: the run is of the bench as it is now
	if tele.finished and tele.sim != null: _restart(); return   # a finished episode: Run plays it again
	tele.running = not tele.running
	if tele.running: _stale = false; _clear_check()
	GameAudio.event("run" if tele.running else "pause")
	if not tele.running: GameAudio.silence_body()
	_sync_run_btn()

## The Run button reads Pause while a run plays. It is outlined when the result on screen is current and amber when the bench changed since the last run.
func _sync_run_btn() -> void:
	if run_btn == null or tele == null: return
	var t := "Pause" if tele.sim != null and tele.running and not tele.finished and not tele.failed and _test.is_empty() else "Run"   # never "Pause" when nothing runs
	if run_btn.text != t: run_btn.text = t
	var kind := "amber" if (_stale and t == "Run") else "panel"
	if kind != _run_kind:
		_run_kind = kind; Kit.skin(run_btn, kind, int((18 if Layout.phone else 22) * 0.6))
		run_btn.tooltip_text = "The circuit changed since the last run. Press Run to see how it does now." if kind == "amber" else "Start or pause the run."

## The Check line on the score card goes when the bench changes or a run starts: it belongs to the bench it was made for.
func _clear_check() -> void:
	if score_card != null: score_card.check_text = ""; score_card.check_verdict = ""

## Back to t = 0. `run`: the episode plays at once (Run on a finished episode, Run again); false (Reset) leaves it paused at the start.
func _restart(run := true) -> void:
	layout.overlay_hide(); _overlay_dismissed = false; _rec_done = false; _rec_pass = false; _fail_shown = false
	if _dirty >= 0.0 and _lrun == null: _dirty = -1.0; _reload(); _build_inspector()
	if run: _stale = false
	_clear_check()
	if editor != null: editor.verdict_target = ""
	if score_card != null: score_card.guilty = ""
	if celebration != null: celebration.abort()
	GameAudio.event("run" if run else "pause")
	if tele.sim != null: tele.reset(); tele.running = run; _sync_run_btn()
	elif tele.task != null: tele.task.reset(int(circuit.get("seed", 1)))
	task_view.attach(tele)

## True when replacing the bench would throw work away: it has neurons and is not just the untouched reference.
func _bench_at_risk() -> bool:
	return task_id != "" and not _is_dx() and Circuits.neuron_count(circuit) > 0 and not Circuits.is_reference_of(circuit, task_id)

## Ask first when the bench has work on it; the replaced bench is then kept in the history (More > Restore previous bench).
func _replace_bench(title: String, what: String, yes: String, act: Callable) -> void:
	layout.close_menu()
	if not _bench_at_risk(): act.call(); return
	ConfirmCard.ask(ov, title, "%s Your current circuit (%s) is kept: More > Restore previous bench brings it back." % [what, Progress.neurons_text(Circuits.neuron_count(circuit))], yes, act)

func _keep_bench() -> void:
	if task_id == "" or _is_dx() or Circuits.is_reference_of(circuit, task_id): return
	Circuits.history_push(task_id, circuit)

## REFERENCE: the reference circuit on the bench. Offered only once the level is passed, or in Guided mode (LabLayout).
func _load_reference() -> void: _replace_bench("Put the reference circuit on the bench?", "The bench is replaced by the reference circuit, which earns no stars.", "Show reference", _do_load_reference)

func _do_load_reference() -> void:
	var txt := Circuits.read_reference(_ref_path(task_id))
	var c := Circuits.parse(txt)
	if c.is_empty(): _banner("the reference circuit for this task is not installed (circuits/%s)" % _ref_path(task_id)); return
	_keep_bench()
	circuit = c; Circuits.ensure_pos(circuit); _set_ref_lock(true); editor.select({}); les.reset(); _reload(true); _build_inspector()

## Start over from the task's skeleton: its sensors and motors, no neurons (and no longer reference-derived).
func _empty_bench() -> void:
	if task_id == "": return
	if Campaign.given_path(task_id) != "": _replace_bench("Restore the given circuit?", "The cell-type cards go back to their starting values.", "Restore given circuit", _do_empty_bench); return
	_replace_bench("Empty the bench?", "All neurons and connections are removed.", "Empty bench", _do_empty_bench)

func _do_empty_bench() -> void:
	layout.close_menu(); _test = {}; _lrun = null; _keep_bench(); _set_ref_lock(false)
	circuit = _skeleton(task_id); Circuits.ensure_pos(circuit); editor.select({}); les.reset(); _reload(true); _build_inspector(); _autosave()

## More > Restore previous bench: the newest bench in the history comes back (the one on the bench now goes into the history in its place).
func _has_history() -> bool: return task_id != "" and not _is_dx() and not Circuits.history_list(task_id).is_empty()

func _restore_bench() -> void:
	layout.close_menu()
	var c := Circuits.history_latest(task_id)
	if c.is_empty(): return
	Circuits.history_pop(task_id); _keep_bench()
	circuit = c; _drop_old_flag(); Circuits.ensure_pos(circuit)
	if bool((circuit.get("meta", {}) as Dictionary).get("editor", {}).get("ref_lock", false)): _ref_loaded[task_id] = true
	else: _ref_loaded.erase(task_id)
	editor.select({}); les.reset(); _reload(true); _build_inspector(); _autosave()

func _save_dialog() -> void:
	for cn in _file_dlg.file_selected.get_connections(): _file_dlg.file_selected.disconnect(cn["callable"])
	_file_dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE; _file_dlg.title = "Save circuit"
	_file_dlg.current_file = str(circuit.get("name", "circuit")).to_lower().replace(" ", "_") + ".json"
	_file_dlg.file_selected.connect(func(p):
		if not SaveIO.write_text(p, Circuits.to_json(circuit), -1.0): _banner_raw("The circuit could not be saved to %s." % p))
	_popup_file()

func _load_dialog() -> void:
	for cn in _file_dlg.file_selected.get_connections(): _file_dlg.file_selected.disconnect(cn["callable"])
	_file_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE; _file_dlg.title = "Load circuit"
	_file_dlg.file_selected.connect(func(p):
		var r := Circuits.parse_checked(FileAccess.get_file_as_string(p))
		if str(r["error"]) != "": _banner_raw("%s could not be opened: %s." % [p, str(r["error"])]); return
		_replace_bench("Load this circuit?", "The bench is replaced by the circuit in %s." % p.get_file(), "Load", func():
			_autosave(); _keep_bench()
			circuit = r["circuit"]; _notice_repairs(int(r["repaired"])); _drop_old_flag(); Circuits.ensure_pos(circuit)
			if bool((circuit.get("meta", {}) as Dictionary).get("editor", {}).get("ref_lock", false)): _ref_loaded[task_id] = true
			else: _ref_loaded.erase(task_id)
			editor.select({}); les.reset(); _reload(true); _build_inspector(); _autosave()))
	_popup_file()

func _popup_file() -> void: _file_dlg.popup_centered_clamped(Vector2i(900, 560), 0.9)

## Persist the player's circuit per task (user://circuits/last_<task>.json). Called after each edit, when a neuron is dropped, on leaving the lab and on window close.
## Never writes the untouched reference (it would replace the player's own saved bench); the reference lock is stored in the file (meta.editor.ref_lock).
func _autosave() -> void:
	if not SaveIO.enabled() or circuit.is_empty() or _is_dx(): return
	if task_id != "" and Circuits.is_reference_of(circuit, task_id): return
	var text := Circuits.to_json(circuit)
	if text == _saved_text: return
	if SaveIO.write_text(_last_path(), text, 120.0): _saved_text = text; _saved_ms = Time.get_ticks_msec()

## The window is closing or the lab is left: write everything pending (the circuit, the play log) and drop the live-run marker.
func flush_on_close() -> void:
	_autosave(); _run_marker(false); Playlog.flush()

func _marker_path() -> String: return Circuits.user_dir().path_join("live_%s.run" % (task_id if task_id != "" else "free"))

func _run_marker(on: bool) -> void:
	if not SaveIO.enabled(): _marker_on = false; return
	var p := _marker_path()
	if on:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null: f.store_string("1"); f.close()
	elif FileAccess.file_exists(p): DirAccess.remove_absolute(SaveIO.g(p))
	_marker_on = on

func _open_analysis() -> void: app.open_analysis(circuit, tele, task_id)

# ---------- progress, the episode record, 5-seed test ----------
func _rate_per_neuron() -> float: return tele.spike_rate_hz() / maxf(float(Circuits.neuron_count(circuit)), 1.0) if tele != null and tele.sim != null else -1.0

func _stars_now() -> int:
	if tele == null or tele.task == null: return 0
	var st := Progress.stars_for(task_id, bool(tele.score.get("passed", false)), false, Circuits.neuron_count(circuit), tele.spike_rate_hz() / maxf(float(Circuits.neuron_count(circuit)), 1.0))
	return mini(st, 2) if _recipe_used() else st

## Called every frame: record a pass the moment it happens and the final result at the end of the episode; report a stopped run.
func _watch_episode() -> void:
	if tele == null: return
	if tele.failed and not _fail_shown: _fail_shown = true; _banner_raw("The simulation stopped: " + tele.error + ". Fix the circuit and press “Reset”.")
	if _is_bet(): _watch_bet(); return
	if tele.task == null or tele.sim == null or tele.failed or not _test.is_empty() or lesion_on or _is_dx(): return
	var passed := bool(tele.score.get("passed", false))
	if passed and not _rec_pass:
		_rec_pass = true
		var first := not bool(Progress.best(task_id)["passed"]) and not _is_reference() and variant == ""
		_record(true, false)
		if mode == "researcher" and variant == "": first = false; celebration.toast("Passed once", "Researcher mode counts a pass only from “Test x5”: press it to record the pass.", Kit.AMBER, 5.0)
		if editor != null: editor.hint_target = ""; editor.verdict_target = ""
		if score_card != null: score_card.guilty = ""
		GameAudio.event("pass")
		if first: _celebrate()
		layout.refresh_bar()   # passing opens tools (Test x5 on the bar, Reference, Lesions, Results)
	if tele.finished and not _rec_done:
		_rec_done = true
		_record(passed, false)
		if not passed: play.note_fail()
		# (no card rises over the bench: the result is on the score card)

## Record a result: a pass in a challenge variant goes on the variant list (no stars), everything else is the task's own best.
func _record(passed: bool, five_seeds: bool, mean := -1.0, rate := -2.0) -> void:
	var r := _rate_per_neuron() if rate < -1.5 else rate
	var v := float(tele.score.get("value", 0.0)) if mean < 0.0 else mean
	if variant != "":
		if passed and not _is_reference() and _variant_ok(): Progress.record_variant(task_id, variant)
		return
	if mode == "researcher" and not five_seeds: passed = false   # Researcher: a pass needs all five TEST seeds
	Progress.record_result(task_id, v, {"passed": passed, "five_seeds": five_seeds, "neurons": Circuits.neuron_count(circuit), "rate_hz": r, "reference_derived": _is_reference(), "recipe_used": _recipe_used()})

## Diagnosis, third star: the case lists the probes that tell its top candidates apart (Task::diagnosis().probes: {kind "scope" target population id | kind "cut" target candidate id});
## the answer must come after one of them. A scope is the probe key "scope:<id>"; a cut is a "cut:" key of the link (or population) the candidate names, or a lesion re-run of it.
func _dx_probe_evidence() -> bool:
	var probes: Array = _dx_info.get("probes", [])
	if probes.is_empty(): return true   # an older extension lists none: nothing to require
	var seen: Dictionary = _dx.get("probed", {})
	for p in probes:
		var kind := str((p as Dictionary).get("kind", "")); var tgt := str((p as Dictionary).get("target", ""))
		if kind == "scope" and seen.has("scope:" + tgt): return true
		if kind != "cut": continue
		var parts := tgt.split("+")[0].split(">") if ">" in tgt else PackedStringArray()
		var key := "pop:" + tgt.trim_prefix("pop:") if tgt.begins_with("pop:") else ""
		if key == "" and parts.size() == 2:
			var i := 0
			for pr in circuit.get("projections", []):
				if str(pr.get("pre", "")) == parts[0] and str(pr.get("post", "")) == parts[1] and seen.has("cut:proj:%d" % i): return true
				i += 1
		elif key != "" and seen.has("cut:" + key): return true
		for k in seen:   # a lesion re-run (every single lesion) names its label: the link or group of the candidate
			if str(k).begins_with("run:") and (tgt.trim_prefix("pop:") in str(k)): return true
	return false

## The challenge variants that bind the lab, not only the engine's verdict: half_neurons passes only within half the par (Progress.budget).
func _variant_ok() -> bool:
	if variant != "half_neurons": return true
	var par := Progress.budget(task_id)
	if par <= 0: return true
	var lim := Progress.variant_budget(task_id, variant); var n := Circuits.neuron_count(circuit)   # the engine's own figure (half the par, rounded up), not a second rounding here
	if n <= lim: return true
	if not _half_warned and celebration != null:
		_half_warned = true
		celebration.toast("Over the half-neuron limit", "%s; this variant allows %d (half of par %d, rounded up). It does not count until the circuit is smaller." % [Progress.neurons_text(n), lim, par], Kit.AMBER, 6.0)
	return false

## A recipe is in force for the stars: Guided shows it inline (no cost), Standard costs the third star once Show recipe was pressed.
func _recipe_used() -> bool: return mode == "standard" and (_recipe_open or Progress.recipe_used(task_id))

## Task::recipe() when the extension has it (concrete numbers kept apart from the brief), else "".
func _recipe_text() -> String:
	if task_id == "" or tele == null or tele.task == null or not tele.task.has_method("recipe"): return ""
	return str(tele.task.call("recipe"))

func _ov_passed() -> bool:
	if not _test_result.is_empty(): return int(_test_result["passes"]) == int(_test_result["n"])
	return bool(tele.score.get("passed", false))

## TEST x5: five headless episodes of the task on five other seeds, run a slice of each frame. Pass on all five earns the second star.
func _test_start() -> void:
	if task_id == "" or tele.task == null or Circuits.neuron_count(circuit) == 0 or not _test.is_empty(): return
	if tele.wiring_issue() != "": _banner_raw(tele.wiring_issue()); return
	layout.close_menu(); _overlay_dismissed = false
	if tele.sim != null: tele.sim.stop()
	var sim = ClassDB.instantiate("SpikeSim"); var task = Campaign.make(task_id); Telemetry.configure(task, mode, variant)
	_test = {"i": 0, "res": [], "sim": sim, "task": task, "t": -1.0}
	tele.running = false
	layout.overlay_show(true)

func _test_cancel() -> void:
	_test = {}; layout.overlay_hide(); _reload(); _build_inspector()

func _test_step() -> void:
	var sim = _test["sim"]; var task = _test["task"]
	if float(_test["t"]) < 0.0:   # begin episode i
		var tc := Telemetry.sanitized(circuit)
		tc["seed"] = 1000 * int(TEST_SEEDS[int(_test["i"])]) + int(circuit.get("seed", 1))   # the circuit is reseeded with the world (as the engine's tests do), so a deterministic world is not five identical runs
		if not sim.load_circuit(Circuits.to_json(tc)): _test = {}; layout.overlay_hide(); _reload(); _banner(str(sim.error())); return
		task.reset(int(TEST_SEEDS[int(_test["i"])])); _test["t"] = 0.0
	var t0 := Time.get_ticks_usec(); var dur := float(task.duration_ms())
	while float(_test["t"]) < dur and Time.get_ticks_usec() - t0 < 12000:
		task.step(sim, 1.0); _test["t"] = float(_test["t"]) + 1.0
		if not bool(task.step_ok(sim)):
			_test = {}; layout.overlay_hide(); _reload(); _banner_raw("The test stopped: " + str(sim.error())); return
		if int(_test["t"]) % 200 == 0: sim.drain_spikes()
	layout.test_progress(int(TEST_SEEDS[int(_test["i"])]), 100.0 * float(_test["t"]) / maxf(dur, 1.0), _test["res"])
	if float(_test["t"]) < dur: return
	var sc: Dictionary = task.score(); (_test["res"] as Array).append({"value": float(sc.get("value", 0.0)), "passed": bool(sc.get("passed", false))})
	_test["i"] = int(_test["i"]) + 1; _test["t"] = -1.0
	if int(_test["i"]) < TEST_SEEDS.size(): return
	var res: Array = _test["res"]; var passes := 0
	for r in res: passes += 1 if r["passed"] else 0
	sim.stop(); _test = {}
	_reload()   # the live view again (the engine is a process-wide singleton and the test used it)
	_test_result = {"passes": passes, "n": res.size(), "scores": res.map(func(r): return r["value"])}
	if passes > 0:   # the mean of the five scores is the record, not the best of them
		var mean := 0.0
		for r in res: mean += float(r["value"])
		mean /= float(res.size())
		_record(true, passes == res.size(), mean, -1.0)
	if passes < res.size(): play.note_fail()
	_rec_done = true; layout.overlay_show(); _build_inspector(); layout.refresh_bar()
	if OS.get_environment("SP_TESTNOW") != "" and OS.get_environment("SP_SHOT") == "": print("TEST RESULT ", _test_result, " best ", Progress.best(task_id)); get_tree().quit()

# ---------- inspector (lab_inspector.gd) ----------
func _select_env(s: String) -> void:   # SP_SEL=pop:L | proj:0 | in:drive | out:left_motor
	var p := s.split(":"); if p.size() < 2: return
	match p[0]:
		"pop": editor.select({"t": "pop", "id": p[1]})
		"proj": editor.select({"t": "proj", "i": int(p[1])})
		"in", "out": editor.select({"t": p[0], "name": p[1]})

func _build_inspector() -> void: insp.build()

# ---------- lesion lab (lab_lesions.gd); kept here for the smoke test and the end card ----------
func _lesion_ok() -> bool: return les.ok()
func _lesion_toggle() -> void: les.toggle()

# ----- surprise: an unintended rhythm -----
func _surprise_tick(dt: float) -> void:
	_surprise_clock += dt
	if _surprise_clock < 0.8: return
	_surprise_clock = 0.0
	if task_id == "" or tele == null or tele.sim == null or tele.finished or not tele.running or not _test.is_empty() or _lrun != null or _surprise_done.has("osc") or _is_dx(): return
	var info := Campaign.info(task_id)
	if Surprise.is_rhythm_task(task_id, (info.get("concepts_new", []) as Array) + (info.get("concepts_used", []) as Array)): return
	if not Circuits.has_loop(circuit): return   # no feedback loop in the circuit: a rhythm in its spikes is the task's own stimulus, not something the player built
	var r := Surprise.rhythm(tele)
	if not bool(r["found"]): return
	if Surprise.stimulus_is_periodic(info.get("timeline", []), float(r["period_ms"])): return   # the task itself pulses: a rhythm that follows it is not a surprise
	_surprise_done["osc"] = true
	var tx := Surprise.oscillation_text(r)
	GameAudio.event("celebrate")
	celebration.toast(str(tx["title"]), str(tx["text"]), Kit.GREEN, 9.0)
	Playlog.event("surprise", {"task": task_id, "period_ms": r["period_ms"], "pop": r["pop"]})

# ----- first-pass celebration -----
func _celebrate() -> void:
	var sens := Array(tele.task.sensor_channels()) if tele.task != null else []
	var mot := Array(tele.task.motor_channels()) if tele.task != null else []
	var path := Circuits.critical_path(circuit, Circuits.pop_activity(circuit, tele.count), sens, mot)
	celebration.first_pass(editor, tele, path, Campaign.notebook(task_id))
	Playlog.event("celebrate", {"task": task_id})

# ---------- diagnosis cases ----------
## A probe of a diagnosis case (a scope opened on a group, a cut tried on the live view, a lesion run): counted once per thing probed, so that looking again is free.
## The count goes to the engine with the answer (Task variant "candidate@probes:wrong", engine/src/tasks/dx_common.h), where it lowers the case's score beyond the first few.
func _dx_probe(kind: String, key: String) -> void:
	if not _is_dx() or bool(_dx.get("solved", false)) or bool(_dx.get("gave_up", false)): return
	var seen: Dictionary = _dx.get("probed", {}); var k := kind + ":" + key
	if seen.has(k): return
	seen[k] = true; _dx["probed"] = seen; _dx["probes"] = seen.size(); _dx_persist()

## The case state as the save holds it: a new visit does not start from nothing.
func _dx_load() -> Dictionary:
	var st := Progress.dx_state(task_id)
	return {"tries": int(st["tries"]), "probes": int(st["probes"]), "probed": st["probed"], "wrong": st["wrong"], "revealed": bool(st["revealed"])}

func _dx_persist() -> void:
	if task_id == "": return
	Progress.dx_put(task_id, {"tries": int(_dx.get("tries", 0)), "probes": int(_dx.get("probes", 0)), "probed": _dx.get("probed", {}), "wrong": _dx.get("wrong", []), "revealed": bool(_dx.get("revealed", false))})

func _dx_submit() -> void:
	var cand := str(_dx.get("picked", ""))
	if cand == "" or tele == null or tele.task == null or not tele.task.has_method("set_variant"): return
	if _is_bet(): _bet_commit(); return
	tele.task.set_variant("%s@%d:%d" % [cand, int(_dx.get("probes", 0)), int(_dx.get("tries", 0))])   # the diagnosis tasks take the answer through the variant slot (engine/src/tasks/dx_common.h)
	_dx_apply(cand, tele.task.score())

## A prediction bet: the commit is sent with the new run (the answer string "candidate@reads:wrong" is handed to the task before it is reset, as the engine expects), the
## episode plays on the bench, and the verdict is read when it ends (_watch_bet). A wrong bet can be followed by another; each costs what the engine says.
func _bet_commit() -> void:
	var cand := str(_dx.get("picked", ""))
	if cand == "" or bool(_dx.get("running", false)) or bool(_dx.get("solved", false)) or bool(_dx.get("gave_up", false)): return
	_dx["committed"] = cand; _dx["running"] = true; _dx["verdict"] = ""
	var keep := variant
	variant = "%s@%d:%d" % [cand, int(_dx.get("probes", 0)), int(_dx.get("tries", 0))]
	_reload(); variant = keep
	if tele != null: tele.running = true
	_sync_run_btn(); _build_inspector()

func _watch_bet() -> void:
	if not bool(_dx.get("running", false)) or tele == null or tele.task == null or tele.sim == null or not tele.finished: return
	_dx["running"] = false
	_dx_apply(str(_dx.get("committed", "")), tele.task.score())

## The judgement of an answer (a diagnosis case's submit, or a bet's finished run): the result card, the record, the next state.
func _dx_apply(cand: String, sc: Dictionary) -> void:
	var ok := bool(sc.get("passed", false))
	_dx["verdict"] = str(sc.get("verdict", "")); _dx["score"] = float(sc.get("value", 0.0))
	Playlog.event("diagnosis", {"task": task_id, "answer": cand, "correct": ok, "probes": int(_dx.get("probes", 0)), "wrong_before": int(_dx.get("tries", 0))})
	if ok:
		_dx["solved"] = true; editor.verdict_target = Circuits.candidate_focus(cand); editor.verdict_ok = true
		var first := not bool(Progress.best(task_id)["passed"])
		Progress.record_result(task_id, float(sc.get("value", 100.0)), {"passed": true, "five_seeds": int(_dx.get("tries", 0)) == 0, "neurons": 0, "rate_hz": -1.0, "reference_derived": false,
			"max_stars": 1 if (bool(_dx.get("revealed", false)) or Progress.dx_revealed(task_id)) else (3 if float(sc.get("value", 0.0)) >= 85.0 and _dx_probe_evidence() else 2)})   # one star for the cause, two for no wrong answer, three for no wrong answer and few probes (a score of 85 or more); a revealed case: one
		Progress.dx_solved(task_id)
		GameAudio.event("pass")
		if first: celebration.first_pass(editor, tele, Circuits.critical_path(circuit, Circuits.pop_activity(circuit, tele.count), Array(tele.task.sensor_channels()), Array(tele.task.motor_channels())), Campaign.notebook(task_id))
	else:
		_dx["tries"] = int(_dx.get("tries", 0)) + 1; GameAudio.event("fail")
		var wr: Array = _dx.get("wrong", []); if not wr.has(cand): wr.append(cand)
		if _is_bet(): _dx["picked"] = ""   # a wrong bet: the answer is chosen again
		_dx["wrong"] = wr; _dx_persist()   # a wrong pick says only "not that one": no lit-up connection, no reason (the reasons come with the solved or revealed case)
	_build_inspector(); _scroll_end.call_deferred()

## Bring the bottom of the inspector (a diagnosis reveal) into view once the new content is laid out.
func _scroll_end() -> void:
	await get_tree().process_frame; await get_tree().process_frame
	if insp_scroll != null and is_instance_valid(insp_scroll): insp_scroll.scroll_vertical = int(insp_scroll.get_v_scroll_bar().max_value)

func _dx_reveal() -> void:
	_dx["gave_up"] = true; _dx["revealed"] = true; _dx_persist()   # saved: coming back later does not give the case back for full marks
	if tele != null and tele.task != null and tele.task.has_method("set_variant"):
		tele.task.set_variant("%s@revealed" % str(_dx_info.get("answer", "")))
		_dx["verdict"] = str(tele.task.score().get("verdict", ""))
	editor.verdict_target = Circuits.candidate_focus(str(_dx_info.get("answer", ""))); editor.verdict_ok = false
	_build_inspector(); _scroll_end.call_deferred()

# ---------- dev hooks for screenshots ----------
## SP_HINT=1|2|3 opens the hint card with that many tiers shown (with SP_FAKEHINTS=1 for tasks the engine has no hints for), SP_VERDICT=1 lights the guilty element,
## SP_HISTO=1 opens the histograms, SP_CELEB=1 runs the first-pass celebration, SP_DXPICK=<candidate> picks and SP_DXSUBMIT=1 submits in a diagnosis case,
## SP_FAILS=n sets the failed-run count, SP_CHECK=1 presses Check, SP_SKIP=1 presses Skip, SP_BRIEF=full opens the brief's expander.
func _demo_hooks() -> void:
	if OS.get_environment("SP_FAILS") != "": _fails[task_id] = int(OS.get_environment("SP_FAILS")); play.hint_btn_sync()
	if OS.get_environment("SP_BRIEF") == "full": _brief_full = true; _build_inspector()
	if OS.get_environment("SP_HINT") != "":
		await get_tree().create_timer(0.8).timeout
		_hints_cache = play.task_hints(); play.hint_open = true; _hint_tier[task_id] = 0
		for i in int(OS.get_environment("SP_HINT")): play.hint_next()
		play.hint_render()
	if OS.get_environment("SP_VERDICT") != "":
		await get_tree().create_timer(1.0).timeout
		_hints_cache = play.task_hints(); play.verdict_show()
	if OS.get_environment("SP_HISTO") != "":
		await get_tree().create_timer(1.2).timeout
		layout.histo_show()
	if OS.get_environment("SP_CELEB") != "":
		await get_tree().create_timer(1.0).timeout
		_celebrate()
	if OS.get_environment("SP_CHECK") != "":
		await get_tree().create_timer(1.0).timeout
		play.check_start()
	if OS.get_environment("SP_SKIP") != "":
		await get_tree().create_timer(1.0).timeout
		play.skip_event()
	if OS.get_environment("SP_DXPICK") != "":
		await get_tree().create_timer(0.8).timeout
		_dx["picked"] = OS.get_environment("SP_DXPICK"); _build_inspector()
		if OS.get_environment("SP_DXSUBMIT") != "": _dx_submit()
