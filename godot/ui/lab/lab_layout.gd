class_name LabLayout
extends RefCounted
## The lab's layout (godot/ui/screens/lab.gd is the controller; this builds what it shows): the editor column and the instrument column, the top bar
## and the add-neuron palette, the phone's view tabs and bottom-sheet inspector, the More menu (every tool that is not an essential), the parts bin,
## the end-of-episode card, the 5-seed test card and the post-solve histogram card.
##
## Progressive disclosure (LabUnlocks, docs/REQ-0.4.md): the bar holds only Back, Run / Pause, Reset, Check, Brief and More, plus Hint once hints are
## open and Test x5 once the level is passed (or always in Researcher mode, where a pass needs it). The palette holds + Excitatory and Connect, plus
## the parts bin, + Inhibitory and + Noise from the level that first needs them. Everything else (speed, mode, variants, Skip, Fit, Results, Reference,
## Empty bench, Lesions, Analysis, Load / Save) is in More, and some of it only once it can be used (Reference after a pass or in Guided mode, Lesions
## after a pass, Analysis and Load / Save from chapter II).
var lab: LabScreen
var compact := false
var bar: HFlowContainer
var palette_row: HFlowContainer
var parts_btn: Button
var connect_btn: Button
var hint_btn: Button
var check_btn: Button
var menu: Control = null
var parts_ov: Control = null
var histo_ov: Control = null
var import_ov: Control = null
var undo_btn: Button = null
var redo_btn: Button = null
const SLOTS := ["A", "B", "C"]
static var _mem_slots := {}       # solution slots while saving is off (test hooks): "<task>/<slot>" -> circuit text, for the session only

func build() -> void:
	var phone := Layout.phone; var f := Kit.f()
	lab.add_child(Kit.bench())
	var margin := MarginContainer.new(); margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mx := int(26 * f) if not phone else 14; var my := int(18 * f) if not phone else 8
	for side in ["left", "right"]: margin.add_theme_constant_override("margin_" + side, mx)
	margin.add_theme_constant_override("margin_top", my); margin.add_theme_constant_override("margin_bottom", my); lab.add_child(margin)
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", int(10 * f) if not phone else 6); margin.add_child(v)
	compact = phone or lab.get_viewport_rect().size.x < 1180.0
	bar = HFlowContainer.new(); Kit.ident(bar, "TopBar"); bar.add_theme_constant_override("h_separation", 8); bar.add_theme_constant_override("v_separation", 6); v.add_child(bar)
	fill_bar()
	if compact and not phone: v.add_child(_tabs_row())
	var body := HBoxContainer.new(); body.size_flags_vertical = Control.SIZE_EXPAND_FILL; body.add_theme_constant_override("separation", int(14 * f)); v.add_child(body)
	# left: editor
	var left := VBoxContainer.new(); left.size_flags_horizontal = Control.SIZE_EXPAND_FILL; left.size_flags_stretch_ratio = 1.55; left.add_theme_constant_override("separation", int(8 * f)); body.add_child(left)
	lab.panels["circuit"] = left
	palette_row = HFlowContainer.new(); Kit.ident(palette_row, "Palette"); palette_row.add_theme_constant_override("h_separation", 8); palette_row.add_theme_constant_override("v_separation", 6); left.add_child(palette_row)
	fill_palette()
	var editor := CircuitEditor.new(); Kit.ident(editor, "Editor"); lab.editor = editor; editor.size_flags_vertical = Control.SIZE_EXPAND_FILL; editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size = Vector2(300, 200)
	var edp := PanelContainer.new(); edp.add_theme_stylebox_override("panel", Kit.sb(Gfx.SHEET, Color(Kit.INK, 0.75), 1, 2, 0, false)); edp.size_flags_vertical = Control.SIZE_EXPAND_FILL; edp.add_child(editor); left.add_child(edp)
	editor.structure_changed.connect(lab._on_structure); editor.moved.connect(lab._autosave)   # a dropped neuron is saved at once
	editor.history_changed.connect(sync_undo); editor.circuit_restored.connect(_on_restored); editor.command.connect(_on_command)
	editor.blocked = modal_open
	editor.selection_changed.connect(func(_s): lab._sel_audio(); lab._build_inspector())
	editor.lesion_clicked.connect(lab.les.click)
	editor.editable = not lab._is_dx()   # a diagnosis case is probed, never rebuilt
	var inspector := PanelContainer.new(); Kit.ident(inspector, "Inspector"); lab.inspector = inspector; inspector.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL, Kit.LINE, 1, 12, 12 if phone else 14, false))
	var insp_box := VBoxContainer.new(); insp_box.add_theme_constant_override("separation", 8); inspector.add_child(insp_box)
	lab.insp_scroll = ScrollContainer.new(); lab.insp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; lab.insp_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL; insp_box.add_child(lab.insp_scroll)
	var insp_footer := VBoxContainer.new(); Kit.ident(insp_footer, "InspFooter"); insp_footer.visible = false; insp_box.add_child(insp_footer)   # pinned below the scroll: the diagnosis Submit row
	lab.insp_body = VBoxContainer.new(); lab.insp_body.add_theme_constant_override("separation", 8); lab.insp_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL; lab.insp_scroll.add_child(lab.insp_body)
	lab.insp_body.set_meta("footer", insp_footer)
	var ov := Control.new(); lab.ov = ov; ov.set_anchors_preset(Control.PRESET_FULL_RECT); ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if phone:   # the inspector is a bottom sheet over the editor, so the canvas keeps the whole screen when nothing is selected
		inspector.set_anchors_preset(Control.PRESET_BOTTOM_WIDE); inspector.grow_vertical = Control.GROW_DIRECTION_BEGIN
		inspector.offset_left = float(mx); inspector.offset_right = -float(mx); inspector.offset_bottom = -float(my)
		ov.add_child(inspector)
	else: left.add_child(inspector)
	# right: instruments
	var right := VBoxContainer.new(); right.size_flags_horizontal = Control.SIZE_EXPAND_FILL; right.size_flags_stretch_ratio = 1.0; right.add_theme_constant_override("separation", int(8 * f)); body.add_child(right)
	lab.panels["scopes"] = right
	var world := VBoxContainer.new(); world.size_flags_vertical = Control.SIZE_EXPAND_FILL; world.size_flags_stretch_ratio = 3.0; world.add_theme_constant_override("separation", int(8 * f)); right.add_child(world)
	lab.panels["world"] = world
	var tid := lab.task_id
	var info := Campaign.info(tid) if tid != "" else {}
	var has_tl := tid != "" and not ((info.get("bands", []) as Array).is_empty() and (info.get("timeline", []) as Array).is_empty())
	lab.task_view = TaskView.new(); lab.task_view.size_flags_vertical = Control.SIZE_EXPAND_FILL; lab.task_view.size_flags_stretch_ratio = 2.0; world.add_child(lab.task_view)
	lab.timeline_view = TimelineView.new(); lab.timeline_view.visible = has_tl
	lab.timeline_view.custom_minimum_size = Vector2(0, TimelineView.wanted_height((info.get("bands", []) as Array).size(), phone) if has_tl else 0.0); world.add_child(lab.timeline_view)
	lab.score_card = ScoreCard.new(); lab.score_card.lab = lab; world.add_child(lab.score_card)
	if tid == "":   # the sandbox: no body to draw, so the world panel is the sandbox panel (dials, energy)
		lab.task_view.visible = false; lab.score_card.visible = false
		lab.sandbox_panel = SandboxPanel.new().setup(func(): return lab.tele); world.add_child(lab.sandbox_panel)
	if lab._is_dx(): lab.score_card.visible = false   # the case has no score to watch: the answer is the score
	world.size_flags_stretch_ratio = 5.6 if has_tl else 3.0
	var body_view := has_tl or str(info.get("view", "polyline")) != "polyline"
	if body_view: lab.task_view.custom_minimum_size.y = 110.0 if phone else (230.0 if Kit.vh >= 900.0 else 136.0)   # a body view needs room for its readouts (less in a short window: 1366x768, Large text)
	var scopes := VBoxContainer.new(); scopes.size_flags_vertical = Control.SIZE_EXPAND_FILL; scopes.size_flags_stretch_ratio = 3.1 if has_tl else 4.1; scopes.add_theme_constant_override("separation", int(8 * f)); right.add_child(scopes)
	lab.panels["scopes_only"] = scopes
	lab.raster = RasterView.new(); lab.raster.size_flags_vertical = Control.SIZE_EXPAND_FILL; lab.raster.size_flags_stretch_ratio = 0.8; scopes.add_child(lab.raster)
	lab.traces = TraceView.new(); lab.traces.size_flags_vertical = Control.SIZE_EXPAND_FILL; lab.traces.size_flags_stretch_ratio = 1.3; scopes.add_child(lab.traces)
	if body_view and not phone: lab.raster.custom_minimum_size.y = 90.0 if Kit.vh >= 900.0 else 70.0; lab.traces.custom_minimum_size.y = 90.0 if Kit.vh >= 900.0 else 86.0   # the scopes give way to the body view and its timeline
	lab.gauges = GaugeView.new(); lab.gauges.custom_minimum_size = Vector2(0, (40.0 + 30.0 * maxi(1, lab.tele.rates.size() if lab.tele.sim != null else 2)) if Kit.vh >= 900.0 else (32.0 + 24.0 * maxi(1, lab.tele.rates.size() if lab.tele.sim != null else 2))); scopes.add_child(lab.gauges)
	if tid != "" and not (info.get("modulators", []) as Array).is_empty() and ModDials.available():   # task-driven neuromodulators: read-only gauges
		if Kit.vh >= 900.0 or phone: lab.mod_dials = ModDials.new().setup(func(): return lab.tele, info["modulators"], false, tid); scopes.add_child(lab.mod_dials)
		else: lab.gauges.mods = info["modulators"]   # a short window (1366x768, Large text): the levels ride on the motor-output header instead of their own panel
	lab.banner = Kit.label("", 17, Kit.RED, true); lab.banner.visible = false; v.add_child(lab.banner)
	lab.celebration = Celebration.new(); ov.add_child(lab.celebration)
	lab.celebration.open_notebook = func(): lab.app.show_screen("notebook")   # Back on the notebook returns to this lab (main.gd origin), circuit kept (lab_keep)
	lab.celebration.blocked = func() -> bool: return lab._overlay != null and is_instance_valid(lab._overlay)
	lab.add_child(ov)

