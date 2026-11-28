class_name LabInspector
extends RefCounted
## The lab's inspector panel (the controller is godot/ui/screens/lab.gd): what shows under the editor (desktop) or in the bottom sheet (phone) for the
## current selection. Nothing selected: the level's brief (its first sentences, with a More expander), the recipe button and the star rule. A population:
## model, preset, size, trace, E / I, the Advanced parameters and its neuromodulator response. An axon: weight, delay, spread, wiring. A sensor or motor
## card: what it is wired to, its kind and weight. In the lesion lab: the lesion table. In a diagnosis case: the case card and read-only facts.
var lab: LabScreen

const QUAD_STEP := 0.0025
const BRIEF_LEAD := 330   # characters of the brief shown before the More expander (two or three lines; fewer on a phone)

func build() -> void:
	if lab.insp_body == null: return
	var editor := lab.editor
	if not editor.sel.is_empty(): lab._brief_forced = false
	for c in lab.insp_body.get_children(): lab.insp_body.remove_child(c); c.queue_free()
	var foot: Control = lab.insp_body.get_meta("footer", null)
	if foot != null:
		for c in foot.get_children(): foot.remove_child(c); c.queue_free()
		foot.visible = false
	lab._autosave()
	var sel := editor.sel if editor != null else {}
	var small := 17 if not Layout.phone else 16
	# what the inspector shows, for the interaction graph (godot/tests/interaction_graph.json): brief | dx | dxpick | lesion | pop | proj | in | out
	lab.insp_body.set_meta("sp_view", "lesion" if lab.lesion_on else (("dx" if lab._is_dx() else "brief") if sel.is_empty() else ("dxpick" if lab._is_dx() else str(sel["t"]))))
	if lab.lesion_on: lab.les.inspect(small)
	elif sel.is_empty(): inspect_dx(small) if lab._is_dx() else inspect_brief(small)
	elif lab._is_dx(): inspect_dx_pick(sel, small)
	else:
		match sel["t"]:
			"pop": inspect_pop(str(sel["id"]), small)
			"proj": inspect_proj(int(sel["i"]), small)
			"in": inspect_channel("inputs", str(sel["name"]), small)
			"out": inspect_channel("outputs", str(sel["name"]), small)
			"ilink", "olink": inspect_link(sel, small)
	lab.layout.sheet_sync()
	lab.layout.fit_inspector.call_deferred()

func add(c: Control) -> void: lab.insp_body.add_child(c)

func head(title: String, kind_col: Color, tag := "") -> HBoxContainer:
	var h := HBoxContainer.new(); h.add_theme_constant_override("separation", 10)
	h.add_child(Kit.chip(title, kind_col, 18))
	var l := Kit.label(tag, 17, Kit.TEXT_SOFT); l.size_flags_horizontal = Control.SIZE_EXPAND_FILL; l.clip_text = true; h.add_child(l)
	if Layout.phone: h.add_child(Kit.btn("Done", func(): lab._brief_forced = false; lab.editor.select({}); (lab._lesion_toggle() if lab.lesion_on else build()), "panel", 18))
	return h

## The first sentences of `t` that fit in `n` characters (at least one sentence), and whether anything was left out.
static func lead(t: String, n: int) -> Array:
	var out := ""; var sents := t.split(". "); var used := 0
	for sent in sents:
		var nxt := (out + (" " if out != "" else "") + sent + ("" if sent.ends_with(".") or sent.ends_with("?") or sent.ends_with("!") else "."))
		if out != "" and nxt.length() > n: break
		out = nxt; used += 1
	return [out, used < sents.size()]

## What the level asks, in the brief's own words, for the part of the brief that stays visible: the sentences that state the pass rule ("Pass: ...", "Score: ...", "... to pass"), else the last
## sentences that state a requirement ("must", "needs", "at least"). Sentences already in `shown` are left out. At most two sentences and `n` characters; "" when there are none.
static func pass_lines(t: String, shown: String, n := 300) -> String:
	var sents := t.split(". "); var picks := []
	for raw in sents:
		var sn := str(raw).strip_edges(); var low := sn.to_lower()
		if sn == "" or shown.contains(sn.trim_suffix(".")): continue
		if low.begins_with("pass") or low.begins_with("score") or "pass:" in low or "score:" in low or " to pass" in low or " pass " in low: picks.append(sn)
	if picks.is_empty():
		for raw in sents:
			var sn2 := str(raw).strip_edges(); var low2 := sn2.to_lower()
			if sn2 == "" or shown.contains(sn2.trim_suffix(".")): continue
			if " must " in low2 or " needs " in low2 or "at least" in low2 or " keep " in low2: picks.append(sn2)
		picks = picks.slice(maxi(0, picks.size() - 2))
	if picks.is_empty(): return ""
	var out := ""
	for sn3 in picks.slice(0, 2):
		var piece := str(sn3).trim_suffix(".") + "."
		if out != "" and out.length() + piece.length() > n: break
		out += ("" if out == "" else " ") + piece
	return out if out.length() <= n + 120 else out.substr(0, n).strip_edges() + "…"

const BUILD_VERBS := ["make ", "build ", "create ", "connect ", "add ", "wire ", "give ", "use ", "put ", "feed ", "set ", "choose ", "then ", "start ", "place ", "pick ", "drive ", "keep "]

## What to build, in the brief's own words, for the part that stays visible without More: the sentences that tell the player what to make or connect (they begin with a verb such as
## "Make", "Connect", "Build", "Then build"). Sentences already in `shown` are left out. At most two sentences, the second only if both fit in `n` characters; "" when there are none.
static func build_lines(t: String, shown: String, n := 360) -> String:
	var out := ""
	for raw in t.split(". "):
		var sn := str(raw).strip_edges(); var low := sn.to_lower()
		if sn == "" or shown.contains(sn.trim_suffix(".")): continue
		var act := false
		for v in BUILD_VERBS:
			if low.begins_with(v): act = true
		if not act: continue
		var piece := sn.trim_suffix(".") + "."
		if out != "" and out.length() + piece.length() > n: break
		out += ("" if out == "" else " ") + piece
		if out.length() > n: break
	return out

