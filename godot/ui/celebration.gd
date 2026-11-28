class_name Celebration
extends Control
## The lab's moments layer (docs/DESIGN-0.3.md section 8): toasts, and the first-pass celebration: a toast, a glow trail that runs down the critical path (sensor
## to motor) and the lab-notebook entry unlocked by the pass. One node over the whole lab; it ignores the mouse and never blocks the bench.
## Reduced motion keeps the toasts and drops the trail.
const TRAIL_LOOP_S := 1.0
const TRAIL_LOOPS := 3

var _toasts: Array = []             # {node, age, life}: the toast on screen (at most one)
var _queue: Array = []              # toasts waiting for their turn: {title, text, col, life}
## () -> bool, set by the lab: true while the result modal is open. A toast never shows over the modal (its title would be covered): it waits, and appears when the modal closes.
var blocked: Callable = Callable()
var _col: VBoxContainer
var _editor: CircuitEditor = null
var _tele: Telemetry = null
var _t := -1.0                      # seconds into a celebration, < 0 = none
var _note := {}
var _note_shown := false
var _note_card: PanelContainer = null  # the notebook entry a first pass unlocks: two lines and "Open notebook", pinned to the editor's bottom-left corner
var _note_age := 0.0
const NOTE_LIFE := 7.0
## () -> void, set by the lab: opens the notebook (the lab keeps its circuit). Unset: the card has no button.
var open_notebook: Callable = Callable()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 60   # above the end card, the hint card and the sheets the lab adds to the overlay later: the notebook entry must not sit behind them
	_col = VBoxContainer.new(); _col.mouse_filter = Control.MOUSE_FILTER_IGNORE; _col.add_theme_constant_override("separation", 8)
	add_child(_col)

## A toast: a title and a line of text, gone after `life` seconds. `col` is its accent.
## Toasts are queued: only one is on screen at a time, the next one appears when it has gone (and none while the result modal is open).
func toast(title: String, text: String, col: Color = Kit.AMBER, life := 5.0) -> void:
	if _col == null: return
	if col.is_equal_approx(Kit.CYAN) or col.is_equal_approx(Kit.CYAN_CB): col = Kit.TEXT   # Prussian blue means inhibition only: neutral messages are ink
	for q in _queue:
		if str(q["title"]) == title and str(q["text"]) == text: return   # the same message twice in a row is one message
	_queue.append({"title": title, "text": text, "col": col, "life": life})
	while _queue.size() > 6: _queue.pop_front()
	_pump()

func _is_blocked() -> bool: return blocked.is_valid() and bool(blocked.call())

## Show the next queued toast when none is on screen and the modal is not up.
func _pump() -> void:
	if _col == null or not _toasts.is_empty() or _queue.is_empty() or _is_blocked(): return
	var q: Dictionary = _queue.pop_front()
	_show_toast(str(q["title"]), str(q["text"]), q["col"], float(q["life"]))

func _show_toast(title: String, text: String, col: Color, life: float) -> void:
	var pn := PanelContainer.new(); Kit.ident(pn, "Toast"); pn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pn.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL_HI, col, 2, 12, 12 if Layout.phone else 16, true))
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 2); v.mouse_filter = Control.MOUSE_FILTER_IGNORE; pn.add_child(v)
	v.add_child(Kit.shout(title, 26 if not Layout.phone else 20, col))
	var l := Kit.label(text, 17 if not Layout.phone else 15, Kit.TEXT, true); l.custom_minimum_size.x = 520.0 if not Layout.phone else 440.0; v.add_child(l)
	_col.add_child(pn); _toasts.append({"node": pn, "age": 0.0, "life": life})

func clear_toasts() -> void:
	for t in _toasts: (t["node"] as Node).queue_free()
	_toasts.clear(); _queue.clear()
	if _note_card != null: _note_card.queue_free(); _note_card = null

## The first sentence of `text` (the notebook entry's lead), for a two-line card. The full entry, citation and all, is in the notebook.
static func lead(text: String) -> String:
	var t := text.strip_edges(); var cut := -1
	for mark in [". ", "! ", "? "]:
		var i := t.find(mark)
		if i > 0 and (cut < 0 or i < cut): cut = i
	return t.substr(0, cut + 1) if cut > 0 else t