# ---------- the top bar ----------
## Fill (or refill, after a pass opens tools) the top bar. Desktop: Back, title, Run / Pause, Reset, Check, [Hint], Brief, [Test x5], read-out, More.
## Phone: Back, the three view tabs, Run / Pause, Reset, Check, Menu.
func fill_bar() -> void:
	for c in bar.get_children(): bar.remove_child(c); c.queue_free()
	lab.tab_btns = {}
	var phone := Layout.phone; var bs := 22 if not phone else 18; var dxm := lab._is_dx(); var tid := lab.task_id
	lab.back_btn = Kit.btn("Back", func(): lab.app.back(), "panel", bs, Vector2(96 if not phone else 70, 0)); bar.add_child(lab.back_btn)
	if not phone:
		var t := lab._title(); var ttl := Kit.shout(t, 34 if t.length() <= 14 else 28, Kit.TEXT); ttl.size_flags_vertical = Control.SIZE_SHRINK_CENTER; bar.add_child(ttl)
	else:
		for t in [["circuit", "Circuit"], ["world", "World"], ["scopes_only", "Scopes"]]:
			var b := Kit.btn(t[1], func(): lab.tab = t[0]; apply_tab(), "panel", bs, Vector2(0, 0)); lab.tab_btns[t[0]] = b; bar.add_child(b)
	lab._run_kind = ""; lab.run_btn = Kit.btn("Run", lab._toggle_run, "panel", bs, Vector2(120 if not phone else 92, 0)); Kit.ident(lab.run_btn, "BtnRun"); bar.add_child(lab.run_btn)
	bar.add_child(Kit.btn("Reset", func(): lab._restart(false), "panel", bs, Vector2(92 if not phone else 70, 0)))
	check_btn = null; hint_btn = null
	if tid != "" and not dxm:
		check_btn = Kit.btn("Check", lab.play.check_start, "green", bs); bar.add_child(check_btn)
		check_btn.tooltip_text = "Score the circuit now, headless, on the five worlds of Test x5 (seeds 101 to 105; a challenge variant runs on one world). All five passing earns the second star."
	if tid != "" and not phone:
		hint_btn = Kit.btn("Hint", lab.play.hint_toggle, "amber", bs); Kit.ident(hint_btn, "BtnHint"); bar.add_child(hint_btn)
		bar.add_child(Kit.btn("Case" if dxm else "Brief", func(): show_brief(), "ghost", bs, Vector2(84, 0)))
		if not dxm and test_on_bar(): bar.add_child(Kit.btn("Test x5", lab._test_start, "green", bs, Vector2(110, 0)))
	if not phone: _add_undo(bar, bs - 2)
	lab.status = Kit.label("", 17 if not phone else 15, Kit.TEXT_SOFT); lab.status.size_flags_vertical = Control.SIZE_SHRINK_CENTER; lab.status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; lab.status.custom_minimum_size.x = 0; lab.status.clip_text = true
	bar.add_child(lab.status)
	if phone: lab.status.visible = false   # shown in the menu on a phone
	var mb := Kit.btn("Menu" if phone else "More", toggle_menu, "panel", bs, Vector2(84, 0)); Kit.ident(mb, "BtnMore"); mb.tooltip_text = "Speed, difficulty, tests, lesions, analysis, files"; bar.add_child(mb)
	lab.play.hint_btn_sync()
	lab._sync_run_btn.call_deferred()

## Test x5 sits on the bar once the level is passed (the second star is the next goal) and always in Researcher mode (a pass needs it).
func test_on_bar() -> bool:
	return lab.mode == "researcher" or Campaign.passed(lab.task_id) or lab._rec_pass