func inspect_brief(small: int) -> void:
	var tid := lab.task_id; var t: String = ""
	if tid != "" and lab.ext_ok: t = str(Campaign.info(tid)["brief"])
	var hd := head("BRIEF" if tid != "" else "FREE RUN", Kit.exc(), lab._title() if tid != "" else "build any circuit and watch it run"); add(hd)
	var txt := t if t != "" else "Add neurons, connect them by dragging from one disc's rim to another, and watch the raster and the voltage traces."
	var ld := lead(txt, BRIEF_LEAD if not Layout.phone else 200)
	var short := not lab._brief_full and bool(ld[1])
	if bool(ld[1]):   # More / Less sits in the header row, not under the text: a long brief (the bosses) never pushes it off the bottom of the screen
		var mb: Button = Kit.ident(Kit.btn("More…" if short else "Less", func(): lab._brief_full = short; build(), "ghost", 16), "BtnBriefMore"); mb.size_flags_horizontal = Control.SIZE_SHRINK_END
		hd.add_child(mb); hd.move_child(mb, 2 if not Layout.phone else hd.get_child_count() - 1)
	add(Kit.label(str(ld[0]) if short else txt, small, Kit.TEXT if short else Kit.TEXT_SOFT, true))
	if short and tid != "":   # what to build and the pass rule stay in view, not behind More (which keeps the background)
		var bl := build_lines(txt, str(ld[0]), 700 if not Layout.phone else 300)
		if bl != "":
			var br := HBoxContainer.new(); br.add_theme_constant_override("separation", 8); add(br)
			var bc := Kit.chip("TO BUILD", Kit.exc(), 14); bc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN; br.add_child(bc)
			var bt := Kit.label(bl, small, Kit.TEXT, true); bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL; br.add_child(bt)
		var pl := pass_lines(txt, str(ld[0]) + " " + bl, 260 if not Layout.phone else 170)
		if pl != "":
			var pr := HBoxContainer.new(); pr.add_theme_constant_override("separation", 8); add(pr)
			var pc := Kit.chip("TO PASS", Kit.AMBER, 14); pc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN; pr.add_child(pc)
			var pt := Kit.label(pl, small, Kit.TEXT, true); pt.size_flags_horizontal = Control.SIZE_EXPAND_FILL; pr.add_child(pt)
	var rec := lab._recipe_text()
	if rec != "" and lab.mode != "researcher":
		if lab.mode == "guided" or lab._recipe_open:
			var rh := HBoxContainer.new(); rh.add_theme_constant_override("separation", 8); rh.add_child(Kit.chip("RECIPE", Kit.AMBER, 14)); add(rh)
			add(Kit.label(rec, small, Kit.TEXT, true))
			if lab.mode == "standard": add(Kit.label("You used the recipe: this level can earn two stars, not three.", small, Kit.AMBER, true))
		else:
			var rr := HBoxContainer.new(); rr.add_theme_constant_override("separation", 12); add(rr)
			var rb := Kit.btn("Show recipe", func(): lab._recipe_open = true; Progress.record_recipe(tid); build(), "amber", 18); rb.size_flags_vertical = Control.SIZE_SHRINK_CENTER; rr.add_child(rb)
			var rl := Kit.label("The recipe gives the numbers. Using it costs the third star.", small, Kit.TEXT_SOFT, true); rl.size_flags_horizontal = Control.SIZE_EXPAND_FILL; rl.size_flags_vertical = Control.SIZE_SHRINK_CENTER; rr.add_child(rl)
	if not Circuits.groups(lab.circuit).is_empty(): inspect_groups(small)   # a locked-wiring level: one card per cell type, always in view
	if not lab._brief_full and tid != "": return   # the star rule and the legend sit behind the expander with the rest of the brief
	if tid != "" and str(Progress.challenge(tid)["text"]) != "": add(Kit.label(Progress.star_rules_text(tid), small, Kit.TEXT_SOFT, true))
	var leg := HBoxContainer.new(); leg.add_theme_constant_override("separation", 8)
	leg.add_child(Kit.chip("EXCITATORY", Kit.exc(), 14)); leg.add_child(Kit.chip("INHIBITORY", Kit.inh(), 14)); leg.add_child(Kit.chip("SENSOR", Kit.SENSOR, 14)); leg.add_child(Kit.chip("MOTOR", Gfx.VIOLET, 14))
	add(leg)

## ---- locked wiring and cell types (0.6, the Atlas): what the inspector shows for the given circuit ----

## A locked group: read-only facts (it is engraved on the bench), the reason in words, its trace, and the card of its cell type.
func inspect_locked_pop(id: String, p: Dictionary, kd: Dictionary, small: int) -> void:
	var circuit := lab.circuit; var tele := lab.tele
	var pi := Circuits.pop_index(circuit, id)
	add(head(id, Kit.inh() if kd[id] == "I" else Kit.exc(), "%s  %s   given (locked)" % ["inhibitory" if kd[id] == "I" else "excitatory", str(p.get("model", ""))]))
	add(Kit.label("%d cell%s of %s. %s" % [Circuits.pop_n(p), "" if Circuits.pop_n(p) == 1 else "s", str(p.get("model", "")), Circuits.LOCK_POP], small, Kit.TEXT_SOFT, true))
	var row := HFlowContainer.new(); row.add_theme_constant_override("h_separation", 10); add(row)
	row.add_child(Kit.btn("Trace", func(): toggle_trace(id), "on" if tele.watched.has(Circuits.pop_first(circuit, pi)) else "panel", 18))
	var grp := Circuits.group_of_pop(circuit, id)
	if not grp.is_empty(): group_card(grp, small)

## A locked axon: its facts, the reason in words, and the card of the cell type it leaves (the only thing that changes it).
func inspect_locked_proj(i: int, pr: Dictionary, w_eff: float, small: int) -> void:
	var circuit := lab.circuit
	var pre := Circuits.proj_pop(pr.get("pre", ""))
	var n := (pr.get("edges", []) as Array).size()
	var unit := "pA"
	var pi := Circuits.pop_index(circuit, Circuits.proj_pop(pr.get("post", "")))
	if pi >= 0: unit = Catalog.unit_of(str(circuit["populations"][pi].get("model", "")))
	add(Kit.label("%d connection%s, delay %s ms, %s %s a spike. Engraved: part of the given wiring." % [n, "" if n == 1 else "s", str(snappedf(Circuits.proj_delay(pr), 0.1)), "each carries" if w_eff != 0.0 else "none carries", "%s%s %s" % ["+" if w_eff >= 0.0 else "-", str(snappedf(absf(w_eff), 0.1)), unit]], small, Kit.TEXT, true))
	add(Kit.label(Circuits.LOCK_PROJ, small, Kit.TEXT_SOFT, true))
	var grp := Circuits.group_of_pop(circuit, pre)
	if not grp.is_empty(): group_card(grp, small)

## One card for every cell type of the circuit (a locked-wiring level's free parameters), under the brief.
func inspect_groups(small: int) -> void:
	add(Kit.hsep())
	add(Kit.label("CELL TYPES: the wiring is given, these are not. A control that is not free is fixed by the level.", small, Kit.TEXT_SOFT, true))
	for g in Circuits.groups(lab.circuit): group_card(g, small)

