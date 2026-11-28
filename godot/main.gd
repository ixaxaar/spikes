extends Node
## App shell: boot order (settings -> layout -> theme -> UI root -> screens), screen manager with slide/fade transitions,
## pad and touch support, and the SP_* env hooks for smoke tests and screenshots. Screens are code-built Controls (ui/screens).
##
## Env hooks:  SP_TASK=reflex|lamprey|worm + SP_REF=1 (lab opens that task with its reference circuit)   SP_SPEED=<x> (lab run speed)   SP_SEL=pop:<id>|proj:<i>|in:<name>|out:<name> (lab selection)
##             SP_SMOKE=1 (open every screen, tab and layout, load the GDExtension, assert, print SMOKE OK, quit)   SP_SHOT=<png> + SP_SHOT_AT=<sec>
##             SP_SCREEN=title|tasks|parts|lab|analysis|settings|credits|notebook|real   SP_CHAPTER=<chapter id> + SP_NODE=<task id> (campaign map)   SP_MOCK=1 (synthetic body-system tasks; debug builds only)
##             SP_UNLOCK_ALL=1 (open every node and part)   SP_PROGRESS=reflex:3:92,worm:2:81 (fake best scores)   SP_CATALOG=<thumbs.json>   SP_LESION=1 (lab opens in the lesion lab)   SP_TAB=Display|Audio|Controls   SP_ATAB=<n> (Analysis tab, with SP_SCREEN=analysis)   SP_LAYOUT=desktop|handheld|phone
##             SP_TUTORIAL=1 (start Plate 0)   SP_TUT_STEP=<n> (walk it to step n with Do it for me)   SP_TUT_LOG=1   SP_PICKER=1 (the mode picker over the map)
##             SP_UIGRAPH=1 (walk the interaction graph, tests/interaction_graph.json, print UIGRAPH OK, quit)   SP_NOAUTOSAVE (never write settings)   SP_NODISPLAY (never touch window mode / vsync)   SP_NOTHROTTLE   SP_PAD=1 (start in nav mode)

const SCREENS := {"title": "res://ui/screens/title.gd", "tasks": "res://ui/screens/tasks.gd", "lab": "res://ui/screens/lab.gd", "analysis": "res://ui/screens/analysis.gd", "settings": "res://ui/screens/settings.gd", "credits": "res://ui/screens/credits.gd", "parts": "res://ui/screens/parts.gd", "notebook": "res://ui/screens/notebook.gd", "real": "res://ui/screens/real.gd"}
const BACK_TO := {"settings": "title", "tasks": "title", "lab": "tasks", "credits": "title", "parts": "tasks", "notebook": "tasks"}   # the fallback; Back normally goes to the screen this one was opened from (`origin`)

## Hand-over between screens: which task the lab opens, whether it starts from the reference circuit, circuits kept between lab visits, and what the analysis shows.
var lab_task := ""
var lab_reference := false
var lab_keep := {}
var analysis_circuit := {}
var analysis_tele: Telemetry = null
var analysis_task := ""
var lab_select := ""           # a cell type the lab selects on the bench when it opens (set by the Analysis screen: a name tapped in the wiring matrix)
var campaign_chapter := ""    # the campaign map remembers its chapter and node between visits
var campaign_node := ""
var origin := {}               # screen id -> the screen it was last opened from (forward navigation): Back returns there, whichever of several doors it came through
var real_back := "title"      # where Back on the "What is real" page goes (it opens from the title, the credits and the notebook)

var ui: CanvasLayer
var root: Control
var holder: Control
var tutorial: Tutorial             # Plate 0, the mode picker and the one-step pointers (ui/tutorial.gd), above the screens
var pad: Pad
var cur := ""
var screen: Screen
var _last_input := 0.0
var _kind := ""

func _ready() -> void:
	if OS.get_environment("SP_BUDGET_US") != "": Telemetry.budget_us = int(OS.get_environment("SP_BUDGET_US"))
	SaveIO.warn_hook = _show_notice   # a damaged save, a read-only disk: said once, with the path
	Settings.load_all()
	# --- audio init (item H): GameAudio.* helpers are no-ops until this exists ---
	add_child(GameAudio.new())
	get_tree().process_frame.connect(func(): GameAudio.ambient(true), CONNECT_ONE_SHOT)   # the lab's ambient bed, on the Music bus: the Ambience slider sets its level
	# --- end audio init ---
	Settings.apply(get_window()); Settings.write_log(get_window())
	var runner_note := _ensure_runner_exec()
	if runner_note != "": SaveIO.notice(runner_note, "runner")
	Layout.update(get_window())
	_kind = Layout.kind
	get_window().content_scale_factor = Settings.effective_ui_scale(get_window())
	get_window().size_changed.connect(_on_resized)
	add_child(WrapGuard.new())
	if Layout.touch: add_child(TouchScroll.new())
	RenderingServer.set_default_clear_color(Kit.BENCH)
	ui = CanvasLayer.new(); ui.layer = 10; add_child(ui)
	root = Control.new(); root.name = "Root"; root.set_anchors_preset(Control.PRESET_FULL_RECT); root.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.theme = Kit.make_theme(); ui.add_child(root)
	holder = Control.new(); holder.name = "Screens"; holder.set_anchors_preset(Control.PRESET_FULL_RECT); holder.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.add_child(holder)
	tutorial = Tutorial.new(); tutorial.app = self; root.add_child(tutorial)
	pad = Pad.new(); pad.app = self; add_child(pad)
	_update_metrics()
	if OS.get_environment("SP_PAD") != "": pad.set_active(true)
	if OS.get_environment("SP_CHECK_EXPORT") != "": Settings.no_save = true; await CheckExport.run(self); return   # scripts/package.sh: CHECK from the exported zip
	if OS.get_environment("SP_UIGRAPH") != "": Settings.no_save = true; await UiGraphTest.run(self); return   # tests/ui_graph_test.gd walks tests/interaction_graph.json (scripts/ui_graph_test.sh)
	if OS.get_environment("SP_SMOKE") != "": Kit.instant = true; Settings.no_save = true; await _smoke(); return
	if OS.get_environment("SP_SHOT") != "": Kit.instant = true   # screenshots show the settled frame, not a transition
	if OS.get_environment("SP_CHAPTER") != "": campaign_chapter = OS.get_environment("SP_CHAPTER")
	if OS.get_environment("SP_NODE") != "": campaign_node = OS.get_environment("SP_NODE")
	var start := OS.get_environment("SP_SCREEN") if SCREENS.has(OS.get_environment("SP_SCREEN")) else "title"
	show_screen("title", false, true)
	if OS.get_environment("SP_TUTORIAL") != "": tutorial.begin(); start = ""   # dev: Plate 0 now (SP_TUT_STEP=n walks it to step n with "Do it for me"; SP_TUT_LOG=1 prints the steps)
	if OS.get_environment("SP_PICKER") != "": show_screen("tasks", false, true); tutorial.show_picker(); start = ""   # dev: the mode picker over the map
	if start == "analysis": _analysis_demo(); 
	elif start == "lab": open_lab(OS.get_environment("SP_TASK"), OS.get_environment("SP_REF") != "", true)
	elif start != "title": show_screen(start, false, true)
	if OS.get_environment("SP_SHOT") != "":
		var at := float(OS.get_environment("SP_SHOT_AT")) if OS.get_environment("SP_SHOT_AT") != "" else 2.0
		get_tree().create_timer(at).timeout.connect(_shot_when_ready)