## Rebuild the bar and the palette when the tools on offer change (a pass, a mode switch). Keeps the view tabs and the connect state.
func refresh_bar() -> void:
	if bar == null or not is_instance_valid(bar): return
	fill_bar(); fill_palette()
	if compact: apply_tab()

func show_brief() -> void:
	lab.editor.select({}); lab._brief_forced = true; lab._build_inspector()

func _tabs_row() -> Control:
	var h := HBoxContainer.new(); h.add_theme_constant_override("separation", 8)
	for t in [["circuit", "Circuit"], ["world", "World"], ["scopes_only", "Scopes"]]:
		var b := Kit.btn(t[1], func(): lab.tab = t[0]; apply_tab(), "panel", 20, Vector2(0, 0)); b.size_flags_horizontal = Control.SIZE_EXPAND_FILL; lab.tab_btns[t[0]] = b; h.add_child(b)
	return h

func apply_tab() -> void:
	for k in ["circuit", "world", "scopes_only"]:
		var p: Control = lab.panels[k]; p.visible = (k == lab.tab)
		if lab.tab_btns.has(k) and is_instance_valid(lab.tab_btns[k]): Kit.skin(lab.tab_btns[k], "amber" if k == lab.tab else "panel", 12)
	lab.panels["scopes"].visible = lab.tab != "circuit"; lab.panels["circuit"].visible = lab.tab == "circuit"
	sheet_sync()

# ---------- the palette ----------
## The add-neuron palette: [Parts], + Excitatory, [+ Inhibitory], [+ Noise], Connect. Bracketed ones open with the level that needs them (LabUnlocks), except + Noise,
## which is offered in the sandbox only: a level is scored on the sensors it declares, so an input the player adds on a level is a stimulus of the circuit's own
## (undeclared stimulus is a cheat, the engine refuses to pass it, Guarded in engine/src/tasks/registry.cpp). The noise a level wants is its own sensor (Renshaw's
## "noise" card) or the Researcher mode's physiological noise; the sandbox has nothing to score, so a free noise source is only a tool there.
func fill_palette() -> void:
	if palette_row == null: return
	for c in palette_row.get_children(): palette_row.remove_child(c); c.queue_free()
	var sz := 18; var tid := lab.task_id
	parts_btn = null
	if not Layout.phone and LabUnlocks.has(tid, "parts"): parts_btn = Kit.btn(part_text(), open_parts, "panel", sz); Kit.ident(parts_btn, "BtnParts"); palette_row.add_child(parts_btn)   # on a phone the parts button lives in the menu
	palette_row.add_child(Kit.btn("+ Excitatory", func(): lab._add_neuron("E"), "amber", sz))
	if LabUnlocks.has(tid, "inhibitory"): palette_row.add_child(Kit.btn("+ Inhibitory", func(): lab._add_neuron("I"), "panel", sz))
	if tid == "": var nb := Kit.btn("+ Noise", lab._add_noise, "panel", sz); nb.tooltip_text = "A free noise source for the sandbox. Levels are scored on their own sensors only, so a level has no + Noise."; Kit.ident(nb, "BtnNoise"); palette_row.add_child(nb)
	connect_btn = Kit.btn("Connect", lab._toggle_connect, "panel", sz); palette_row.add_child(connect_btn)
	connect_btn.tooltip_text = "Connect mode: click a source, then a target. You can also drag from a neuron's rim."
	sync_connect_btn()
	if Layout.phone: _add_undo(palette_row, sz)   # on a phone the bar has no room

## Undo / Redo: on the top bar (desktop), in the palette (phone); not on a diagnosis case (read-only).
func _add_undo(row: Control, sz: int) -> void:
	if lab._is_dx(): return
	undo_btn = Kit.btn("Undo", func(): lab.editor.undo(), "panel", sz); undo_btn.tooltip_text = "Undo the last change (Ctrl+Z)"; row.add_child(undo_btn)
	redo_btn = Kit.btn("Redo", func(): lab.editor.redo(), "panel", sz); redo_btn.tooltip_text = "Redo (Ctrl+Shift+Z or Ctrl+Y)"; row.add_child(redo_btn)
	sync_undo()

## Undo / Redo are greyed out when there is nothing to undo or redo.
func sync_undo() -> void:
	if lab.editor == null: return
	if undo_btn != null and is_instance_valid(undo_btn): undo_btn.disabled = not lab.editor.can_undo()
	if redo_btn != null and is_instance_valid(redo_btn): redo_btn.disabled = not lab.editor.can_redo()

## Undo / redo put an older circuit on the bench: the reference lock follows the circuit (meta.editor.ref_lock), as when a kept bench is restored.
func _on_restored() -> void:
	var tid := lab.task_id
	if tid == "": return
	var ed: Variant = (lab.circuit.get("meta", {}) as Dictionary).get("editor", {})
	if ed is Dictionary and bool((ed as Dictionary).get("ref_lock", false)): LabScreen._ref_loaded[tid] = true
	else: LabScreen._ref_loaded.erase(tid)

## The bench's shortcuts (CircuitEditor.command): Space run / pause, C Check, R Reset, I / Y the inspector.
func _on_command(name: String) -> void:
	match name:
		"run": lab._toggle_run()
		"check": if check_btn != null and is_instance_valid(check_btn) and check_btn.is_visible_in_tree() and not check_btn.disabled: lab.play.check_start()
		"reset": lab._restart(false)
		"inspect": focus_inspector.call_deferred()

## The first control of the inspector takes the focus (keyboard and pad: Y / I on the bench).
func focus_inspector() -> void:
	if lab.insp_body == null: return
	if Layout.phone: sheet_sync()
	for c in lab.insp_body.find_children("*", "Control", true, false):
		var cc := c as Control
		if cc.focus_mode == Control.FOCUS_ALL and cc.is_visible_in_tree() and (cc is BaseButton or cc is Kit.Stepper or cc is HSlider) and not (cc is BaseButton and (cc as BaseButton).disabled):
			cc.grab_focus(); return

## A modal covers the bench (its shortcuts are off): a confirm card, the More menu, the parts bin, an end / test / results card, the import list, a file dialog.
func modal_open() -> bool:
	if ConfirmCard.is_open(): return true
	for o in [menu, parts_ov, histo_ov, lab._overlay, import_ov]:
		if o != null and is_instance_valid(o): return true
	return lab._file_dlg != null and lab._file_dlg.visible

## Esc closes the import list first (LabScreen.on_back).
func close_extra() -> bool:
	if import_ov != null and is_instance_valid(import_ov): close_import(); return true
	return false

func sync_connect_btn() -> void:
	if connect_btn != null and is_instance_valid(connect_btn) and lab.editor != null: Kit.skin(connect_btn, "amber" if lab.editor.tool == "connect" else "panel", 12)

func part_text() -> String:   # the part the add button makes, by its title (not its catalogue id)
	var t := str(Catalog.card(lab.part_card).get("title", ""))
	return "Parts: " + (t.split(" (")[0] if t != "" else lab.part_card)