## The card of one cell type: its cell groups, and its sign and scale. A free parameter has a control (a sign toggle, a scale stepper); a fixed one is shown as text.
## Every change is one undo step (lab._on_structure) and is saved with the circuit (the autosave and the solution slots keep the whole file).
func group_card(g: Dictionary, small: int) -> void:
	var circuit := lab.circuit; var gid := str(g.get("id", ""))
	var neg := float(g.get("sign", 1)) < 0.0
	var card := Kit.card(Circuits.group_label(g), Kit.PANEL_HI, Kit.inh() if neg else Kit.exc())
	card[0].set_meta("sp_group", gid)
	var body: VBoxContainer = card[1]
	body.add_child(Kit.label("cell groups: %s" % ", ".join(PackedStringArray((g.get("pops", []) as Array).map(func(x): return str(x)))), small, Kit.TEXT_SOFT, true))
	var srow := HFlowContainer.new(); srow.add_theme_constant_override("h_separation", 10); body.add_child(srow)
	srow.add_child(Kit.label("sign", small, Kit.TEXT_SOFT))
	if Circuits.group_free(g, "sign"):
		srow.add_child(Kit.ident(Kit.stepper([["1", "excitatory"], ["-1", "inhibitory"]], "-1" if neg else "1", func(v): _group_edit(Circuits.group_set_sign(circuit, gid, int(v))), 230.0 if not Layout.phone else 180.0, 18, 40.0), "StepSign_" + gid))
	else:
		srow.add_child(Kit.label("%s (fixed by the level)" % ("inhibitory" if neg else "excitatory"), small, Kit.TEXT))
	var crow := HFlowContainer.new(); crow.add_theme_constant_override("h_separation", 10); body.add_child(crow)
	crow.add_child(Kit.label("state" if Circuits.group_off(g) and Circuits.group_free(g, "scale") else "scale", small, Kit.TEXT_SOFT))
	var sc := float(g.get("scale", 1.0))
	if Circuits.group_free(g, "scale") and Circuits.group_off(g):
		# a cell type that can be switched off: two states, active (scale 1) or silenced (scale 0); the stepper of 0.05 steps is not offered
		crow.add_child(Kit.ident(Kit.stepper([["1", "active"], ["0", "silenced"]], "0" if Circuits.group_silenced(g) else "1", func(v): _group_edit(Circuits.group_set_active(circuit, gid, str(v) == "1")), 230.0 if not Layout.phone else 180.0, 18, 40.0), "StepActive_" + gid))
		if Circuits.group_silenced(g): body.add_child(Kit.label("Silenced: every connection out of %s carries nothing." % gid, small, Kit.TEXT_SOFT, true))
	elif Circuits.group_free(g, "scale"):
		var r := Circuits.group_scale_range(g)
		crow.add_child(Kit.ident(Kit.btn("-", func(): _group_edit(Circuits.group_step_scale(circuit, gid, -1)), "panel", 18, Vector2(44, 40)), "BtnScaleDown_" + gid))
		var vl := Kit.label("%.2f" % sc, 20, Kit.TEXT); vl.custom_minimum_size.x = 60; vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; Kit.ident(vl, "ScaleValue_" + gid); crow.add_child(vl)
		crow.add_child(Kit.ident(Kit.btn("+", func(): _group_edit(Circuits.group_step_scale(circuit, gid, 1)), "panel", 18, Vector2(44, 40)), "BtnScaleUp_" + gid))
		crow.add_child(Kit.label("allowed %.2f to %.2f" % [r.x, r.y], small, Kit.TEXT_SOFT))
		if not Circuits.group_in_range(g): body.add_child(Kit.label("This scale is outside the allowed range: CHECK will refuse the circuit. Use - or + to bring it back.", small, Kit.RED, true))
	else:
		crow.add_child(Kit.label("%.2f (fixed by the level)" % sc, small, Kit.TEXT))
	add(card[0])

func _group_edit(why: String) -> void:
	if why != "": lab.editor.note(why, 5.0); return
	lab._on_structure(); build()

## A slider row. `quad` makes the slider square-law (value = hi * s^2 for s in 0..1): fine steps near zero for weights, which run from fractions of a pA (a burster
## onto an integrate-and-fire cell) to thousands (a relay), with the same slider.
func val_row(name: String, lo: float, hi: float, step: float, val: float, unit: String, cb: Callable, dec := -1, quad := false) -> Control:
	var h := HBoxContainer.new(); h.add_theme_constant_override("separation", 10); h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := Kit.label(name, 17, Kit.TEXT_SOFT); nm.custom_minimum_size.x = 100; h.add_child(nm)
	var s := HSlider.new(); s.size_flags_horizontal = Control.SIZE_EXPAND_FILL; s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if quad: s.min_value = 0.0; s.max_value = 1.0; s.step = QUAD_STEP; s.value = sqrt(clampf(val, 0.0, hi) / maxf(hi, 1e-9))
	else: s.min_value = lo; s.max_value = hi; s.step = step; s.value = val
	s.custom_minimum_size = Vector2(120, maxf(30.0, Layout.tap())); s.focus_mode = Kit.focus_mode(); h.add_child(s)
	# The value is also a field: click it and type a number (Enter or leaving the field applies it, clamped to the slider's range); the slider follows.
	var vl := LineEdit.new(); vl.text = numd(val, dec if dec >= 0 or not quad else quad_dec(val)); vl.custom_minimum_size.x = 78; vl.alignment = HORIZONTAL_ALIGNMENT_RIGHT; vl.select_all_on_focus = true
	vl.add_theme_font_size_override("font_size", 17); vl.tooltip_text = "Click to type a value"; vl.focus_mode = Control.FOCUS_CLICK; vl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var flat := StyleBoxFlat.new(); flat.bg_color = Color(Kit.PANEL_HI, 0.0); flat.border_color = Kit.LINE; flat.set_border_width_all(1); flat.border_width_top = 0; flat.border_width_left = 0; flat.border_width_right = 0; flat.set_content_margin_all(2)
	var focus := flat.duplicate() as StyleBoxFlat; focus.bg_color = Color("#FBF7EE"); focus.border_color = Kit.AMBER; focus.set_border_width_all(1)
	vl.add_theme_stylebox_override("normal", flat); vl.add_theme_stylebox_override("focus", focus); vl.add_theme_color_override("font_color", Kit.TEXT); vl.add_theme_color_override("caret_color", Kit.TEXT)
	h.add_child(vl)
	var ul := Kit.label(unit, 17, Kit.TEXT); ul.custom_minimum_size.x = 30 if unit != "" else 0; h.add_child(ul)
	var apply_typed := func(_t = ""):
		var v := clampf(vl.text.strip_edges().to_float(), lo if not quad else 0.0, hi)
		if not vl.text.strip_edges().is_valid_float(): v = hi * s.value * s.value if quad else s.value   # not a number: back to the slider's value
		if quad: s.set_value_no_signal(sqrt(clampf(v, 0.0, hi) / maxf(hi, 1e-9)))
		else: s.set_value_no_signal(v)
		vl.text = numd(v, dec if dec >= 0 else (-1 if not quad else quad_dec(v))); vl.release_focus(); cb.call(v)
	vl.text_submitted.connect(apply_typed)
	vl.focus_exited.connect(func(): if vl.text.strip_edges().is_valid_float() and absf(vl.text.to_float() - (hi * s.value * s.value if quad else s.value)) > 1e-6 * maxf(1.0, hi): apply_typed.call())
	s.value_changed.connect(func(x):
		var v: float = hi * x * x if quad else x
		if not vl.has_focus(): vl.text = numd(v, dec if dec >= 0 else (-1 if not quad else quad_dec(v)))
		cb.call(v))
	return h

## Decimals for a square-law weight: whole numbers above 100, one decimal above 1, else three.
static func quad_dec(v: float) -> int: return 0 if v >= 100.0 else (1 if v >= 1.0 else 3)
static func numd(x: float, dec: int) -> String: return num(x) if dec < 0 else String.num(x, dec)
static func num(x: float) -> String: return "%d" % int(roundf(x)) if absf(x) >= 100.0 or is_equal_approx(x, roundf(x)) else "%.1f" % x