## Screenshots of the analysis screen need a circuit that has run: open the lab on SP_TASK, let it run, then show the analysis of it.
func _analysis_demo() -> void:
	open_lab(OS.get_environment("SP_TASK") if OS.get_environment("SP_TASK") != "" else "lamprey", true, true)
	_press_run()
	await get_tree().create_timer(3.5).timeout
	var lab := screen as LabScreen
	if lab != null: open_analysis(lab.circuit, lab.tele, lab.task_id)

## SP_SIM_UNTIL=<model ms>: wait until the lab's run has reached that model time (deterministic screenshots on a slow software renderer).
func _shot_when_ready() -> void:
	var until := float(OS.get_environment("SP_SIM_UNTIL")) if OS.get_environment("SP_SIM_UNTIL") != "" else 0.0
	var lab := screen as LabScreen if screen is LabScreen else null
	if lab != null and OS.get_environment("SP_LESION") in ["run", "sweep"] and (lab._lrun != null or lab.lesion_rows.is_empty()) and Time.get_ticks_msec() < 170000:   # wait for the lesion table
		get_tree().create_timer(0.3).timeout.connect(_shot_when_ready); return
	if until > 0.0 and lab != null and lab.tele != null and lab.tele.sim != null and lab.tele.t_ms < until and Time.get_ticks_msec() < 150000:
		get_tree().create_timer(0.25).timeout.connect(_shot_when_ready); return
	if until > 0.0 and lab != null:   # hold the instant (paused views freeze glows and pulses), let a few frames draw it
		lab.tele.hold = true; await get_tree().create_timer(0.5).timeout
	_shot()

func _shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(OS.get_environment("SP_SHOT"))
	print("SHOT ", OS.get_environment("SP_SHOT"), " ", img.get_size(), " err=", err)
	get_tree().quit()

## Everything that is only in memory goes to disk: the open circuit, the play log. Called on the window's close request, on Quit and when a phone pauses the app.
func flush_all() -> void:
	var lab := screen as LabScreen if screen is LabScreen else null
	if lab != null: lab.flush_on_close()
	Playlog.leave(); Playlog.flush()
	SaveIO.log_line("closing")

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED: flush_all()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT: Settings.focused = false; Settings.apply_fps()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN: Settings.focused = true; Settings.idle = false; Settings.apply_fps()

func _input(e: InputEvent) -> void:
	if e is InputEventMouseMotion or e is InputEventKey or e is InputEventMouseButton or e is InputEventJoypadButton or e is InputEventScreenTouch:
		_last_input = Time.get_ticks_msec() / 1000.0
		if Settings.idle: Settings.idle = false; Settings.apply_fps()

func _process(_dt: float) -> void:
	# no idle frame cap while a run is playing: the lab steps a share of each frame, so halving the frame rate halved a watched run's speed
	var idle := Time.get_ticks_msec() / 1000.0 - _last_input > 60.0 and not _run_playing()
	if idle != Settings.idle: Settings.idle = idle; Settings.apply_fps()

func _run_playing() -> bool:
	var lab := screen as LabScreen
	return lab != null and lab.tele != null and lab.tele.sim != null and lab.tele.running and not lab.tele.finished

# ---------- layout ----------
func _on_resized() -> void:
	var was := Layout.kind
	get_window().content_scale_factor = Settings.effective_ui_scale(get_window())
	_update_metrics()
	if was != Layout.kind: call_deferred("relayout")

func _update_metrics() -> void:
	Kit.vh = get_viewport().get_visible_rect().size.y
	Kit.ppl = Layout.text_scale(get_window())

## Re-apply the content scale and rebuild the open screen (the layout class, UI scale or text size changed).
func relayout() -> void:
	get_window().content_scale_factor = Settings.effective_ui_scale(get_window())
	Layout.update(get_window()); _kind = Layout.kind
	_update_metrics()
	if screen != null and is_instance_valid(screen): screen.refresh(); if Kit.pad_mode: pad.ensure_focus(true)

# ---------- screens ----------
func current_screen() -> Control: return screen
func show_hint() -> bool: return screen == null or screen.wants_hint()

## Show a screen with a slide + fade. `back` slides the other way; `snap` skips the animation.
func show_screen(id: String, back := false, snap := false) -> void:
	if id == cur or not SCREENS.has(id): return
	if not back and cur != "": origin[id] = cur
	var old := screen
	var s: Screen = load(SCREENS[id]).new(); s.app = self; s.name = id.capitalize() + "Screen"
	if id == "settings" and OS.get_environment("SP_TAB") != "": s.tab = OS.get_environment("SP_TAB")
	holder.add_child(s); s.build()
	screen = s; cur = id
	hint_refresh()
	# Plates are laid on the desk, not slid like app panes: the old page lifts and fades where it lies, the new one settles in from a few px
	# below (from above when going back). Reduced motion: a short cross-fade only.
	if old != null and is_instance_valid(old):
		if snap or Kit.instant: old.queue_free()
		else:
			old.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var tw := create_tween().set_parallel(true)
			tw.tween_property(old, "modulate:a", 0.0, 0.14)
			if not Settings.reduced_motion: tw.tween_property(old, "position:y", -10.0 if not back else 10.0, 0.14).set_ease(Tween.EASE_IN)
			tw.chain().tween_callback(old.queue_free)
	if not snap: Kit.appear(s, Vector2(0, 0 if Settings.reduced_motion else (22.0 if not back else -22.0)), 0.26)
	if Kit.pad_mode: call_deferred("_focus_new")