func open_parts() -> void:
	close_menu(); close_parts()
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT); root.mouse_filter = Control.MOUSE_FILTER_STOP; lab.ov.add_child(root); parts_ov = root; Kit.ident(root, "PartsModal")
	var dim := ColorRect.new(); dim.color = Color(Kit.BENCH, 0.78); dim.set_anchors_preset(Control.PRESET_FULL_RECT); root.add_child(dim)
	var phone := Layout.phone
	var pn := PanelContainer.new(); pn.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL, Kit.LINE, 1, 16, 14 if phone else 20, true)); root.add_child(pn)
	pn.set_anchors_preset(Control.PRESET_FULL_RECT); var mg := 16 if phone else int(48 * Kit.f()); pn.offset_left = mg; pn.offset_right = -mg; pn.offset_top = mg * 0.6; pn.offset_bottom = -mg * 0.6
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 8); pn.add_child(v)
	var hd := HBoxContainer.new(); hd.add_theme_constant_override("separation", 12); v.add_child(hd)
	var t := Kit.shout("Parts bin", 34 if not phone else 24, Kit.TEXT); t.size_flags_horizontal = Control.SIZE_EXPAND_FILL; hd.add_child(t)
	hd.add_child(Kit.btn("Close", close_parts, "panel", 20 if not phone else 18))
	var bin := PartsBin.new().setup("pick", Circuits.sandbox, lab.part_card, lab._task_cards(), lab._reference_cards()); v.add_child(bin)
	bin.picked.connect(func(id): lab.part_card = id; close_parts(); sync_parts_btn())

func close_parts() -> void:
	if parts_ov != null and is_instance_valid(parts_ov): parts_ov.queue_free()
	parts_ov = null

func sync_parts_btn() -> void:
	if parts_btn != null and is_instance_valid(parts_btn): parts_btn.text = part_text()

# ---------- the More menu ----------
func toggle_menu() -> void:
	if menu != null: close_menu()
	else: open_menu()

func close_menu() -> void:
	if menu != null and is_instance_valid(menu): menu.queue_free()
	menu = null

## Every tool that is not an essential, in three groups (run, level, tools), and a line on what opens later. On a phone it also holds the read-out,
## the parts bin, Brief and Hint (the bar has no room).
func open_menu() -> void:
	close_menu()
	var phone := Layout.phone; var tid := lab.task_id; var dxm := lab._is_dx()
	var scrim := Button.new(); scrim.flat = true; scrim.set_anchors_preset(Control.PRESET_FULL_RECT); scrim.focus_mode = Control.FOCUS_NONE
	scrim.pressed.connect(close_menu); lab.ov.add_child(scrim); menu = scrim; Kit.ident(scrim, "MoreMenu")
	var pn := PanelContainer.new(); pn.add_theme_stylebox_override("panel", Kit.plate_sb(Kit.PANEL, 14)); scrim.add_child(pn)
	var mw := 470.0 if phone else 560.0
	pn.set_anchors_preset(Control.PRESET_TOP_RIGHT); pn.grow_horizontal = Control.GROW_DIRECTION_BEGIN; pn.offset_right = -14.0; pn.offset_left = -14.0 - mw; pn.offset_top = 62.0 if phone else 70.0
	var sc := ScrollContainer.new(); sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; sc.custom_minimum_size = Vector2(mw - 32.0, 120); pn.add_child(sc)
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 8); v.size_flags_horizontal = Control.SIZE_EXPAND_FILL; v.custom_minimum_size.x = mw - 48.0; sc.add_child(v)
	var fs := 18
	var group := func(title: String) -> HFlowContainer:
		if v.get_child_count() > 0: v.add_child(Kit.hsep())
		v.add_child(Kit.small_caps(title, 15, Kit.TEXT_SOFT))
		var row := HFlowContainer.new(); row.add_theme_constant_override("h_separation", 8); row.add_theme_constant_override("v_separation", 8); v.add_child(row)
		return row
	var item := func(row: Control, t: String, cb: Callable, kind := "panel") -> Button:
		var b := Kit.btn(t, func(): close_menu(); cb.call(), kind, fs); row.add_child(b); return b
	if phone:
		var stx := lab.status.text if lab.status != null and lab.status.text != "" else ""
		if stx != "": v.add_child(Kit.label(stx, 16, Kit.TEXT_SOFT))
		if LabUnlocks.has(tid, "parts"):
			v.add_child(Kit.small_caps("New neuron type", 15, Kit.TEXT_SOFT))
			var pb := Kit.btn(part_text(), open_parts, "panel", 18); pb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN; v.add_child(pb)
	# I. the run
	var run: HFlowContainer = group.call("Run")
	run.add_child(Kit.ident(Kit.stepper(LabScreen.SPEEDS, String.num(lab.tele.speed), func(id): lab.tele.speed = float(id), 76.0 if not phone else 60.0, 20 if not phone else 18, 44.0 if not phone else 36.0), "StepSpeed"))
	if tid != "": item.call(run, "Skip", lab.play.skip_event)
	item.call(run, "Fit", func(): lab.editor.fit())
	# II. the level
	if tid != "":
		var lv: HFlowContainer = group.call("Level")
		lv.add_child(Kit.ident(Kit.stepper([["guided", "Guided"], ["standard", "Standard"], ["researcher", "Researcher"]], lab.mode, func(m): lab.play.set_mode(str(m)), 250.0 if not phone else 220.0, 18, 40.0), "StepMode"))
		var vs: Dictionary = Campaign.info(tid).get("variants", {})
		if not vs.is_empty() and not dxm:
			var opts := [["base", "Base task"]]
			for k in vs: opts.append([str(k), str(vs[k])])
			lv.add_child(Kit.ident(Kit.stepper(opts, lab.variant if lab.variant != "" else "base", func(x): lab.play.set_variant("" if str(x) == "base" else str(x)), 320.0 if not phone else 260.0, 18, 40.0), "StepVariant"))
		var lv2 := HFlowContainer.new(); lv2.add_theme_constant_override("h_separation", 8); lv2.add_theme_constant_override("v_separation", 8); v.add_child(lv2)
		if phone:
			item.call(lv2, "Case" if dxm else "Brief", show_brief, "ghost")
			if lab.mode != "researcher":
				var hb: Button = item.call(lv2, HintPanel.button_text(lab.mode, int(LabScreen._fails.get(tid, 0)), int(LabScreen._hint_tier.get(tid, 0))), lab.play.hint_toggle, "amber"); Kit.ident(hb, "BtnHint")
				Kit.skin(hb, "amber" if HintPanel.available(lab.mode, int(LabScreen._fails.get(tid, 0))) else "ghost", 12)
		if not dxm:
			if phone or not test_on_bar(): item.call(lv2, "Test x5", lab._test_start, "green")
			if passed_here(): item.call(lv2, "Results", histo_show, "panel")
			if reference_open(): item.call(lv2, "Reference", lab._load_reference, "panel")
			item.call(lv2, "Restore given circuit" if Campaign.given_path(tid) != "" else "Empty bench", lab._empty_bench)
			if lab._has_history(): item.call(lv2, "Restore previous bench", lab._restore_bench)
	# II b. solution slots: three saved circuits per level, kept across restarts
	if not dxm:
		var sl: HFlowContainer = group.call("Solution slots")
		var info := PackedStringArray()
		for x in SLOTS:
			Kit.ident(item.call(sl, "Save to " + x, func(): slot_save(x)), "BtnSaveTo" + x)
			var st := slot_text(x)
			if st != "": Kit.ident(item.call(sl, "Load " + x, func(): slot_load(x)), "BtnLoad" + x)
			info.append("%s: %s" % [x, slot_summary(st)])
		var il := Kit.label("   ".join(info), 15, Kit.TEXT_SOFT, true); il.custom_minimum_size.x = mw - 60.0; v.add_child(il)
	# III. tools
	var tools: HFlowContainer = group.call("Tools")
	if tid != "" and (lab.lesion_on or lab._lesion_ok()): item.call(tools, "Leave lesions" if lab.lesion_on else "Lesions", lab._lesion_toggle, "amber" if lab.lesion_on else "panel")
	if LabUnlocks.has(tid, "analysis"): item.call(tools, "Analysis", lab._open_analysis, "green")
	if not dxm and LabUnlocks.has(tid, "loadsave"):
		item.call(tools, "Load", lab._load_dialog); item.call(tools, "Save", lab._save_dialog)
		item.call(tools, "Copy circuit as JSON", copy_json); item.call(tools, "Paste circuit JSON", paste_json)
		item.call(tools, "Import from a passed level", open_import)
	if tools.get_child_count() == 0:   # an empty group: drop its heading and rule too
		var n := v.get_child_count()
		for k in 3: var c := v.get_child(n - 1 - k); v.remove_child(c); c.queue_free()
	var later := LabUnlocks.locked_text(tid)
	if tid != "" and not lab._lesion_ok() and not dxm: later = ("Lesions open after a pass. " + later).strip_edges()
	if tid != "" and not reference_open() and not dxm: later = (later + " The reference circuit opens once you pass the level (or in Guided mode).").strip_edges()
	if later != "":
		v.add_child(Kit.hsep())
		var ll := Kit.label(later, 15, Kit.TEXT_SOFT, true); ll.custom_minimum_size.x = mw - 60.0; v.add_child(ll)
	_size_menu.call_deferred(sc, v)