func inspect_pop(id: String, small: int) -> void:
	var circuit := lab.circuit; var tele := lab.tele
	var pi := Circuits.pop_index(circuit, id); if pi < 0: inspect_brief(small); return
	var p: Dictionary = circuit["populations"][pi]; var kd := Circuits.kinds(circuit)
	var kcol := Kit.inh() if kd[id] == "I" else Kit.exc()
	if Circuits.is_locked(p): inspect_locked_pop(id, p, kd, small); return
	add(head(id, kcol, "%s  %s" % ["inhibitory" if kd[id] == "I" else "excitatory", str(p.get("model", ""))]))
	var grp := Circuits.group_of_pop(circuit, id)
	if not grp.is_empty(): group_card(grp, small)   # the cell type this group belongs to: its sign and scale act on every axon out of it
	var row := HFlowContainer.new(); row.add_theme_constant_override("h_separation", 10); row.add_theme_constant_override("v_separation", 6); add(row)
	var model := str(p.get("model", "")); var presets: Array = Circuits.presets_of(model)
	var models := Circuits.model_options(model)
	row.add_child(Kit.stepper(models, model, func(m): Circuits.set_model(circuit, id, str(m), 0); lab._on_structure(); build(), 230.0 if not Layout.phone else 170.0, 18, 40.0))
	var po := []
	for i in presets.size(): po.append([str(i), presets[i][0]])
	var cur := Circuits.preset_of(p)
	if not po.is_empty(): row.add_child(Kit.stepper(po, str(maxi(cur, 0)), func(i): Circuits.set_model(circuit, id, model, int(i)); lab._on_structure(); build(), 190.0 if not Layout.phone else 140.0, 18, 40.0))
	row.add_child(Kit.btn("Trace", func(): toggle_trace(id), "on" if tele.watched.has(Circuits.pop_first(circuit, pi)) else "panel", 18))
	row.add_child(Kit.btn("E / I", func(): flip_kind(id), "panel", 18))
	row.add_child(Kit.btn("Delete", func(): lab.editor.delete_selected(), "danger", 18))
	var nrow := HBoxContainer.new(); nrow.add_theme_constant_override("separation", 10)
	nrow.add_child(Kit.label("neurons in group", small, Kit.TEXT_SOFT)); nrow.add_child(Kit.stepper(Circuits.group_size_steps(Circuits.pop_n(p)), str(Circuits.pop_n(p)), func(v): Circuits.set_n(circuit, id, int(v)); lab._on_structure(), 70.0, 18, 40.0))
	add(nrow)
	var info: String = str(presets[cur][2]) if cur >= 0 else "Custom parameters."
	add(Kit.label(info + "  Drag the disc to move it, drag from its rim to connect.", small, Kit.TEXT_SOFT, true))
	add(Kit.ident(Kit.btn("Hide advanced" if lab._adv_open else "Advanced", func(): lab._adv_open = not lab._adv_open; build(), "ghost", 18), "BtnAdvanced"))
	var adv := Circuits.advanced_of(model)
	if lab._adv_open and not adv.is_empty():
		var prm: Dictionary = p.get("params", {})
		for a in adv:
			var key: String = a[0]
			add(val_row(str(a[1]), float(a[2]), float(a[3]), float(a[4]), float(prm.get(key, a[5])), str(a[6]), func(x): var pp: Dictionary = p.get("params", {}); pp[key] = x; p["params"] = pp; lab._on_structure()))
		add(Kit.btn("Reset parameters", func(): Circuits.set_model(circuit, id, model, 0); lab._on_structure(); build(), "panel", 18))
	if lab._adv_open: inspect_modulation(id, model, small)

## Advanced: how this group responds to the circuit-wide NE / ACh / DA levels. Cells with ach / ne inputs (the NESTML cells) follow those levels by themselves
## (the engine's per-model default); a row here overrides it for one parameter: value = value + gain * level, or value * (1 + scale * level).
func inspect_modulation(id: String, model: String, small: int) -> void:
	var circuit := lab.circuit
	add(Kit.hsep())
	add(Kit.label("Responds to neuromodulators", small, Kit.TEXT, true))
	var params := Circuits.mod_params(model)
	if params.is_empty(): add(Kit.label("This model has no parameter a modulator can act on.", small, Kit.TEXT_SOFT, true)); return
	var rows := Circuits.mod_rows(circuit, id)
	add(Kit.label(("Rows below replace the default response of this group." if not rows.is_empty() else "No rows: cells with ach / ne inputs follow the ACh and NE levels by themselves; others ignore them. Add a row to make any parameter respond."), small, Kit.TEXT_SOFT, true))
	for ri in rows:
		var row: Dictionary = (circuit["modulation"] as Array)[ri]
		var scale := row.has("scale_per_unit"); var val := float(row.get("scale_per_unit" if scale else "gain", 1.0))
		var h := HFlowContainer.new(); h.add_theme_constant_override("h_separation", 8); h.add_theme_constant_override("v_separation", 4); add(h)
		h.add_child(Kit.stepper(Circuits.MODULATORS.map(func(m): return [m, m]), str(row.get("modulator", "NE")), func(m): row["modulator"] = str(m); lab._on_structure(), 90.0, 18, 40.0))
		var po := params.map(func(q): return [q, q])
		h.add_child(Kit.stepper(po, str(row.get("param", params[0])), func(q): row["param"] = str(q); lab._on_structure(), 150.0, 18, 40.0))
		h.add_child(Kit.stepper([["gain", "add"], ["scale", "scale"]], "scale" if scale else "gain", func(m):
			var v: float = float(row.get("scale_per_unit", row.get("gain", 1.0))); row.erase("gain"); row.erase("scale_per_unit")
			row["scale_per_unit" if str(m) == "scale" else "gain"] = v; lab._on_structure(); build(), 100.0, 18, 40.0))
		h.add_child(Kit.btn("X", func(): Circuits.remove_mod_row(circuit, ri); lab._on_structure(); build(), "danger", 18))
		var small_p := str(row.get("param", "")) in ["ach", "ne"]
		add(val_row("per unit", -2.0 if small_p else -500.0, 2.0 if small_p else 500.0, 0.05 if small_p else 5.0, val, "", func(x): row["scale_per_unit" if row.has("scale_per_unit") else "gain"] = x; lab._on_structure(), 2 if small_p else -1))
	add(Kit.btn("Add row", func(): Circuits.add_mod_row(circuit, id, "NE", str(params[0]), 1.0 if str(params[0]) in ["ach", "ne"] else 50.0); lab._on_structure(); build(), "panel", 18))

func toggle_trace(id: String) -> void:
	var circuit := lab.circuit; var tele := lab.tele
	var pi := Circuits.pop_index(circuit, id); var g := Circuits.pop_first(circuit, pi); var w: Array = tele.watched.duplicate()
	if w.has(g): w.erase(g)
	else:
		w.append(g)
		if w.size() > 4: w.pop_front()
	if tele.sim != null: tele.set_watched(w)
	if lab._is_dx() and w.has(g): lab._dx_probe("scope", id)   # opening a scope on a group of the patient is a probe
	build()

func flip_kind(id: String) -> void:
	var circuit := lab.circuit
	var kd := Circuits.kinds(circuit); var want := "E" if kd[id] == "I" else "I"
	for pr in circuit["projections"]:
		if Circuits.proj_pop(pr.get("pre", "")) == id:
			Circuits.set_proj_weight(pr, -Circuits.proj_weight(pr))
	var ed: Dictionary = circuit["meta"].get("editor", {}); var ei: Dictionary = ed.get("ei", {}); ei[id] = want; ed["ei"] = ei; circuit["meta"]["editor"] = ed
	lab._on_structure(); build()

