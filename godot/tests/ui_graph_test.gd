class_name UiGraphTest
extends RefCounted
## Walks godot/tests/interaction_graph.json (docs/INTERACTION-GRAPH.md): the game's UI as nodes (screens, tabs, panels, modals, toasts) and edges (a user action
## on a named control that moves between them). Run by scripts/ui_graph_test.sh (ctest `ui_graph`):
##   SP_UIGRAPH=1 godot --headless --path godot            prints "UIGRAPH OK ..." or "UIGRAPH FAIL ..." and quits (exit 1 on failure)
## From the title it visits every edge: sets the guard's state (mode, passed, unlock all, missed runs) instead of playing levels, goes to the edge's source,
## presses the control with a real mouse click (so a covered or dead control fails), and asserts that the target node is what the UI now shows, that at most one
## modal is open, and, for an edge marked "returns", that the target's Back / Close control and Escape both return to the source. At every node it checks
## completeness: every visible interactive control (button, stepper, slider, text box, the circuit editor) must be listed by an active node of the graph or
## match the graph's explicit ignore list. Finally every node must have been reached. An edge or node marked "known_bug" in the JSON is expected to fail:
## it is listed as XFAIL and the run still passes; if it starts working the run fails until the marker is removed.

const GRAPH := "res://tests/interaction_graph.json"
const MODALS := ["MoreMenu", "PartsModal", "EndCard", "TestCard", "HistoCard", "ImportModal"]   # roots in the lab's overlay layer (FileDlg is a Window)

var app: Node
var vp: Viewport
var g := {}
var nodes := {}
var edges: Array = []
var fails: Array = []
var xfails: Array = []
var seen_nodes := {}
var seen_edges := {}
var checked_complete := {}
var back_tick := {}
var ctx := ""                      # what is being tested, for messages
var cur_known := ""                # the known_bug text of the edge being walked ("" = none)
var cur_failed := false
var pos_node := ""                 # where the UI is now (clean position), "" = unknown
var pos_sig := ""
var synthetic := 0                 # presses that had to be emitted because the click did not arrive
var clicks := 0
var world_resets := 0

static func run(app_: Node) -> void:
	var t := UiGraphTest.new()
	await t._run(app_)

func _fail(msg: String) -> void:
	cur_failed = true
	var m := "%s: %s" % [ctx, msg]
	if cur_known != "": xfails.append("%s  [known_bug: %s]" % [m, cur_known])
	else: fails.append(m)

func _frames(n := 2) -> void:
	for i in n: await app.get_tree().process_frame