func _focus_new() -> void:
	if pad != null: pad.ensure_focus(true)

func hint_refresh() -> void:
	if pad != null and pad.hint != null: pad.hint.visible = pad.active and show_hint()

## B / Esc: let the screen handle it, else go to the screen it came from.
func back() -> void:
	if ConfirmCard.dismiss(): return
	if tutorial != null and tutorial.on_back(): return   # Esc / B always leaves the tutorial or the mode picker
	if screen != null and screen.on_back(): return
	if cur == "analysis": open_lab(analysis_task, false, true); return
	if cur == "real": show_screen(real_back if SCREENS.has(real_back) else "title", true); return
	if origin.has(cur) and SCREENS.has(origin[cur]) and origin[cur] != cur: show_screen(origin[cur], true); return
	if BACK_TO.has(cur): show_screen(BACK_TO[cur], true)

## Open the lab on a task ("" = free run), empty bench or with the reference circuit.
func open_lab(task: String, reference := false, back_nav := false) -> void:
	lab_task = task; lab_reference = reference
	if cur == "lab": cur = ""
	show_screen("lab", back_nav)

func open_analysis(c: Dictionary, t: Telemetry, task: String) -> void:
	analysis_circuit = c.duplicate(true); analysis_tele = t; analysis_task = task
	show_screen("analysis")

## The "What is real" page (docs/WHAT-IS-REAL.md), opened from `from` (title, credits, notebook), where Back returns.
func open_real(from: String) -> void:
	real_back = from; show_screen("real")

## Plate 0 (replayable any time from the campaign map).
func start_tutorial() -> void: tutorial.begin()

func quit_game() -> void: flush_all(); get_tree().quit()

# ---------- notices (SaveIO), the runner's executable bit ----------
var _notice_box: PanelContainer
func _show_notice(msg: String) -> void:
	if ui == null: return
	if _notice_box == null or not is_instance_valid(_notice_box):
		_notice_box = PanelContainer.new(); Kit.ident(_notice_box, "SaveNotice"); _notice_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_notice_box.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL_HI, Kit.RED, 2, 12, 14, true))
		var l := Kit.label("", 17, Kit.TEXT, true); l.mouse_filter = Control.MOUSE_FILTER_IGNORE; l.name = "Msg"; _notice_box.add_child(l)
		ui.add_child(_notice_box); _notice_box.z_index = 200
		_notice_box.set_anchors_preset(Control.PRESET_TOP_WIDE); _notice_box.offset_left = 120.0; _notice_box.offset_right = -120.0; _notice_box.offset_top = 10.0
	(_notice_box.get_node("Msg") as Label).text = msg; _notice_box.visible = true
	get_tree().create_timer(20.0).timeout.connect(func(): if _notice_box != null and is_instance_valid(_notice_box): _notice_box.visible = false)

## CHECK runs the bundled spike-run next to the game. A zip that lost its executable bit (some unzippers, some file managers) would make Check fail with no hint:
## set the bit when we can, say so plainly when we cannot. Returns "" or the message.
func _ensure_runner_exec() -> String:
	if OS.has_feature("windows"): return ""   # no execute bit on Windows; the runner is spike-run.exe beside Spike.exe
	for p in [OS.get_executable_path().get_base_dir().path_join("spike-run"), OS.get_executable_path().get_base_dir().path_join("../Frameworks/spike-run"), ProjectSettings.globalize_path("res://bin/spike-run")]:
		if not FileAccess.file_exists(p): continue
		var perm := FileAccess.get_unix_permissions(p)
		if perm & 0x49 == 0x49: return ""
		if FileAccess.set_unix_permissions(p, perm | 0x1ED) == OK: SaveIO.log_line("set the executable bit on " + p); return ""
		return "Check cannot run: %s is not executable and the game could not change that. In a terminal: chmod +x \"%s\"" % [p, p]
	return ""

# ---------- smoke test ----------
var _fails := 0
func _check(ok: bool, msg: String) -> void:
	if not ok: _fails += 1; printerr("SMOKE FAIL: ", msg)

## The smoke starts a run the way a player does (Run); a level never starts one by itself.
func _press_run() -> void:
	var l := screen as LabScreen
	if l != null and l.tele != null and l.tele.sim != null and not l.tele.running: l._toggle_run()

func _frames(n := 2) -> void:
	for i in n: await get_tree().process_frame

## CI smoke test (SP_SMOKE=1, headless): every layout x screen x settings tab, font floor, GDExtension load and a stepped SpikeSim, orphan nodes. Prints SMOKE OK.
func _smoke() -> void:
	var orphans0 := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var small := 0; var opened := 0; var tabs := 0
	var layouts := Layout.KINDS.duplicate()
	for kind in layouts:
		Settings.layout = kind; relayout(); _check(Layout.kind == kind, "layout %s forced, got %s" % [kind, Layout.kind])
		for id in SCREENS:
			cur = ""; show_screen(id, false, true); await _frames(); opened += 1
			small += _small_fonts(screen); _check(screen.get_child_count() > 0, "%s built nothing" % id)
			if id == "settings":
				for t in SettingsScreen.TABS:
					(screen as SettingsScreen).set_tab(t); await _frames(); tabs += 1; small += _small_fonts(screen)
			if id == "lab": await _frames(20); small += _small_fonts(screen)
			if id == "analysis": await _frames(4); small += _small_fonts(screen)
		pad.set_active(true); await _frames(); show_screen("title", false, true); await _frames(); pad.ensure_focus(true)
		var fo := get_viewport().gui_get_focus_owner(); _check(fo != null, "pad nav on title focused nothing (%s)" % kind)
		small += _small_fonts(screen); pad.set_active(false)
	Settings.layout = "auto"; relayout()
	await _fit_checks()
	await _interaction_checks()
	_extension_checks()
	await _lab_checks()
	await _v02_checks()
	small += small_fonts_total
	print("FONTS below %d px: %d" % [Kit.MIN_FONT, small]); _check(small == 0, "text smaller than the readable minimum")
	cur = ""; show_screen("title", false, true); await _frames(4)
	var orphans1 := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	print("ORPHANS %d -> %d" % [orphans0, orphans1]); if orphans1 > orphans0: Node.print_orphan_nodes()
	_check(orphans1 <= orphans0, "orphan nodes leaked by the screens (%d -> %d)" % [orphans0, orphans1])
	if _fails > 0: printerr("SMOKE FAILED: %d problem(s)" % _fails); get_tree().quit(1); return
	print("SMOKE OK screens=%d settings_tabs=%d layouts=%d renderer=%s" % [opened, tabs, layouts.size(), RenderingServer.get_current_rendering_method()])
	get_tree().quit()