func inspect_proj(i: int, small: int) -> void:
	var circuit := lab.circuit
	if i >= circuit["projections"].size(): inspect_brief(small); return
	var pr: Dictionary = circuit["projections"][i]; var w := Circuits.proj_weight_eff(circuit, pr)
	var pre := Circuits.proj_pop(pr.get("pre", "")); var post := Circuits.proj_pop(pr.get("post", ""))
	add(head("%s > %s" % [pre, post], Kit.inh() if w < 0.0 else Kit.exc(), "%s synapse   %s" % ["inhibitory" if w < 0.0 else "excitatory", str(pr.get("rule", "explicit edges"))]))
	if Circuits.is_locked(pr): inspect_locked_proj(i, pr, w, small); return
	w = Circuits.proj_weight(pr)
	var pi := Circuits.pop_index(circuit, post); var wmax: float = Circuits.proj_wmax_for(str(circuit["populations"][pi].get("model", "")), lab.task_id) if pi >= 0 else 400.0
	var unit := Catalog.unit_of(str(circuit["populations"][pi].get("model", ""))) if pi >= 0 else "pA"
	var r1 := HFlowContainer.new(); r1.add_theme_constant_override("h_separation", 10); add(r1)
	var cur_syn := Circuits.proj_model(pr)
	var rate_syn := ["rate_connection_instantaneous", "rate_connection_delayed", "diffusion_connection"].has(cur_syn)
	if cur_syn != "static_synapse" and not rate_syn and lab.task_id != "h_learn": r1.add_child(Kit.stepper([["static_synapse", "static"], [cur_syn, cur_syn.replace("_synapse", "")]], cur_syn, func(m): var s: Dictionary = pr.get("synapse", {}); s["synapse_model"] = str(m); pr["synapse"] = s; lab._on_structure(), 190.0 if not Layout.phone else 150.0, 18, 40.0))
	r1.add_child(Kit.btn("E / I", func(): Circuits.set_proj_weight(pr, -Circuits.proj_weight(pr)); lab._on_structure(); build(), "panel", 18))
	r1.add_child(Kit.btn("Delete", func(): lab.editor.delete_selected(), "danger", 18))
	if Campaign.chapter_of(lab.task_id) == "aplysia": _aplysia_synapse(pr, i, small)
	if Campaign.chapter_of(lab.task_id) == "fly_mb": _mb_synapse(pr, i, small)
	if lab.task_id == "h_learn": _plastic_synapse(pr, small)
	var pa_i := Circuits.pop_index(circuit, pre)
	var na := Circuits.pop_n(circuit["populations"][pa_i]) if pa_i >= 0 else 1; var nb := Circuits.pop_n(circuit["populations"][pi]) if pi >= 0 else 1
	if na > 1 and nb > 1:   # N4: segment wiring, neuron k to neuron k + offset, instead of every pair
		var wr := HFlowContainer.new(); wr.add_theme_constant_override("h_separation", 10); wr.add_theme_constant_override("v_separation", 4); add(wr)
		var wiring := Circuits.proj_wiring(pr); var off := Circuits.segment_offset(pr)
		var ch_id := Campaign.chapter_of(lab.task_id); var ring := ch_id == "fly_compass"; var mb := ch_id == "fly_mb"
		var modes := [["all", "every pair"], ["segment", "neuron k to k"]]
		if mb or ch_id == "rates" or ch_id == "memory": modes.append(["random", "random few inputs"])
		wr.add_child(Kit.label("wiring", small, Kit.TEXT_SOFT))
		wr.add_child(Kit.stepper(modes, wiring, func(m): Circuits.set_wiring(circuit, pr, str(m), 0, ring); lab._on_structure(); build(), 330.0 if not Layout.phone else 240.0, 18, 40.0))
		if wiring == "segment":
			wr.add_child(Kit.label("shift", small, Kit.TEXT_SOFT))
			wr.add_child(Kit.stepper([[-2, "-2"], [-1, "-1"], [0, "0"], [1, "+1"], [2, "+2"]], str(off), func(o): Circuits.set_wiring(circuit, pr, "segment", int(o), ring); lab._on_structure(); build(), 64.0, 18, 40.0))
		if wiring == "random": add(val_row("inputs per cell", 1.0, 100.0 if Campaign.chapter_of(lab.task_id) == "rates" else 12.0, 1.0, float(pr.get("indegree", 4)), "", func(x): pr["indegree"] = int(x); lab._on_structure(), 0))
		if wiring == "random": add(Kit.label("Random sparse wiring: each cell of %s listens to just this many cells of %s, picked at random (a fresh draw for every circuit seed)." % [post, pre], small, Kit.TEXT_SOFT, true))
		else: add(Kit.label("Segment wiring connects neuron k of %s to neuron k%s of %s, one synapse per segment%s, instead of all %d x %d pairs." % [pre, ("" if off == 0 else " %+d" % off), post, ("; the ends of a ring are joined" if ring else ""), na, nb], small, Kit.TEXT_SOFT, true))
	add(val_row("weight", 0.0, wmax, wmax / 200.0, absf(w), unit, func(x): Circuits.set_proj_weight(pr, x * (-1.0 if Circuits.proj_weight(pr) < 0.0 else 1.0)); lab._on_structure(), -1, true))
	if cur_syn == "diffusion_connection":   # v0.6 mean-field projection: weight is J (mV), K the number of such inputs per cell
		add(val_row("K inputs", 1.0, 200.0, 1.0, float(pr.get("synapse", {}).get("K", 1.0)), "per cell", func(x): var sy: Dictionary = pr.get("synapse", {}); sy["K"] = maxf(1.0, snappedf(x, 1.0)); pr["synapse"] = sy; lab._on_structure(), 0))
		add(Kit.label("A mean-field projection: J (the weight) is the size of one input in mV of the spiking network it stands for (negative for inhibition), K how many such inputs each cell gets. The mean input grows with J K r, its variance with J squared K r.", small, Kit.TEXT_SOFT, true))
	if not rate_syn: add(val_row("delay", 0.0, Circuits.DELAY_MAX, 0.1, Circuits.proj_delay(pr), "ms", func(x): Circuits.set_proj_delay(pr, maxf(0.1, snappedf(x, 0.1))); lab._on_structure(), -1, true))
	if cur_syn != "gap_junction" and not rate_syn:
		add(val_row("spread", 0.0, 100.0, 1.0, float(pr.get("weight_cv", 0.0)) * 100.0, "%", func(x): Circuits.set_proj_spread(pr, snappedf(x, 1.0) * 0.01); lab._on_structure(), 0))
		add(Kit.label("Spread: each synapse of this axon gets its own weight, varying by this much around the value above (fixed by the circuit seed; “Test x5” draws it again for every seed). A circuit that only works with identical weights fails here.", small, Kit.TEXT_SOFT, true))