## The level has been passed (now or before): Results and the reference open.
func passed_here() -> bool:
	return lab._rec_pass or Campaign.passed(lab.task_id) or (lab.tele != null and bool(lab.tele.score.get("passed", false)))

## REFERENCE is hidden until the level is passed, except in Guided mode.
func reference_open() -> bool: return lab.mode == "guided" or passed_here()

func _size_menu(sc: ScrollContainer, v: Control) -> void:
	await lab.get_tree().process_frame
	if is_instance_valid(sc) and is_instance_valid(v): sc.custom_minimum_size.y = minf(v.get_combined_minimum_size().y, lab.size.y - 90.0)

# ---------- solution slots, circuit JSON, import ----------
func _slot_key(x: String) -> String: return "%s/%s" % [lab.task_id if lab.task_id != "" else "free", x]
static func slot_path_of(tid: String, x: String) -> String: return Circuits.user_dir().path_join(tid if tid != "" else "free").path_join("slot_%s.json" % x)

## The circuit text in slot `x` of task `tid` ("" when empty): the file through SaveIO, or the session copy while saving is off.
static func slot_text_of(tid: String, x: String) -> String:
	if not SaveIO.enabled(): return str(_mem_slots.get("%s/%s" % [tid if tid != "" else "free", x], ""))
	var p := slot_path_of(tid, x)
	return FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else ""

func slot_text(x: String) -> String: return slot_text_of(lab.task_id, x)

func slot_summary(text: String) -> String:
	if text == "": return "empty"
	var c := Circuits.parse(text)
	return Progress.neurons_text(Circuits.neuron_count(c)) if not c.is_empty() else "damaged"

## Save to slot `x`: atomic write (SaveIO), no confirmation (the slot only ever holds what you put in it).
func slot_save(x: String) -> void:
	var text := Circuits.to_json(lab.circuit)
	var ok := true
	if SaveIO.enabled(): ok = SaveIO.write_text(slot_path_of(lab.task_id, x), text, -1.0)
	else: _mem_slots[_slot_key(x)] = text
	if ok: lab.editor.note("Saved to slot %s (%s)" % [x, Progress.neurons_text(Circuits.neuron_count(lab.circuit))])
	else: lab._banner_raw("Slot %s could not be saved." % x)

## Load slot `x` onto the bench (asks first when the bench has work on it; the replaced bench goes into the history and one undo brings it back).
func slot_load(x: String) -> void:
	var r := Circuits.parse_checked(slot_text(x))
	if str(r["error"]) != "": lab._banner_raw("Slot %s could not be opened: %s." % [x, str(r["error"])]); return
	adopt_bench(r, "Load slot %s?" % x, "The bench is replaced by the circuit in slot %s." % x, "Load " + x)

## Put a checked circuit (Circuits.parse_checked result) on the bench, as Load does: confirm, keep the old bench, the reference lock from the file.
func adopt_bench(r: Dictionary, title: String, what: String, yes: String) -> void:
	lab._replace_bench(title, what, yes, func():
		lab._autosave(); lab._keep_bench()
		lab.circuit = r["circuit"]; lab._notice_repairs(int(r["repaired"])); lab._drop_old_flag(); Circuits.ensure_pos(lab.circuit)
		if lab.task_id != "":
			if bool((lab.circuit.get("meta", {}) as Dictionary).get("editor", {}).get("ref_lock", false)): LabScreen._ref_loaded[lab.task_id] = true
			else: LabScreen._ref_loaded.erase(lab.task_id)
		lab.editor.select({}); lab.les.reset(); lab._reload(true); lab._build_inspector(); lab._autosave())

## More > Copy circuit as JSON: the whole circuit on the clipboard (to share or keep).
func copy_json() -> void:
	var t := Circuits.to_json(lab.circuit)
	CircuitClip.text = t; DisplayServer.clipboard_set(t)
	lab.editor.note("Circuit copied as JSON")

## More > Paste circuit JSON: a circuit from the clipboard, checked (Circuits.validate) before it replaces the bench.
func paste_json() -> void:
	var t := DisplayServer.clipboard_get()
	if t.strip_edges() == "": t = CircuitClip.text   # no system clipboard (headless): the last copy made in the game
	var r := Circuits.parse_checked(t)
	if str(r["error"]) != "": lab._banner_raw("The clipboard does not hold a usable circuit: %s." % str(r["error"])); return
	adopt_bench(r, "Paste this circuit?", "The bench is replaced by the circuit on the clipboard.", "Paste")

func close_import() -> void:
	if import_ov != null and is_instance_valid(import_ov): import_ov.queue_free()
	import_ov = null