func _wait(cond: Callable, secs: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < secs * 1000.0:
		if cond.call(): return true
		await _frames(1)
	return cond.call()

# ---------------------------------------------------------------------------------------------------- the run
func _run(app_: Node) -> void:
	app = app_; vp = app.get_viewport()
	var t0 := Time.get_ticks_msec()
	var txt := FileAccess.get_file_as_string(GRAPH)
	var parsed = JSON.parse_string(txt)
	if not (parsed is Dictionary): print("UIGRAPH FAIL: %s is not valid JSON" % GRAPH); app.get_tree().quit(1); return
	g = parsed; nodes = g["nodes"]; edges = g["edges"]
	OS.set_environment("SP_NOAUTOSAVE", "1"); Settings.no_save = true; Kit.instant = true; Engine.max_fps = 0
	app.get_window().size = Vector2i(1920, 1080); await _frames(3)   # a desktop-sized window: the lab keeps its wide layout
	Settings.layout = str(g.get("layout", "desktop")); app.relayout(); await _frames(2)
	print("UIGRAPH window ", app.get_window().size, " viewport ", vp.get_visible_rect().size)
	ctx = "graph"; _static_checks()
	var only := OS.get_environment("SP_UIGRAPH_ONLY")   # dev: walk only the edges whose id contains this
	for e in edges:
		if only != "" and not str(e["id"]).contains(only): seen_edges[e["id"]] = true; continue
		await _walk_edge(e)
	for n in g.get("negatives", []): await _negative(n)
	if only == "" or only.contains("pad"): await _pad_tutorial()   # SP_UIGRAPH_ONLY=pad walks only the gamepad tutorial
	_coverage()
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	print("UIGRAPH walked %d edges, %d nodes seen of %d, %d negatives, %d world resets, %d clicks (%d emitted instead), %.0f s" % [seen_edges.size(), seen_nodes.size(), nodes.size(), g.get("negatives", []).size(), world_resets, clicks, synthetic, secs])
	for x in xfails: print("UIGRAPH XFAIL ", x)
	for f in fails: printerr("UIGRAPH FAIL: ", f)
	_reset_env()
	if fails.is_empty(): print("UIGRAPH OK edges=%d nodes=%d xfail=%d" % [seen_edges.size(), seen_nodes.size(), xfails.size()]); app.get_tree().quit(0)
	else: print("UIGRAPH FAILED: %d problem(s)" % fails.size()); app.get_tree().quit(1)

func _reset_env() -> void:
	OS.unset_environment("SP_UNLOCK_ALL")

# ---------------------------------------------------------------------------------------------------- static checks
## The nodes that are active together with `nid`: the ones it names in "co" and, with `with_parent`, the screen it is a state of.
func _implied(nid: String, with_parent := true) -> Array:
	var out := [nid]; var i := 0
	while i < out.size():
		var n: Dictionary = nodes.get(out[i], {})
		var more: Array = (n.get("co", []) as Array).duplicate()
		if n.has("state_of") and with_parent: more.append(n["state_of"])
		for m in more:
			if not out.has(m): out.append(m)
		i += 1
	return out

func _static_checks() -> void:
	for eid in edges.size():
		var e: Dictionary = edges[eid]; ctx = "edge " + str(e.get("id", eid))
		for k in ["from", "to"]:
			if not nodes.has(str(e.get(k, ""))): _fail("%s node '%s' is not in the graph" % [k, e.get(k, "")])
	ids_unique()
	# reachability from the entry over the edges (a node is reached when an edge leads to it or to a node that implies it)
	var reach := {}; var queue: Array = [str(g["entry"])]
	for q in _implied(queue[0]): reach[q] = true
	var i := 0
	while i < queue.size():
		var here: Array = _implied(queue[i]); i += 1
		for e in edges:
			if here.has(str(e["from"])) and not reach.has(str(e["to"])):
				for q in _implied(str(e["to"])): reach[q] = true
				queue.append(str(e["to"]))
	ctx = "graph"
	for nid in nodes:
		if not reach.has(nid) and not bool(nodes[nid].get("abstract", false)): _fail("node %s is not reachable from the entry by any edge" % nid)
	# the code's screens, chapters and tabs are all in the graph
	var screens := {}
	for nid in nodes:
		var d: Dictionary = nodes[nid]["detect"]
		if d.has("screen"): screens[d["screen"]] = true
	for s in app.SCREENS: if not screens.has(s): _fail("screen '%s' (main.gd SCREENS) has no node" % s)
	for c in Campaign.CHAPTERS:
		var found := false
		for nid in nodes: if str(nodes[nid]["detect"].get("chapter", "")) == str(c["id"]): found = true
		if not found: _fail("campaign chapter '%s' has no tab node" % c["id"])
	for pair in [["settings", SettingsScreen.TABS], ["notebook", NotebookScreen.TABS]]:
		for t in pair[1]:
			var f2 := false
			for nid in nodes: if str(nodes[nid]["detect"].get("screen", "")) == pair[0] and str(nodes[nid]["detect"].get("tab", "")) == str(t): f2 = true
			if not f2: _fail("%s tab '%s' has no node" % [pair[0], t])
	for t in AnalysisScreen.TABS:
		var f3 := false
		for nid in nodes: if str(nodes[nid]["detect"].get("screen", "")) == "analysis" and nodes[nid]["detect"].has("tab") and int(nodes[nid]["detect"]["tab"]) == int(t[0]): f3 = true
		if not f3: _fail("analysis tab '%s' has no node" % t[1])

func ids_unique() -> void:
	var seen := {}
	for e in edges:
		if seen.has(e["id"]): _fail("edge id '%s' is used twice" % e["id"])
		seen[e["id"]] = true

func _coverage() -> void:
	ctx = "coverage"; cur_known = ""
	for nid in nodes:
		if bool(nodes[nid].get("abstract", false)): continue
		if not seen_nodes.has(nid):
			if nodes[nid].has("known_bug"): xfails.append("node %s was never reached  [known_bug: %s]" % [nid, nodes[nid]["known_bug"]])
			else: _fail("node %s was never reached by the walk" % nid)
	for e in edges:
		if not seen_edges.has(e["id"]) and not e.has("known_bug"): _fail("edge %s was never walked" % e["id"])

# ---------------------------------------------------------------------------------------------------- state of the world
var _level_cache := {}

func _level(tok: String) -> String:
	if tok == "" or not tok.begins_with("$"): return tok
	if _level_cache.has(tok): return _level_cache[tok]
	var out := ""
	match tok:
		"$first": out = str(Campaign.order()[0])
		"$locked":
			for id in Campaign.order():
				if not Campaign.unlocked(str(id)): out = str(id); break
		"$inhibition": out = "m_inhibition" if Campaign.order().has("m_inhibition") else ""
		"$dx":
			for c in Campaign.CHAPTERS:
				for n in Campaign.nodes(str(c["id"])):
					if out == "" and bool(n["installed"]) and str(n["kind"]) == "diagnosis": out = str(n["id"])
	_level_cache[tok] = out
	return out

func _sig(setup: Dictionary) -> String: return JSON.stringify(setup, "", true)

## Start over: no progress, Standard mode, nothing open, the title shown, then the guard's state.
func _reset_world(setup: Dictionary) -> void:
	world_resets += 1
	app.cur = ""; app.origin = {}; app.lab_keep = {}; app.lab_reference = false; app.campaign_chapter = ""; app.campaign_node = ""; app.real_back = "title"
	Progress._best = {}; Progress._loaded = true; Progress._mode = "standard"
	LabScreen._fails = {}; LabScreen._hint_tier = {}; LabScreen._ref_loaded = {}; LabScreen._fail_fp = {}
	Campaign.pending_variant = ""
	Settings.reduced_motion = false; Settings.telemetry = false
	if bool(setup.get("unlock_all", false)): OS.set_environment("SP_UNLOCK_ALL", "1")
	else: OS.unset_environment("SP_UNLOCK_ALL")
	app.tutorial.reset_for_test(); Tutorial.test_world(str(setup.get("tutorial", "seen")))   # Plate 0: "seen" unless the edge is about the tutorial (fresh | skipped | tips)
	LabUnlocks.refresh(); Campaign.refresh()
	if setup.has("mode"): Progress._mode = str(setup["mode"])
	var tid := _level(str(setup.get("level", "$first")))
	if bool(setup.get("passed", false)) and tid != "":
		Progress._best[tid] = {"value": 100.0, "passed": true, "stars": 1, "modes": {Progress._mode: {"value": 100.0, "passed": true, "stars": 1}}}
	if setup.has("misses"): LabScreen._fails[tid] = int(setup["misses"])
	Campaign.refresh()
	app.show_screen("title", false, true)
	await _frames(2)

# ---------------------------------------------------------------------------------------------------- finding controls
func _all_controls(root: Node, out: Array) -> void:
	for c in root.get_children():
		if c.is_queued_for_deletion(): continue
		if c is Control: out.append(c)
		_all_controls(c, out)

func _raw_id(c: Node) -> String:
	if c.has_meta("sp"): return str(c.get_meta("sp"))
	return ""

## The graph id of a control: its own, or that of the row / stepper it is part of (the arrows of a stepper, the slider of a settings row).
func _cid(c: Control) -> String:
	var id := _raw_id(c)
	if id in ["StepLeft", "StepRight", "Slider"] and c.get_parent() is Control: return _cid(c.get_parent())
	return id

func _isa(n: Node, cls: String) -> bool:
	match cls:
		"Stepper": return n is Kit.Stepper
		"ModDials": return n is ModDials
		"PartsBin": return n is PartsBin
	return n.is_class(cls)

func _interactive(c: Control) -> bool:
	if c.mouse_filter == Control.MOUSE_FILTER_IGNORE: return false
	return c is BaseButton or c is Kit.Stepper or c is HSlider or c is LineEdit or c is CircuitEditor

func _match_id(pat: String, id: String) -> bool:
	if pat.ends_with("*"): return id.begins_with(pat.trim_suffix("*"))
	return pat == id

func _root_for(nid: String) -> Node:
	var n: Dictionary = nodes.get(nid, {})
	var sc := str(n.get("scope", ""))
	if sc == "": return app.screen
	if sc == "Tutorial": return app.tutorial if app.tutorial.ui_visible() else null
	if sc == "FileDlg": return _lab()._file_dlg if _lab() != null and _lab()._file_dlg.visible else null
	var all: Array = []; _all_controls(app.screen, all)
	for c in all:
		if _raw_id(c) == sc and c.is_visible_in_tree(): return c
	return null

func _find(id: String, root: Node = null, need_visible := true) -> Control:
	if root == null: root = app.screen
	var all: Array = []
	if root is Control: all.append(root)
	_all_controls(root, all)
	for c in all:
		var cid := _raw_id(c)
		if cid == "" or not _match_id(id, cid): continue
		if need_visible and not c.is_visible_in_tree(): continue
		return c
	return null

func _find_all(id: String, root: Node = null) -> Array:
	if root == null: root = app.screen
	var all: Array = []; _all_controls(root, all)
	return all.filter(func(c): return _raw_id(c) != "" and _match_id(id, _raw_id(c)) and c.is_visible_in_tree())

func _lab() -> LabScreen: return app.screen as LabScreen

## The control to act on for an id, looked up in the scope of the node it belongs to: the open modal's own root, else the screen.
func _control(id: String, nid: String) -> Control:
	var root: Node = _root_for(nid)
	var c: Control = _find(id, root) if root != null else null
	if c == null: c = _find(id, _top_root())
	return c

func _open_modals() -> Array:
	var out := []
	var lab := _lab()
	if lab != null and lab.ov != null:
		for c in lab.ov.get_children():
			if not c.is_queued_for_deletion() and c is Control and _raw_id(c) in MODALS: out.append(c)
	if lab != null and lab._file_dlg != null and lab._file_dlg.visible: out.append(lab._file_dlg)
	return out

func _top_root() -> Node:
	var m := _open_modals()
	return m.back() if not m.is_empty() else app.screen

# ---------------------------------------------------------------------------------------------------- detect
func _detect(nid: String) -> bool:
	var d: Dictionary = nodes[nid]["detect"]
	var scr = app.screen
	if d.has("screen") and app.cur != str(d["screen"]): return false
	if d.has("chapter") and str(scr.chapter) != str(d["chapter"]): return false
	if d.has("tab"):
		if typeof(d["tab"]) == TYPE_STRING:
			if str(scr.tab) != str(d["tab"]): return false
		elif int(scr.tab) != int(d["tab"]): return false
	var lab := _lab()
	if d.has("task"):
		if lab == null: return false
		match str(d["task"]):
			"none": if lab.task_id != "": return false
			"level": if lab.task_id == "" or lab._is_dx(): return false
			"dx": if not lab._is_dx(): return false
	if d.has("view"):
		if lab == null or lab.insp_body == null or str(lab.insp_body.get_meta("sp_view", "")) != str(d["view"]): return false
	if d.has("dx"):
		if lab == null: return false
		var st: Dictionary = lab._dx
		match str(d["dx"]):
			"wrong": if not (int(st.get("tries", 0)) > 0 and not bool(st.get("solved", false)) and not bool(st.get("gave_up", false))): return false
			"solved": if not bool(st.get("solved", false)): return false
			"revealed": if not bool(st.get("gave_up", false)): return false
	if d.has("tutorial") and app.tutorial.step_id() != str(d["tutorial"]): return false
	if d.has("find"):
		if lab == null: return false
		if str(d["find"]) == "FileDlg": return lab._file_dlg != null and lab._file_dlg.visible
		var c := _find(str(d["find"]), lab, false)
		if c == null or not c.is_visible_in_tree(): return false
	if d.has("result"):   # the score card after a run: "passed" (the pass was recorded) or "missed" (the episode ended without a pass)
		if lab == null or lab.tele == null: return false
		var rec_pass: bool = lab._rec_pass; var fin: bool = lab.tele.finished
		match str(d["result"]):
			"passed": if not rec_pass: return false
			"missed": if not (fin and not rec_pass): return false
	if d.has("checked"):   # the score card carries the Check result
		if lab == null or lab.score_card == null or (lab.score_card.check_text != "") != bool(d["checked"]): return false
	if d.has("toast"):
		if lab == null or lab.celebration == null or (lab.celebration._toasts.size() > 0) != bool(d["toast"]): return false
	if d.has("celebrating"):
		if lab == null or lab.celebration == null or lab.celebration.active() != bool(d["celebrating"]): return false
	return true

func _active_nodes() -> Array:
	var out := []
	for nid in nodes: if _detect(nid): out.append(nid)
	return out

# ---------------------------------------------------------------------------------------------------- completeness
func _ignored(c: Control) -> bool:
	for r in g.get("ignore", []):
		if r.has("class") and not _isa(c, str(r["class"])): continue
		if r.has("under"):
			var hit := false; var p := c.get_parent()
			while p != null and not hit: hit = p is Control and _raw_id(p) == str(r["under"]); p = p.get_parent()
			if not hit: continue
		if r.has("under_class"):
			var hit2 := false; var p2 := c.get_parent()
			while p2 != null and not hit2: hit2 = _isa(p2, str(r["under_class"])); p2 = p2.get_parent()
			if not hit2: continue
		return true
	return false

func _check_complete(nid: String) -> void:
	var active := _active_nodes()
	var allowed: Array = []
	var screens_listed := false
	for a0 in active:
		for a in _implied(a0):
			var n: Dictionary = nodes[a]
			allowed.append_array(n.get("controls", [])); allowed.append_array(n.get("optional", []))
			if str(n["detect"].get("screen", "")) == app.cur: screens_listed = true
	if not screens_listed: _fail("the screen '%s' is not a node of the graph" % app.cur)
	var all: Array = []; _all_controls(_top_root(), all)
	if app.tutorial.ui_visible(): _all_controls(app.tutorial, all)   # the overlay's own buttons (Plate 0: banner, picker, pointer) are listed by their nodes too
	for c in all:
		if not _interactive(c) or not c.is_visible_in_tree() or _ignored(c): continue
		var id := _cid(c)
		if id == "": _fail("%s '%s' (%s) has no id (name it with Kit.ident, or list it in the graph's ignore rules); active nodes: %s" % [c.get_class(), c.name, app.screen.get_path_to(c), active]); continue
		var ok := false
		for pat in allowed: if _match_id(str(pat), id): ok = true; break
		if not ok: _fail("control '%s' (%s) is on screen but no active node lists it; active nodes: %s" % [id, c.get_class(), active])
	if _open_modals().size() > 1: _fail("more than one modal is open: %s" % str(_open_modals().map(func(m): return m.name)))

func _check_present(nid: String) -> void:
	for a in _implied(nid, false):
		var n: Dictionary = nodes[a]
		if bool(n.get("abstract", false)) and a != nid and not _detect(a): continue
		for id in n.get("controls", []):
			var root: Node = _root_for(a) if not bool(n.get("abstract", false)) else app.screen
			if root == null: _fail("node %s: its scope '%s' is not on screen" % [a, n.get("scope", "")]); continue
			if _find(str(id), root) == null: _fail("node %s: control '%s' is not on screen" % [a, id])

func _arrive(nid: String) -> void:
	seen_nodes[nid] = true
	for a in _implied(nid): if not bool(nodes[a].get("abstract", false)): seen_nodes[a] = true
	if not checked_complete.has(nid):
		checked_complete[nid] = true
		_check_present(nid); _check_complete(nid)

# ---------------------------------------------------------------------------------------------------- input
func _ensure_visible(c: Control) -> void:
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer: (p as ScrollContainer).ensure_control_visible(c)
		p = p.get_parent()

func _click_pos(c: Control) -> Vector2:
	var local := c.size * 0.5
	if "disc" in c: local = c.disc
	return c.get_global_transform_with_canvas() * local

## A real mouse click at the control's centre. If it does not arrive: when something else covers the control that is a failure; otherwise the press is emitted.
func _press_control(c: Control, what: String) -> void:
	if c == null: _fail("%s: no such control" % what); return
	if c is BaseButton and (c as BaseButton).disabled: _fail("%s: the control is disabled" % what); return
	_ensure_visible(c); await _frames(1)
	var pos := _click_pos(c)
	var fired := [false]
	var cb := func(): fired[0] = true
	if c is BaseButton: (c as BaseButton).pressed.connect(cb)
	var mv := InputEventMouseMotion.new(); mv.position = pos; mv.global_position = pos; vp.push_input(mv, true)
	await _frames(1)
	var hov := vp.gui_get_hovered_control()
	var down := InputEventMouseButton.new(); down.position = pos; down.global_position = pos; down.button_index = MOUSE_BUTTON_LEFT; down.pressed = true; down.button_mask = MOUSE_BUTTON_MASK_LEFT
	vp.push_input(down, true)
	var up := InputEventMouseButton.new(); up.position = pos; up.global_position = pos; up.button_index = MOUSE_BUTTON_LEFT; up.pressed = false; up.button_mask = 0
	vp.push_input(up, true)
	await _frames(1)
	clicks += 1
	if not is_instance_valid(c): fired[0] = true   # the press replaced the screen: it worked
	elif c is BaseButton and (c as BaseButton).pressed.is_connected(cb): (c as BaseButton).pressed.disconnect(cb)
	if not fired[0] and c is BaseButton:
		if hov != null and hov != c and not c.is_ancestor_of(hov) and not hov.is_ancestor_of(c): _fail("%s: the click lands on %s '%s' instead: the control is covered" % [what, hov.get_class(), hov.name])
		else: synthetic += 1; (c as BaseButton).pressed.emit()
	await _frames(2)

func _key_escape() -> void:
	for down in [true, false]:
		var k := InputEventKey.new(); k.keycode = KEY_ESCAPE; k.physical_keycode = KEY_ESCAPE; k.pressed = down
		vp.push_input(k)
	await _frames(2)

func _press_id(id: String, nid: String, what: String) -> void:
	var c := _control(id, nid)
	if c == null: _fail("%s: control '%s' is not on screen (scope of %s)" % [what, id, nid]); return
	await _press_control(c, what + " (" + id + ")")

## A stepper is driven through its right arrow.
func _step(id: String, nid: String) -> void:
	var c := _control(id, nid)
	if c == null or not (c is Kit.Stepper): _fail("control '%s' is not a stepper" % id); return
	await _press_control((c as Kit.Stepper).right, "stepper " + id)

# ---------------------------------------------------------------------------------------------------- navigation
var _path_tut := false   # the path being planned ends at a Plate 0 node: only then may it use the tutorial's own edges (they would otherwise be shortcuts into the lab)

func _allowed_path_edge(e: Dictionary, need_ref: bool) -> bool:
	if str(e["id"]).begins_with("tut.") and not _path_tut: return false
	if bool(e.get("reference_entry", false)) and not need_ref: return false
	if bool(e.get("plain_entry", false)) and need_ref: return false
	if bool(e.get("sandbox_only", false)): return false
	if bool(e.get("dx_only", false)) and _walk_level != "$dx": return false
	if _walk_avoid.has(str(e["id"])): return false
	if bool(e.get("needs_reference", false)) and not need_ref: return false
	if bool(e.get("plain_only", false)) and need_ref: return false
	if str(e.get("action", "")) == "terminal": return false
	if e.has("known_bug"): return false
	return true

## The shortest list of edges from the entry to a state in which `nid` is active.
func _path_to(nid: String, need_ref: bool) -> Array:
	_path_tut = nid.begins_with("tut.")
	var start := str(g["entry"])
	if _implied(start).has(nid): return []
	var prev := {start: null}; var queue: Array = [start]; var i := 0
	while i < queue.size():
		var here := str(queue[i]); i += 1
		var imp := _implied(here)
		for e in edges:
			if not imp.has(str(e["from"])) or not _allowed_path_edge(e, need_ref): continue
			var to := str(e["to"])
			if prev.has(to): continue
			prev[to] = [here, e]; queue.append(to)
			if _implied(to).has(nid):
				var path := []; var cur := to
				while prev[cur] != null: path.push_front(prev[cur][1]); cur = prev[cur][0]
				return path
	return []

func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate(); for k in b: out[k] = b[k]
	return out

## Go to a state where `nid` is active, with `setup` in force.
var _walk_avoid: Array = []
var _walk_level := "$first"

func _goto(nid: String, setup: Dictionary, need_ref: bool) -> bool:
	var sig := _sig(setup) + str(need_ref)
	if pos_node != "" and pos_sig == sig and _implied(pos_node).has(nid) and _detect(nid): return true
	var path := _path_to(nid, need_ref)
	if path.is_empty() and not _implied(str(g["entry"])).has(nid): _fail("no path of edges leads to node %s" % nid); return false
	var world := {}
	for pe in path: world = _merge(world, pe.get("setup", {}))
	world = _merge(world, setup)
	await _reset_world(world)
	pos_node = ""; pos_sig = ""
	for pe in path:
		var save_ctx := ctx; ctx += " (on the way: " + str(pe["id"]) + ")"
		await _trigger(pe, world)
		ctx = save_ctx
	if not _detect(nid): _fail("after %d edges the UI is not at %s" % [path.size(), nid]); return false
	pos_node = nid; pos_sig = sig
	return true

func _select_level(level: String) -> void:
	var tid := _level(level)
	if tid == "": _fail("no level for %s" % level); return
	var scr = app.screen
	if app.cur != "tasks": _fail("cannot pick level %s: the campaign is not open" % tid); return
	var ch := Campaign.chapter_of(tid)
	if str(scr.chapter) != ch and Campaign.wing_of(ch) != Campaign.wing_of(str(scr.chapter)): await _press_id("Wing_" + Campaign.wing_of(ch), "campaign", "wing switch")   # the map shows one wing's chapters at a time
	if str(scr.chapter) != ch: await _press_id("Chapter_" + ch, "campaign", "chapter tab")
	await _press_id("Pin_" + tid, "campaign", "pin")
	if str(app.campaign_node) != tid: _fail("pressing the pin of %s selected '%s'" % [tid, app.campaign_node])

# ---------------------------------------------------------------------------------------------------- triggers
func _trigger(e: Dictionary, world: Dictionary) -> void:
	var act := str(e.get("action", "press")); var ctl := str(e.get("control", "")); var from := str(e["from"])
	if act.begins_with("event:"): await _event(act.substr(6), e); return
	await _trigger_control(e, world, act, ctl, from)
	if e.has("wait"): await _wait(func(): return _detect(str(e["to"])), float(e["wait"]))

func _trigger_control(e: Dictionary, world: Dictionary, act: String, ctl: String, from: String) -> void:
	if (ctl == "BtnBuild" or ctl == "BtnReference") and app.cur == "tasks": await _select_level(str(world.get("level", "$first")))
	match act:
		"press", "toggle": await _press_id(ctl, from, "edge " + str(e["id"]))
		"step": await _step(ctl, from)
		"select":
			var pool := _find_all(ctl, _root_for(from))
			var pick: Control = null
			for c in pool:
				if c is Button and ctl.begins_with("Pin_") and str(app.campaign_node) == _raw_id(c).trim_prefix("Pin_"): continue
				if c is Button and (c as Button).disabled: continue
				if ctl.begins_with("Pin_") and not bool((c as TasksScreen.NodeCard).node.get("installed", false)): continue
				pick = c; break
			if pick == null: _fail("no control matches '%s'" % ctl)
			else: await _press_control(pick, "edge " + str(e["id"]) + " (" + _raw_id(pick) + ")")
		"key:escape": await _key_escape()
		"terminal":
			var tc := _control(ctl, from)
			if tc == null: _fail("the %s entry is missing" % ctl)
			elif tc is BaseButton and (tc as BaseButton).disabled: _fail("the %s entry is disabled" % ctl)
		_:
			if act.begins_with("press_after:"): await _pre(act.substr(12), from); await _press_id(ctl, from, "edge " + str(e["id"]))
			elif act.begins_with("tut:"): await _tutorial_action(act.substr(4))
			elif act.begins_with("select:") or act == "link" or act == "lesion_pick" or act.begins_with("dx:"): await _editor_action(act)
			elif act.begins_with("script:"): await _editor_script(act.substr(7), str(e["id"]))
			else: _fail("unknown action '%s'" % act)

func _pre(what: String, from: String) -> void:
	if what == "lesion_pick": await _editor_action("lesion_pick")
	else: await _press_id(what, from, "preparing")

## Plate 0 actions, done the way a player does them: real mouse drags on the editor, a real click on the sensor card, the weight slider moved.
func _tutorial_action(what: String) -> void:
	var lab := _lab()
	if lab == null: _fail("not in the lab for tutorial action %s" % what); return
	var ed := lab.editor
	var origin := ed.get_global_rect().position
	match what:
		"drag_in":
			var c: Rect2 = ed._cards["in:pulse"]; var cell := origin + ed.to_screen(Vector2(lab.circuit["populations"][0]["pos"][0][0], lab.circuit["populations"][0]["pos"][0][1]))
			await _drag(origin + Vector2(c.end.x - 12.0, c.get_center().y), cell)
		"drag_out":
			var m: Rect2 = ed._cards["out:spike"]; var cell2 := origin + ed.to_screen(Vector2(lab.circuit["populations"][0]["pos"][0][0], lab.circuit["populations"][0]["pos"][0][1]))
			await _drag(cell2 + Vector2(ed._r * 0.85, 0.0), origin + m.get_center())
		"raise":
			var c2: Rect2 = ed._cards["in:pulse"]
			await _click_at(origin + c2.get_center() - Vector2(18.0, 0.0))
			var sl := lab.insp_body.find_children("*", "HSlider", true, false)
			if sl.is_empty(): _fail("the sensor's weight slider did not appear after clicking the card")
			else:
				var hs := sl[0] as HSlider
				hs.value = sqrt(470.0 / Circuits.input_wmax_for("", "dc", lab.task_id))   # the weight slider is square-law (value = wmax * s^2): 470 pA is inside the level's band
		"raise_run":   # the weight raised, then a real click on Run (the player starts every run)
			await _tutorial_action("raise")
			await _press_id("BtnRun", "lab", "Run")
		_: _fail("unknown tutorial action '%s'" % what)
	await _frames(3)

func _click_at(pos: Vector2) -> void:
	var mv := InputEventMouseMotion.new(); mv.position = pos; mv.global_position = pos; vp.push_input(mv, true); await _frames(1)
	var down := InputEventMouseButton.new(); down.position = pos; down.global_position = pos; down.button_index = MOUSE_BUTTON_LEFT; down.pressed = true; down.button_mask = MOUSE_BUTTON_MASK_LEFT; vp.push_input(down, true)
	var up := InputEventMouseButton.new(); up.position = pos; up.global_position = pos; up.button_index = MOUSE_BUTTON_LEFT; up.pressed = false; up.button_mask = 0; vp.push_input(up, true)
	clicks += 1; await _frames(2)

func _drag(a: Vector2, b: Vector2) -> void:
	var mv := InputEventMouseMotion.new(); mv.position = a; mv.global_position = a; vp.push_input(mv, true); await _frames(1)
	var down := InputEventMouseButton.new(); down.position = a; down.global_position = a; down.button_index = MOUSE_BUTTON_LEFT; down.pressed = true; down.button_mask = MOUSE_BUTTON_MASK_LEFT; vp.push_input(down, true)
	await _frames(1)
	for i in range(1, 7):
		var p := a.lerp(b, float(i) / 6.0)
		var m2 := InputEventMouseMotion.new(); m2.position = p; m2.global_position = p; m2.button_mask = MOUSE_BUTTON_MASK_LEFT; vp.push_input(m2, true); await _frames(1)
	var up := InputEventMouseButton.new(); up.position = b; up.global_position = b; up.button_index = MOUSE_BUTTON_LEFT; up.pressed = false; up.button_mask = 0; vp.push_input(up, true)
	clicks += 1; await _frames(2)

func _first_pop() -> String:
	var lab := _lab()
	var ps: Array = lab.circuit.get("populations", [])
	return str(ps[0].get("id", "")) if not ps.is_empty() else ""

## Wire a cell if the bench has none, then select the link of a sensor to it (or of it to a motor) with a real click on the link.
func _link_select(is_in: bool) -> void:
	var lab := _lab(); var ed := lab.editor
	# a known bench: one cell and nothing wired (the circuit an earlier edge left in the lab's memory is not this edge's business)
	for ps in (lab.circuit.get("populations", []) as Array).slice(1): Circuits.remove_population(lab.circuit, str(ps["id"]))
	lab.circuit["projections"] = []
	for ch in lab.circuit.get("inputs", []): ch["targets"] = []
	for ch in lab.circuit.get("outputs", []): ch["neurons"] = []
	if _first_pop() == "": lab._add_neuron("E")
	lab._on_structure(); await _settle()
	var pid := _first_pop()
	var chs: Array = lab.circuit.get("inputs" if is_in else "outputs", [])
	if chs.is_empty(): _fail("the circuit has no %s channel" % ("sensor" if is_in else "motor")); return
	var nm := str(chs[0]["name"])
	ed._make_link({"t": "in", "name": nm} if is_in else {"t": "pop", "id": pid}, {"t": "pop", "id": pid} if is_in else {"t": "out", "name": nm})
	await _settle(); ed.fit(); ed._geo(); await _frames(2)
	var mid := ed.link_mid("in" if is_in else "out", nm, pid)
	if mid == Vector2.INF: _fail("the %s link is not drawn" % ("sensor" if is_in else "motor")); return
	await _click_editor(mid)
	if str(ed.sel.get("t", "")) != ("ilink" if is_in else "olink"): _fail("a click on the %s link selected %s" % [("sensor" if is_in else "motor"), str(ed.sel)])

func _editor_action(act: String) -> void:
	var lab := _lab()
	if lab == null: _fail("not in the lab for '%s'" % act); return
	var ed := lab.editor
	match act:
		"select:none": ed.select({})
		"select:pop":
			if _first_pop() == "": lab._add_neuron("E"); ed.select({})
			ed.select({"t": "pop", "id": _first_pop()})
		"select:in":
			var ins: Array = lab.circuit.get("inputs", [])
			if ins.is_empty(): _fail("the circuit has no input channel to select")
			else: ed.select({"t": "in", "name": str(ins[0]["name"])})
		"select:out":
			var outs: Array = lab.circuit.get("outputs", [])
			if outs.is_empty(): _fail("the circuit has no output channel to select")
			else: ed.select({"t": "out", "name": str(outs[0]["name"])})
		"link":
			while (lab.circuit.get("populations", []) as Array).size() < 2: lab._add_neuron("E")
			var ps: Array = lab.circuit["populations"]
			ed._make_link({"t": "pop", "id": str(ps[0]["id"])}, {"t": "pop", "id": str(ps[1]["id"])})
		"select:ilink": await _link_select(true)
		"select:olink": await _link_select(false)
		"lesion_pick": ed.lesion_clicked.emit({"t": "pop", "id": _first_pop()})
		"dx:right": await _dx_submit(true)
		"dx:wrong": await _dx_submit(false)
		"dx:reveal":
			for _i in DiagnosisPanel.REVEAL_AFTER: await _dx_submit(false)   # giving up is offered only after several misses
			await _press_id("BtnRevealAnswer", "lab.insp.dx", "reveal")
		_: _fail("unknown editor action '%s'" % act)
	await _frames(3)


# ---------------------------------------------------------------------------------------------------- the tutorial with a gamepad only
var _pad_seen_text := ""   # what the last pad reachability search reached (for the failure message)
const PAD_DIRS := [JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN]
## The focus each step starts on (a control id, "editor", or "next").
const PAD_START := {1: "next", 2: "BtnExcitatory", 3: "editor", 4: "editor", 5: "BtnRun", 6: "next", 7: "editor", 8: "BtnRun", 9: "BtnCheck", 10: "next", 11: "BtnEI", 12: "next"}

## A press of a gamepad button, as the pad sends it: pressed, then released.
func _pad_press(btn: JoyButton) -> void:
	for down in [true, false]:
		var e := InputEventJoypadButton.new(); e.button_index = btn; e.pressed = down; e.device = 0
		vp.push_input(e)
	await _frames(2)

## Where the focus goes from `c` when the D-pad is pressed toward `btn` (the bench takes the first presses with its cursor, so it gets several tries); null when it stays.
func _pad_leave(c: Control, btn: JoyButton) -> Control:
	for i in (8 if c is CircuitEditor else 1):
		if not is_instance_valid(c): return null
		c.grab_focus(); await _frames(1)
		await _pad_press(btn)
		var n := vp.gui_get_focus_owner()
		if n != c: return n
	return null

## Of `goals`, the controls the pad cannot reach from `start` with the D-pad. Every control the focus lands on on the way must be one the tutorial lights.
func _pad_unreached(start: Control, goals: Array, what: String) -> Array:
	var tut = app.tutorial
	var seen := {start: true}; var queue: Array = [start]; var found := {}
	_pad_seen_text = ""
	while not queue.is_empty():
		var c: Control = queue.pop_front()
		if goals.has(c): found[c] = true
		for b in PAD_DIRS:
			var n: Control = await _pad_leave(c, b)
			if n == null: continue
			if not tut.focus_ok(n): _fail("%s: the pad focus can land on '%s' (%s), a control the tutorial dims" % [what, _raw_id(n), n.get_class()])
			if not seen.has(n): seen[n] = true; queue.append(n); _pad_seen_text += "%s '%s' %s; " % [n.get_class(), _raw_id(n), str(n.get_global_rect())]
	return goals.filter(func(gc): return not found.has(gc))

func _pad_cursor_to(kind: String, dir: JoyButton) -> bool:
	var ed := _lab().editor
	for i in 8:
		if str(ed._cursor.get("t", "")) == kind: return true
		await _pad_press(dir)
	return str(ed._cursor.get("t", "")) == kind

func _tut_step_is(n: int) -> bool: return app.tutorial.active and app.tutorial.step == n

## Plate 0 with a gamepad and nothing else: on every step the focus starts on the right control and is never on a dimmed one, Back, Do it for me, Next or Finish, Skip and the lit
## controls can all be reached with the D-pad, and each step is finished with pad presses only (the bench's own flow for the wires: X starts one, A ends it). Then the mode picker.
func _pad_tutorial() -> void:
	ctx = "pad tutorial"; cur_known = ""; cur_failed = false
	var tut = app.tutorial
	await _reset_world({"tutorial": "fresh", "mode": "guided"})
	tut.on_play()
	if not await _wait(func(): return _tut_step_is(1) and _lab() != null and _lab().editor != null, 10.0): _fail("Play on a fresh save did not start the tutorial"); return
	app.pad.set_active(true)
	await _frames(20)
	for n in range(1, 13):
		ctx = "pad tutorial step %d" % n
		if not await _wait(func(): return _tut_step_is(n), 150.0): _fail("the tutorial never reached step %d" % n); break
		await _frames(30)   # the gate and the focus settle
		var lab := _lab()
		var st: Dictionary = tut._steps()[n - 1]
		var act := str(st.get("kind", "")) == "act"
		var banner := {"next": tut.find_child("TutNext", true, false), "do": tut.find_child("TutDo", true, false), "back": tut.find_child("TutBack", true, false), "skip": tut.find_child("TutSkip", true, false)}
		var start_id := str(PAD_START[n])
		var want_of := func() -> Control: return banner["next"] if start_id == "next" else (lab.editor if start_id == "editor" else _find(start_id, lab))
		await _wait(func(): var w: Control = want_of.call(); return w != null and vp.gui_get_focus_owner() == w, 8.0)   # the lit control may appear a moment after the step starts
		var want: Control = want_of.call()
		var fo := vp.gui_get_focus_owner()
		if fo == null or fo != want: _fail("the focus starts on %s, not on %s" % [("%s '%s'" % [fo.get_class(), _raw_id(fo)]) if fo != null else "nothing", start_id])
		# every control of the step can be reached
		var goals := [banner["skip"], want]
		if n > 1: goals.append(banner["back"])
		goals.append(banner["do"] if act else banner["next"])
		if act and n == 12: goals.append(banner["next"])
		for gl in goals:
			if gl == null or not gl.is_visible_in_tree(): _fail("a button of the step is not on screen")
		goals = goals.filter(func(gc): return gc != null and gc.is_visible_in_tree())
		var start: Control = want if want != null else fo
		if start != null:
			for miss in await _pad_unreached(start, goals, "step %d" % n): _fail("the pad cannot reach '%s' (%s, rect %s, focus mode %d); the focus can reach: %s" % [_raw_id(miss), miss.get_class(), str(miss.get_global_rect()), miss.focus_mode, _pad_seen_text])
		# the step, done with the pad
		match n:
			2: want.grab_focus(); await _pad_press(JOY_BUTTON_A)
			3:
				lab.editor.grab_focus(); await _frames(1)
				if not await _pad_cursor_to("in", JOY_BUTTON_DPAD_LEFT): _fail("the cursor could not reach the sensor")
				await _pad_press(JOY_BUTTON_X)
				if not await _pad_cursor_to("pop", JOY_BUTTON_DPAD_RIGHT): _fail("the cursor could not reach the cell")
				await _pad_press(JOY_BUTTON_A)
			4:
				lab.editor.grab_focus(); await _frames(1)
				if not await _pad_cursor_to("pop", JOY_BUTTON_DPAD_LEFT): _fail("the cursor could not reach the cell")
				await _pad_press(JOY_BUTTON_X)
				if not await _pad_cursor_to("out", JOY_BUTTON_DPAD_RIGHT): _fail("the cursor could not reach the motor")
				await _pad_press(JOY_BUTTON_A)
			5: want.grab_focus(); await _pad_press(JOY_BUTTON_A)
			7:
				lab.editor.grab_focus(); await _frames(1)
				if not await _pad_cursor_to("in", JOY_BUTTON_DPAD_LEFT): _fail("the cursor could not reach the sensor")
				await _pad_press(JOY_BUTTON_A)   # select it: its weight slider is in the inspector
				await _frames(10)
				var sl := lab.insp_body.find_children("*", "HSlider", true, false)
				if sl.is_empty(): _fail("selecting the sensor with A showed no weight slider")
				else:
					await _wait(func(): return (sl[0] as Control).focus_mode == Control.FOCUS_ALL, 5.0)   # the gate lets the lit weight row take focus within a moment
					for miss in await _pad_unreached(lab.editor, [sl[0]], "step 7"): _fail("the pad cannot reach the weight slider; the focus can reach: %s" % _pad_seen_text)
					(sl[0] as HSlider).value = sqrt(470.0 / Circuits.input_wmax_for("", "dc", lab.task_id))
				await _pad_press(JOY_BUTTON_START)   # Start runs
			8: pass   # the run of step 7 plays on; the step ends when it passes
			9: want.grab_focus(); await _pad_press(JOY_BUTTON_A)
			10: want.grab_focus(); await _pad_press(JOY_BUTTON_A)
			11: want.grab_focus(); await _pad_press(JOY_BUTTON_A)
			12: banner["next"].grab_focus(); await _pad_press(JOY_BUTTON_A)
			_: banner["next"].grab_focus(); await _pad_press(JOY_BUTTON_A)
		if n < 12 and not await _wait(func(): return tut.step > n or not tut.active, 150.0 if n in [7, 8, 9] else 15.0): _fail("pressing the pad buttons did not finish the step"); break
	# the mode picker: its three buttons reachable, one pressed
	ctx = "pad tutorial picker"
	if not await _wait(func(): return tut.picker_open, 15.0): _fail("Finish did not open the mode picker"); app.pad.set_active(false); return
	await _frames(30)
	var fp := vp.gui_get_focus_owner()
	var modes := []
	for m in Progress.MODES: modes.append(tut.find_child("Mode_" + m, true, false))
	if fp == null or not modes.has(fp): _fail("the focus does not start on a mode button")
	else:
		for miss in await _pad_unreached(fp, modes, "the mode picker"): _fail("the pad cannot reach '%s'" % _raw_id(miss))
	var pick: Control = tut.find_child("Mode_standard", true, false)
	if pick != null: pick.grab_focus(); await _pad_press(JOY_BUTTON_A)
	if not await _wait(func(): return not tut.picker_open and app.cur == "tasks", 10.0): _fail("a pad press on a mode button did not close the picker and open the map")
	app.pad.set_active(false); Kit.pad_mode = false
	tut.reset_for_test()

# ---------------------------------------------------------------------------------------------------- editor scripts (undo, zoom, selection, clipboard, slots)
## A key press through the viewport, as the player types it.
func _key(code: Key, ctrl := false, shift := false) -> void:
	for down in [true, false]:
		var k := InputEventKey.new(); k.keycode = code; k.physical_keycode = code; k.pressed = down; k.ctrl_pressed = ctrl; k.shift_pressed = shift
		vp.push_input(k)
	await _frames(2)

func _mouse(pos: Vector2, button: MouseButton, down: bool, shift := false) -> void:
	var m := InputEventMouseButton.new(); m.position = pos; m.global_position = pos; m.button_index = button; m.pressed = down; m.shift_pressed = shift
	m.button_mask = (1 << (button - 1)) if down else 0
	vp.push_input(m, true)

func _click_editor(local: Vector2, shift := false) -> void:
	var ed := _lab().editor; var pos := ed.get_global_transform_with_canvas() * local
	var mv := InputEventMouseMotion.new(); mv.position = pos; mv.global_position = pos; vp.push_input(mv, true)
	_mouse(pos, MOUSE_BUTTON_LEFT, true, shift); _mouse(pos, MOUSE_BUTTON_LEFT, false, shift)
	await _frames(2)

func _text() -> String: return Circuits.to_json(_lab().circuit)

func _settle() -> void:   # an edit becomes an undo step after a short quiet spell; the lab reloads after 0.3 s
	await _wait(func(): return _lab().editor._pending < 0.0 and _lab()._dirty < 0.0, 5.0); await _frames(2)

func _confirm_if_asked() -> void:
	await _frames(2)
	var yes := _find("BtnConfirmYes", _lab())
	if yes != null: await _press_control(yes, "confirm")
	await _settle()

func _editor_script(name: String, eid: String) -> void:
	var lab := _lab()
	if lab == null: _fail("not in the lab for script %s" % name); return
	var ed := lab.editor
	match name:
		"undo":
			await _settle(); var before := _text()
			await _press_id("BtnExcitatory", "lab.task", eid); await _settle()
			if _text() == before: _fail("+ Excitatory changed nothing")
			await _press_id("BtnUndo", "lab.task", eid); await _settle()
			if _text() != before: _fail("Undo did not give the circuit back byte for byte")
			await _key(KEY_Z, true, true); await _settle()
			if Circuits.neuron_count(lab.circuit) == 0 and Circuits.neuron_count(Circuits.parse(before)) == 0: _fail("Ctrl+Shift+Z did not redo")
			await _key(KEY_Z, true); await _settle()
			if _text() != before: _fail("Ctrl+Z did not undo the redo")
		"redo":
			await _settle(); var n0 := Circuits.neuron_count(lab.circuit)
			await _press_id("BtnExcitatory", "lab.task", eid); await _settle()
			await _key(KEY_Z, true); await _settle()
			if Circuits.neuron_count(lab.circuit) != n0: _fail("Ctrl+Z did not undo the new neuron")
			await _press_id("BtnRedo", "lab.task", eid); await _settle()
			if Circuits.neuron_count(lab.circuit) != n0 + 1: _fail("Redo did not bring the neuron back")
		"zoom_fit":
			await _settle(); ed._geo(); var s0 := ed.view_scale
			var pos := ed.get_global_transform_with_canvas() * (ed.size * 0.5)
			_mouse(pos, MOUSE_BUTTON_WHEEL_UP, true); _mouse(pos, MOUSE_BUTTON_WHEEL_UP, false); await _frames(2)
			if not ed.view_scale > s0: _fail("the wheel did not zoom in (%s -> %s)" % [s0, ed.view_scale])
			var o0 := ed.view_off
			_mouse(pos, MOUSE_BUTTON_MIDDLE, true)
			var mv := InputEventMouseMotion.new(); mv.position = pos + Vector2(40, 20); mv.global_position = mv.position; mv.button_mask = MOUSE_BUTTON_MASK_MIDDLE; vp.push_input(mv, true)
			_mouse(pos + Vector2(40, 20), MOUSE_BUTTON_MIDDLE, false); await _frames(2)
			if ed.view_off.distance_to(o0 + Vector2(40, 20)) > 1.0: _fail("middle-drag did not pan")
			await _key(KEY_F); ed._geo()
			if absf(ed.view_scale - s0) > 0.02: _fail("F did not fit (%s, fitted %s)" % [ed.view_scale, s0])
		"multiselect":
			while (lab.circuit.get("populations", []) as Array).size() < 2: lab._add_neuron("E")
			await _settle(); ed.fit(); ed._geo()
			var a := ed.pop_rect(0).get_center(); var b := ed.pop_rect(1).get_center()
			await _click_editor(a); await _click_editor(b, true)
			if ed.selected_pops().size() != 2: _fail("click then shift-click did not select two groups (%s)" % str(ed.selected_pops()))
			await _click_editor(Vector2(4, 4))   # empty bench: nothing selected
			if not ed.selected_pops().is_empty(): _fail("a click on the empty bench did not clear the selection")
			ed._band_select(Rect2(Vector2.ZERO, ed.size), false)
			if ed.selected_pops().size() != (lab.circuit["populations"] as Array).size(): _fail("a box over the bench did not select every group")
		"copy_paste":
			while (lab.circuit.get("populations", []) as Array).size() < 2: lab._add_neuron("E")
			await _settle(); var n1 := Circuits.neuron_count(lab.circuit); var t1 := _text()
			ed.grab_focus(); await _key(KEY_A, true); await _key(KEY_C, true); await _key(KEY_V, true); await _settle()
			if Circuits.neuron_count(lab.circuit) != 2 * n1: _fail("Ctrl+A, Ctrl+C, Ctrl+V did not paste a copy (%d neurons, had %d)" % [Circuits.neuron_count(lab.circuit), n1])
			await _key(KEY_D, true); await _settle()
			if Circuits.neuron_count(lab.circuit) != 3 * n1: _fail("Ctrl+D did not duplicate the pasted groups")
			await _key(KEY_Z, true); await _settle(); await _key(KEY_Z, true); await _settle()
			if _text() != t1: _fail("two Ctrl+Z did not take the paste and the duplicate back")
		"slot":
			if (lab.circuit.get("populations", []) as Array).is_empty(): lab._add_neuron("E")
			await _settle(); var saved := _text()
			await _press_id("BtnMore", "lab.task", eid); await _press_id("BtnSaveToA", "lab.more", eid); await _settle()
			lab._add_neuron("E"); await _settle()
			await _press_id("BtnMore", "lab.task", eid); await _press_id("BtnLoadA", "lab.more", eid); await _confirm_if_asked()
			if Circuits.fingerprint(lab.circuit) != Circuits.fingerprint(Circuits.parse(saved)): _fail("Load A did not put the saved circuit back")
		"json":
			if (lab.circuit.get("populations", []) as Array).is_empty(): lab._add_neuron("E")
			await _settle(); var copied := _text()
			await _press_id("BtnMore", "lab.task", eid); await _press_id("BtnCopyCircuitAsJson", "lab.more", eid); await _settle()
			lab._add_neuron("E"); await _settle()
			await _press_id("BtnMore", "lab.task", eid); await _press_id("BtnPasteCircuitJson", "lab.more", eid); await _confirm_if_asked()
			if Circuits.fingerprint(lab.circuit) != Circuits.fingerprint(Circuits.parse(copied)): _fail("Paste circuit JSON did not put the copied circuit back")
		"card_move":   # a sensor card dragged with the mouse stays where it was dropped: kept in the circuit, through a reload, undone and redone
			if _first_pop() == "": lab._add_neuron("E")
			await _settle(); ed.fit(); ed._geo()
			var cins: Array = lab.circuit.get("inputs", [])
			if cins.is_empty(): _fail("the circuit has no sensor card"); return
			var ckey := "in:" + str(cins[0]["name"])
			var origin := ed.get_global_rect().position
			var r0: Rect2 = ed._cards[ckey]
			var a0 := origin + r0.get_center() - Vector2(16, 0)   # clear of the wiring handle on the right edge
			await _drag(a0, a0 + Vector2(0, 80)); await _settle()
			var off: Vector2 = ed._card_off(ckey)
			if off.length() < 20.0: _fail("the sensor card did not follow the drag (offset %s)" % str(off)); return
			var saved := Circuits.parse(Circuits.to_json(lab.circuit))
			if not (((saved.get("meta", {}) as Dictionary).get("editor", {}) as Dictionary).has("cards")): _fail("the card position is not written with the circuit")
			await _wait(func(): return false, 1.0)
			lab._reload(); lab._build_inspector(); await _frames(5)
			if ed._card_off(ckey).distance_to(off) > 0.01: _fail("the sensor card moved back when the engine reloaded (%s)" % str(ed._card_off(ckey)))
			await _key(KEY_Z, true); await _settle()
			if ed._card_off(ckey).length() > 0.01: _fail("Ctrl+Z did not put the sensor card back")
			await _key(KEY_Z, true, true); await _settle()
			if ed._card_off(ckey).distance_to(off) > 0.01: _fail("Ctrl+Shift+Z did not move the sensor card again")
		"link_delete":   # a link is selected by a click and removed with Delete (and undone); the sensor and the cell stay
			await _link_select(true)
			if ((lab.circuit["inputs"][0]["targets"]) as Array).is_empty(): _fail("the sensor has no link to delete"); return
			await _key(KEY_DELETE); await _settle()
			if not ((lab.circuit["inputs"][0]["targets"]) as Array).is_empty() or Circuits.neuron_count(lab.circuit) < 1: _fail("Delete did not take the sensor link away alone")
			await _key(KEY_Z, true); await _settle()
			if ((lab.circuit["inputs"][0]["targets"]) as Array).is_empty(): _fail("Ctrl+Z did not bring the sensor link back")
			await _link_select(false)
			await _key(KEY_DELETE); await _settle()
			if not ((lab.circuit["outputs"][0]["neurons"]) as Array).is_empty() or Circuits.neuron_count(lab.circuit) < 1: _fail("Delete did not take the motor link away alone")
			await _key(KEY_Z, true); await _settle()
			if ((lab.circuit["outputs"][0]["neurons"]) as Array).is_empty(): _fail("Ctrl+Z did not bring the motor link back")
		_: _fail("unknown editor script '%s'" % name)
	await _frames(3)

func _dx_submit(right: bool) -> void:
	var lab := _lab()
	var ans := str(lab._dx_info.get("answer", ""))
	var cands: Array = lab._dx_info.get("candidates", [])
	var pick := ""
	for c in cands:
		if (str(c) == ans) == right: pick = str(c); break
	if pick == "": _fail("the case has no %s candidate" % ("right" if right else "wrong")); return
	await _press_id("Cand_" + pick, "lab.insp.dx", "candidate")
	await _press_id("BtnSubmitDiagnosis", "lab.insp.dx", "submit")

func _event(name: String, e: Dictionary) -> void:
	var lab := _lab()
	match name:
		"episode_end", "episode_end_failing":
			if name == "episode_end_failing":   # a circuit that cannot pass: the reference with every axon cut and every sensor unwired (the walk's shortcut for a hand-built failing circuit)
				lab.circuit["projections"] = []
				for ch in lab.circuit.get("inputs", []): ch["targets"] = []
				lab._on_structure(); await _wait(func(): return lab._dirty < 0.0, 10.0); await _frames(3)
			if lab == null or lab.tele == null or lab.tele.task == null or lab.tele.sim == null: _fail("no running episode to finish (the lab has no simulation)"); return
			lab.tele.running = true; lab.tele.skip_until(float(lab.tele.task.duration_ms()))
			if not await _wait(func(): return _detect(str(e["to"])), 120.0): _fail("the episode never ended: the score card shows no result after 120 s")
		"test_done":
			if not await _wait(func(): return _detect("lab.endcard"), 400.0): _fail("the 5-seed test never finished (400 s)")
		"check_done":
			if not await _wait(func(): return _detect("lab.checked"), 120.0): _fail("Check never wrote its result on the score card (120 s)")
		"tut_pass":   # Plate 0 step 7: the live run finishes and passes by itself (the weight is already in the band)
			if not await _wait(func(): return _detect(str(e["to"])), 90.0): _fail("the live run never passed: the tutorial did not leave step 7")
		"first_pass": lab._celebrate(); await _frames(3)
		"celebration_ends":
			if not await _wait(func(): return not lab.celebration.active(), 12.0): _fail("the celebration never ended")
			lab.celebration.clear_toasts(); await _frames(2)
		"toast_expires": lab.celebration.clear_toasts(); await _frames(3)
		_: _fail("unknown event '%s'" % name)

# ---------------------------------------------------------------------------------------------------- expectations
func _control_state_text(id: String) -> String:
	var c := _control(id, "lab")
	if c == null: c = _find(id, _top_root())
	return (c as Button).text if c is Button else ""

func _snapshot() -> Dictionary:
	var lab := _lab()
	return {"mode": Progress.mode(), "speed": lab.tele.speed if lab != null and lab.tele != null else 0.0, "rm": Settings.reduced_motion, "tel": Settings.telemetry, "node": str(app.campaign_node)}

func _check_expect(e: Dictionary, before: Dictionary) -> void:
	var ex: Dictionary = e.get("expect", {})
	for k in ex:
		match k:
			"text":
				for id in ex[k]:
					var t := _control_state_text(str(id))
					if t.to_lower() != str(ex[k][id]).to_lower(): _fail("the text of %s is '%s', expected '%s'" % [id, t, ex[k][id]])
			"mode_changes": if Progress.mode() == before["mode"]: _fail("the difficulty mode did not change")
			"speed_changes": if _lab() == null or _lab().tele.speed == before["speed"]: _fail("the run speed did not change")
			"setting":
				var key := str(ex[k]); var was: bool = before["rm"] if key == "reduced_motion" else before["tel"]
				if (Settings.reduced_motion if key == "reduced_motion" else Settings.telemetry) == was: _fail("the setting %s did not flip" % key)
			"editor_tool": if _lab().editor.tool != str(ex[k]): _fail("the editor tool is '%s', expected '%s'" % [_lab().editor.tool, ex[k]])
			"reference": if _lab()._is_reference() != bool(ex[k]): _fail("the bench is %sthe reference circuit" % ("not " if bool(ex[k]) else ""))
			"enabled":
				var c := _control(str(ex[k]), str(e["to"]))
				if c == null or (c as BaseButton).disabled: _fail("%s is not enabled" % ex[k])
			"disabled":
				var c2 := _control(str(ex[k]), str(e["to"]))
				if c2 != null and not (c2 as BaseButton).disabled: _fail("%s should be disabled" % ex[k])
			"visible":
				var wait_for := str(ex[k])
				if not await _wait(func(): return _control(wait_for, str(e["to"])) != null, 150.0 if bool(e.get("slow", false)) else 20.0): _fail("%s did not appear" % wait_for)
			"gone":
				if _control(str(ex[k]), str(e["to"])) != null: _fail("%s is still on screen" % ex[k])
			_: _fail("unknown expectation '%s'" % k)

# ---------------------------------------------------------------------------------------------------- one edge
func _walk_edge(e: Dictionary) -> void:
	ctx = "edge " + str(e["id"]); cur_known = str(e.get("known_bug", "")); cur_failed = false
	if OS.get_environment("SP_UIGRAPH_ONLY") != "": print("UIGRAPH walking ", e["id"])   # progress for a partial walk (stdout is buffered when redirected: run with stdbuf -oL)
	var from := str(e["from"]); var to := str(e["to"])
	var setup: Dictionary = e.get("setup", {})
	var need_ref := bool(e.get("needs_reference", false))
	_walk_avoid = e.get("path_avoid", []); _walk_level = str(setup.get("level", "$first"))
	var level_tok := str(setup.get("level", "$first"))
	if level_tok == "$dx" and _level("$dx") == "": _fail("the build has no diagnosis case"); return
	if not await _goto(from, setup, need_ref):
		pos_node = ""; _finish_edge(e); return
	var before := _snapshot()
	await _trigger(e, _merge({"level": level_tok}, setup))
	await _frames(2)
	pos_node = ""      # whatever the edge did, the next edge re-navigates unless the return below puts us back
	if e.has("may_finish_to") and not _detect(to) and _detect(str(e["may_finish_to"])): to = str(e["may_finish_to"])   # a fast engine finished the 5-seed test before the first look
	if not _detect(to): _fail("after the action, %s is not what the UI shows (screen %s%s)" % [to, app.cur, _hint_of_state()])
	else:
		var fd: Dictionary = nodes[from]["detect"]; var td: Dictionary = nodes[to]["detect"]
		if from != to and not _implied(to).has(from) and ((fd.has("screen") and td.has("screen") and fd["screen"] != td["screen"]) or str(nodes[from]["kind"]) in ["modal", "overlay", "toast", "tab"]):
			if _detect(from): _fail("%s is still active after the move to %s" % [from, to])
		_arrive(to)
		if _open_modals().size() > 1: _fail("more than one modal is open")
		await _check_expect(e, before)
	if bool(e.get("returns", false)) and not cur_failed: await _check_return(e)
	_finish_edge(e)

func _hint_of_state() -> String:
	var lab := _lab()
	if lab == null: return ""
	var s := ""
	if lab.tele != null: s += "; score passed %s verdict '%s'" % [lab.tele.score.get("passed", null), str(lab.tele.score.get("verdict", ""))]
	s += "; task '%s' view '%s' lesion_on %s" % [lab.task_id, str(lab.insp_body.get_meta("sp_view", "")), lab.lesion_on]
	if lab.banner != null and lab.banner.visible: s += "; banner: " + lab.banner.text
	if lab.celebration != null and lab.celebration._toasts.size() > 0: s += "; toast: " + " / ".join(((lab.celebration._toasts[0]["node"] as Node).find_children("*", "Label", true, false)).map(func(l): return (l as Label).text))
	return s

func _finish_edge(e: Dictionary) -> void:
	seen_edges[e["id"]] = true
	if cur_known != "" and not cur_failed: fails.append("edge %s is marked known_bug but it works: remove the marker" % e["id"])

## Back / Close and Escape must both return to the edge's source. First visit of a node uses the control, the second the key.
func _check_return(e: Dictionary) -> void:
	var to := str(e["to"]); var from := str(e.get("returns_to", e["from"]))
	if e.has("may_finish_to") and not _detect(to) and _detect(str(e["may_finish_to"])): to = str(e["may_finish_to"])
	var bk: Dictionary = nodes[to].get("back", {})
	if bk.is_empty():
		for a in _implied(to):
			if bk.is_empty() and nodes[a].has("back"): bk = nodes[a]["back"]
	if bk.is_empty(): _fail("the graph says the edge returns but node %s declares no back" % to); return
	var tick := int(back_tick.get(to, 0)); back_tick[to] = tick + 1
	var use_key := tick % 2 == 1 and bk.has("key")
	if bk.has("call"):
		if _lab() != null and _lab()._file_dlg != null: _lab()._file_dlg.hide()
		await _frames(2)
	elif use_key: await _key_escape()
	else: await _press_id(str(bk["control"]), to, "back from %s" % to)
	var how := "Escape" if use_key else "Back/Close"
	if e.has("may_finish_to") and _detect(str(e["may_finish_to"])): await _press_id("BtnClose", str(e["may_finish_to"]), "closing the finished test's card")   # Cancel lost the race with the fast engine
	if not _detect(from): _fail("%s from %s does not return to %s (the UI shows screen '%s')" % [how, to, from, app.cur])
	elif str(nodes[to]["kind"]) in ["modal", "screen", "panel"] and not _implied(to).has(from) and not _implied(from).has(to) and _detect(to):
		_fail("%s is still active after %s" % [to, how])
	if _open_modals().size() > 0 and str(nodes[from]["kind"]) != "modal": _fail("a modal is still open after %s: %s" % [how, str(_open_modals().map(func(m): return m.name))])
	if not cur_failed and from == str(e["from"]): pos_node = from; pos_sig = _sig(e.get("setup", {})) + str(bool(e.get("needs_reference", false)))

# ---------------------------------------------------------------------------------------------------- negatives
func _negative(n: Dictionary) -> void:
	ctx = "negative " + str(n["id"]); cur_known = ""; cur_failed = false
	var setup: Dictionary = n.get("setup", {})
	if not await _goto(str(n["node"]), setup, false): pos_node = ""; return
	if app.cur == "tasks" and setup.has("level"): await _select_level(str(setup["level"]))
	var c := _control(str(n["control"]), str(n["node"]))
	match str(n["expect"]):
		"absent": if c != null: _fail("%s is on screen but should be absent: %s" % [n["control"], n.get("why", "")])
		"disabled":
			if c == null: _fail("%s is not on screen" % n["control"])
			elif not (c as BaseButton).disabled: _fail("%s should be disabled: %s" % [n["control"], n.get("why", "")])
	pos_node = ""