## h_learn (v0.6): a connection among the pattern's cells can be plastic (NEST stdp_synapse: strengthened when its presynaptic cell fires just before its postsynaptic one, weakened in the other order).
## Excitatory only: an inhibitory connection stays static.
func _plastic_synapse(pr: Dictionary, small: int) -> void:
	var cur := Circuits.proj_model(pr); var w := Circuits.proj_weight(pr)
	if w <= 0.0 and cur != "stdp_synapse": add(Kit.label("Only excitatory connections can be plastic.", small, Kit.TEXT_SOFT, true)); return
	add(Kit.label("Synapse type: a static synapse keeps its weight; a plastic one learns: it strengthens when its presynaptic cell fires just before its postsynaptic one and weakens in the other order.", small, Kit.TEXT_SOFT, true))
	add(Kit.stepper([["static_synapse", "static"], ["stdp_synapse", "plastic (STDP)"]], cur, func(m):
		var sy: Dictionary = pr.get("synapse", {})
		if str(m) == "stdp_synapse":
			sy["synapse_model"] = "stdp_synapse"; sy["lambda"] = 0.0015; sy["alpha"] = 0.5; sy["tau_plus"] = 20.0; sy["Wmax"] = maxf(absf(w) * 10.0, 100.0)
		else:
			for k in ["lambda", "alpha", "tau_plus", "Wmax"]: sy.erase(k)
			sy["synapse_model"] = "static_synapse"
		pr["synapse"] = sy; lab._on_structure(); build(), 280.0 if not Layout.phone else 200.0, 18, 40.0))
	if cur == "stdp_synapse":
		var sy: Dictionary = pr.get("synapse", {})
		add(val_row("learning rate", 0.0001, 0.03, 0.0001, float(sy.get("lambda", 0.0015)), "", func(x): sy["lambda"] = x; pr["synapse"] = sy; lab._on_structure(), 4))
		add(val_row("weakening", 0.1, 3.0, 0.05, float(sy.get("alpha", 0.5)), "x", func(x): sy["alpha"] = x; pr["synapse"] = sy; lab._on_structure(), 2))
		add(val_row("ceiling", 10.0, 3000.0, 10.0, float(sy.get("Wmax", 800.0)), "pA", func(x): sy["Wmax"] = x; pr["synapse"] = sy; lab._on_structure(), 0))
		add(Kit.label("Learning rate: how much one spike pair changes the weight. Weakening: how much stronger a late pairing weakens than an early one strengthens. Ceiling: the weight a connection can never exceed.", small, Kit.TEXT_SOFT, true))

## Aplysia levels (v0.5): a connection can be a depressing synapse (NEST tsodyks2: it runs out of transmitter with use and recovers slowly) and can be strengthened by a released
## modulator (a row of the circuit's modulation table that acts on this connection: its release probability U for a depressing synapse, its weight for a static one).
func _aplysia_synapse(pr: Dictionary, i: int, small: int) -> void:
	var circuit := lab.circuit
	var cur := Circuits.proj_model(pr)
	add(Kit.label("Synapse type: a static synapse answers every spike alike; a depressing one loses strength with use and recovers.", small, Kit.TEXT_SOFT, true))
	add(Kit.stepper([["static_synapse", "static"], ["tsodyks2_synapse", "depressing"]], cur, func(m):
		var sy: Dictionary = pr.get("synapse", {})
		if str(m) == "tsodyks2_synapse":
			var u0 := 0.2 if lab.task_id == "a_depress" else 0.1   # the reference values: a_depress 0.2, aplysia_gill 0.1
			sy["synapse_model"] = "tsodyks2_synapse"; sy["U"] = u0; sy["u"] = u0; sy["x"] = 1.0; sy["tau_rec"] = 1000.0; sy["tau_fac"] = 0.0
		else:
			for k in ["U", "u", "x", "tau_rec", "tau_fac"]: sy.erase(k)
			sy["synapse_model"] = "static_synapse"
		pr["synapse"] = sy
		# a modulation row aimed at the old parameter no longer fits: drop it, the player adds it again
		var rows: Array = circuit.get("modulation", [])
		for r in range(rows.size() - 1, -1, -1):
			if rows[r].has("projection") and int(rows[r]["projection"]) == i: Circuits.remove_mod_row(circuit, r)
		lab._on_structure(); build(), 260.0 if not Layout.phone else 200.0, 18, 40.0))
	if cur == "tsodyks2_synapse":
		var sy: Dictionary = pr.get("synapse", {})
		add(val_row("U", 0.01, 1.0, 0.01, float(sy.get("U", 0.2)), "", func(x): sy["U"] = x; sy["u"] = x; pr["synapse"] = sy; lab._on_structure(), 2))
		add(val_row("recovery", 50.0, 5000.0, 50.0, float(sy.get("tau_rec", 1000.0)), "ms", func(x): sy["tau_rec"] = x; pr["synapse"] = sy; lab._on_structure(), 0))
		add(Kit.label("U: the share of the available transmitter released by each spike (larger = deeper depression). Recovery: how long the synapse takes to refill.", small, Kit.TEXT_SOFT, true))
	var rows2: Array = circuit.get("modulation", []); var row_i := -1
	for r in rows2.size():
		if rows2[r].has("projection") and int(rows2[r]["projection"]) == i: row_i = r
	var param := "U" if cur == "tsodyks2_synapse" else "weight"
	if row_i < 0:
		add(Kit.btn("Strengthen with serotonin (NE channel)", func():
			var rr: Array = circuit.get("modulation", [])
			var row := {"modulator": "NE", "projection": i, "param": param}
			if param == "U": row["gain"] = 3.0; row["min"] = 0.0; row["max"] = 1.0   # a gain of about 1 to 5 sensitises the reflex; 1.0 was at the weak end and U 0.2 below it too deep a depression
			else: row["scale_per_unit"] = 4.0
			rr.append(row); circuit["modulation"] = rr; lab._on_structure(); build(), "panel", 18))
	else:
		var row: Dictionary = rows2[row_i]; var key := "scale_per_unit" if row.has("scale_per_unit") else "gain"
		add(Kit.label("The released modulator changes this synapse's %s." % str(row.get("param", param)), small, Kit.TEXT_SOFT, true))
		add(val_row("per unit", 0.0, 8.0, 0.1, float(row.get(key, 1.0)), "", func(x): row[key] = x; lab._on_structure(), 1))
		add(Kit.btn("Remove modulation", func(): Circuits.remove_mod_row(circuit, row_i); lab._on_structure(); build(), "panel", 18))