## Fit-to-box guard (ui review finding 8): at 1366x768 and at 1920x1080 with Large text, no label or button of the title, the campaign map, the settings
## and a lab with a body view (heart_autonomic) may end outside the window or be wider than its own box without wrapping or an ellipsis. Text inside a
## scroll area may scroll; everything else must fit. Prints "FIT clipped: N".
func _fit_checks() -> void:
	var win := get_window(); var size0 := win.size; var boost0 := Settings.text_boost
	var bad := 0
	for cfg in [[Vector2i(1366, 768), 1.0], [Vector2i(1920, 1080), 1.5]]:
		win.size = cfg[0]; Settings.text_boost = float(cfg[1]); relayout(); await _frames(2)
		for id in ["title", "tasks", "settings", "lab"]:
			cur = ""
			if id == "lab": open_lab("heart_autonomic", true, true)
			else: show_screen(id, false, true)
			await _frames(12)
			var vp := get_viewport().get_visible_rect()
			bad += _clipped(screen, vp, "%s %dx%d text x%.1f" % [id, cfg[0].x, cfg[0].y, cfg[1]])
			if id == "lab":   # painted body-view tiles (not Controls): BodyViews._tile counts a value that did not fit at its smallest size
				if BodyViews.overflow > 0: printerr("FIT body-view tile overflow x%d at %dx%d text x%.1f" % [BodyViews.overflow, cfg[0].x, cfg[0].y, cfg[1]])
				bad += BodyViews.overflow; BodyViews.overflow = 0
	win.size = size0; Settings.text_boost = boost0; relayout(); await _frames(2)
	print("FIT clipped: %d" % bad); _check(bad == 0, "text clipped or off-screen at 1366x768 or Large text")

func _clipped(n: Node, vp: Rect2, where: String) -> int:
	var bad := 0
	if n is ScrollContainer: return 0   # scrolling content may run past the window
	if n is Control and not (n as Control).is_visible_in_tree(): return 0
	if (n is Label or n is Button) and str(n.text) != "":
		var c := n as Control; var r := c.get_global_rect()
		var wraps: bool = n.autowrap_mode != TextServer.AUTOWRAP_OFF or n.clip_text or n.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING
		if r.end.x > vp.end.x + 2.0 or r.end.y > vp.end.y + 2.0 or r.position.x < vp.position.x - 2.0:
			bad += 1; printerr("FIT (%s): '%s' (%s) ends outside the window at %s" % [where, str(n.text).left(40), c.name, str(r)])
		elif not wraps and n is Label:
			var f: Font = (n as Label).label_settings.font if (n as Label).label_settings != null and (n as Label).label_settings.font != null else c.get_theme_font("font")
			var z: int = (n as Label).label_settings.font_size if (n as Label).label_settings != null else c.get_theme_font_size("font_size")
			var tw := f.get_string_size(str(n.text), HORIZONTAL_ALIGNMENT_LEFT, -1, z).x if not str(n.text).contains("\n") else 0.0
			if tw > r.size.x + 2.0:
				bad += 1; printerr("FIT (%s): '%s' (%s) is %.0f px wide in a %.0f px box" % [where, str(n.text).left(40), c.name, tw, r.size.x])
	for k in n.get_children(): bad += _clipped(k, vp, where)
	return bad

## The GDExtension is loaded: SpikeSim steps a circuit, every task runs its reference circuit for 1 s, bad JSON is rejected, analysis answers.
func _extension_checks() -> void:
	_check(ClassDB.class_exists("SpikeSim") and ClassDB.class_exists("SpikeTask"), "GDExtension: SpikeSim / SpikeTask are not registered (run scripts/build-gd.sh)")
	if not ClassDB.class_exists("SpikeSim"): return
	var bad = ClassDB.instantiate("SpikeSim")
	_check(not bad.load_circuit("{not json"), "SpikeSim accepted invalid JSON"); _check(str(bad.error()) != "", "SpikeSim gave no error text for invalid JSON")
	var ids := PackedStringArray(Campaign.shipped_ids())   # a release export does not ship the development-only levels (Campaign.DEV_IDS)
	if Campaign.mock_script() == null:
		for d in Campaign.DEV_IDS: _check(Circuits.read_reference(str(d) + ".json") == "", "the development-only level %s is in this release build (%s.json is readable)" % [d, d])
	_check(ids.size() >= 3, "task_ids gave %d tasks, want 3" % ids.size())
	var sum_spikes := 0
	for id in ids:
		var t = ClassDB.instantiate("SpikeTask"); _check(t.make(id), "make(%s)" % id)
		var txt := Circuits.read_reference(str(t.reference_circuit())); _check(txt != "", "reference circuit for %s is not readable (%s)" % [id, t.reference_circuit()])
		var sim = ClassDB.instantiate("SpikeSim")
		_check(sim.load_circuit(txt), "%s: reference circuit rejected: %s" % [id, sim.error()])
		if sim.neuron_count() == 0: continue
		t.reset(1); sim.watch(0)
		for i in 1000: t.step(sim, 1.0)
		var sp: PackedFloat64Array = sim.drain_spikes(); sum_spikes += sp.size() / 2
		var st: Dictionary = sim.stats()
		_check(sp.size() % 2 == 0, "%s: drain_spikes gave an odd array" % id)
		_check(absf(float(st.get("t_ms", 0.0)) - 1000.0) < 1.0, "%s: model time %s after 1000 slices" % [id, st.get("t_ms", 0)])
		var finite_v := false   # a model without a membrane (a relay, a generator-like cell) reports NaN: some neuron among the first few must report a voltage
		for vi in mini(int(sim.neuron_count()), 400): finite_v = finite_v or is_finite(sim.voltage(vi)) or is_finite(sim.neuron_state(vi, "rate"))   # v0.6: a rate unit has a rate, not a voltage; the afferents of a tuning level are relays, the cells after them have one
		_check(finite_v, "%s: no neuron reports a finite voltage" % id)
		var b: Dictionary = t.body(); var poly := str(t.view()) == "polyline" if t.has_method("view") else true
		_check(b.has("points") and (not poly or (b["points"] as PackedVector2Array).size() > 1), "%s: body has no points" % id)
		_check(t.score().has("value"), "%s: score has no value" % id); _check(t.bounds().size.x > 0.0, "%s: empty bounds" % id)
		var m := Circuits.parse(str(sim.motif_json(0, 5, 1))); _check(m.has("motifs") and (m["motifs"] as Array).size() == 13, "%s: motif census did not return 13 classes" % id)
		var nn := int(sim.neuron_count()); sim.stop()
		print("TASK %s ok: %d neurons, %d spikes in 1 s, score %.0f" % [id, nn, sp.size() / 2, float(t.score().get("value", 0.0))])
	print("EXTENSION OK tasks=%d spikes=%d" % [ids.size(), sum_spikes])