## The circuits that can be imported: each passed level's saved bench and slots, the player's own (a bench built from a reference is not offered).
## [{tid, src ("bench" | "A" | "B" | "C"), title, circuit}], and how many reference-derived ones were left out.
func import_sources() -> Array:
	var out := []; var skipped := 0
	for t in Campaign.order():
		var tid := str(t)
		if tid == lab.task_id or not Campaign.passed(tid) or str(Campaign.info(tid).get("kind", "")) == "diagnosis": continue
		var srcs := [["bench", ""]]
		for x in SLOTS: srcs.append([x, slot_text_of(tid, x)])
		if SaveIO.enabled():
			var lp := Circuits.user_dir().path_join("last_%s.json" % tid)
			srcs[0][1] = FileAccess.get_file_as_string(lp) if FileAccess.file_exists(lp) else ""
		for s in srcs:
			if str(s[1]) == "": continue
			var r := Circuits.parse_checked(str(s[1]))
			if str(r["error"]) != "" or Circuits.neuron_count(r["circuit"]) == 0: continue
			var c: Dictionary = r["circuit"]
			var ed: Variant = (c.get("meta", {}) as Dictionary).get("editor", {})
			if (ed is Dictionary and bool((ed as Dictionary).get("ref_lock", false))) or Circuits.is_reference_of(c, tid): skipped += 1; continue
			out.append({"tid": tid, "src": str(s[0]), "title": str(Campaign.info(tid).get("title", tid)), "circuit": c})
	return [out, skipped]

## More > Import from a passed level: pick one of your solved circuits; its groups are pasted onto this bench as one selected group.
func open_import() -> void:
	close_menu(); close_import()
	var phone := Layout.phone
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT); root.mouse_filter = Control.MOUSE_FILTER_STOP; lab.ov.add_child(root); import_ov = root; Kit.ident(root, "ImportModal")
	var dim := ColorRect.new(); dim.color = Color(Kit.BENCH, 0.78); dim.set_anchors_preset(Control.PRESET_FULL_RECT); root.add_child(dim)
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); cc.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.add_child(cc)
	var pn := PanelContainer.new(); pn.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL, Kit.LINE, 1, 16, 14 if phone else 22, true)); cc.add_child(pn)
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 10); v.custom_minimum_size.x = minf(720.0, lab.size.x - 40.0); pn.add_child(v)
	var hd := HBoxContainer.new(); hd.add_theme_constant_override("separation", 12); v.add_child(hd)
	var t := Kit.shout("Import from a passed level", 30 if not phone else 22, Kit.TEXT); t.size_flags_horizontal = Control.SIZE_EXPAND_FILL; t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; hd.add_child(t)
	hd.add_child(Kit.btn("Close", close_import, "panel", 20 if not phone else 18))
	v.add_child(Kit.label("Your circuit from a level you passed is pasted onto this bench as one group, selected so you can move it. Links to sensors and motors this level does not have are dropped, and the note says which.", 17 if not phone else 15, Kit.TEXT, true))
	var res := import_sources(); var list: Array = res[0]
	var sc := ScrollContainer.new(); sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; sc.custom_minimum_size.y = minf(56.0 * maxf(list.size(), 1.0), lab.size.y * 0.5); v.add_child(sc)
	var lv := VBoxContainer.new(); lv.add_theme_constant_override("separation", 6); lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(lv)
	for s in list:
		var what := "saved bench" if str(s["src"]) == "bench" else "slot " + str(s["src"])
		var b := Kit.btn("%s · %s (%s)" % [str(s["title"]), what, Progress.neurons_text(Circuits.neuron_count(s["circuit"]))], func(): import_from(s), "panel", 18)
		Kit.ident(b, "Imp_%s_%s" % [str(s["tid"]), str(s["src"])]); b.alignment = HORIZONTAL_ALIGNMENT_LEFT; lv.add_child(b)
	if list.is_empty(): lv.add_child(Kit.label("No passed level has a circuit of your own saved yet. Pass a level (its bench is saved as you build) or save one to a slot.", 17, Kit.TEXT_SOFT, true))
	if int(res[1]) > 0: v.add_child(Kit.label("%d saved circuit%s built from a reference circuit %s not offered." % [int(res[1]), "" if int(res[1]) == 1 else "s", "is" if int(res[1]) == 1 else "are"], 15, Kit.TEXT_SOFT, true))

func import_from(s: Dictionary) -> void:
	close_import()
	var c: Dictionary = s["circuit"]; var ids := []
	for p in c.get("populations", []): ids.append(str(p.get("id", "")))
	var r := lab.editor.paste_fragment(CircuitClip.fragment(c, ids, true))
	if r.has("error"): lab._banner_raw("The import did not fit on this bench: %s." % str(r["error"])); return
	var msg := "Imported %s (%d group%s)." % [str(s["title"]), (r["ids"] as Array).size(), "" if (r["ids"] as Array).size() == 1 else "s"]
	if not (r["dropped"] as Array).is_empty(): msg += " Dropped links to channels this level does not have: %s." % ", ".join(r["dropped"])
	lab.editor.note(msg, 9.0)
	Playlog.event("import", {"task": lab.task_id, "from": str(s["tid"]), "src": str(s["src"])})

# ---------- the phone sheet ----------
## On a phone the inspector is a bottom sheet that shows only while something is selected (or the brief is asked for) and only on the circuit tab.
func sheet_sync() -> void:
	if lab.inspector == null or lab.editor == null: return
	sync_undo()
	if not Layout.phone:
		lab.inspector.visible = true
		if palette_row != null: palette_row.visible = not lab.lesion_on and not lab._is_dx()
		return
	var show := (not lab.editor.sel.is_empty() or lab._brief_forced or lab.lesion_on) and lab.tab == "circuit"
	lab.inspector.visible = show
	if palette_row != null: palette_row.visible = not show and not lab._is_dx()   # the sheet needs the room
	if not show and lab.editor.inset_bottom != 0.0: lab.editor.inset_bottom = 0.0; lab.editor.fit()

## Size the inspector's scroll area to its content (capped), and keep the phone editor's neurons above the sheet.
func fit_inspector() -> void:
	await lab.get_tree().process_frame
	if not lab.is_inside_tree() or lab.insp_scroll == null or lab.insp_body == null: return
	var want := lab.insp_body.get_combined_minimum_size().y
	var big := lab.lesion_on or (lab._is_dx() and lab.editor.sel.is_empty())   # the lesion table and the case card need more room than a neuron's inspector
	var cap := lab.size.y * ((0.62 if big else 0.46) if Layout.phone else (0.6 if lab.lesion_on else (0.5 if big else 0.36)))
	lab.insp_scroll.custom_minimum_size.y = minf(want, cap)
	if Layout.phone:
		await lab.get_tree().process_frame
		if not lab.is_inside_tree() or lab.editor == null: return
		var inset: float = (lab.inspector.size.y + 12.0) if lab.inspector.visible else 0.0
		if absf(inset - lab.editor.inset_bottom) > 12.0: lab.editor.inset_bottom = inset; lab.editor.fit()