## Fly mushroom body levels (v0.5): a connection can be a dopamine-gated depressing synapse (NEST stdp_dopamine_synapse used as depression: when its input was active and the dopamine source fires, it loses strength).
## The source is a population of the circuit; the learning amplitude sets how much each pairing takes away (A_plus = -A, A_minus = +A).
func _mb_synapse(pr: Dictionary, i: int, small: int) -> void:
	var circuit := lab.circuit
	var cur := str((pr.get("synapse", {}) as Dictionary).get("synapse_model", "static_synapse"))
	var gated := cur == "stdp_dopamine_synapse"
	add(Kit.label("Synapse type: a static synapse never changes; a dopamine-gated one weakens when its input was active and its dopamine source fires.", small, Kit.TEXT_SOFT, true))
	add(Kit.stepper([["static_synapse", "static"], ["stdp_dopamine_synapse", "dopamine-gated"]], cur, func(m):
		var sy: Dictionary = pr.get("synapse", {}); var w := absf(Circuits.proj_weight(pr))
		if str(m) == "stdp_dopamine_synapse":
			var src := ""
			for pp in circuit.get("populations", []):
				var id := str(pp.get("id", ""))
				if id != Circuits.proj_pop(pr.get("pre", "")) and id != Circuits.proj_pop(pr.get("post", "")) and src == "": src = id
			pr["synapse"] = {"synapse_model": "stdp_dopamine_synapse", "weight": maxf(w, 1.0), "delay": Circuits.proj_delay(pr), "A_plus": -1.0, "A_minus": 1.0, "Wmin": 0.0, "Wmax": maxf(w, 1.0) * 3.0, "tau_c": 30.0, "tau_n": 200.0, "b": 0.0, "tau_plus": 20.0}
			pr["dopamine_source"] = src
		else:
			pr["synapse"] = {"synapse_model": "static_synapse", "weight": w, "delay": Circuits.proj_delay(pr)}; pr.erase("dopamine_source")
		lab._on_structure(); build(), 330.0 if not Layout.phone else 240.0, 18, 40.0))
	if gated:
		var sy: Dictionary = pr.get("synapse", {})
		var opts := []
		for pp in circuit.get("populations", []): opts.append([str(pp.get("id", "")), str(pp.get("id", ""))])
		add(Kit.label("Dopamine source: the cells whose spikes release dopamine onto this synapse.", small, Kit.TEXT_SOFT, true))
		add(Kit.stepper(opts, str(pr.get("dopamine_source", "")), func(m): pr["dopamine_source"] = str(m); lab._on_structure(); build(), 420.0 if not Layout.phone else 300.0, 18, 40.0))
		add(val_row("learning", 0.0, 3000.0, 1.0, absf(float(sy.get("A_minus", 1.0))), "", func(x): sy["A_minus"] = x; sy["A_plus"] = -x; pr["synapse"] = sy; lab._on_structure(), 1))
		add(val_row("trace", 5.0, 500.0, 1.0, float(sy.get("tau_c", 30.0)), "ms", func(x): sy["tau_c"] = x; pr["synapse"] = sy; lab._on_structure(), 0))
		add(val_row("max weight", 1.0, 10000.0, 10.0, float(sy.get("Wmax", 100.0)), "", func(x): sy["Wmax"] = x; pr["synapse"] = sy; lab._on_structure(), 0))
		add(Kit.label("Learning: how much one pairing takes away (the sign is set so that the synapse depresses). Trace: how long a synapse stays eligible after its input fired. Max weight: the largest strength it can have.", small, Kit.TEXT_SOFT, true))

## One link of a sensor or a motor: the sensor (or cell) it leaves, the cell (or motor) it reaches, and the way to take it away.
func inspect_link(sel: Dictionary, small: int) -> void:
	var is_in := str(sel["t"]) == "ilink"; var name := str(sel.get("name", "")); var pop := str(sel.get("pop", ""))
	var names: Array = sel.get("names", [name])
	var from_to := ("%s > %s" % [name if names.size() <= 1 else "%s (%d)" % [name, names.size()], pop]) if is_in else ("%s > %s" % [pop, name])
	add(head(from_to, Kit.SENSOR if is_in else Gfx.VIOLET, "link from a sensor to a cell" if is_in else "link from a cell to a motor"))
	if Circuits.has_locks(lab.circuit):
		add(Kit.label(Circuits.LOCK_IO, small, Kit.TEXT_SOFT, true)); return
	add(Kit.label(("This link carries the signal of %s into %s. Disconnect it to cut the signal." % [name, pop]) if is_in else ("This link carries the spikes of %s to %s. Disconnect it to cut the output." % [pop, name]), small, Kit.TEXT_SOFT, true))
	add(Kit.ident(Kit.btn("Disconnect", func(): lab.editor.delete_selected(), "danger", 18), "BtnDisconnect"))

func inspect_channel(key: String, name: String, small: int) -> void:
	var circuit := lab.circuit; var tele := lab.tele
	var ch := {}
	for c in circuit.get(key, []):
		if str(c.get("name", "")) == name: ch = c
	if ch.is_empty(): inspect_brief(small); return
	var is_in := key == "inputs"; var driven := false
	if tele.task != null and is_in: driven = (tele.task.sensor_channels() as PackedStringArray).has(name)
	add(head(name, Kit.SENSOR if is_in else Gfx.VIOLET, ("sensor, driven by the task" if driven else "input device") + "  " + str(ch.get("kind", "")) if is_in else "motor output: mean rate of the connected neurons"))
	var tg: Array = ch.get("targets" if is_in else "neurons", [])
	var names := []
	for x in tg: names.append(Circuits.proj_pop(x))
	add(Kit.label(("Connected to: " + ", ".join(names)) if not names.is_empty() else ("Not connected yet: drag from the card's right edge onto a neuron." if is_in else "Not connected yet: drag from a neuron's rim onto this card."), small, Kit.TEXT_SOFT, true))
	var fam := Circuits.channel_family(circuit, key, name)
	if not fam.is_empty():   # N4: one drag or one button wires a whole group to the family
		var fnames: Array = fam["names"]
		add(Kit.label("%s0 to %s%d are a numbered family of %d. A group of %d neurons wired to any one of them connects neuron k to %s k." % [fam["stem"], fam["stem"], fnames.size() - 1, fnames.size(), fnames.size(), "sensor" if is_in else "channel"], small, Kit.TEXT_SOFT, true))
		var fr := HFlowContainer.new(); fr.add_theme_constant_override("h_separation", 8); fr.add_theme_constant_override("v_separation", 6); add(fr)
		for pp in circuit.get("populations", []):
			if Circuits.pop_n(pp) == fnames.size():
				var pid := str(pp.get("id", ""))
				fr.add_child(Kit.ident(Kit.btn("Wire %s (%d) to all" % [pid, fnames.size()] if not is_in else "Wire all to %s" % pid, func(): Circuits.wire_family(circuit, key, name, pid); lab._on_structure(); build(), "panel", 18), "BtnWireAll"))
	if is_in:
		var kind := str(ch.get("kind", "dc")); var unit := "pA" if kind == "dc" else "Hz"
		if kind == "rate_drive": add(Kit.label("A rate drive: the level the task sets is written to the drive of the rate units it reaches (times the weight below).", small, Kit.TEXT_SOFT, true))
		elif kind == "tuned_poisson": add(Kit.label("A tuned input: the task sets a stimulus angle, and each cell it reaches fires at a rate that depends on how far its preferred angle is from the stimulus.", small, Kit.TEXT_SOFT, true))
		else:
			add(Kit.stepper([["poisson", "Poisson spikes"], ["dc", "DC current"]], kind, func(k):
				ch["kind"] = str(k); var tm0 := "iaf_psc_alpha"
				if not tg.is_empty():
					var tp0 := Circuits.pop_index(circuit, Circuits.proj_pop(tg[0]))
					if tp0 >= 0: tm0 = str(circuit["populations"][tp0].get("model", tm0))
				ch["weight"] = Circuits.input_weight(tm0, str(k)); lab._on_structure(); build(), 250.0 if not Layout.phone else 200.0, 18, 40.0))
		var wunit := "pA"; var wmax := Circuits.input_wmax_for("", kind, lab.task_id) if kind == "dc" else maxf(1500.0, Circuits.input_wmax_for("", kind, lab.task_id))
		if kind == "rate_drive": wunit = ""; wmax = 5.0   # a dc input is a current: pA of drive per unit of value, whatever the cell
		if not tg.is_empty() and kind != "dc" and kind != "rate_drive":
			var tpi := Circuits.pop_index(circuit, Circuits.proj_pop(tg[0]))
			if tpi >= 0:
				var tm := str(circuit["populations"][tpi].get("model", ""))
				wunit = Catalog.unit_of(tm); wmax = Circuits.input_wmax_for(tm, kind, lab.task_id)
		add(val_row("weight", 0.0, wmax, wmax / 300.0, float(ch.get("weight", 1.0)), wunit + ("/unit" if kind == "dc" else ""), func(x): ch["weight"] = x; lab._on_structure(), -1, true))
		if not driven: add(val_row("rate" if kind != "dc" else "value", 0.0, 1000.0 if kind == "dc" else 400.0, 1.0, float(ch.get("value", 0.0)), unit, func(x): ch["value"] = x; lab._on_structure()))
		if not driven: add(Kit.btn("Remove input", func(): lab.editor.delete_selected(), "danger", 18))
	if not is_in: inspect_output_kind(ch, small)
	add(Kit.btn("Disconnect all", func(): ch["targets" if is_in else "neurons"] = []; lab._on_structure(); build(), "panel", 18))