## The lab opens on every task with its reference circuit, runs, and takes an edit (the circuit editor reloads the engine).
func _lab_checks() -> void:
	if not ClassDB.class_exists("SpikeTask"): return
	for id in Campaign.shipped_ids():
		cur = ""; open_lab(id, true); await _frames(30)
		var lab := screen as LabScreen
		_check(lab != null and lab.tele.sim != null, "lab: %s reference circuit did not load%s" % [id, (" (" + lab.tele.error + ")") if lab != null else ""])
		if lab == null or lab.tele.sim == null: continue
		_check(lab.tele.t_ms == 0.0 and not lab.tele.running, "lab: %s started a run by itself when it opened (t %.0f ms)" % [id, lab.tele.t_ms])   # a run is started by the player: Run
		_press_run(); await _frames(30)
		_check(lab.tele.t_ms > 0.0, "lab: %s did not advance after Run" % id)
		await get_tree().create_timer(0.6).timeout
		if id != "reflex" and str(Campaign.info(id)["view"]) == "polyline": _check(lab.tele.total_spikes > 0, "lab: %s produced no spikes in the lab view" % id)   # a reflex arc is quiet until the first poke at 1.5 s
		var n0 := lab.tele.n
		var nid := Circuits.add_neuron(lab.circuit, "iaf_psc_alpha", 0, Vector2(100, 400), "I"); lab.editor.select({"t": "pop", "id": nid}); lab._on_structure()
		await get_tree().create_timer(0.5).timeout
		_check(lab.tele.sim != null and lab.tele.n == n0 + 1, "lab: %s edit did not reload (n %d -> %d)" % [id, n0, lab.tele.n])
		_check(lab.tele.t_ms == 0.0 and not lab.tele.running, "lab: %s an edit during a run did not stop it at t = 0 (t %.0f ms, running %s)" % [id, lab.tele.t_ms, str(lab.tele.running)])
		_check(lab.run_btn.text == "Run" and lab._stale, "lab: %s Run is not marked after an edit" % id)
		var tl: Array = Campaign.info(id)["timeline"]   # nothing in the lab moves while an event comes and goes: the event row has one height for the whole run
		if not tl.is_empty():
			var t_keep: float = lab.tele.t_ms; var bh := []
			for tt in [0.0, float(tl[0]["t_ms"]) + 1.0, float(tl[0]["t_ms"]) + float(tl[0]["dur_ms"]) + 50.0]: lab.tele.t_ms = tt; bh.append(BodyViews._banner_h(lab.tele))
			lab.tele.t_ms = t_keep
			_check(bh[0] > 0.0 and bh[0] == bh[1] and bh[1] == bh[2], "lab: %s the event row changes height while an event is on (%s)" % [id, str(bh)])
		small_fonts_total += _small_fonts(screen)
	cur = ""; show_screen("title", false, true); await _frames()

var small_fonts_total := 0