## The notebook card: "Notebook: <title>", one line of the entry, and "Open notebook →", pinned to the bottom-left of the circuit editor so it
## never covers the circuit's middle, the body view or the score. Fades after NOTE_LIFE seconds; a new pass replaces it.
func _show_note(title: String, text: String) -> void:
	if _note_card != null: _note_card.queue_free()
	var pn := PanelContainer.new(); Kit.ident(pn, "NotebookToast"); pn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pn.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL_HI, Kit.TEXT, 2, 4, 10 if Layout.phone else 14, true))
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 4); v.mouse_filter = Control.MOUSE_FILTER_IGNORE; pn.add_child(v)
	var w := 380.0 if Layout.phone else 460.0
	var hl := Kit.italic("Notebook: " + title, 20 if not Layout.phone else 17, Kit.TEXT); hl.custom_minimum_size.x = w; hl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; hl.clip_text = true; v.add_child(hl)
	var l := Kit.label(lead(text), 16 if not Layout.phone else 15, Kit.TEXT_SOFT, true); l.custom_minimum_size.x = w; l.max_lines_visible = 1 if Layout.phone else 2; l.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS; v.add_child(l)
	if open_notebook.is_valid():
		var b := Kit.btn("Open notebook →", func(): open_notebook.call(), "panel", 17); Kit.ident(b, "BtnOpenNotebook"); b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN; b.mouse_filter = Control.MOUSE_FILTER_STOP; v.add_child(b)
	add_child(pn); _note_card = pn; _note_age = 0.0
	_place_note()

## Take the notebook card away now (the tutorial does, when it moves on: the card is about the step before and would cover the next one).
func dismiss_note() -> void:
	if _note_card != null: _note_card.queue_free(); _note_card = null

func _place_note() -> void:
	if _note_card == null: return
	var ms := _note_card.get_combined_minimum_size(); _note_card.size = ms
	var r := Rect2(Vector2(12, size.y - 12), Vector2.ZERO)
	if _editor != null and is_instance_valid(_editor) and _editor.is_inside_tree():
		var g := _editor.get_global_rect(); r = Rect2(g.position - get_global_rect().position, g.size)
		_note_card.position = Vector2(r.position.x + 12.0, r.end.y - ms.y - 12.0)
	else: _note_card.position = Vector2(12.0, size.y - ms.y - 12.0)

## Start the first-pass celebration on `editor` / `tele`: `path` is the critical path (Circuits.critical_path), `note` the notebook entry (Task::notebook()).
## It never blocks input and never covers the bench: a glow runs along the path from the sensor to the motor, a short toast says what happened, and the notebook card
## (small, in a corner) offers the entry the pass unlocked. The run is not slowed and the view does not move.
func first_pass(editor: CircuitEditor, tele: Telemetry, path: Array, note: Dictionary) -> void:
	if _t >= 0.0: return
	_editor = editor; _tele = tele; _note = note; _note_shown = false; _t = 0.0
	GameAudio.event("celebrate")
	toast("First pass", "Score %d of 100. The glow shows the path your signal took." % int(roundf(float(tele.score.get("value", 100.0)))), Kit.GREEN, 4.0)
	if Kit.motion() or OS.get_environment("SP_CELEB") != "":   # the dev hook shows the motion even where screenshots turn it off
		editor.trail = path; editor.trail_u = 0.0 if path.size() >= 2 else -1.0

func active() -> bool: return _t >= 0.0

func _process(dt: float) -> void:
	if _col != null: _col.position = Vector2((size.x - _col.size.x) * 0.5, 150.0 if not Layout.phone else 44.0)   # positioned by hand: the layer's own size is only known once it is in the tree
	var held := _is_blocked()
	if _col != null: _col.visible = not held   # the result modal is up: the toast on screen waits (its clock stops) instead of covering the modal's title
	if not held: _pump()
	for i in range(_toasts.size() - 1, -1, -1):
		if held: break
		var t: Dictionary = _toasts[i]; t["age"] = float(t["age"]) + dt
		var left := float(t["life"]) - float(t["age"])
		if left < 0.0: (t["node"] as Node).queue_free(); _toasts.remove_at(i)
		elif left < 0.5: (t["node"] as Control).modulate.a = left / 0.5
	if _note_card != null:
		if held: _note_card.visible = false
		else:
			_note_card.visible = true; _note_age += dt; _place_note()
			var left := NOTE_LIFE - _note_age
			if left < 0.0: _note_card.queue_free(); _note_card = null
			elif left < 0.6: _note_card.modulate.a = left / 0.6
	if _t < 0.0: return
	_t += dt
	if _editor != null and is_instance_valid(_editor) and _editor.trail_u >= 0.0:
		var loop := _t / TRAIL_LOOP_S
		_editor.trail_u = -1.0 if loop >= float(TRAIL_LOOPS) else fposmod(loop, 1.0)
		if _editor.trail_u < 0.0: _editor.trail = []
	if not _note_shown and _t >= 1.0:
		_note_shown = true
		if str(_note.get("title", "")) != "": _show_note(str(_note["title"]), str(_note.get("text", "")))
	if _t >= 3.2:
		_t = -1.0
		if _editor != null and is_instance_valid(_editor): _editor.trail_u = -1.0; _editor.trail = []

## Stop a celebration at once (the circuit was edited or reloaded): the trail goes out.
func abort() -> void:
	_t = -1.0
	if _editor != null and is_instance_valid(_editor): _editor.trail_u = -1.0; _editor.trail = []