## An output is a rate readout (the task reads the mean firing rate of its neurons) or a modulator release: each spike adds `gain` to the NE / ACh / DA pool,
## which decays with `tau` (docs/CIRCUIT-FORMAT.md). The heart tasks read ACh (vagal) and NE (sympathetic) that way.
func inspect_output_kind(ch: Dictionary, small: int) -> void:
	var tele := lab.tele
	var kind := str(ch.get("kind", "rate"))
	var wanted := ""
	if tele != null and tele.task != null:
		var kk := Circuits.task_channel_kinds(lab.task_id, tele.task); var wk: Dictionary = (kk["outputs"] as Dictionary).get(str(ch.get("name", "")), {})
		if str(wk.get("kind", "rate")) == "modulator": wanted = str(wk.get("modulator", ""))
	if kind == "rate_value":   # v0.6: the mean rate of rate units; nothing to choose
		add(Kit.label("Rate readout: the mean rate of the rate units connected to this channel (arbitrary units, or spikes per second for a mean-field unit).", small, Kit.TEXT_SOFT, true))
		return
	var r := HFlowContainer.new(); r.add_theme_constant_override("h_separation", 10); r.add_theme_constant_override("v_separation", 6); add(r)
	var ring_task := false
	if tele != null and tele.task != null:
		var kk2 := Circuits.task_channel_kinds(lab.task_id, tele.task); var wk2: Dictionary = (kk2["outputs"] as Dictionary).get(str(ch.get("name", "")), {})
		ring_task = str(wk2.get("kind", "rate")) == "population_vector"
	var kinds := [["rate", "rate readout"], ["modulator", "releases modulator"]]
	if ring_task: kinds = [["rate", "rate readout"], ["population_vector", "ring readout"]]
	r.add_child(Kit.stepper(kinds, kind, func(k):
		if str(k) == "modulator": Circuits.set_output_kind(ch, "modulator", wanted if wanted != "" else "NE")
		elif str(k) == "population_vector": Circuits.set_output_kind(ch, "population_vector")
		else: Circuits.set_output_kind(ch, "rate")
		lab._on_structure(); build(), 330.0 if not Layout.phone else 240.0, 18, 40.0))
	if kind == "population_vector":
		add(Kit.label("Ring readout: the bump angle is the direction of the circular mean of the spikes of this channel's cells, taken in the order they were connected (cell k of N at 360 k / N degrees, cell 0 at the top). Connect the whole ring group, in order.", small, Kit.TEXT_SOFT, true))
		return
	if kind != "modulator":
		if wanted != "": add(Kit.label("This task reads %s from this channel: switch it to \"releases modulator\" so the spikes of its neurons make %s." % [wanted, wanted], small, Kit.AMBER, true))
		return
	var mod := str(ch.get("modulator", "NE")); var gain := float(ch.get("gain", Circuits.MOD_GAIN)); var tau := float(ch.get("tau_ms", Circuits.MOD_TAU))
	r.add_child(Kit.stepper(Circuits.MODULATORS.map(func(m): return [m, m]), mod, func(m): ch["modulator"] = str(m); lab._on_structure(); build(), 90.0, 18, 40.0))
	add(val_row("gain", 0.001, 0.5, 0.001, gain, "/spike", func(x): ch["gain"] = x; lab._on_structure(), 3))
	add(val_row("tau", 50.0, 5000.0, 50.0, tau, "ms", func(x): ch["tau_ms"] = x; lab._on_structure()))
	add(Kit.label("Each spike adds %s to the %s level, which fades with tau %s ms. At 20 spikes/s the level settles near %s." % [String.num(gain, 3), mod, str(int(roundf(tau))), String.num(gain * 20.0 * tau * 0.001, 2)], small, Kit.TEXT_SOFT, true))

# ---------- diagnosis cases ----------
func inspect_dx(small: int) -> void:
	if Layout.phone:
		var hb := Kit.btn("Hide case", func(): lab._brief_forced = false; build(), "panel", 16); hb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN; add(hb)
	var note := Campaign.notebook(lab.task_id)
	var panel := DiagnosisPanel.new()
	panel.picked.connect(func(c): lab._dx["picked"] = c; build())
	panel.submit_pressed.connect(lab._dx_submit); panel.reveal_pressed.connect(lab._dx_reveal); panel.lesion_lab_pressed.connect(lab._lesion_toggle)
	add(panel.setup(lab._dx_info, lab._dx, note if (bool(lab._dx.get("solved", false)) or bool(lab._dx.get("gave_up", false))) else {}, lab.lesion_on))
	var foot: Control = lab.insp_body.get_meta("footer", null)
	if foot != null and panel.submit_row != null and is_instance_valid(panel.submit_row):   # Submit stays on screen, outside the scroll area
		panel.submit_row.get_parent().remove_child(panel.submit_row); foot.add_child(panel.submit_row); foot.visible = true

## A population or axon picked in a diagnosis case: read-only facts, a Trace button, a way back to the case card.
func inspect_dx_pick(sel: Dictionary, small: int) -> void:
	var circuit := lab.circuit
	var id := str(sel.get("id", sel.get("name", "")))
	add(head(id if str(sel["t"]) != "proj" else "axon", Kit.exc(), "read-only: this is the patient's circuit"))
	if str(sel["t"]) == "pop":
		var pi := Circuits.pop_index(circuit, id)
		if pi >= 0:
			var p: Dictionary = circuit["populations"][pi]
			add(Kit.label("%s, %d cell%s. Trace it to watch its membrane voltage, or select it and listen: only its spikes click." % [str(p.get("model", "")), Circuits.pop_n(p), "" if Circuits.pop_n(p) == 1 else "s"], small, Kit.TEXT_SOFT, true))
			add(Kit.btn("Trace", func(): toggle_trace(id), "on" if lab.tele.watched.has(Circuits.pop_first(circuit, pi)) else "panel", 18))
	elif str(sel["t"]) == "proj":
		var i := int(sel["i"])
		if i < circuit["projections"].size():
			var pr: Dictionary = circuit["projections"][i]; var w := Circuits.proj_weight_shown(circuit, i)
			# a patient's axon: its type and delay only. The strength is not shown: the dead connection has none, and that must be found by probing, not read off a number.
			add(Kit.label("%s > %s, %s, delay %s ms." % [Circuits.proj_pop(pr.get("pre", "")), Circuits.proj_pop(pr.get("post", "")), "inhibitory" if w < 0.0 else "excitatory", num(Circuits.proj_delay(pr))], small, Kit.TEXT_SOFT, true))
	add(Kit.btn("Back to the case", func(): lab.editor.select({}); lab._brief_forced = true; build(), "ghost", 18))