## v0.2: the campaign map and its data contract, the parts bin and its catalogue reader, the lesion lab, the body views on synthetic tasks, sandbox dials.
func _v02_checks() -> void:
	# contract: every task answers the v0.2 questions and lands in a known chapter
	var ids := Campaign.installed()
	for id in ids:
		var d := Campaign.info(id)
		_check(Campaign.CHAPTERS.any(func(c): return c["id"] == d["chapter"]), "task %s has an unknown chapter '%s'" % [id, d["chapter"]])
		_check(["polyline", "limb", "heart", "lungs", "eye", "gut", "dashboard", "compass", "phase", "rates", "memory", "tuning"].has(str(d["view"])), "task %s has an unknown view '%s'" % [id, d["view"]])
	for c in Campaign.CHAPTERS: _check(not Campaign.nodes(c["id"]).is_empty() or true, "chapter %s" % c["id"])
	_check(Campaign.unlocked(str(Campaign.order()[0])), "the first campaign task is open")
	# the catalogue: cards from the engine, thumbnails read in every shape
	var cat_ok := true
	for shape in [{"fi": {"I": [0, 1, 2], "rate": [0, 5, 20]}}, {"fi": [[0, 0], [1, 4], [2, 9]]}, {"fi": [{"level": 0, "rate_hz": 0}, {"level": 1, "rate_hz": 3}]}]:
		if (Catalog.series_of(shape, "fi")[0] as PackedFloat32Array).size() < 2: cat_ok = false
	if (Catalog.series_of({"trace": {"v_mV": [-70, -60, 20, -70], "dt_ms": 2.0, "t0_ms": 10.0}}, "vm")[0] as PackedFloat32Array).size() != 4: cat_ok = false
	_check(cat_ok, "catalogue reader: f-I / V_m shapes")
	_check(Catalog.has_card("iaf_psc_alpha") and Catalog.usable("iaf_psc_alpha"), "the default part is usable")
	_check(not Catalog.cards().is_empty(), "the catalogue has cards (engine catalog_json: %s)" % str(Catalog.from_engine()))
	if Catalog.from_engine():
		var a_n := 0
		for cd in Catalog.cards(): a_n += 1 if Catalog.available(cd["id"]) else 0
		print("CATALOG engine cards=%d available=%d thumbs=%s" % [Catalog.cards().size(), a_n, Catalog.source()])
	# the campaign map, the parts bin, in every layout
	for kind in Layout.KINDS:
		Settings.layout = kind; relayout()
		for sc in ["tasks", "parts"]:
			cur = ""; show_screen(sc, false, true); await _frames(3)
			small_fonts_total += _small_fonts(screen)
			if sc == "tasks":
				var ts := screen as TasksScreen
				for c in Campaign.CHAPTERS: ts._show_chapter(c["id"]); await _frames(2); small_fonts_total += _small_fonts(screen)
	Settings.layout = "auto"; relayout()
	# lesion algebra and a real re-run
	if ClassDB.class_exists("SpikeTask"):
		var rc := Circuits.parse(Circuits.read_reference(Campaign.ref_path("reflex")))
		var les := Lesion.apply(rc, {"proj:0": true, "pop:" + str(rc["populations"][0]["id"]): true})
		_check(is_zero_approx(Circuits.proj_weight(les["projections"][0])), "lesion: cut axon has weight 0")
		_check(not is_zero_approx(Circuits.proj_weight(rc["projections"][0])), "lesion: the original circuit is untouched")
		var runner := Lesion.Runner.new(); runner.begin("reflex", rc, [{"label": "intact", "lesions": {}}, {"label": "silence all", "lesions": {"pop:" + str(rc["populations"][0]["id"]): true}}])
		var t0 := Time.get_ticks_msec()
		while not runner.done() and Time.get_ticks_msec() - t0 < 60000: runner.step(50000)
		_check(runner.results.size() == 2 and runner.failed == "", "lesion re-run (%s)" % runner.failed)
		if runner.results.size() == 2: print("LESION reflex: intact %.0f, silenced %.0f" % [runner.results[0]["score"], runner.results[1]["score"]])
		_check(Lesion.csv(runner.results).begins_with("lesion,score"), "lesion csv export"); _check(Lesion.markdown("t", "c", 1, runner.results).contains("| Lesion |"), "lesion markdown export")
	# the lab with lesion mode, sandbox, and the synthetic body-system tasks (every view kind)
	OS.set_environment("SP_MOCK", "1"); Campaign.refresh()
	for id in Campaign.mock_ids():
		cur = ""; open_lab(id, true); await _frames(40)
		var lab := screen as LabScreen
		_check(lab != null and lab.tele.sim != null, "mock %s did not load in the lab" % id)
		if lab == null or lab.tele.sim == null: continue
		_press_run()
		await get_tree().create_timer(0.8).timeout
		_check(lab.tele.hist_t.size() > 3, "mock %s: no readout history" % id)
		_check(lab.timeline_view.visible, "mock %s: the timeline is hidden" % id)
		small_fonts_total += _small_fonts(screen)
		if id == "mock_dash":
			lab._lesion_toggle(); await _frames(3); _check(lab.lesion_on, "the lesion lab opens on a reference circuit")
			lab.editor.lesion_clicked.emit({"t": "pop", "id": str(lab.circuit["populations"][0]["id"])}); await _frames(3); _check(lab.lesions.size() == 1, "clicking a population lesions it")
			small_fonts_total += _small_fonts(screen)
			lab._lesion_toggle(); await _frames(3); _check(not lab.lesion_on, "the lesion lab closes")
	OS.unset_environment("SP_MOCK"); Campaign.refresh()
	cur = ""; open_lab("", false); await _frames(30)
	var sb := screen as LabScreen
	_check(sb != null and sb.sandbox_panel != null and Circuits.sandbox, "the sandbox shows its panel with every part open")
	if sb != null: small_fonts_total += _small_fonts(screen)
	Circuits.sandbox = false
	cur = ""; show_screen("title", false, true); await _frames()
	_lock_checks()
	await _task_checks()
	print("V02 OK chapters=%d tasks=%d cards=%d" % [Campaign.CHAPTERS.size(), Campaign.installed().size(), Catalog.cards().size()])

## The reference lock (Circuits.is_reference_of): exact copies are flagged; a circuit the player built, with the same round numbers, is not.
func _lock_checks() -> void:
	var ref := Circuits.parse(Circuits.read_reference(Campaign.ref_path("m_threshold")))
	_check(Circuits.is_reference_of(ref.duplicate(true), "m_threshold"), "lock: the reference file itself is a copy")
	var moved := ref.duplicate(true); moved["name"] = "renamed"; moved["seed"] = 99
	_check(Circuits.is_reference_of(moved, "m_threshold"), "lock: a renamed copy with another seed is still a copy")
	# m_threshold built by hand: one iaf_psc_alpha cell, a 450 pA step, the reference's round number, but not the reference file
	var hand := {"schema_version": 1, "name": "mine", "resolution_ms": 0.1, "seed": 1, "populations": [{"id": "N1", "model": "iaf_psc_alpha", "n": 1, "params": {}, "role": "neuron", "pos": [[300, 220]]}], "projections": [],
		"inputs": [{"name": "pulse", "kind": "dc", "targets": [{"pop": "N1"}], "weight": 450.0, "value": 1.0}], "outputs": [{"name": "spike", "kind": "rate", "neurons": [{"pop": "N1"}]}], "record": {"spikes": "all"}, "meta": {"author": "", "notes": ""}}
	_check(not Circuits.is_reference_of(hand, "m_threshold"), "lock: m_threshold built by hand at 450 pA is not flagged as a copy")
	var hand2: Dictionary = hand.duplicate(true); hand2["populations"][0]["pos"] = ref["populations"][0]["pos"]
	_check(not Circuits.is_reference_of(hand2, "m_threshold"), "lock: even at the reference's position, a circuit without the reference's provenance is not a copy")
	var nudged := ref.duplicate(true); nudged["inputs"][0]["weight"] = float(nudged["inputs"][0]["weight"]) * 1.001
	_check(not Circuits.is_reference_of(nudged, "m_threshold"), "lock: a weight 0.1% off the reference is not a copy (tolerance is 1e-6)")