# ---------- end-of-episode card, 5-seed test card ----------
func overlay_hide() -> void:
	if lab._overlay != null and is_instance_valid(lab._overlay): lab._overlay.queue_free()
	lab._overlay = null

func _end_text() -> String:
	var sc: Dictionary = lab.tele.score; var passed := lab._ov_passed(); var parts := []; var tid := lab.task_id
	if not lab._test_result.is_empty():
		parts.append("Test: %d of %d seeds passed." % [int(lab._test_result["passes"]), int(lab._test_result["n"])])
	if lab._is_reference():
		if Circuits.has_locks(lab.circuit): parts.append("This is the reference circuit, or a copy of it: it earns no stars. Open More, press “Restore given circuit” and set the cell-type cards yourself.")
		else: parts.append("This is the reference circuit, or a copy of it: it earns no stars. Open More, press “Empty bench” and build your own.")
	elif not passed:
		if lab._test_result.is_empty(): parts.append(Circuits.cap_verdict(str(sc.get("verdict", "")), lab.circuit, tid))
		if lab.mode == "researcher": parts.append("Researcher mode: no hints. Read the scopes and the lesion table.")
		elif HintPanel.available(lab.mode, int(LabScreen._fails.get(tid, 0))): parts.append("The glowing part of the circuit is what the verdict is about. Press “Hint” for a nudge.")
		else: parts.append("The glowing part of the circuit is what the verdict is about. Hints open after %d missed runs (%d so far)." % [HintPanel.UNLOCK_FAILS, int(LabScreen._fails.get(tid, 0))])
	else:
		var st := Progress.best(tid)["stars"] as int
		var nn := Circuits.neuron_count(lab.circuit); var bud := Progress.budget(tid)
		if lab._test_result.is_empty() and st < 2: parts.append("Next star: press “Test x5”. It runs 5 other random worlds; all must pass.")
		elif st == 2 and nn > bud: parts.append("Third star: pass again with %s or fewer (you have %d)." % [Progress.neurons_text(bud), nn])
		elif st >= 3: parts.append("Three stars. Try the next task" + (", or open Analysis to see which motifs your circuit uses." if LabUnlocks.has(tid, "analysis") else "."))
		elif st < 3 and lab._test_result.has("passes") and int(lab._test_result["passes"]) < int(lab._test_result["n"]): parts.append("It passes the fixed world but not every seed: make it less fragile, then test again.")
	return "  ".join(parts)

## The card of a TEST x5 (the player pressed it): its progress while the five worlds run, then the result with the stars, what to try next, Next level after a pass and Close.
## A plain run raises no card: its result is on the score card (ScoreCard), with the same ways on.
func overlay_show(testing := false) -> void:
	overlay_hide(); close_menu(); close_parts()   # one modal at a time: the card that rises when the run ends closes the More menu and the parts bin
	var phone := Layout.phone; var tele := lab.tele; var tid := lab.task_id
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT); root.mouse_filter = Control.MOUSE_FILTER_STOP; lab.ov.add_child(root); lab._overlay = root; Kit.ident(root, "TestCard" if testing else "EndCard")
	var dim := ColorRect.new(); dim.color = Color(Kit.BENCH, 0.62); dim.set_anchors_preset(Control.PRESET_FULL_RECT); dim.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.add_child(dim)
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); cc.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.add_child(cc)
	var pn := PanelContainer.new(); pn.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL, Kit.LINE, 1, 16, 14 if phone else 24, true)); cc.add_child(pn)
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 6 if phone else 12); v.custom_minimum_size.x = 560 if not phone else 600; pn.add_child(v)
	var passed := lab._ov_passed(); var val := int(roundf(float(tele.score.get("value", 0.0))))
	if not lab._test_result.is_empty():
		var tot := 0.0
		for x in lab._test_result["scores"]: tot += float(x)
		val = int(roundf(tot / maxf(float((lab._test_result["scores"] as Array).size()), 1.0)))
	if testing:
		var i := int(lab._test.get("i", 0))
		v.add_child(Kit.shout("Testing  %d of %d" % [mini(i + 1, LabScreen.TEST_SEEDS.size()), LabScreen.TEST_SEEDS.size()], 34 if not phone else 26, Kit.TEXT))
		var pl := Kit.label("", 20 if not phone else 17, Kit.TEXT_SOFT, true); pl.name = "TestProg"; v.add_child(pl)
		v.add_child(Kit.btn("Cancel", lab._test_cancel, "panel", 20))
		return
	# a rubber stamp beside "N of 100" and the stars; one soft line for a reference circuit; one primary button (the next level after a pass, else run
	# again), the rest outlined. The energy bill lives in Results (its Energy row), not here.
	var hd := HBoxContainer.new(); hd.add_theme_constant_override("separation", 22 if not phone else 14); v.add_child(hd)
	var col := Kit.success() if passed else Kit.RED
	var ref := lab._is_reference()
	var seeds := not lab._test_result.is_empty()
	var stp := Kit.stamp(str(val), "PASSED" if passed else "NOT PASSED", "of 100", col, 120.0 if not phone else 88.0); Kit.ident(stp, "EndStamp"); hd.add_child(stp)
	var hv := VBoxContainer.new(); hv.add_theme_constant_override("separation", 6); hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL; hv.alignment = BoxContainer.ALIGNMENT_CENTER; hd.add_child(hv)
	var tl := Kit.display("%d of 100" % val if not seeds else "%d of %d worlds passed" % [int(lab._test_result["passes"]), int(lab._test_result["n"])], 40 if not phone else 28, Kit.TEXT); hv.add_child(tl)
	var best := Progress.best(tid)
	if ref: hv.add_child(Kit.italic("Reference circuit: practice only", 19 if not phone else 16, Kit.TEXT_SOFT))
	else:
		var sr := HBoxContainer.new(); sr.add_theme_constant_override("separation", 14); hv.add_child(sr)
		var ev := _OvStars.new(); ev.n = int(best["stars"]); ev.custom_minimum_size = Vector2(110, 30); sr.add_child(ev)
		if passed and int(best["stars"]) > 0: GameAudio.event("star%d" % clampi(int(best["stars"]), 1, 3))   # the stars ring as the card rises
		var bl := Kit.label("best %d" % int(roundf(float(best["value"]))), 18 if not phone else 16, Kit.TEXT_SOFT); bl.size_flags_vertical = Control.SIZE_SHRINK_CENTER; sr.add_child(bl)
	var et := _end_text()
	if et != "": v.add_child(Kit.label(et, 19 if not phone else 16, Kit.TEXT, true))
	var br := HFlowContainer.new(); br.add_theme_constant_override("h_separation", 10); br.add_theme_constant_override("v_separation", 8); v.add_child(br)
	var nx := Progress.next_task(tid)
	var next_first := passed and nx != ""
	if next_first: br.add_child(Kit.ident(Kit.btn("Next level →", func(): lab.app.open_lab(nx), "amber", 22), "BtnNextTask"))
	br.add_child(Kit.btn("Close", func(): lab._overlay_dismissed = true; overlay_hide(), "ghost", 20))