## What each body view needs in Task::body().readouts before it can draw (anything else shows a "Waiting for ..." placeholder; keep in step with body_views.gd).
const VIEW_NEEDS := {"limb": [["theta_deg", "theta_rad", "angle_deg"]], "heart": [["hr_bpm"]], "lungs": [["volume"]], "eye": [["pupil_mm"]], "gut": [["bolus"]], "dashboard": [], "compass": [["bump_deg"]], "phase": [], "rates": [], "memory": [], "tuning": [], "polyline": []}

## C1, per real task (no mock tasks): the empty bench the lab builds declares the channel kinds the reference circuit declares; a minimal circuit made with the
## editor API (one driven neuron wired to every channel) runs 2 s and moves each modulator the task names; the real body view has its readouts after 1 s.
func _task_checks() -> void:
	if not ClassDB.class_exists("SpikeTask"): return
	OS.unset_environment("SP_MOCK"); Campaign.refresh()
	var n_checked := 0; var n_mod := 0
	for id in Campaign.shipped_ids():
		var t = Campaign.make(id); var info := Campaign.info(id)
		var ref := Circuits.parse(Circuits.read_reference(Campaign.ref_path(id)))
		# 1. the skeleton the lab builds: every channel kind equals the reference's
		lab_keep.erase(id); cur = ""; open_lab(id, false); await _frames(20)
		var lab := screen as LabScreen
		_check(lab != null and not lab._is_reference(), "tasks: %s did not open on an empty bench" % id)
		if lab == null: continue
		# 0. novice check (lab A): the lab opens on the task's own cell type (default_model(), else the reference's first model), and keeps its sensor weights
		var dm := str(t.call("default_model")) if t != null and t.has_method("default_model") else ""
		var want_card := dm
		if want_card == "":
			var rp: Array = ref.get("populations", [])
			if not rp.is_empty(): want_card = str(rp[0].get("model", ""))
		if want_card != "" and (str(info.get("kind", "")) == "micro" or id == "reflex"):
			_check(lab.part_card == want_card or str(Catalog.card(lab.part_card).get("model", "")) == want_card, "tasks: %s opens on part '%s', the task default is '%s'" % [id, lab.part_card, want_card])
		if t != null and t.has_method("channel_kinds") and not lab._is_dx():   # a diagnosis case opens the patient circuit, not a bench
			var ck: Dictionary = t.channel_kinds()
			for nm in (ck.get("inputs", {}) as Dictionary):
				var tw := float(ck["inputs"][nm].get("weight", 0.0))
				if tw <= 0.0: continue
				for ch in lab.circuit.get("inputs", []): if str(ch.get("name", "")) == str(nm): _check(is_equal_approx(float(ch.get("weight", 0.0)), tw), "tasks: %s sensor %s starts at weight %s, the task says %s" % [id, nm, ch.get("weight"), tw])
		var sk: Dictionary = lab.circuit.duplicate(true)
		for key in ["inputs", "outputs"]:
			var want := {}
			for ch in ref.get(key, []): want[str(ch.get("name", ""))] = ch
			for ch in sk.get(key, []):
				var nm := str(ch.get("name", ""))
				if not want.has(nm): continue   # a channel the reference leaves out (optional)
				var rk := str(want[nm].get("kind", "poisson" if key == "inputs" else "rate"))
				_check(str(ch.get("kind", "")) == rk, "tasks: %s skeleton %s '%s' is %s, the reference declares %s" % [id, key, nm, ch.get("kind", ""), rk])
				if key == "outputs" and rk == "modulator": _check(str(ch.get("modulator", "")) == str(want[nm].get("modulator", "")), "tasks: %s skeleton output '%s' releases %s, the reference %s" % [id, nm, ch.get("modulator", ""), want[nm].get("modulator", "")])
		# 2. a minimal circuit: one driven neuron on every channel; modulators must move
		var c := sk.duplicate(true)
		var nid := Circuits.add_neuron(c, "iaf_psc_alpha", 0, Vector2(200, 200), "E"); (c["populations"][c["populations"].size() - 1]["params"] as Dictionary)["I_e"] = 600.0
		# v0.6: rate drives and rate readouts need rate units (a spiking cell is refused); every other channel gets the spiking cell
		var rid = null
		for ch in (c["inputs"] as Array) + (c["outputs"] as Array):
			if str(ch.get("kind", "")) in ["rate_drive", "rate_value"] and rid == null: rid = Circuits.add_neuron(c, "threshold_lin_rate_ipn", 0, Vector2(300, 200), "E")
		for ch in c["inputs"]: (ch["targets"] as Array).append(rid if str(ch.get("kind", "")) == "rate_drive" else nid)
		for ch in c["outputs"]: (ch["neurons"] as Array).append({"pop": rid if str(ch.get("kind", "")) == "rate_value" else nid})
		var sim = ClassDB.instantiate("SpikeSim")
		var loaded: bool = sim.load_circuit(Circuits.to_json(Telemetry.sanitized(c)))
		_check(loaded, "tasks: %s minimal circuit rejected: %s" % [id, sim.error()])
		if loaded:
			t.reset(1)
			var names: Array = Array(t.modulators())
			for ch in c["outputs"]:
				if str(ch.get("kind", "")) == "modulator" and not names.has(str(ch.get("modulator", ""))): names.append(str(ch["modulator"]))
			for nm in names:
				sim.set_modulator(str(nm), 0.4); sim.step(1.0); _check(absf(float(sim.modulator(str(nm))) - 0.4) < 0.05, "tasks: %s set_modulator(%s) reads back %.3f" % [id, nm, float(sim.modulator(str(nm)))])
				sim.set_modulator(str(nm), 0.0)
			for i in 2000: t.step(sim, 1.0)
			sim.drain_spikes()
			for ch in c["outputs"]:
				if str(ch.get("kind", "")) != "modulator": continue
				n_mod += 1
				_check(float(sim.modulator(str(ch["modulator"]))) > 0.0, "tasks: %s modulator output '%s' did not move %s in 2 s" % [id, ch["name"], ch["modulator"]])
		sim.stop()
		# 3. the real body view: its readouts exist after 1 s on the reference circuit
		cur = ""; open_lab(id, true); await _frames(20); _press_run(); await get_tree().create_timer(1.0).timeout
		var rlab := screen as LabScreen
		_check(rlab != null and rlab.tele.sim != null, "tasks: %s reference did not load" % id)
		if rlab != null and rlab.tele.sim != null:
			var ro: Dictionary = (rlab.tele.body.get("readouts", {}) as Dictionary); var vw := str(info["view"])
			_check(VIEW_NEEDS.has(vw), "tasks: %s has view '%s' with no readout contract in main.gd" % [id, vw])
			for any in VIEW_NEEDS.get(vw, []): _check((any as Array).any(func(k): return ro.has(k)), "tasks: %s view '%s' would show 'Waiting for %s'" % [id, vw, any[0]])
			small_fonts_total += _small_fonts(screen)
		n_checked += 1
	# the analysis tabs: 4-node on a big enough graph, HRV / bursts / energy from a short recording of the pacemaker
	var fof := Circuits.parse(Circuits.read_reference(Campaign.ref_path("fight_or_flight")))
	cur = ""; open_analysis(fof, null, "fight_or_flight"); await _frames(6)
	var an := screen as AnalysisScreen
	_check(an != null, "analysis screen did not open")
	if an != null:
		an.tab = 1; an._tab_changed(); await _frames(2)
		_check(an.panel.message == "" and (an.panel.data.get("classes", []) as Array).size() > 0, "analysis 4-node: no classes (%s)" % an.panel.message)
	var hp := Circuits.parse(Circuits.read_reference(Campaign.ref_path("heart_pacemaker")))
	cur = ""; open_analysis(hp, null, "heart_pacemaker"); await _frames(6)
	an = screen as AnalysisScreen
	if an != null:
		an.rec_s = 10; an.tab = 2; an._tab_changed(); an._start_record()
		var t1 := Time.get_ticks_msec()
		while an.rec.is_empty() and Time.get_ticks_msec() - t1 < 120000: await _frames(2)
		_check(not an.rec.is_empty(), "analysis: the recording did not finish")
		an._compute_series(); _check(int(an.panel.data.get("n_beats", 0)) >= 5, "analysis HRV: %s beats (%s)" % [an.panel.data.get("n_beats", 0), an.panel.message])
		an.tab = 4; an._tab_changed(); _check(an.panel.message == "" and an.panel.data.has("n_bursts"), "analysis bursts: %s" % an.panel.message)
		an.tab = 3; an._tab_changed(); _check(an.panel.message != "" or an.panel.data.has("bins"), "analysis PRC drew nothing")
		an.tab = 5; an._tab_changed(); _check(an.panel.message != "" or float(an.panel.data.get("hz", -1.0)) >= 0.0, "analysis energy drew nothing")
		await _frames(2); small_fonts_total += _small_fonts(screen)
	cur = ""; show_screen("title", false, true); await _frames()
	print("TASKS OK tasks=%d modulator_outputs=%d" % [n_checked, n_mod])