## The 5-seed test card's progress line.
func test_progress(seed: int, pct: float, done: Array) -> void:
	if lab._overlay == null: return
	var pl := lab._overlay.find_child("TestProg", true, false) as Label
	if pl == null: return
	pl.text = "Seed %d: %d%% of the episode simulated." % [seed, int(pct)]
	if not done.is_empty(): pl.text += "  Finished: " + ", ".join(done.map(func(r): return "%d%s" % [int(r["value"]), "" if r["passed"] else " (miss)"]))

class _OvStars extends Control:
	var n := 0
	func _draw() -> void:
		for k in 3: ScoreCard.draw_star_on(self, Vector2(14.0 + 34.0 * k, size.y * 0.5), 13.0, Kit.GAMBOGE if k < n else Color(Kit.LINE, 0.95))

# ---------- post-solve histograms ----------
## The three axes of the post-solve card: neurons, energy (mean spikes/s per neuron, the ATP bill) and the task's own quality metric.
func metric_rows() -> Array:
	var tele := lab.tele
	var nn := Circuits.neuron_count(lab.circuit)
	var hz := tele.spike_rate_hz() / maxf(float(nn), 1.0) if tele != null and tele.sim != null else 0.0
	var rows := [{"id": "neurons", "label": "Neurons", "value": float(nn), "unit": "neurons", "lower": true},
		{"id": "energy_hz", "label": "Energy", "value": hz, "unit": "spikes/s/neuron", "lower": true}]
	var found := false
	if tele != null and tele.task != null and tele.task.has_method("metrics"):
		var m: Dictionary = tele.task.metrics()
		for k in m:
			if str(k) in ["neurons", "energy_hz"] or found: continue
			var d: Dictionary = m[k]
			rows.append({"id": str(k), "label": BodyViews.pretty(str(k))[0] if BodyViews.pretty(str(k)).size() > 0 else str(k).capitalize(), "value": float(d.get("value", 0.0)), "unit": str(d.get("unit", "")), "lower": bool(d.get("lower_is_better", true))}); found = true
	if not found: rows.append({"id": "score", "label": "Task score", "value": float(tele.score.get("value", 0.0)) if tele != null else 0.0, "unit": "points", "lower": false})
	return rows

func histo_hide() -> void:
	if histo_ov != null and is_instance_valid(histo_ov): histo_ov.queue_free()
	histo_ov = null

## What the post-solve card is compared against, said plainly (docs/HISTOGRAMS.md, docs/WHAT-IS-REAL.md): GENERATED variants of the reference circuit.
const HISTO_TRUTH := "These are generated variants of the reference circuit, not other players: a script changed the reference at random and kept every variant that passed."

func histo_show() -> void:
	var tid := lab.task_id
	if tid == "" or lab.tele == null or lab._is_dx(): return
	histo_hide(); close_menu(); overlay_hide(); lab._overlay_dismissed = true
	var phone := Layout.phone
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT); root.mouse_filter = Control.MOUSE_FILTER_STOP; lab.ov.add_child(root); histo_ov = root; Kit.ident(root, "HistoCard")
	var dim := ColorRect.new(); dim.color = Color(Kit.BENCH, 0.78); dim.set_anchors_preset(Control.PRESET_FULL_RECT); root.add_child(dim)
	var pn := PanelContainer.new(); pn.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL, Kit.LINE, 1, 16, 12 if phone else 20, true)); root.add_child(pn)
	pn.set_anchors_preset(Control.PRESET_FULL_RECT); var mg := 14 if phone else int(70 * Kit.f()); pn.offset_left = mg; pn.offset_right = -mg; pn.offset_top = mg * 0.5; pn.offset_bottom = -mg * 0.5
	if not phone: pn.set_anchors_preset(Control.PRESET_CENTER); pn.grow_horizontal = Control.GROW_DIRECTION_BOTH; pn.grow_vertical = Control.GROW_DIRECTION_BOTH; pn.offset_left = -float(lab.size.x) * 0.45; pn.offset_right = float(lab.size.x) * 0.45; pn.offset_top = 0.0; pn.offset_bottom = 0.0
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 6 if phone else 10); pn.add_child(v)
	var hd := HBoxContainer.new(); hd.add_theme_constant_override("separation", 12); v.add_child(hd)
	var t := Kit.shout("Your circuit against generated variants", 32 if not phone else 22, Kit.TEXT); t.size_flags_horizontal = Control.SIZE_EXPAND_FILL; t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; hd.add_child(t)
	hd.add_child(Kit.btn("Close", histo_hide, "panel", 20 if not phone else 18))
	var raw := HistogramView.load_file(tid)
	var passed := bool(lab.tele.score.get("passed", false)) or bool(Progress.best(tid)["passed"])
	var truth := Kit.label(HISTO_TRUTH + (" Beat their median on any axis." if not raw.is_empty() else ""), 17 if not phone else 15, Kit.TEXT, true)
	v.add_child(truth)
	if raw.is_empty(): v.add_child(Kit.label("No generated variants exist for this level yet. Your numbers are below; pin a target to chase.", 17 if not phone else 15, Kit.TEXT_SOFT, true))
	if not passed: v.add_child(Kit.label("This run has not passed yet: the numbers are for the run so far.", 16, Kit.AMBER, true))
	var sc := ScrollContainer.new(); sc.size_flags_vertical = Control.SIZE_EXPAND_FILL; sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; sc.custom_minimum_size.y = 0.0 if phone else 190.0; v.add_child(sc)
	var fl := HFlowContainer.new(); fl.size_flags_horizontal = Control.SIZE_EXPAND_FILL; fl.add_theme_constant_override("h_separation", 14); fl.add_theme_constant_override("v_separation", 10); sc.add_child(fl)
	var wins := 0
	for r in metric_rows():
		var hv := HistogramView.new().setup(tid, str(r["id"]), str(r["label"]), float(r["value"]), str(r["unit"]), bool(r["lower"]), (raw.get(str(r["id"]), {}) as Dictionary) if raw.get(str(r["id"]), {}) is Dictionary else {})
		hv.custom_minimum_size.x = 300.0 if phone else 440.0; hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL; fl.add_child(hv)
		if HistogramView.beats_median(hv.dist, float(r["value"]), bool(r["lower"])): wins += 1
	if wins > 0: v.add_child(Kit.label("You beat the variants' median on %d of 3 axes." % wins, 19, Kit.GREEN, true))
	if lab.tele.sim != null:   # the energy bill of this run (moved here from the end card)
		var hz := lab.tele.spike_rate_hz()
		v.add_child(Kit.label("Energy: %s spikes/s in the whole circuit, about %s (each spike costs roughly a hundred million to a billion ATP)." % [str(int(roundf(hz))), Telemetry.atp_text(hz)], 16 if not phone else 15, Kit.TEXT_SOFT, true))
	Playlog.event("histogram", {"task": tid})