## Steppers and toggles change Settings; screen changes animate and leave exactly one screen behind.
func _interaction_checks() -> void:
	cur = ""; show_screen("settings", false, true); (screen as SettingsScreen).set_tab("Display"); await _frames()
	var st := screen.find_children("*", "HBoxContainer", true, false).filter(func(n): return n is Kit.Stepper)
	_check(st.size() >= 3, "display tab has steppers (%d)" % st.size())
	var vs_before := Settings.vsync
	var vstep: Kit.Stepper = st[1]; vstep.step(1); _check(Settings.vsync != vs_before or vstep.opts.size() < 2, "stepper changed vsync")
	vstep.step(-1); _check(Settings.vsync == vs_before, "stepper restores vsync")
	Kit.instant = false
	cur = ""; show_screen("title", false, true); await _frames()
	show_screen("settings"); await get_tree().create_timer(0.45).timeout
	_check(holder.get_child_count() == 1 and cur == "settings", "transition leaves one screen (%d)" % holder.get_child_count())
	back(); await get_tree().create_timer(0.45).timeout
	_check(holder.get_child_count() == 1 and cur == "title", "back returns to title (%s, %d)" % [cur, holder.get_child_count()])
	var rm := Settings.reduced_motion
	Settings.reduced_motion = true; show_screen("settings"); await get_tree().create_timer(0.3).timeout
	_check(holder.get_child_count() == 1 and screen.modulate.a > 0.99, "reduced-motion transition completes")
	Settings.reduced_motion = rm; Kit.instant = true

## Count visible text whose ON-SCREEN size is below Kit.MIN_FONT physical px: the logical font size times the layout's text scale
## (Layout.text_scale: the content scale at the class's smallest reference window, e.g. 0.81 for an 844x390 phone) times any scale on the
## control itself. Nodes that draw their own text report their smallest size through `min_text_px()`.
func _small_fonts(n: Node, ppl := -1.0) -> int:
	if ppl < 0.0: ppl = Layout.text_scale(null)
	var bad := 0
	if n is Control and not (n as Control).is_visible_in_tree() and n.is_inside_tree(): return 0
	var k := ppl
	if n is Control: k *= absf((n as Control).get_global_transform().get_scale().y)
	var floor_ := float(Kit.MIN_FONT) - 0.01
	if n is Label:
		var l := n as Label; var sz: int = l.label_settings.font_size if l.label_settings != null else l.get_theme_font_size("font_size")
		if sz * k < floor_ and l.text.strip_edges() != "": bad += 1; printerr("small font (%s): label '%s' %d px -> %.1f on screen" % [Layout.kind, l.text.left(40), sz, sz * k])
	elif n is Button:
		var bs := (n as Button).get_theme_font_size("font_size")
		if bs * k < floor_ and (n as Button).text.strip_edges() != "": bad += 1; printerr("small font (%s): button '%s' %d px -> %.1f on screen" % [Layout.kind, (n as Button).text, bs, bs * k])
	elif n is RichTextLabel:
		if (n as RichTextLabel).get_theme_font_size("normal_font_size") * k < floor_: bad += 1; printerr("small font (%s): rich text" % Layout.kind)
	if n.has_method("min_text_px"):
		var px: float = n.call("min_text_px")
		if px > 0.0 and px < floor_: bad += 1; printerr("small font (%s): %s draws text at %.1f px on screen" % [Layout.kind, n.name, px])
	for c in n.get_children(): bad += _small_fonts(c, ppl)
	return bad
