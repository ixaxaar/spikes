class_name CircuitEditor
extends Control
## The circuit editor and the live circuit view in one, drawn as a Cajal plate on engineering graph paper: neurons are Golgi-stained somata with inked
## dendrites (sienna excitatory, Prussian blue inhibitory) that spread a watercolour stain on a spike, projections are inked axons ending in an arrowhead
## (excitatory) or a bar (inhibitory) with ink beads that travel at (a slowed-down) synaptic delay, sensors and motors are index-card tabs left and right.
##
## Large circuits stay readable: a population of more than ENSEMBLE_N cells is one stained ellipse with its name and count inside and a ring of sample cells
## that flash on spikes; numbered channels of one kind ("cue0" .. "cue15") collapse into one bus card with an activity comb (click to open it); every
## population outline (with room for its label) is pushed POP_GAP px clear of the others; labels are placed where they hide least, on a paper halo, drawn last;
## a self-loop goes on the free side. All of this is display only: the circuit's positions are never changed by it.
##
## Editing: drag a cell to move it (or the whole selection), drag a sensor or motor card to move it (kept in the circuit's meta.editor.cards as an offset from where the
## layout puts it, so it stays put and undo takes it back), drag from a cell's rim to another cell to connect, click an axon to edit it, click the dashed link between a
## sensor card and a cell, or a cell and a motor card, to select that one link (Delete or the inspector's Disconnect removes it), shift-click or drag a box on
## the empty bench to select several, right-click deletes. Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y undo and redo (every structural change, weight or parameter edit and
## drag is one step, 100 kept), Ctrl+C / Ctrl+V / Ctrl+D copy, paste and duplicate cells with their internal connections, Ctrl+A selects every group.
## View: the wheel or a pinch zooms (ZOOM_MIN .. ZOOM_MAX) around the pointer, middle-drag or Space+drag pans, F fits; the readout in the corner (click: fit).
## Keyboard and pad: Tab / arrows / D-pad move a cursor over cards, cells and axons; Enter / A selects (and completes a wire), W / X starts a wire from the
## cursor, I / Y opens the inspector, Delete removes; Space (Start) runs or pauses, C checks, R resets (the `command` signal; the lab does them).
##
## Geometry is cached in "scaled space" (model * view_scale, plus the display offsets): a pan only moves the canvas transform, a redraw rebuilds nothing.
## Hit tests go through a grid index. Public geometry for overlays (tutorial, celebration) is in editor-local pixels: card_rect, pop_rect, proj_at, proj_mid.
signal structure_changed          # populations / projections / channels added or removed: the lab must reload the engine
signal selection_changed(sel: Dictionary)
signal moved                       # editor positions changed (no reload needed)
signal lesion_clicked(h: Dictionary)   # lesion lab: a population, axon or sensor card was clicked
signal history_changed             # the undo / redo stacks changed (the Undo / Redo buttons)
signal circuit_restored            # undo / redo replaced the circuit's content in place (the lab re-reads the reference lock from it)
signal command(name: String)       # a shortcut on the bench for the lab: "run", "check", "reset", "inspect"
signal view_changed                # zoom or pan changed

const ZOOM_MIN := 0.15
const ZOOM_MAX := 3.0
const UNDO_CAP := 100
const ENSEMBLE_N := 12             # more cells than this: one stained ellipse
const POP_GAP := 24.0              # px between population outlines (label room included)
const BUS_MIN := 4                 # numbered channels of one kind that collapse into one bus card
const RING_MAX := 24               # sample cells on an ensemble's ring
const COMMIT_S := 0.4              # a burst of edits (a slider drag) closer together than this is one undo step
const GRID := 64.0                 # hit-test grid cell (px)

var tele: Telemetry = null
var circuit := {}
var sel := {}                      # {t:"pop", id} | {t:"proj", i} | {t:"in", name} | {t:"out", name} | {t:"ilink" | "olink", name, pop, names}: what the inspector shows (a link: one sensor-to-cell or cell-to-motor connection)
var msel := {}                     # the selected populations (id -> true); sel is the one of them the inspector shows
var tool := "select"               # select | connect
var editable := true
var view_scale := 1.0
var view_off := Vector2.ZERO
var _hover := {}
var _paper: Control                 # behind the editor: the graph paper (redrawn when the view moves)
var _ink: Control                   # behind the editor, above the paper: axons and resting cells, drawn once per geometry (pan and zoom move it as a transform)
var _gen := 0                       # bumped at every geometry rebuild: the ink layer's cache key
var _ink_key := []; var _paper_key := []
var _drag := {}                    # {mode: move|cardmove|connect|pan|band, ...}
var _connect_from := {}            # tool == connect: the first tap
var _cards_g := {}                   # channel card rects (scaled space) by "in:name" / "out:name" (a member of a closed bus: the bus card)
var _rg := 20.0                     # cell radius in geometry space (on screen: _rg times the view's zoom)
## Compatibility for overlays (the tutorial): the cell radius in screen px, as drawn now.
var _r: float:
	get: return _rg * (_world_xf().get_scale().x if not _g.is_empty() else 1.0)
## Compatibility for overlays (the tutorial): the channel cards' rects in canvas (screen) space, as drawn now, by "in:name" / "out:name"
## (a channel inside a closed bus maps to the bus card).
var _cards: Dictionary:
	get:
		_geo(); var out := {}
		for k in _cards_g: out[k] = _g2s_rect(_cards_g[k])
		return out
var _fit_pending := true
var lesion_mode := false           # lesion lab: clicks cut and silence instead of selecting and dragging
var lesions := {}                  # the lab's lesion set ("proj:<i>", "pop:<id>", "in:<name>"): drawn cut / silenced
var hint_target := ""              # v0.3 hint tier 2: the population, channel ("in:<name>" / "out:<name>") or axon ("pre>post") to point at: a pulsing outline
var verdict_ok := false            # the verdict target is a right answer (diagnosis solved): green, not red
var verdict_target := ""           # v0.3 verdict highlight: the element the failed score is about glows red
var trail: Array = []              # v0.3 first-pass celebration: the critical path ["in:<name>", <pop>, ..., "out:<name>"]
var trail_u := -1.0                # head of the glow trail along it, 0..1 (< 0 = no trail)
var _push_t := -1.0                # camera push (celebration): seconds into it
var _push_dur := 1.0
var _push_k := 0.0
var _push_now := 1.0
var inset_bottom := 0.0            # px at the bottom covered by the phone inspector sheet: fit() keeps the neurons above it
var blocked := Callable()          # the lab: true while a modal covers the bench (the bench's shortcuts are off)
var _bus_open := {}                # "in:<stem>" / "out:<stem>" -> true: that bus is shown as its member cards
var _g := {}                       # the geometry cache (see _build)
var _gkey := []
var _rev := 0                      # bumped by every change of the circuit
var _undo: Array = []              # circuit texts before each step
var _redo: Array = []
var _base := ""                    # the circuit text as of the last committed step
var _pending := -1.0               # seconds since an uncommitted edit (-1: none)
var _attached: Variant = null      # the circuit Dictionary last attached (another one = the bench was replaced)
var _cursor := {}                  # keyboard / pad cursor: a hit dictionary
var _kbd := false                  # the cursor is in use (shown)
var _wire := {}                    # keyboard / pad wiring: the source picked with W / X
var _space := 0                    # Space: 0 up, 1 held, 2 held and used to pan
var _touch := {}                   # touch index -> position (pinch)
var _pinch := {}
var _note := ""                    # a short message drawn in the corner (Copied, Pasted, Imported ...)
var _note_t := -1.0
var _zoom_ms := -100000            # the last zoom step: while zooming, the cached geometry is drawn scaled and rebuilt once the zoom rests
var _stale := false

func _ready() -> void:
	clip_contents = true; mouse_filter = Control.MOUSE_FILTER_STOP; focus_mode = Control.FOCUS_ALL
	_paper = Control.new(); _paper.name = "Paper"; _paper.mouse_filter = Control.MOUSE_FILTER_IGNORE; _paper.show_behind_parent = true
	_paper.set_anchors_preset(Control.PRESET_FULL_RECT); add_child(_paper, false, Node.INTERNAL_MODE_FRONT)
	_paper.draw.connect(func(): Gfx.graph_paper(_paper, Rect2(Vector2.ZERO, size), clampf(22.0 * view_scale, 12.0, 40.0), Gfx.SHEET, view_off))
	_ink = Control.new(); _ink.name = "Ink"; _ink.mouse_filter = Control.MOUSE_FILTER_IGNORE; _ink.show_behind_parent = true
	add_child(_ink, false, Node.INTERNAL_MODE_FRONT); _ink.draw.connect(_draw_ink)
	resized.connect(func(): _fit_pending = true)
	focus_entered.connect(queue_redraw); focus_exited.connect(func(): _kbd = false; queue_redraw())

func _process(dt: float) -> void:
	if _push_t >= 0.0: _push_step(dt)
	if _pending >= 0.0:
		_pending += dt
		if _pending >= COMMIT_S and _drag.is_empty(): commit_now()
	if _note_t >= 0.0:
		_note_t -= dt
		if _note_t < 0.0: _note = ""
		queue_redraw()
	if _stale: queue_redraw()
	if is_visible_in_tree() and _ink != null: _sync_layers()
	if is_visible_in_tree() and ((tele != null and (tele.sim != null or tele.running)) or hint_target != "" or verdict_target != "" or trail_u >= 0.0): queue_redraw()

## Camera push: zoom in on the canvas centre by `k` (0.15 = 15%) and back over `dur` seconds, easing out and in (a transform: nothing is rebuilt).
func push(k: float, dur: float) -> void:
	if _push_t >= 0.0 or _fit_pending: return
	_push_t = 0.0; _push_dur = maxf(dur, 0.1); _push_k = k

func _push_step(dt: float) -> void:
	_push_t += dt
	var u := clampf(_push_t / _push_dur, 0.0, 1.0); _push_now = 1.0 + _push_k * sin(PI * u)
	if u >= 1.0: _push_t = -1.0; _push_now = 1.0
	queue_redraw()

func min_text_px() -> float: return float(Kit.fs(14)) * Kit.ppl

## A short message in the canvas corner for `secs` seconds.
func note(t: String, secs := 3.0) -> void: _note = t; _note_t = secs; queue_redraw()

func set_circuit(c: Dictionary, t: Telemetry) -> void:
	tele = t
	var fresh := not is_same(c, _attached)
	circuit = c
	if fresh:
		_tidy(c)
		var txt := _snap(c)
		if _attached != null and _base != "" and txt != _base: _push_undo(_base); _redo.clear()   # the lab replaced the bench (Reference, Empty bench, Load, a slot): one step back
		_base = txt; _pending = -1.0
		sel = {}; msel = {}; _cursor = {}; _wire = {}; _connect_from = {}; _drag = {}; _fit_pending = true
		_attached = c
		history_changed.emit()
	else:
		Circuits.ensure_pos(c)
		_clean_sel()
	_rev += 1; queue_redraw()

func fit() -> void: _fit_pending = true; queue_redraw()

## A newly attached circuit: positions filled in (a long row of automatic positions is laid out as a grid instead), and its numbers made what a save would read
## back (ints outside the integer fields become floats), so that undo can restore it byte for byte.
func _tidy(c: Dictionary) -> void:
	Circuits.ensure_pos(c)
	_grid_auto_rows(c)
	var d := Circuits.parse(Circuits.to_json(c))
	if not d.is_empty():
		c.clear(); c.merge(d)

## Populations still at Circuits.auto_pos (a file without positions gets one long row: 60 groups are 11000 units wide) are laid out in a grid of about the
## canvas's shape to the right of the placed ones. Only when at least 8 groups are in that row; a circuit with real positions is never touched.
static func _grid_auto_rows(c: Dictionary) -> void:
	var pops: Array = c.get("populations", []); var auto := []
	for pi in pops.size():
		var p: Dictionary = pops[pi]; var n := Circuits.pop_n(p); var pos: Array = p.get("pos", []); var is_auto := pos.size() == n
		for k in mini(n, pos.size()):
			var a := Circuits.auto_pos(pi, k, n)
			if not (pos[k] is Array and (pos[k] as Array).size() >= 2 and is_equal_approx(float(pos[k][0]), a.x) and is_equal_approx(float(pos[k][1]), a.y)): is_auto = false; break
		if is_auto: auto.append(pi)
	if auto.size() < 8: return
	var x0 := 160.0; var y0 := 120.0
	for pi in pops.size():
		if auto.has(pi): continue
		for q in pops[pi].get("pos", []): x0 = maxf(x0, float(q[0]) + 140.0)
	var cols := clampi(roundi(sqrt(float(auto.size()) * 1.6 * 150.0 / 226.0)), 1, 40)   # about the canvas's shape (1.6:1) with steps of 226 x 150 units
	var row_h := 0.0; var x := x0; var y := y0
	for i in auto.size():
		var p: Dictionary = pops[auto[i]]; var n := Circuits.pop_n(p); var per := mini(n, 5); var rows := ceili(float(n) / 5.0)
		if i > 0 and i % cols == 0: x = x0; y += row_h + 150.0; row_h = 0.0
		var pos := []
		for k in n: pos.append([x + float(k % 5) * 34.0, y + float(k / 5) * 34.0])
		p["pos"] = pos
		x += maxf(190.0, float(per) * 34.0 + 90.0); row_h = maxf(row_h, float(rows - 1) * 34.0)

func _clean_sel() -> void:
	if not sel.is_empty() and not _sel_exists(sel): sel = {}
	for id in msel.keys():
		if Circuits.pop_index(circuit, str(id)) < 0: msel.erase(id)

func _sel_exists(s: Dictionary) -> bool:
	match str(s.get("t", "")):
		"pop": return Circuits.pop_index(circuit, str(s.get("id", ""))) >= 0
		"proj": return int(s.get("i", -1)) >= 0 and int(s.get("i", -1)) < (circuit.get("projections", []) as Array).size()
		"in", "out":
			for ch in circuit.get("inputs" if s["t"] == "in" else "outputs", []):
				if str(ch.get("name", "")) == str(s.get("name", "")): return true
		"ilink", "olink":
			var is_in: bool = str(s["t"]) == "ilink"
			for ch in circuit.get("inputs" if is_in else "outputs", []):
				if str(ch.get("name", "")) != str(s.get("name", "")): continue
				for x in ch.get("targets" if is_in else "neurons", []):
					if str(Circuits.proj_pop(x)) == str(s.get("pop", "")): return true
	return false

# ---------- undo / redo ----------
## The circuit as text in the form a save reads back (Circuits.to_json, with ints outside the integer fields written as floats): equal texts are equal circuits.
static func _snap(c: Dictionary) -> String: return JSON.stringify(_canon(c, ""), "  ")

static func _canon(v: Variant, key: String) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in v: out[k] = _canon(v[k], str(k))
		return out
	if v is Array:
		var out := []
		if key == "edges":
			for e in v:
				var ee := []
				for i in (e as Array).size(): ee.append(int(e[i]) if i < 2 else (float(e[i]) if e[i] is int else e[i]))
				out.append(ee)
			return out
		for x in v: out.append(_canon(x, key))
		return out
	if key in Circuits.INT_KEYS and (v is float or v is int) and is_equal_approx(float(v), roundf(float(v))): return int(v)
	if v is int: return float(v)
	return v

## The lab calls this for every edit (LabScreen._on_structure): a burst of them is committed as one step COMMIT_S after the last.
func edit_pending() -> void:
	_rev += 1; _pending = 0.0; history_changed.emit(); queue_redraw()

## Commit what changed since the last step as one undo step (no-op when nothing did).
func commit_now() -> void:
	var was := _pending >= 0.0; _pending = -1.0
	if circuit.is_empty(): return
	var t := _snap(circuit)
	if t == _base:   # nothing new (the lab's reload after an undo): Redo is available again
		if was: history_changed.emit()
		return
	_push_undo(_base); _base = t; _redo.clear(); history_changed.emit()

func _push_undo(t: String) -> void:
	if t == "": return
	_undo.append(t)
	while _undo.size() > UNDO_CAP: _undo.pop_front()

func can_undo() -> bool: return editable and (not _undo.is_empty() or _pending >= 0.0)
func can_redo() -> bool: return editable and not _redo.is_empty() and _pending < 0.0
func undo_depth() -> int: return _undo.size()

func undo() -> bool:
	if not editable: return false
	commit_now()
	if _undo.is_empty(): return false
	_redo.append(_base); _base = _undo.pop_back(); _restore(_base); note("Undone"); return true

func redo() -> bool:
	if not editable: return false
	commit_now()
	if _redo.is_empty(): return false
	_undo.append(_base); _base = _redo.pop_back(); _restore(_base); note("Redone"); return true

func _restore(t: String) -> void:
	var d := Circuits.parse(t)
	if d.is_empty(): return
	circuit.clear(); circuit.merge(d)
	_rev += 1; _drag = {}; _wire = {}; _connect_from = {}
	_clean_sel()
	circuit_restored.emit(); structure_changed.emit(); selection_changed.emit(sel); history_changed.emit(); queue_redraw()

# ---------- geometry ----------
func _neurons() -> Array: return Circuits.neurons(circuit)

func _bbox(ns: Array) -> Rect2:
	if ns.is_empty(): return Rect2(0, 0, 300, 200)
	var lo := Vector2(1e9, 1e9); var hi := Vector2(-1e9, -1e9)
	for n in ns:
		lo = lo.min(n["pos"]); hi = hi.max(n["pos"])
	return Rect2(lo, hi - lo)

func _card_size() -> Vector2:
	var k := clampf(Kit.f(), 0.85, 1.0)
	var w := clampf(size.x * 0.135, 112.0, 150.0 * k) if size.x > 0.0 else 150.0 * k   # narrower on a small bench
	return Vector2(w * _card_k, maxf(52.0 * k, float(Kit.fs(14)) * 2.0 + 18.0))

## Card width factor: 1, or less when nothing fits at full width on a small bench (1366x768, Large text): _do_fit narrows the cards before it gives up zoom.
var _card_k := 1.0

## Channel cards stack in one column down each side; many cards go in several columns so none run off the bench.
func _card_cols(count: int) -> int:
	if count <= 0 or inset_bottom > 0.0: return 1   # with the phone sheet open the canvas is a strip: one column, squeezed
	var avail := maxf(size.y - 40.0 - inset_bottom, 120.0)   # cards may overlap like a fanned stack (each still shows its name) before a second column opens
	return clampi(ceili(float(count) * (_card_size().y * 0.62) / avail), 1, 4)

## Centre of card `i` of `count` on one side (side -1 left, +1 right), `x0` the x of the column nearest the neurons.
func _card_centre(count: int, i: int, side: int, x0: float, cy: float, pitch: float) -> Vector2:
	var cols := _card_cols(count); var per := ceili(float(count) / float(cols)); var col := i / per; var row := i % per
	var rows_here := mini(per, count - col * per)
	var shown_col := col if side > 0 else (cols - 1 - col)   # reading order: on the left the first column is the OUTER one
	return Vector2(x0 + float(side) * float(shown_col) * (_card_size().x + 14.0), cy + (float(row) - float(rows_here - 1) * 0.5) * pitch)

## A model position (circuit "pos", in µm) to canvas (screen) px, as drawn now: the layout may move a group (spacing, grid rows), so a point is
## carried with the nearest neuron (exact at a neuron's own position; a large group's ensemble centre stands for its cells).
func to_screen(m: Vector2) -> Vector2:
	var g := _geo()
	if g.is_empty(): return _raw_to_screen(m)
	var best := Vector2.INF; var bd := INF
	for p in g["pops"]:
		var pi: int = p["pi"]; var mp: Array = (circuit["populations"][pi] as Dictionary).get("pos", [])
		var pts: PackedVector2Array = p.get("pts", PackedVector2Array())   # an ensemble has none: its centre stands for every cell
		for k in mp.size():
			var q := Vector2(float(mp[k][0]), float(mp[k][1])); var d := q.distance_squared_to(m)
			if d < bd:
				bd = d
				var at: Vector2 = pts[k] if k < pts.size() else p["c"]
				best = _g2s(at) + (m - q) * view_scale
	return best if best != Vector2.INF else _raw_to_screen(m)
func _raw_to_screen(m: Vector2) -> Vector2: return m * view_scale + view_off
func to_model(s: Vector2) -> Vector2: return (s - view_off) / view_scale

## The geometry of the current circuit, view scale and canvas size (rebuilt only when one of them changed).
func _geo() -> Dictionary:
	if circuit.is_empty(): return {}
	if _fit_pending: _do_fit()
	var key := [_rev, view_scale, size, inset_bottom, Kit.f(), _sig(), _card_k]
	_stale = false
	if key != _gkey or _g.is_empty():
		var only_zoom: bool = not _g.is_empty() and _gkey.size() == key.size() and key[0] == _gkey[0] and key[2] == _gkey[2] and key[3] == _gkey[3] and key[5] == _gkey[5]
		if only_zoom and Time.get_ticks_msec() - _zoom_ms < 160: _stale = true; return _g
		_g = _build(); _gkey = key; _gen += 1
	return _g

## Cached geometry was built at _g["scale"]: the factor that maps it to the current zoom (1 except while a zoom is in progress).
func _k() -> float: return view_scale / float(_g.get("scale", view_scale)) if not _g.is_empty() else 1.0
func _s2g(p: Vector2) -> Vector2: return (p - view_off) / _k()
func _g2s(q: Vector2) -> Vector2: return q * _k() + view_off
func _g2s_rect(r: Rect2) -> Rect2: var k := _k(); return Rect2(r.position * k + view_off, r.size * k)

## A cheap signature of the circuit's shape: catches an edit made behind the editor's back before the lab's reload attaches it.
func _sig() -> Array:
	return [(circuit.get("populations", []) as Array).size(), Circuits.neuron_count(circuit), (circuit.get("projections", []) as Array).size(), (circuit.get("inputs", []) as Array).size(), (circuit.get("outputs", []) as Array).size()]

## Fit: the largest zoom (up to 2x) at which the populations as drawn (labels, ensembles and gaps do not shrink with the zoom) and the card columns fit the
## canvas, found by bisection; when even ZOOM_MIN does not fit (hundreds of groups in a small window) the block is centred at ZOOM_MIN and can be panned.
func _do_fit() -> void:
	_fit_pending = false; _card_k = 1.0
	var ns := _neurons()
	var bb := _bbox(ns).grow(46.0)
	var avail := _fit_avail()
	var s0 := clampf(minf(avail.size.x / maxf(bb.size.x, 1.0), avail.size.y / maxf(bb.size.y, 1.0)), ZOOM_MIN, 2.0)
	var fits := func(sc: float) -> Rect2:
		view_scale = sc; var g := _build(true); return g.get("bb", Rect2(0, 0, 1, 1))
	var room := _fit_room()   # the block's bounding box includes the cards
	var ub: Rect2 = fits.call(s0)
	if ub.size.x > room.size.x or ub.size.y > room.size.y:
		var lo := ZOOM_MIN; var hi := s0; var good := -1.0
		for it in 7:
			var mid := (lo + hi) * 0.5; var r: Rect2 = fits.call(mid)
			if r.size.x <= room.size.x and r.size.y <= room.size.y: good = mid; lo = mid
			else: hi = mid
		if good > 0.0: ub = fits.call(good)
		else:   # nothing fits (a small window, many groups and channels): narrower cards and the zoom whose layout overflows least, centred (pan for the rest)
			# Candidates: card width factors x nine zooms. If one fits (overflow <= 1) the largest zoom among them wins; else the least overflow, but a zoom is not thrown away for
			# a sliver (7 px of overflow at 15% zoom is no choice): the largest zoom within 3% of the least overflow wins. A block whose labels do not fit at all is never chosen
			# while another candidate fits them. Huge circuits (hundreds of groups) keep the full cards: they are a rounding error there and every candidate is a rebuild.
			var cks := [1.0, 0.9, 0.8] if (circuit.get("populations", []) as Array).size() <= 24 else [1.0]
			var cand := []; var bo := INF
			for ck in cks:
				_card_k = ck
				for k in 9:
					var sc := lerpf(ZOOM_MIN, maxf(s0, ZOOM_MIN), float(k) / 8.0); view_scale = sc; var gk := _build(true)
					var r: Rect2 = gk.get("bb", room); var rb: Rect2 = gk.get("bbp", r)
					var ob := maxf(rb.size.x / room.size.x, rb.size.y / room.size.y)
					var over := maxf(r.size.x / room.size.x, r.size.y / room.size.y) if ob <= 1.0 else 100.0 + ob
					cand.append([over, sc, ck]); bo = minf(bo, over)
			var lim := 1.0 if bo <= 1.0 else bo + 0.03
			var best := ZOOM_MIN; var best_ck := 1.0; var picked := false
			for c in cand:
				if float(c[0]) > lim + 1e-6: continue
				if not picked or float(c[1]) > best + 1e-6 or (absf(float(c[1]) - best) < 1e-6 and float(c[2]) > best_ck): best = float(c[1]); best_ck = float(c[2]); picked = true
			_card_k = best_ck; view_scale = best; var gb := _build(true); ub = gb.get("bb", ub); var bp: Rect2 = gb.get("bbp", ub)
			var off := room.get_center() - ub.get_center()   # centred, then moved so the neuron block and its labels stay in view (cards may be a pan away)
			for ax in 2:
				if bp.size[ax] >= room.size[ax]: off[ax] = room.get_center()[ax] - bp.get_center()[ax]
				else: off[ax] = clampf(off[ax], room.position[ax] - bp.position[ax], room.end[ax] - bp.end[ax])
			view_off = off; _gkey = []; view_changed.emit(); return
	view_off = room.get_center() - ub.get_center()
	_gkey = []; view_changed.emit()

## The room for the neuron block: the canvas less the card columns and the phone sheet.
func _fit_avail() -> Rect2:
	var cw := _card_size().x
	var ni := _items_count("in"); var no := _items_count("out")
	var side_in := float(_card_cols(ni)) * (cw + 14.0) + 62.0 if ni > 0 else 0.0
	var side_out := float(_card_cols(no)) * (cw + 14.0) + 62.0 if no > 0 else 0.0
	var top := 12.0; var bottom := (40.0 if inset_bottom > 0.0 else 34.0) + inset_bottom
	return Rect2(12.0 + side_in, top, maxf(size.x - 24.0 - side_in - side_out, 80.0), maxf(size.y - top - bottom, 80.0))

## The whole canvas less a margin and the phone sheet (what the block and its cards together must fit).
func _fit_room() -> Rect2:
	var bottom := (40.0 if inset_bottom > 0.0 else 30.0) + inset_bottom
	return Rect2(8.0, 8.0, maxf(size.x - 16.0, 80.0), maxf(size.y - 8.0 - bottom, 80.0))

func _items_count(side: String) -> int: return _card_items(side).size()

## The cards of one side in order: {type card|bus|head, side, names, stem, key}. A numbered family (Circuits.channel_family) of BUS_MIN or more channels
## of one kind is one "bus" card while closed, else a "head" tab (click to close) followed by its member cards.
func _card_items(side: String) -> Array:
	var key := "inputs" if side == "in" else "outputs"
	var chans: Array = circuit.get(key, [])
	var re := RegEx.new(); re.compile("^(.*?)(\\d+)$")
	var fam := {}; var kinds := {}
	for ch in chans:
		var nm := str(ch.get("name", "")); var m := re.search(nm)
		if m == null: continue
		var st := m.get_string(1)
		if not fam.has(st): fam[st] = []; kinds[st] = str(ch.get("kind", ""))
		(fam[st] as Array).append(nm)
		if str(ch.get("kind", "")) != str(kinds[st]): kinds[st] = "*mixed*"
	var out := []; var done := {}
	for ch in chans:
		var nm := str(ch.get("name", "")); var m := re.search(nm)
		var st := m.get_string(1) if m != null else ""
		if m != null and (fam[st] as Array).size() >= BUS_MIN and str(kinds[st]) != "*mixed*":
			if done.has(st): continue
			done[st] = true
			var names: Array = fam[st]
			var bk := side + ":" + st
			if _bus_open.has(bk):
				out.append({"type": "head", "side": side, "names": names, "stem": st, "key": "bus:" + bk})
				for n2 in names: out.append({"type": "card", "side": side, "names": [n2], "stem": st, "key": side + ":" + str(n2)})
			else: out.append({"type": "bus", "side": side, "names": names, "stem": st, "key": "bus:" + bk})
			continue
		out.append({"type": "card", "side": side, "names": [nm], "stem": "", "key": side + ":" + nm})
	return out

## Cell radius in px: scaled to the nearest-neighbour spacing of the drawn cells so dense groups stay readable.
func _calc_radius(pts: PackedVector2Array) -> float:
	var nn := 1e9
	for i in pts.size():
		for j in range(i + 1, mini(pts.size(), i + 40)): nn = minf(nn, pts[i].distance_to(pts[j]))
	var base := 26.0 * clampf(view_scale, 0.8, 1.4) * clampf(Kit.f() + 0.25, 0.8, 1.15)
	return clampf(minf(base, nn * 0.42), 8.0, 36.0)

func _label_size(nm: String, n: int, ens: bool) -> Vector2:
	var lz := Kit.fs(16); var fz := Kit.fs(14); var fi := Gfx.serif_italic()
	var nw := fi.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, lz).x
	if ens: return Vector2(maxf(nw, fi.get_string_size("×%d" % n, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x), float(lz + fz) + 6.0)
	var mw := fi.get_string_size((" ×%d" % n) if n > 1 else "", HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x
	return Vector2(nw + mw, float(lz) + 6.0)

## Build the geometry (scaled space). `shapes_only`: just the population shapes and their bounding box (for fit).
func _build(shapes_only := false) -> Dictionary:
	var g := {"scale": view_scale}
	var pops: Array = circuit.get("populations", [])
	var kd := Circuits.kinds(circuit); g["kinds"] = kd
	var ns := _neurons()
	var small_pts := PackedVector2Array()
	var per_pop := []
	for pi in pops.size(): per_pop.append(PackedVector2Array())
	for n in ns:
		var q: Vector2 = (n["pos"] as Vector2) * view_scale
		var arr: PackedVector2Array = per_pop[n["pi"]]; arr.append(q); per_pop[n["pi"]] = arr
	for pi in pops.size():
		if Circuits.pop_n(pops[pi]) <= ENSEMBLE_N: small_pts.append_array(per_pop[pi])
	_rg = _calc_radius(small_pts); g["r"] = _rg
	var lz := Kit.fs(16); var fz := Kit.fs(14)
	var P := []; var ix := {}; var first := 0
	for pi in pops.size():
		var pd: Dictionary = pops[pi]; var n := Circuits.pop_n(pd); var id := str(pd.get("id", ""))
		var pts: PackedVector2Array = per_pop[pi]
		var p := {"id": id, "pi": pi, "n": n, "first": first, "kind": str(kd.get(id, "E")), "ens": n > ENSEMBLE_N, "locked": Circuits.is_locked(pd)}
		first += n
		var lo := pts[0] if pts.size() > 0 else Vector2.ZERO; var hi := lo; var c := Vector2.ZERO
		for q in pts: lo = lo.min(q); hi = hi.max(q); c += q
		c /= maxf(float(pts.size()), 1.0)
		var ls := _label_size(id, n, p["ens"]); p["lsize"] = ls
		if p["ens"]:
			var ext := hi - lo; var asp := clampf((ext.x + 1.0) / (ext.y + 1.0), 0.45, 2.2)
			var rm := (22.0 + 5.5 * sqrt(float(n))) * view_scale
			var rx := rm * sqrt(asp); var ry := rm / sqrt(asp)
			rx = maxf(rx, ls.x * 0.5 / 0.62 + 8.0); ry = maxf(ry, ls.y * 0.5 / 0.6 + 6.0)
			var k := mini(n, RING_MAX)
			var per := PI * (3.0 * (rx + ry) - sqrt((3.0 * rx + ry) * (rx + 3.0 * ry))) * 0.82
			var need := float(k) * 11.0
			if per < need: var s := need / maxf(per, 1.0); rx *= s; ry *= s
			p["c"] = c; p["rx"] = rx; p["ry"] = ry; p["box"] = Rect2(c - Vector2(rx, ry), Vector2(rx, ry) * 2.0)
			p["rad"] = maxf(rx, ry)
		else:
			p["pts"] = pts; p["c"] = c
			if n > 1:
				p["box"] = Rect2(lo, hi - lo).grow(_rg + 9.0); p["rad"] = 0.0
				for q in pts: p["rad"] = maxf(float(p["rad"]), q.distance_to(c))
				p["rad"] = float(p["rad"]) + _rg + 8.0
			else:
				p["box"] = Rect2(c - Vector2(_rg, _rg), Vector2(_rg, _rg) * 2.0); p["rad"] = _rg
		ix[id] = P.size(); P.append(p)
	# push the outlines (each with room for its label underneath) POP_GAP apart
	var boxes := []
	for p in P:
		var b: Rect2 = p["box"]
		if not p["ens"]:
			var ls2: Vector2 = p["lsize"]
			b = b.merge(Rect2(Vector2((p["c"] as Vector2).x - ls2.x * 0.5, b.end.y + 2.0), ls2))
		boxes.append(b.grow(POP_GAP * 0.5))
	var off := _relax(boxes)
	for i in P.size():
		var p: Dictionary = P[i]; var d := off[i]
		if d == Vector2.ZERO: continue
		p["c"] = (p["c"] as Vector2) + d; p["box"] = Rect2((p["box"] as Rect2).position + d, (p["box"] as Rect2).size)
		if p.has("pts"):
			var pts2: PackedVector2Array = p["pts"]
			for k in pts2.size(): pts2[k] += d
			p["pts"] = pts2
	var bb := Rect2()
	for i in P.size():
		var b2: Rect2 = Rect2((boxes[i] as Rect2).position + off[i], (boxes[i] as Rect2).size).grow(-POP_GAP * 0.5)
		bb = b2 if i == 0 else bb.merge(b2)
	if P.is_empty(): bb = Rect2(Vector2(300, 200) * view_scale, Vector2(1, 1))
	g["pops"] = P; g["ix"] = ix
	# cards beside the block
	var items_in := _card_items("in"); var items_out := _card_items("out")
	var cs := _card_size(); var card_w := cs.x; var card_h := cs.y
	var xl := bb.position.x - 48.0 - card_w * 0.5; var xr := bb.end.x + 48.0 + card_w * 0.5
	var cy := bb.get_center().y
	var pitch := card_h + 14.0
	for items in [items_in, items_out]:
		var cnt: int = (items as Array).size()
		if cnt > 0 and cnt <= 4 and _card_cols(cnt) == 1: pitch = maxf(pitch, minf(bb.size.y / float(cnt), card_h * 1.9))
	if _card_cols(items_in.size()) > 1 or _card_cols(items_out.size()) > 1: pitch = card_h + 8.0
	for items in [items_in, items_out]:
		var cnt2: int = (items as Array).size(); var per2 := ceili(float(cnt2) / float(_card_cols(cnt2)))
		if per2 > 1: pitch = minf(pitch, maxf((size.y - 16.0 - inset_bottom - card_h) / float(per2 - 1), card_h * 0.6))
	var items := []; _cards_g = {}
	for side in [-1, 1]:
		var list: Array = items_in if side < 0 else items_out
		for i in list.size():
			var it: Dictionary = list[i]
			var cc := _card_centre(list.size(), i, side, xl if side < 0 else xr, cy, pitch)
			var r := Rect2(cc - cs * 0.5, cs)
			if str(it["type"]) == "head": r = Rect2(Vector2(r.position.x, r.end.y - card_h * 0.55), Vector2(cs.x, card_h * 0.55))
			else:
				var coff := _card_off(str(it["key"])) * view_scale   # a card the player moved: where the layout puts it, plus the offset kept in the circuit
				if coff != Vector2.ZERO: r.position += coff; it["moved"] = true
			it["rect"] = r; it["col"] = _card_col_index(list.size(), i, side)
			items.append(it)
			if str(it["type"]) != "head":
				for nm in it["names"]: _cards_g[str(it["side"]) + ":" + str(nm)] = r
			_cards_g[str(it["key"])] = r
	g["items"] = items
	var full := bb; g["bbp"] = bb.grow(8.0)
	for it in items: full = full.merge(it["rect"])
	g["bb"] = full.grow(8.0)
	if shapes_only: return g
	# ensemble rings
	for p in P:
		if not p["ens"]: continue
		var k := mini(int(p["n"]), RING_MAX); var ring := PackedVector2Array(); var c: Vector2 = p["c"]
		for i in k:
			var a := -PI * 0.5 + TAU * float(i) / float(k)
			ring.append(c + Vector2(cos(a) * float(p["rx"]) * 0.8, sin(a) * float(p["ry"]) * 0.8))
		p["ring"] = ring
		p["dot"] = clampf(minf(float(p["rx"]), float(p["ry"])) * 0.8 * TAU / float(k) * 0.3, 3.0, 7.0)
	# projections; self-loops on the side that hides least
	var projs: Array = circuit.get("projections", [])
	var obstacles := []
	for p in P: obstacles.append(p["box"])
	for it in items: obstacles.append(it["rect"])
	var axons := []; var loops := []; var wref := {}
	for pj in projs.size():
		var pr: Dictionary = projs[pj]
		var a := str(Circuits.proj_pop(pr.get("pre", ""))); var b := str(Circuits.proj_pop(pr.get("post", "")))
		if not ix.has(a) or not ix.has(b): axons.append({}); continue
		var pa: Dictionary = P[ix[a]]; var pb: Dictionary = P[ix[b]]
		var cp := _loop(pa, obstacles) if a == b else _axon(pa, pb)
		if a == b: loops.append(_cp_box(cp))
		var w := Circuits.proj_weight_shown(circuit, pj)
		var bpi := int(pb["pi"])
		var model := str(pops[bpi].get("model", ""))
		if not wref.has(model): wref[model] = Circuits.weight_of(model)
		var width := (1.6 + clampf(sqrt(absf(w) / float(wref[model])), 0.0, 2.0) * 1.2) * clampf(view_scale, 0.85, 1.2)
		axons.append({"cp": cp, "pts": Gfx.bez_points(cp[0], cp[1], cp[2], cp[3], 28), "w": w, "width": width, "locked": Circuits.is_locked(pr)})
	g["axons"] = axons
	# channel edges (bundled per target group); a card in an outer column runs through the gap below it
	var ins_by := {}; var outs_by := {}
	for ch in circuit.get("inputs", []): ins_by[str(ch.get("name", ""))] = ch
	for ch in circuit.get("outputs", []): outs_by[str(ch.get("name", ""))] = ch
	var edges := []
	for it in items:
		if str(it["type"]) == "head": continue
		var is_in := str(it["side"]) == "in"; var r: Rect2 = it["rect"]
		var count := {}
		for nm in it["names"]:
			var ch: Dictionary = (ins_by if is_in else outs_by).get(str(nm), {})
			for x in ch.get("targets" if is_in else "neurons", []):
				var pid := str(Circuits.proj_pop(x))
				if ix.has(pid): count[pid] = int(count.get(pid, 0)) + 1
		for pid in count:
			var pd: Dictionary = P[ix[pid]]
			var a := Vector2(r.end.x, r.get_center().y) if is_in else Vector2(r.position.x, r.get_center().y)
			var pre := PackedVector2Array([a])
			if int(it["col"]) > 0 and not bool(it.get("moved", false)):   # an outer column: out through the gap under this card, past the inner columns
				var gx := (bb.position.x - 48.0 - card_w) if is_in else (bb.end.x + 48.0 + card_w)
				var gy := r.end.y + (pitch - card_h) * 0.5
				var sx := a.x + (7.0 if is_in else -7.0)
				pre = PackedVector2Array([a, Vector2(sx, a.y), Vector2(sx, gy), Vector2(gx + (10.0 if is_in else -10.0), gy)])
			var start := pre[pre.size() - 1]
			var dir := ((pd["c"] as Vector2) - start).normalized()
			var e := _edge_pt(pd, -dir) - dir * 4.0   # the point of the outline that faces the card
			var p0 := start if is_in else e; var p1 := e if is_in else start
			var nrm := (p1 - p0).orthogonal().normalized() * 20.0
			var curve := Gfx.bez_points(p0, p0 + (p1 - p0) * 0.4 + nrm, p0 + (p1 - p0) * 0.7 + nrm, p1, 20)
			var pts := PackedVector2Array()
			if is_in: pts.append_array(pre.slice(0, pre.size() - 1)); pts.append_array(curve)
			else:
				pts.append_array(curve)
				var back := pre.duplicate(); back.reverse(); pts.append_array(back.slice(1))
			edges.append({"pts": pts, "item": it, "pid": pid, "count": int(count[pid]), "in": is_in})
	g["edges"] = edges
	# labels: ensembles inside, the rest on the side that hides least
	var placed := []
	for p in P:
		if p["ens"]:
			var ls3: Vector2 = p["lsize"]; p["lab"] = Rect2((p["c"] as Vector2) - ls3 * 0.5, ls3); p["lab_in"] = true; placed.append(p["lab"])
	var lo_obst := obstacles.duplicate(); lo_obst.append_array(loops)
	for p in P:
		if p["ens"]: continue
		var ls4: Vector2 = p["lsize"]; var b: Rect2 = p["box"]; var c: Vector2 = p["c"]
		var cands := [Rect2(Vector2(c.x - ls4.x * 0.5, b.end.y + 4.0), ls4), Rect2(Vector2(c.x - ls4.x * 0.5, b.position.y - ls4.y - 4.0), ls4),
			Rect2(Vector2(b.end.x + 6.0, c.y - ls4.y * 0.5), ls4), Rect2(Vector2(b.position.x - 6.0 - ls4.x, c.y - ls4.y * 0.5), ls4)]
		var zone := b.grow(maxf(ls4.x, ls4.y) + 8.0)
		var near := []; var near_l := []
		for o in lo_obst:
			if (o as Rect2) != b and zone.intersects(o): near.append(o)
		for o in placed:
			if zone.intersects(o): near_l.append(o)
		var best: Rect2 = cands[0]; var bs := INF
		for ci in cands.size():
			var s := float(ci) * 0.5
			for o in near: s += (o as Rect2).intersection(cands[ci]).get_area()
			for o in near_l: s += (o as Rect2).intersection(cands[ci]).get_area() * 2.0
			if s < bs - 0.01: bs = s; best = cands[ci]
		p["lab"] = best; p["lab_in"] = false; placed.append(best)
	# hit-test grid
	var grid := {}
	for i in P.size():
		var p: Dictionary = P[i]
		if p["ens"]: _grid_add(grid, p["box"], [1, i, 0])
		else:
			var pts3: PackedVector2Array = p["pts"]
			for k in pts3.size(): _grid_add(grid, Rect2(pts3[k] - Vector2(_rg + 5.0, _rg + 5.0), Vector2(_rg + 5.0, _rg + 5.0) * 2.0), [0, i, k])
	var agrid := {}   # axons: the cells their sample points fall in (a query looks at the 3 x 3 cells around it)
	for pj in axons.size():
		var ax: Dictionary = axons[pj]
		if ax.is_empty(): continue
		var pts4: PackedVector2Array = ax["pts"]; var last := Vector2i(1 << 30, 0)
		for k in pts4.size():
			var cell := Vector2i(floori(pts4[k].x / GRID), floori(pts4[k].y / GRID))
			if cell == last: continue
			last = cell
			if not agrid.has(cell): agrid[cell] = PackedInt32Array([pj])
			else:
				var arr: PackedInt32Array = agrid[cell]
				if arr[arr.size() - 1] != pj: arr.append(pj); agrid[cell] = arr
	g["grid"] = grid; g["agrid"] = agrid
	return g

func _card_col_index(count: int, i: int, side: int) -> int:
	var cols := _card_cols(count); var per := ceili(float(count) / float(cols)); var col := i / per
	return col if side > 0 else (cols - 1 - col)   # 0 = the column next to the neurons

func _grid_add(grid: Dictionary, r: Rect2, item: Array) -> void:
	for gx in range(floori(r.position.x / GRID), floori(r.end.x / GRID) + 1):
		for gy in range(floori(r.position.y / GRID), floori(r.end.y / GRID) + 1):
			var k := Vector2i(gx, gy)
			if not grid.has(k): grid[k] = [item]
			else:
				var arr: Array = grid[k]
				if arr.back() != item: arr.append(item)

## Push overlapping boxes apart (sweep and prune on x, a few passes): the offset of each.
static func _relax(boxes: Array) -> PackedVector2Array:
	var n := boxes.size(); var off := PackedVector2Array(); off.resize(n)
	if n < 2: return off
	var area := PackedFloat32Array(); area.resize(n)
	for i in n: area[i] = maxf((boxes[i] as Rect2).get_area(), 1.0)
	var order := range(n)
	for it in 160:
		var moved := false
		order.sort_custom(func(a, b): return (boxes[a] as Rect2).position.x + off[a].x < (boxes[b] as Rect2).position.x + off[b].x)
		for ai in n:
			var i: int = order[ai]
			for bi in range(ai + 1, n):
				var j: int = order[bi]
				var ri := Rect2((boxes[i] as Rect2).position + off[i], (boxes[i] as Rect2).size)
				var rj := Rect2((boxes[j] as Rect2).position + off[j], (boxes[j] as Rect2).size)
				if rj.position.x >= ri.end.x: break
				if not ri.intersects(rj): continue
				var ox := minf(ri.end.x - rj.position.x, rj.end.x - ri.position.x) + 0.5
				var oy := minf(ri.end.y - rj.position.y, rj.end.y - ri.position.y) + 0.5
				var d := rj.get_center() - ri.get_center()
				var wi := area[j] / (area[i] + area[j])
				if ox < oy:
					var s := 1.0 if (d.x > 0.0 or (is_zero_approx(d.x) and j > i)) else -1.0
					off[i].x -= s * ox * wi; off[j].x += s * ox * (1.0 - wi)
				else:
					var s2 := 1.0 if (d.y > 0.0 or (is_zero_approx(d.y) and j > i)) else -1.0
					off[i].y -= s2 * oy * wi; off[j].y += s2 * oy * (1.0 - wi)
				moved = true
		if not moved: break
	return off

static func _cp_box(cp: PackedVector2Array) -> Rect2:
	var r := Rect2(cp[0], Vector2.ZERO)
	for q in cp: r = r.expand(q)
	return r

## Control points of the axon from population a to b. Reciprocal pairs bow to opposite sides.
func _axon(pa: Dictionary, pb: Dictionary) -> PackedVector2Array:
	var a: Vector2 = pa["c"]; var b: Vector2 = pb["c"]
	var d := b - a; var l := maxf(d.length(), 1.0); var nrm := d.orthogonal() / l
	var bow := clampf(l * 0.2, 22.0, 90.0)
	var a2 := _edge_pt(pa, d / l); var b2 := _edge_pt(pb, -d / l)
	var d2 := b2 - a2
	return PackedVector2Array([a2, a2 + d2 * 0.33 + nrm * bow * 1.25, a2 + d2 * 0.67 + nrm * bow * 1.25, b2])

## A self-loop: up, right, left or down from the outline, whichever overlaps the other shapes and cards least (and never its own label's usual place below).
func _loop(p: Dictionary, obstacles: Array) -> PackedVector2Array:
	var best := PackedVector2Array(); var bs := INF
	for di in 4:
		var dir: Vector2 = [Vector2.UP, Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN][di]
		var cp := _loop_dir(p, dir)
		var box := _cp_box(cp); var s := float(di) * 4.0 + (box.get_area() * 0.6 if di == 3 else 0.0)
		for o in obstacles:
			if (o as Rect2) != (p["box"] as Rect2): s += (o as Rect2).intersection(box).get_area()
		if s < bs: bs = s; best = cp
	return best

func _loop_dir(p: Dictionary, dir: Vector2) -> PackedVector2Array:
	var c: Vector2 = p["c"]; var t := dir.orthogonal()
	var b := _edge_pt(p, dir)
	var span := clampf(float(p["rad"]), _rg, 70.0); var loop := minf(span, 60.0)
	if p["ens"]: loop = clampf(minf(float(p["rx"]), float(p["ry"])) * 0.5, 24.0, 60.0)
	return PackedVector2Array([b - t * loop * 0.4, b - t * loop * 1.5 + dir * loop * 1.7, b + t * loop * 1.5 + dir * loop * 1.7, b + t * loop * 0.4])

## Where a ray from the population's centre in direction `dir` leaves its outline (circle, rounded box or ellipse).
func _edge_pt(p: Dictionary, dir: Vector2) -> Vector2:
	var c: Vector2 = p["c"]
	if p["ens"]:
		var rx: float = p["rx"]; var ry: float = p["ry"]
		var k := 1.0 / maxf(sqrt(pow(dir.x / rx, 2.0) + pow(dir.y / ry, 2.0)), 1e-6)
		return c + dir * k
	if int(p["n"]) > 1:
		var bx: Rect2 = p["box"]; var tx := 1e9; var ty := 1e9
		if absf(dir.x) > 1e-4: tx = (bx.size.x * 0.5) / absf(dir.x)
		if absf(dir.y) > 1e-4: ty = (bx.size.y * 0.5) / absf(dir.y)
		return bx.get_center() + dir * minf(tx, ty)
	return c + dir * float(p["rad"])

func _kind_col(kind: String) -> Color: return Kit.inh() if kind == "I" else Kit.exc()

## Population geometry (scaled space), cached: {id, c, rad, box, pts | ring, n, first, ens, rx, ry, lab}. Kept for callers of the old API.
func _pops(_ns: Array = []) -> Array: return _geo().get("pops", [])

func _pop_dict(pops: Array, id: String) -> Dictionary:
	var g := _geo(); var ix: Dictionary = g.get("ix", {})
	if ix.has(id) and int(ix[id]) < pops.size(): return pops[int(ix[id])]
	for p in pops:
		if p["id"] == id: return p
	return {}

func _world_xf() -> Transform2D:
	var k := _k()
	if _push_now != 1.0:
		var c := size * 0.5
		return Transform2D(0.0, Vector2(_push_now, _push_now) * k, 0.0, c + (view_off - c) * _push_now)
	return Transform2D(0.0, Vector2(k, k), 0.0, view_off)

# ---------- public geometry (editor-local pixels) ----------
## The card a channel is drawn as ("in:<name>", "out:<name>" or a bare name; a member of a closed bus gives the bus card). Rect2() when there is none.
func card_rect(channel: String) -> Rect2:
	var g := _geo(); if g.is_empty(): return Rect2()
	for k in [channel, "in:" + channel, "out:" + channel]:
		if _cards_g.has(k): return _g2s_rect(_cards_g[k])
	return Rect2()

## The outline of population `index` (file order) as drawn. Rect2() when out of range.
func pop_rect(index: int) -> Rect2:
	var g := _geo(); var P: Array = g.get("pops", [])
	if index < 0 or index >= P.size(): return Rect2()
	return _g2s_rect(P[index]["box"])

func pop_rect_by_id(id: String) -> Rect2: return pop_rect(Circuits.pop_index(circuit, id))

## The projection under editor-local point `p` (-1 when none).
func proj_at(p: Vector2) -> int:
	var h := _hit(p)
	return int(h["i"]) if str(h.get("t", "")) == "proj" else -1

## The middle of projection `i`'s axon (editor-local), or Vector2(-1, -1).
func proj_mid(i: int) -> Vector2:
	var g := _geo(); var ax: Array = g.get("axons", [])
	if i < 0 or i >= ax.size() or (ax[i] as Dictionary).is_empty(): return Vector2(-1, -1)
	var cp: PackedVector2Array = ax[i]["cp"]; return _g2s(Gfx.bez(cp[0], cp[1], cp[2], cp[3], 0.5))

## What is under editor-local point `p`: {} | {t:"pop", id, rim, at} | {t:"in"|"out", name, bus?} | {t:"proj", i}.
func hit_at(p: Vector2) -> Dictionary: return _hit(p)

# ---------- draw ----------
## The two cached layers behind the editor follow the view: the paper redraws when the view moves; the ink only when the geometry (or a lesion) changed,
## and otherwise just takes the view transform (pan and zoom cost nothing there).
func _sync_layers() -> void:
	var pk := [view_off, view_scale, size]
	if pk != _paper_key: _paper_key = pk; _paper.queue_redraw()
	if circuit.is_empty():
		if not _ink_key.is_empty(): _ink_key = []; _ink.queue_redraw()
		return
	_geo()
	var xf := _world_xf(); _ink.position = xf.origin; _ink.scale = xf.get_scale()
	# the layer's own rect must reach the bench: a zero-size Control whose origin sits above or left of the canvas (a fit that pans the
	# block up, view_off < 0) was culled whole, and the axons and resting cells vanished (a diagnosis case at 1920x1080)
	_ink.size = Vector2(1e5, 1e5)
	var ik := [_gen, lesions.hash(), Settings.colorblind, editable, _off_key()]
	if ik != _ink_key: _ink_key = ik; _ink.queue_redraw()

## Which cell types the level lets the player switch off are switched off now (part of the ink layer's cache key).
func _off_key() -> String:
	var s := ""
	for g in Circuits.groups(circuit):
		if Circuits.group_silenced(g): s += str(g.get("id", "")) + ","
	return s

## The ink layer (in geometry space; the layer's transform is the view): every axon and every cell at rest. The editor's own _draw adds what moves.
func _draw_ink() -> void:
	if circuit.is_empty() or _g.is_empty(): return
	var ci := _ink; var axons: Array = _g["axons"]
	for pj in axons.size():
		var ax: Dictionary = axons[pj]
		if ax.is_empty(): continue
		var cp: PackedVector2Array = ax["cp"]; var pts: PackedVector2Array = ax["pts"]
		var w: float = ax["w"]; var col := _kind_col("I" if w < 0.0 else "E"); var width: float = ax["width"]
		if bool(ax.get("locked", false)):   # given wiring: engraved, a quieter stroke than the inked axons (docs/IDENTITY.md)
			Gfx.engraved(ci, pts, col, width); Gfx.engraved_head(ci, cp[3], cp[3] - cp[2], col, 10.0 * clampf(view_scale, 0.9, 1.2), w < 0.0)
		else:
			ci.draw_polyline(pts, Color(col, 0.86), width, true)
			if w < 0.0: Gfx.bar_head(ci, cp[3], cp[3] - cp[2], Color(col, 0.95), 11.0 * clampf(view_scale, 0.9, 1.2), width)
			else: Gfx.arrow_head(ci, cp[3], cp[3] - cp[2], Color(col, 0.95), 11.0 * clampf(view_scale, 0.9, 1.2))
		if lesions.has("proj:%d" % pj):   # a cut axon: dashed red with an X at its middle
			ci.draw_polyline(pts, Color(Gfx.SHEET, 0.85), width + 6.0, true); Gfx.dashed(ci, pts, Color(Kit.RED, 0.95), 2.2, 5.0, 7.0)
			var cm := Gfx.bez(cp[0], cp[1], cp[2], cp[3], 0.5); ci.draw_circle(cm, 13.0, Gfx.SHEET); ci.draw_arc(cm, 13.0, 0, TAU, 24, Kit.RED, 2.2, true)
			ci.draw_line(cm + Vector2(-6, -6), cm + Vector2(6, 6), Kit.RED, 3.0, true); ci.draw_line(cm + Vector2(-6, 6), cm + Vector2(6, -6), Kit.RED, 3.0, true)
	for p in _g["pops"]:
		var col := _kind_col(str(p["kind"])); var silenced := lesions.has("pop:" + str(p["id"])) or Circuits.pop_silenced(circuit, str(p["id"]))   # a lesion, or a cell type the level lets the player switch off (scale 0)
		if p["ens"]: _ink_ensemble(ci, p, col, silenced)
		else: _ink_cells(ci, p, col, silenced)
		if bool(p.get("locked", false)): _engrave_pop(ci, p)

## A locked group wears an engraved frame: a double hairline rule round it (round the outline of a small group, round each cell of a single one, round the ellipse of an ensemble).
func _engrave_pop(ci: CanvasItem, p: Dictionary) -> void:
	if p["ens"]:
		var c: Vector2 = p["c"]; var rx: float = p["rx"]; var ry: float = p["ry"]
		var a := Gfx.ellipse(c, rx + 5.0, ry + 5.0, 64); a.append(a[0]); var b := Gfx.ellipse(c, rx + 8.5, ry + 8.5, 64); b.append(b[0])
		Gfx.engraved_frame(ci, a, b)
	elif int(p["n"]) > 1 and p.has("box"):
		var bx: Rect2 = p["box"]
		Gfx.engraved_frame(ci, _group_outline(bx.grow(3.0)), _group_outline(bx.grow(6.5)))
	else:
		for q in (p["pts"] as PackedVector2Array):
			var a2 := Gfx.ellipse(q, _rg + 4.0, _rg + 4.0, 40); a2.append(a2[0]); var b2 := Gfx.ellipse(q, _rg + 7.0, _rg + 7.0, 40); b2.append(b2[0])
			Gfx.engraved_frame(ci, a2, b2)

func _draw() -> void:
	if _ink != null: _sync_layers()
	if circuit.is_empty(): return
	var g := _geo()
	var P: Array = g["pops"]; var axons: Array = g["axons"]
	var now := tele.now() if tele != null else 0.0
	var fz := Kit.fs(14); var font := Fonts.regular
	var live := tele != null and tele.sim != null
	draw_set_transform_matrix(_world_xf())
	var view := Rect2(_s2g(Vector2.ZERO), size / _k()).grow(40.0)
	# --- channel edges
	for e in g["edges"]:
		var it: Dictionary = e["item"]; var pts: PackedVector2Array = e["pts"]
		var w := 1.6 + minf(float(e["count"]) - 1.0, 15.0) * 0.14
		if bool(e["in"]):
			var act := 0.0
			if live:
				for nm in it["names"]:
					var ch := _chan("inputs", str(nm))
					if float(ch.get("value", 0.0)) > 0.0: act = 1.0; break
			var selected: bool = sel.get("t", "") == "in" and (it["names"] as Array).has(sel.get("name", ""))
			if _link_is(sel, e) or _link_is(_hover, e): draw_polyline(pts, Color(Kit.GAMBOGE, 0.42 if _link_is(sel, e) else 0.24), w + 8.0, true)   # the chosen link under a highlighter stroke
			Gfx.dashed(self, pts, Color(Kit.SENSOR, 0.55 + 0.3 * act + (0.15 if selected else 0.0)), w + (0.6 if selected else 0.0), 6.0, 5.0, now * 26.0 * act if Kit.motion() else 0.0)
			Gfx.arrow_head(self, pts[pts.size() - 1], pts[pts.size() - 1] - pts[pts.size() - 2], Color(Kit.SENSOR, 0.9), 8.0)
		else:
			var rate := 0.0
			if tele != null:
				for nm in it["names"]: rate = maxf(rate, float(tele.rates.get(str(nm), 0.0)))
			if _link_is(sel, e) or _link_is(_hover, e): draw_polyline(pts, Color(Kit.GAMBOGE, 0.42 if _link_is(sel, e) else 0.24), w + 8.0, true)
			Gfx.dashed(self, pts, Color(Kit.MOTOR, 0.55 + clampf(rate / 80.0, 0.0, 0.4)), w, 6.0, 5.0, -now * 26.0 * clampf(rate / 40.0, 0.0, 1.0) if Kit.motion() else 0.0)
			Gfx.arrow_head(self, pts[pts.size() - 1], pts[pts.size() - 1] - pts[pts.size() - 2], Color(Kit.MOTOR, 0.9), 8.0)
	# --- projections
	for pj in axons.size():
		var ax: Dictionary = axons[pj]
		if ax.is_empty(): continue
		var cp: PackedVector2Array = ax["cp"]; var pts: PackedVector2Array = ax["pts"]
		var w: float = ax["w"]; var col := _kind_col("I" if w < 0.0 else "E"); var width: float = ax["width"]
		var isel: bool = sel.get("t", "") == "proj" and int(sel.get("i", -1)) == pj
		var ihov: bool = _hover.get("t", "") == "proj" and int(_hover.get("i", -1)) == pj
		if not (isel or ihov): continue   # at rest it is on the ink layer; selected or hovered it is inked again over a highlighter stroke
		draw_polyline(pts, Color(Kit.GAMBOGE, 0.42 if isel else 0.24), width + 8.0, true)
		if bool(ax.get("locked", false)):   # an engraved axon stays engraved when selected: the highlighter shows it, the cut does not turn into ink
			Gfx.engraved(self, pts, col, width + (0.8 if isel else 0.0)); Gfx.engraved_head(self, cp[3], cp[3] - cp[2], col, 10.0 * clampf(view_scale, 0.9, 1.2), w < 0.0)
			continue
		draw_polyline(pts, Color(col.darkened(0.15 if isel else 0.0), 0.95), width + (0.8 if isel else 0.0), true)
		if w < 0.0: Gfx.bar_head(self, cp[3], cp[3] - cp[2], Color(col, 0.95), 11.0 * clampf(view_scale, 0.9, 1.2), width)
		else: Gfx.arrow_head(self, cp[3], cp[3] - cp[2], Color(col, 0.95), 11.0 * clampf(view_scale, 0.9, 1.2))
	# --- pulses
	if live:
		for pj in axons.size():
			var ax: Dictionary = axons[pj]
			if ax.is_empty() or pj >= tele.pulses.size(): continue   # a new axon is drawn before the debounced reload has made its pulse list
			var cp: PackedVector2Array = ax["cp"]; var col := _kind_col("I" if float(ax["w"]) < 0.0 else "E")
			var trav := Telemetry.pulse_seconds(Circuits.proj_delay(circuit["projections"][pj]))
			var pa: PackedFloat64Array = tele.pulses[pj]
			for birth in pa:
				var u := (now - birth) / trav
				if u < 0.0 or u > 1.25: continue
				var uu := clampf(u, 0.0, 1.0)
				if u <= 1.0:   # an ink bead travelling down the axon, with two fading droplets behind it
					for k in range(2, 0, -1):
						var q := Gfx.bez(cp[0], cp[1], cp[2], cp[3], maxf(uu - 0.045 * k, 0.0)); draw_circle(q, 2.4 - 0.5 * k, Color(col.darkened(0.3), 0.55 - 0.18 * k))
					Gfx.bead(self, Gfx.bez(cp[0], cp[1], cp[2], cp[3], uu), 3.4 * clampf(view_scale, 0.85, 1.2), col.darkened(0.45))
				else:   # arrival: a small blot of stain soaks in at the synapse
					var k2 := (u - 1.0) / 0.25
					Gfx.wash(self, cp[3], 5.0 + (9.0 * k2 if Kit.motion() else 6.0), col, 0.55 * (1.0 - k2), pj)
	# --- populations
	for p in P:
		var id: String = p["id"]; var col := _kind_col(str(p["kind"]))
		var isel: bool = (sel.get("t", "") == "pop" and sel.get("id", "") == id) or msel.has(id)
		var ihov: bool = _hover.get("t", "") == "pop" and _hover.get("id", "") == id
		var silenced := lesions.has("pop:" + id) or Circuits.pop_silenced(circuit, id)
		if not view.intersects(p["box"]): continue
		if p["ens"]: _live_ensemble(p, col, isel, ihov, silenced)
		else: _live_cells(p, col, isel, ihov, silenced)
	# --- the selected axon names its weight and delay
	var projs: Array = circuit.get("projections", [])
	if sel.get("t", "") == "proj" and int(sel.get("i", -1)) < axons.size() and int(sel.get("i", -1)) >= 0 and not (axons[int(sel["i"])] as Dictionary).is_empty():
		var cp: PackedVector2Array = axons[int(sel["i"])]["cp"]
		var pr: Dictionary = projs[int(sel["i"])]; var w := Circuits.proj_weight_shown(circuit, int(sel["i"]))
		var pi2 := Circuits.pop_index(circuit, Circuits.proj_pop(pr.get("post", ""))); var unit := "nS" if pi2 >= 0 and str(circuit["populations"][pi2].get("model", "")).contains("cond") else "pA"
		var txt := "%s%s %s   %s ms" % ["+" if w >= 0.0 else "-", str(snappedf(absf(w), 0.1)), unit, str(snappedf(Circuits.proj_delay(pr), 0.1))]
		if Circuits.has_dx_types(circuit): txt = "%s   %s ms" % ["inhibitory" if w < 0.0 else "excitatory", str(snappedf(Circuits.proj_delay(pr), 0.1))]   # a patient's axon: its type, never its strength
		var mid := Gfx.bez(cp[0], cp[1], cp[2], cp[3], 0.5); var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x + 16.0
		var rect := Rect2(mid - Vector2(tw * 0.5, float(fz) * 0.9 + 4.0), Vector2(tw, float(fz) + 8.0))
		draw_rect(Rect2(rect.position + Vector2(3, 3), rect.size), Color(Gfx.INK, 0.12)); draw_rect(rect, Color("#FBF7EE")); draw_rect(rect, _kind_col("I" if w < 0.0 else "E"), false, 1.4)
		draw_string(font, rect.position + Vector2(8, float(fz) + 2.0), txt, HORIZONTAL_ALIGNMENT_LEFT, tw, fz, Kit.TEXT)
	_draw_marks(P, axons, now)
	# --- cards
	var in_sensor := {}
	if tele != null and tele.task != null:
		for s in tele.task.sensor_channels(): in_sensor[str(s)] = true
	var its: Array = g["items"]
	for ii in range(its.size() - 1, -1, -1): _draw_item(font, fz, its[ii], in_sensor, now)   # bottom card first: a squeezed column shows every card's name
	# --- labels, last, on a paper halo
	for p in P: _draw_label(p, fz)
	# --- keyboard cursor and wire
	if has_focus() and _kbd and not _cursor.is_empty(): _draw_cursor(_cursor)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	if not _wire.is_empty() and not _cursor.is_empty():
		var a := _anchor(_wire); var b := _anchor(_cursor)
		if a.x > -1e8 and b.x > -1e8:
			var pts := Gfx.bez_points(a, a + (b - a) * 0.4 + (b - a).orthogonal().normalized() * 14.0, a + (b - a) * 0.7 + (b - a).orthogonal().normalized() * 14.0, b, 20)
			Gfx.dashed(self, pts, Color(Gfx.INK, 0.9), 2.0, 7.0, 5.0, now * 40.0 if Kit.motion() else 0.0); draw_circle(b, 4.0, Gfx.INK)
	# --- connect rubber band, selection box
	if _drag.get("mode", "") == "connect":
		var a: Vector2 = _drag["from_pt"]; var b: Vector2 = _drag["to"]
		var tgt := _hit(b)
		var ok: bool = not tgt.is_empty() and ((tgt["t"] == "pop") or (tgt["t"] == "out" and _drag["src"]["t"] == "pop"))
		var pts := Gfx.bez_points(a, a + (b - a) * 0.4 + (b - a).orthogonal().normalized() * 14.0, a + (b - a) * 0.7 + (b - a).orthogonal().normalized() * 14.0, b, 20)
		var kc := Color(Gfx.INK, 0.9) if ok else Color(Gfx.INK, 0.45)
		Gfx.dashed(self, pts, kc, 2.0, 7.0, 5.0, now * 40.0 if Kit.motion() else 0.0); draw_circle(b, 4.0, kc)
		if ok: draw_arc(b, 14.0, 0, TAU, 32, Color(Kit.GAMBOGE, 0.95), 2.4, true)
	elif _drag.get("mode", "") == "band":
		var br := Rect2(_drag["from"], Vector2.ZERO).expand(_drag["to"])
		draw_rect(br, Color(Kit.GAMBOGE, 0.10)); Gfx.dashed(self, PackedVector2Array([br.position, Vector2(br.end.x, br.position.y), br.end, Vector2(br.position.x, br.end.y), br.position]), Color(Gfx.INK, 0.8), 1.4, 6.0, 4.0)
	elif tool == "connect" and not _connect_from.is_empty():
		var r0 := _anchor_rect(_connect_from)
		if r0.size != Vector2.ZERO: draw_rect(r0.grow(8.0), Color(Kit.GAMBOGE, 0.95), false, 2.4)
	if has_focus() and Kit.pad_mode and (_cursor.is_empty() or not _kbd): Kit.ring_sb().draw(get_canvas_item(), Rect2(Vector2.ZERO, size).grow(-12.0))
	_draw_scale_bar()
	_draw_zoom()
	if _note != "": _draw_note(font, fz)
	if circuit.get("populations", []).is_empty():
		var lo := 8.0; var hi := size.x - 8.0   # the hint sits between the card columns, not over them (full width when the cards are all below it)
		var hint_bottom := size.y * 0.16 + float(Kit.fs(18)) * 4.0
		for it in g["items"]:
			var rc: Rect2 = _g2s_rect(it["rect"])
			if rc.position.y - 12.0 > hint_bottom: continue
			if rc.get_center().x < size.x * 0.5: lo = maxf(lo, rc.end.x + 10.0)
			else: hi = minf(hi, rc.position.x - 10.0)
		if hi - lo > size.x * 0.7: lo = size.x * 0.15; hi = size.x * 0.85
		var hw := maxf(hi - lo, 160.0)
		draw_multiline_string(font, Vector2(lo, size.y * 0.16), "An empty bench. Press “+ Excitatory” above to add a neuron, then drag from a sensor card to it and from it to a motor card.", HORIZONTAL_ALIGNMENT_CENTER, hw, Kit.fs(18), 6, Kit.TEXT_SOFT)

## Is the selection / hover `h` the link drawn by geometry edge `e`?
func _link_is(h: Dictionary, e: Dictionary) -> bool:
	if str(h.get("t", "")) != ("ilink" if bool(e["in"]) else "olink"): return false
	return str(h.get("pop", "")) == str(e["pid"]) and ((e["item"] as Dictionary)["names"] as Array).has(h.get("name", ""))

func _chan(key: String, name: String) -> Dictionary:
	for ch in circuit.get(key, []):
		if str(ch.get("name", "")) == name: return ch
	return {}

func _flash(gi: int) -> float: return tele.flash[gi] if tele != null and gi >= 0 and gi < tele.flash.size() else 0.0

## A small group at rest, on the ink layer: its dashed outline, the stains and the inked cells (silenced: faded and struck through).
func _ink_cells(ci: CanvasItem, p: Dictionary, col: Color, silenced: bool) -> void:
	var pts: PackedVector2Array = p["pts"]; var first: int = p["first"]
	if int(p["n"]) > 1 and p.has("box"): Gfx.dashed(ci, _group_outline(p["box"]), Color(col, 0.3), 1.0, 2.0, 5.0)
	if not silenced:
		for k in pts.size(): Gfx.wash(ci, pts[k], _rg * 1.5, col, 0.09, (first + k) * 3 + 1)
	for k in pts.size():
		var gi := first + k; var q := pts[k]
		Gfx.soma(ci, q, _rg, col, gi * 7 + 3, 0.0, 0.65 if silenced else 0.0, _rg >= 9.0)
		if silenced:
			ci.draw_arc(q, _rg + 4.0, 0, TAU, 40, Color(Kit.RED, 0.95), 2.4, true)
			ci.draw_line(q + Vector2(-_rg, _rg) * 0.75, q + Vector2(_rg, -_rg) * 0.75, Kit.RED, 3.0, true)

func _group_outline(bx: Rect2) -> PackedVector2Array:   # a rounded rectangle round a group's stain, closed
	var gpts := PackedVector2Array(); var cnr := minf(minf(bx.size.x, bx.size.y) * 0.5, 30.0)
	for k in 32:
		var q := k / 8; var a := PI + float(q) * PI * 0.5 + (float(k % 8) / 7.0) * PI * 0.5
		var cc := [bx.position + Vector2(cnr, cnr), Vector2(bx.end.x - cnr, bx.position.y + cnr), bx.end - Vector2(cnr, cnr), Vector2(bx.position.x + cnr, bx.end.y - cnr)][q] as Vector2
		gpts.append(cc + Vector2(cos(a), sin(a)) * cnr)
	gpts.append(gpts[0]); return gpts

## What moves on a small group, over the ink: firing cells (stain and a brighter soma), the hover glow, the selection, voltage arcs and trace pins.
func _live_cells(p: Dictionary, col: Color, isel: bool, ihov: bool, silenced: bool) -> void:
	var pts: PackedVector2Array = p["pts"]; var first: int = p["first"]
	if isel and int(p["n"]) > 1 and p.has("box"): Gfx.dashed(self, _group_outline(p["box"]), Color(col, 0.7), 1.6, 2.0, 5.0)
	for k in pts.size():
		var gi := first + k; var q := pts[k]; var f := _flash(gi)
		var volt: bool = tele != null and tele.volt.has(gi); var pin: bool = tele != null and tele.watched.has(gi)
		if f <= 0.02 and not (isel or ihov or volt or pin): continue
		var rr := _rg * (1.0 + (0.08 * f if Kit.motion() else 0.0))
		if ihov and not isel: draw_circle(q, rr + 5.0, Color(Kit.GAMBOGE, 0.25))
		if not silenced and (f > 0.02 or (ihov and not isel)):
			Gfx.spike_stain(self, q, _rg, col, f, gi * 3 + 2)
			Gfx.soma(self, q, rr, col, gi * 7 + 3, f, 0.0, false)
		if volt:   # membrane potential as a thin arc of the traced neurons
			var a: PackedFloat32Array = tele.volt[gi]
			if a.size() > 0 and is_finite(a[a.size() - 1]):   # a model without a membrane (relay, generator) reports NaN
				var u := clampf((float(a[a.size() - 1]) + 80.0) / 50.0, 0.0, 1.0)
				draw_arc(q, rr + 4.5, -PI * 0.5, -PI * 0.5 + TAU * u, 40, Color(Gfx.INK, 0.7), 1.6, true)
		if isel: draw_arc(q, rr + 8.0, 0, TAU, 48, Color(Kit.GAMBOGE, 0.95), 2.4, true); draw_arc(q, rr + 10.5, 0, TAU, 48, Color(Gfx.INK, 0.5), 1.0, true)
		if pin:   # traced on the scope: a small inked pin
			var wp := q + Vector2(rr * 0.9, -rr * 0.9)
			draw_circle(wp, 6.5, Gfx.SHEET); draw_arc(wp, 6.5, 0, TAU, 20, Gfx.INK, 1.4, true); draw_circle(wp, 3.2, col)

## A large population at rest, on the ink layer: a stained ellipse, an inked rim, and a ring of sample cells (each standing for n/k cells).
## Name and count are drawn inside by _draw_label.
func _ink_ensemble(ci: CanvasItem, p: Dictionary, col: Color, silenced: bool) -> void:
	var c: Vector2 = p["c"]; var rx: float = p["rx"]; var ry: float = p["ry"]; var first: int = p["first"]
	var ring: PackedVector2Array = p["ring"]
	var fade := 0.65 if silenced else 0.0
	var shape := Gfx.ellipse(c, rx, ry, 64)
	ci.draw_colored_polygon(shape, Color(col.lerp(Gfx.SHEET, 0.55 + 0.3 * fade), 0.42))
	Gfx.wash(ci, c, minf(rx, ry) * 0.9, col, 0.12 * (1.0 - fade), int(p["pi"]) * 11 + 5)
	var rim := shape.duplicate(); rim.append(shape[0])
	ci.draw_polyline(rim, Color(Gfx.INK, 0.85 * (1.0 - 0.5 * fade)), 1.8, true)
	var inner := Gfx.ellipse(c, rx * 0.93, ry * 0.93, 64); inner.append(inner[0]); Gfx.dashed(ci, inner, Color(col.darkened(0.3), 0.45), 1.0, 2.0, 4.0)
	var dot: float = p["dot"]
	for i in ring.size(): Gfx.soma(ci, ring[i], dot, col, first * 7 + i, 0.0, fade, false)
	if silenced:
		ci.draw_line(c + Vector2(-rx, ry) * 0.6, c + Vector2(rx, -ry) * 0.6, Kit.RED, 3.0, true)
		var sx := Gfx.ellipse(c, rx + 3.0, ry + 3.0, 64); sx.append(sx[0]); ci.draw_polyline(sx, Color(Kit.RED, 0.95), 2.4, true)

## What moves on a large population: the stain deepens while it fires, and each sample cell flashes with the strongest of the cells it stands for.
func _live_ensemble(p: Dictionary, col: Color, isel: bool, ihov: bool, silenced: bool) -> void:
	var c: Vector2 = p["c"]; var rx: float = p["rx"]; var ry: float = p["ry"]; var n: int = p["n"]; var first: int = p["first"]
	var ring: PackedVector2Array = p["ring"]; var k := ring.size()
	var acts := PackedFloat32Array(); acts.resize(k); var tot := 0.0
	for i in k:
		var a0 := (i * n) / k; var a1 := ((i + 1) * n) / k; var m := 0.0
		for gi in range(first + a0, first + maxi(a1, a0 + 1)): m = maxf(m, _flash(gi))
		acts[i] = m; tot += m
	if ihov and not isel:
		var hr := Gfx.ellipse(c, rx + 4.0, ry + 4.0, 64); hr.append(hr[0]); draw_polyline(hr, Color(Kit.GAMBOGE, 0.3), 6.0, true)
	var deep := 0.25 * clampf(tot / float(maxi(k, 1)) * 2.0, 0.0, 1.0) * (0.0 if silenced else 1.0)
	if deep > 0.004: draw_colored_polygon(Gfx.ellipse(c, rx * 0.97, ry * 0.97, 48), Color(col.lerp(Gfx.SHEET, 0.55), deep))
	var dot: float = p["dot"]
	for i in k:
		if not silenced and acts[i] > 0.02:
			Gfx.spike_stain(self, ring[i], dot, col, acts[i], first * 3 + i)
			Gfx.soma(self, ring[i], dot * (1.0 + (0.1 * acts[i] if Kit.motion() else 0.0)), col, first * 7 + i, acts[i], 0.0, false)
		if tele != null and not tele.watched.is_empty():
			var a0 := (i * n) / k; var a1 := maxi(((i + 1) * n) / k, a0 + 1)
			for gi in range(first + a0, first + a1):
				if tele.watched.has(gi): draw_arc(ring[i], dot + 3.0, 0, TAU, 16, Gfx.INK, 1.4, true); break
	if isel:
		var sr := Gfx.ellipse(c, rx + 7.0, ry + 7.0, 64); sr.append(sr[0]); draw_polyline(sr, Color(Kit.GAMBOGE, 0.95), 2.6, true)
		var sr2 := Gfx.ellipse(c, rx + 10.0, ry + 10.0, 64); sr2.append(sr2[0]); draw_polyline(sr2, Color(Gfx.INK, 0.5), 1.0, true)

func _draw_label(p: Dictionary, fz: int) -> void:
	var lr: Rect2 = p["lab"]; var id: String = p["id"]; var n: int = p["n"]
	var isel: bool = sel.get("t", "") == "pop" and sel.get("id", "") == id
	var lz := Kit.fs(16); var fi := Gfx.serif_italic(); var halo := Color(Gfx.SHEET, 0.92)
	if bool(p["lab_in"]):
		var nw := fi.get_string_size(id, HORIZONTAL_ALIGNMENT_LEFT, -1, lz).x
		var y1 := lr.position.y + float(lz)
		var p1 := Vector2((p["c"] as Vector2).x - nw * 0.5, y1)
		draw_string_outline(fi, p1, id, HORIZONTAL_ALIGNMENT_LEFT, -1, lz, 6, halo); draw_string(fi, p1, id, HORIZONTAL_ALIGNMENT_LEFT, -1, lz, Kit.TEXT)
		var ct := "×%d" % n; var cw := fi.get_string_size(ct, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x
		var p2 := Vector2((p["c"] as Vector2).x - cw * 0.5, y1 + float(fz) + 3.0)
		draw_string_outline(fi, p2, ct, HORIZONTAL_ALIGNMENT_LEFT, -1, fz, 6, halo); draw_string(fi, p2, ct, HORIZONTAL_ALIGNMENT_LEFT, -1, fz, Kit.TEXT_SOFT)
	else:
		var mult := (" ×%d" % n) if n > 1 else ""
		var nw2 := fi.get_string_size(id, HORIZONTAL_ALIGNMENT_LEFT, -1, lz).x
		var lp := lr.position + Vector2(0.0, float(lz))
		draw_string_outline(fi, lp, id, HORIZONTAL_ALIGNMENT_LEFT, -1, lz, 6, halo)
		if mult != "": draw_string_outline(fi, lp + Vector2(nw2, 0), mult, HORIZONTAL_ALIGNMENT_LEFT, -1, fz, 6, halo)
		draw_string(fi, lp, id, HORIZONTAL_ALIGNMENT_LEFT, -1, lz, Kit.TEXT if isel else Color(Kit.TEXT, 0.88))
		if mult != "": draw_string(fi, lp + Vector2(nw2, 0), mult, HORIZONTAL_ALIGNMENT_LEFT, -1, fz, Kit.TEXT_SOFT)
	if isel:
		var pm: Dictionary = circuit["populations"][int(p["pi"])]
		var mp := Vector2((p["c"] as Vector2).x - 90.0, lr.end.y + float(fz) + 2.0)
		draw_string_outline(Gfx.mono(), mp, str(pm.get("model", "")), HORIZONTAL_ALIGNMENT_CENTER, 180, fz, 6, halo)
		draw_string(Gfx.mono(), mp, str(pm.get("model", "")), HORIZONTAL_ALIGNMENT_CENTER, 180, fz, Kit.TEXT_SOFT)

func _draw_item(font: Font, fz: int, it: Dictionary, in_sensor: Dictionary, now: float) -> void:
	var side := str(it["side"]); var r: Rect2 = it["rect"]; var names: Array = it["names"]
	var col := Kit.GREEN if side == "in" else Gfx.VIOLET
	match str(it["type"]):
		"head":   # an open bus: a slim tab above its cards; click it to fold them back into one card
			var isel_h: bool = _cursor.get("key", "") == it["key"] and _kbd and has_focus()
			Gfx.rounded_rect(self, r, Color("#FBF7EE"), Color(col, 0.9), 6.0, 1.4 if not isel_h else 2.2)
			var t := "%s ×%d" % [str(it["stem"]), names.size()]
			draw_string(Fonts.bold, r.position + Vector2(10.0, r.size.y * 0.5 + float(fz) * 0.36), t, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 40.0, fz, Gfx.INK)
			var cx := r.end.x - 16.0; var cy := r.get_center().y
			draw_polyline(PackedVector2Array([Vector2(cx - 6, cy + 3), Vector2(cx, cy - 3), Vector2(cx + 6, cy + 3)]), col, 2.0, true)
		"bus":
			var isel: bool = sel.get("t", "") == side and names.has(sel.get("name", ""))
			var acts := PackedFloat32Array(); acts.resize(names.size()); var mx := 0.0
			for i in names.size(): acts[i] = _chan_act(side, str(names[i])); mx = maxf(mx, acts[i])
			var task_driven := side == "out" or in_sensor.has(str(names[0])) or tele == null or tele.task == null
			var kicker := ("SENSOR" if task_driven else "INPUT") if side == "in" else "MOTOR"
			Gfx.index_card(self, r, col, kicker, "%s ×%d" % [str(it["stem"]), names.size()], mx, Gfx.serif(), Fonts.bold, fz, isel)
			# the activity comb: one tooth per member, as tall as that member is active
			var x0 := r.end.x - 10.0 - minf(float(names.size()) * 4.0, r.size.x * 0.42); var x1 := r.end.x - 10.0
			var yb := r.end.y - 9.0; var hmax := r.size.y * 0.34
			draw_line(Vector2(x0 - 2.0, yb), Vector2(x1 + 1.0, yb), Color(col, 0.6), 1.0, true)
			for i in names.size():
				var x := lerpf(x0, x1, (float(i) + 0.5) / float(names.size()))
				draw_line(Vector2(x, yb), Vector2(x, yb - 2.0 - hmax * acts[i]), Color(col, 0.55 + 0.45 * acts[i]), 2.0, true)
			if isel: draw_rect(r.grow(6.0), Color(Kit.GAMBOGE, 0.95), false, 2.0)
			for nm in names:
				if lesions.has(side + ":" + str(nm)): draw_rect(r.grow(2.0), Kit.RED, false, 2.2); break
		_:
			var name := str(names[0]); var ch := _chan("inputs" if side == "in" else "outputs", name)
			var isel2: bool = sel.get("t", "") == side and sel.get("name", "") == name
			var act := _chan_act(side, name)
			var task_driven2 := in_sensor.has(name) if side == "in" else true
			var kicker2 := ("SENSOR" if task_driven2 else "INPUT") if side == "in" else "MOTOR"
			Gfx.index_card(self, r, col, kicker2, name, act, Gfx.serif(), Fonts.bold, fz, isel2)
			if isel2: draw_rect(r.grow(6.0), Color(Kit.GAMBOGE, 0.95), false, 2.0)
			if lesions.has(side + ":" + name):   # a cut sensor
				draw_rect(r, Color(Gfx.SHEET, 0.6)); draw_rect(r.grow(2.0), Kit.RED, false, 2.2)
				draw_string(font, r.position + Vector2(r.size.x - 52.0, float(fz) + 3.0), "CUT", HORIZONTAL_ALIGNMENT_RIGHT, 46.0, fz, Kit.RED)
			if ch.is_empty(): return

## How active a channel is now, 0..1: a sensor by its value and the flashes of the cells it drives, a motor by its rate.
func _chan_act(side: String, name: String) -> float:
	if side == "out": return clampf(float(tele.rates.get(name, 0.0)) / 60.0, 0.0, 1.0) if tele != null else 0.0
	var ch := _chan("inputs", name)
	var act := 1.0 if float(ch.get("value", 0.0)) > 0.0 else 0.0
	if tele != null and tele.sim != null:
		for tg in ch.get("targets", []):
			var pi := Circuits.pop_index(circuit, Circuits.proj_pop(tg))
			if pi < 0: continue
			var f0 := Circuits.pop_first(circuit, pi)
			if tg is Dictionary and (tg as Dictionary).has("idx"):
				for k in tg["idx"]: act = maxf(act, _flash(f0 + int(k)))
			else:
				for k in Circuits.pop_n(circuit["populations"][pi]): act = maxf(act, _flash(f0 + k))
	return act

func _draw_cursor(h: Dictionary) -> void:
	var r := _anchor_rect(h, false)
	if str(h.get("t", "")) in ["ilink", "olink"]:
		for eo in _geo().get("edges", []):
			if _same(_link_hit(eo), h):
				draw_polyline(eo["pts"], Color(Kit.GAMBOGE, 0.9), 9.0, true); draw_polyline(eo["pts"], Color(Gfx.INK, 0.9), 2.0, true)
		return
	if str(h.get("t", "")) == "proj":
		var g := _geo(); var ax: Array = g.get("axons", [])
		var i := int(h.get("i", -1))
		if i >= 0 and i < ax.size() and not (ax[i] as Dictionary).is_empty():
			draw_polyline(ax[i]["pts"], Color(Kit.GAMBOGE, 0.9), 9.0, true); draw_polyline(ax[i]["pts"], Color(Gfx.INK, 0.9), 2.0, true)
		return
	if r.size == Vector2.ZERO: return
	var inner := StyleBoxFlat.new(); inner.draw_center = false; inner.border_color = Kit.TEXT; inner.set_border_width_all(3); inner.set_corner_radius_all(6)
	var outer := StyleBoxFlat.new(); outer.draw_center = false; outer.border_color = Kit.GAMBOGE; outer.set_border_width_all(3); outer.set_corner_radius_all(9)
	outer.draw(get_canvas_item(), r.grow(9.0)); inner.draw(get_canvas_item(), r.grow(6.0))

## Scaled-space rect of a hit element (a card, a population's outline); `screen`: editor-local instead.
func _anchor_rect(h: Dictionary, screen := true) -> Rect2:
	var g := _geo(); var r := Rect2()
	if h.has("key") and _cards_g.has(str(h["key"])): r = _cards_g[str(h["key"])]
	elif str(h.get("t", "")) in ["in", "out"] and _cards_g.has(str(h["t"]) + ":" + str(h.get("name", ""))): r = _cards_g[str(h["t"]) + ":" + str(h.get("name", ""))]
	elif str(h.get("t", "")) == "pop":
		var ix: Dictionary = g.get("ix", {})
		if ix.has(str(h["id"])): r = g["pops"][int(ix[str(h["id"])])]["box"]
	if screen and r.size != Vector2.ZERO: r = _g2s_rect(r)
	return r

## The editor-local point a wire leaves from or lands on for a hit element.
func _anchor(h: Dictionary) -> Vector2:
	if str(h.get("t", "")) == "proj": return proj_mid(int(h.get("i", -1)))
	if str(h.get("t", "")) in ["ilink", "olink"]:
		var lm := link_mid("in" if str(h["t"]) == "ilink" else "out", str(h.get("name", "")), str(h.get("pop", "")))
		return lm if lm != Vector2.INF else Vector2(-1e9, -1e9)
	var r := _anchor_rect(h)
	if r.size == Vector2.ZERO: return Vector2(-1e9, -1e9)
	if str(h.get("t", "")) == "in": return Vector2(r.end.x, r.get_center().y)
	if str(h.get("t", "")) == "out": return Vector2(r.position.x, r.get_center().y)
	return r.get_center()

## Does the circuit have the element a hint or verdict names (a population, "in:" / "out:" channel, "pop:ID", "proj:i" or "pre>post")?
func _element_exists(name: String) -> bool:
	if name == "": return false
	if name.begins_with("proj:"): return int(name.substr(5)) < circuit.get("projections", []).size()
	if ">" in name:
		var pq := name.split(">"); return Circuits.proj_between(circuit, pq[0].strip_edges(), pq[1].strip_edges()) >= 0
	var key := name.substr(4) if name.begins_with("pop:") else name
	if Circuits.pop_index(circuit, key) >= 0: return true
	for ch in circuit.get("inputs", []): if name in [str(ch.get("name", "")), "in:" + str(ch.get("name", ""))]: return true
	for ch in circuit.get("outputs", []): if name in [str(ch.get("name", "")), "out:" + str(ch.get("name", ""))]: return true
	return false

## Scaled-space geometry of a named element: {k:"pop", c, rad, box, has_box, ens, rx, ry} | {k:"rect", r} | {k:"proj", pts}; {} when there is no such thing.
func _element(name: String, pops: Array, axons: Array) -> Dictionary:
	if name == "": return {}
	var key := name
	if name.begins_with("pop:"): key = name.substr(4)
	var pj := -1
	if name.begins_with("proj:"): pj = int(name.substr(5))
	elif ">" in name:
		var pq := name.split(">"); pj = Circuits.proj_between(circuit, pq[0].strip_edges(), pq[1].strip_edges())
	if name.begins_with("proj:") or ">" in name:
		if pj >= 0 and pj < axons.size() and not (axons[pj] as Dictionary).is_empty(): return {"k": "proj", "pts": axons[pj]["pts"]}
		return {}
	var pd := _pop_dict(pops, key)
	if not pd.is_empty(): return {"k": "pop", "c": pd["c"], "rad": pd["rad"], "box": pd["box"], "has_box": int(pd["n"]) > 1, "ens": pd["ens"], "rx": pd.get("rx", 0.0), "ry": pd.get("ry", 0.0)}
	for cand in [name, "in:" + name, "out:" + name]:
		if _cards_g.has(cand): return {"k": "rect", "r": _cards_g[cand]}
	return {}

func _mark(el: Dictionary, col: Color, pulse: float) -> void:
	match str(el.get("k", "")):
		"pop":
			var c: Vector2 = el["c"]
			if bool(el["ens"]):
				var e := Gfx.ellipse(c, float(el["rx"]) + 9.0 + 5.0 * pulse, float(el["ry"]) + 9.0 + 5.0 * pulse, 64)
				draw_colored_polygon(e, Color(col, 0.08 + 0.06 * pulse)); e.append(e[0]); draw_polyline(e, Color(col, 0.75 + 0.25 * pulse), 3.2, true)
			elif bool(el["has_box"]):
				var bx: Rect2 = (el["box"] as Rect2).grow(7.0 + 4.0 * pulse)
				Gfx.rounded_rect(self, bx, Color(col, 0.10 + 0.08 * pulse), Color(col, 0.7 + 0.3 * pulse), minf(bx.size.x, bx.size.y) * 0.5 if bx.size.x < 90.0 or bx.size.y < 90.0 else 28.0, 3.0)
			else:
				var rr := float(el["rad"]) + 9.0 + 5.0 * pulse
				Gfx.glow(self, c, rr * 2.2, Color(col, 0.25 + 0.2 * pulse)); draw_arc(c, rr, 0, TAU, 48, Color(col, 0.75 + 0.25 * pulse), 3.2, true)
		"rect":
			var r: Rect2 = (el["r"] as Rect2).grow(5.0 + 3.0 * pulse)
			Gfx.rounded_rect(self, r, Color(col, 0.10 + 0.08 * pulse), Color(col, 0.75 + 0.25 * pulse), 10.0, 3.0)
		"proj":
			var pts: PackedVector2Array = el["pts"]
			draw_polyline(pts, Color(col, 0.25 + 0.2 * pulse), 12.0 + 4.0 * pulse, true); draw_polyline(pts, Color(col, 0.95), 3.4, true)

## The v0.3 overlays: hint outline (amber), verdict glow (red), and the celebration trail along the critical path (green).
func _draw_marks(pops: Array, axons: Array, now: float) -> void:
	var pulse := 0.5 + 0.5 * sin(now * 5.5) if Kit.motion() else 0.6
	if verdict_target != "": _mark(_element(verdict_target, pops, axons), Kit.GREEN if verdict_ok else Kit.RED, pulse)
	if hint_target != "": _mark(_element(hint_target, pops, axons), Kit.exc() if verdict_target != hint_target else Kit.RED, 1.0 - pulse)
	if trail_u < 0.0 or trail.size() < 2: return
	var pts := PackedVector2Array()
	for i in trail.size():
		var nm := str(trail[i])
		if nm.begins_with("in:") or nm.begins_with("out:"):
			if not _cards_g.has(nm): continue
			var r: Rect2 = _cards_g[nm]
			pts.append(Vector2(r.end.x, r.get_center().y) if nm.begins_with("in:") else Vector2(r.position.x, r.get_center().y)); continue
		var pd := _pop_dict(pops, nm)
		if pd.is_empty(): continue
		if i > 0 and not str(trail[i - 1]).begins_with("in:"):
			var pa := _pop_dict(pops, str(trail[i - 1]))
			if not pa.is_empty() and pa != pd:
				var cp := _axon(pa, pd); pts.append_array(Gfx.bez_points(cp[0], cp[1], cp[2], cp[3], 14)); continue
		pts.append(pd["c"])
	if pts.size() < 2: return
	var lens := PackedFloat32Array(); var tot := 0.0; lens.append(0.0)
	for i in range(1, pts.size()): tot += pts[i].distance_to(pts[i - 1]); lens.append(tot)
	draw_polyline(pts, Color(Kit.GAMBOGE, 0.22), 9.0, true)
	var head := trail_u * tot
	for i in range(1, pts.size()):
		if lens[i - 1] > head: break
		var a := pts[i - 1]; var b := pts[i]
		if lens[i] > head: b = a.lerp(b, (head - lens[i - 1]) / maxf(lens[i] - lens[i - 1], 0.001))
		var age := clampf((head - lens[i]) / maxf(tot * 0.45, 1.0), 0.0, 1.0)
		draw_line(a, b, Color(Kit.GREEN, 0.95 - 0.7 * age), 5.0 - 2.5 * age, true)
		Gfx.glow(self, b, 16.0 - 8.0 * age, Color(Kit.GREEN, 0.45 * (1.0 - age)))
	var hp := pts[0]
	for i in range(1, pts.size()):
		if lens[i] >= head: hp = pts[i - 1].lerp(pts[i], (head - lens[i - 1]) / maxf(lens[i] - lens[i - 1], 0.001)); break
		hp = pts[i]
	Gfx.wash(self, hp, 16.0, Kit.GAMBOGE, 0.6, 5); Gfx.bead(self, hp, 4.5, Kit.GREEN.darkened(0.3))

## A scale bar in the bottom-right corner, as on a plate: an inked rule with end ticks and an italic length (the model's 100 units).
func _draw_scale_bar() -> void:
	var fz := Kit.fs(14); var fi := Gfx.serif_italic()
	var px := 100.0 * view_scale; var unit := "100 µm"
	if px > size.x * 0.22: px *= 0.5; unit = "50 µm"
	if px < 30.0: px *= 5.0; unit = "500 µm"
	if px < 30.0: return
	var tw := fi.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x
	var y := size.y - 18.0 - inset_bottom; var x1 := size.x - 22.0 - tw - 10.0; var x0 := x1 - px
	if y < size.y * 0.5: return
	draw_line(Vector2(x0, y), Vector2(x1, y), Gfx.INK, 1.6, true)
	for x in [x0, x1]: draw_line(Vector2(x, y - 6.0), Vector2(x, y + 6.0), Gfx.INK, 1.4, true)
	draw_string(fi, Vector2(x1 + 10.0, y + float(fz) * 0.35), unit, HORIZONTAL_ALIGNMENT_LEFT, -1, fz, Kit.TEXT_SOFT)

## The zoom readout in the bottom-left corner ("100%"): click it to fit.
func _zoom_rect() -> Rect2:
	var fz := Kit.fs(14); var w := Fonts.mono.get_string_size("300%", HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x + 18.0
	var r := Rect2(Vector2(10.0, size.y - inset_bottom - float(fz) - 22.0), Vector2(w, float(fz) + 12.0))
	if not _g.is_empty():   # never over a card: right of the left card column
		for it in _g["items"]:
			var cr := _g2s_rect(it["rect"])
			if cr.grow(4.0).intersects(r): r.position.x = cr.end.x + 10.0
	return r

func _draw_zoom() -> void:
	var fz := Kit.fs(14); var r := _zoom_rect()
	if r.position.y < size.y * 0.5: return
	draw_rect(r, Color("#FBF7EE", 0.92)); draw_rect(r, Color(Gfx.INK, 0.55), false, 1.0)
	draw_string(Fonts.mono, r.position + Vector2(0, float(fz) + 3.0), "%d%%" % roundi(view_scale * 100.0), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fz, Kit.TEXT_SOFT)

func _draw_note(font: Font, fz: int) -> void:
	var zr := _zoom_rect(); var tw := minf(font.get_string_size(_note, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x + 20.0, size.x - zr.end.x - 30.0)
	var r := Rect2(Vector2(zr.end.x + 8.0, zr.position.y), Vector2(tw, zr.size.y))
	draw_rect(Rect2(r.position + Vector2(3, 3), r.size), Color(Gfx.INK, 0.10)); draw_rect(r, Color("#FBF7EE")); draw_rect(r, Color(Kit.GAMBOGE, 0.95), false, 1.4)
	draw_string(font, r.position + Vector2(10.0, float(fz) + 3.0), _note, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16.0, fz, Kit.TEXT)

# ---------- hit testing ----------
func _hit(p: Vector2) -> Dictionary:
	if circuit.is_empty(): return {}
	var g := _geo()
	var q := _s2g(p)
	for it in g["items"]:
		if (it["rect"] as Rect2).grow(4.0).has_point(q):
			var names: Array = it["names"]
			var h := {"t": str(it["side"]), "name": str(names[0]), "key": str(it["key"])}
			if str(it["type"]) != "card": h["bus"] = str(it["type"])
			return h
	var cell := Vector2i(floori(q.x / GRID), floori(q.y / GRID))
	var cand: Array = g["grid"].get(cell, [])
	var P: Array = g["pops"]
	var best := {}; var bd := INF
	for item in cand:
		if int(item[0]) == 0:
			var pd: Dictionary = P[int(item[1])]; var pt: Vector2 = (pd["pts"] as PackedVector2Array)[int(item[2])]
			var d := pt.distance_to(q)
			if d <= _rg + 5.0 and d < bd: bd = d; best = {"t": "pop", "id": pd["id"], "rim": d > _rg * 0.62, "at": _g2s(pt)}
	if not best.is_empty(): return best
	for item in cand:
		if int(item[0]) == 1:
			var pd: Dictionary = P[int(item[1])]; var c: Vector2 = pd["c"]
			var v := q - c; var nn := sqrt(pow(v.x / float(pd["rx"]), 2.0) + pow(v.y / float(pd["ry"]), 2.0))
			if nn <= 1.06: return {"t": "pop", "id": pd["id"], "rim": nn > 0.78, "at": _g2s(_edge_pt(pd, v.normalized() if v.length() > 0.01 else Vector2.RIGHT))}
	var ax: Array = g["axons"]; var bpj := -1; var bdist := 11.0; var tried := {}
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			var ids: PackedInt32Array = g["agrid"].get(cell + Vector2i(dx, dy), PackedInt32Array())
			for pj in ids:
				if tried.has(pj): continue
				tried[pj] = true
				var pts: PackedVector2Array = ax[pj]["pts"]
				for k in range(1, pts.size()):
					var d2 := Geometry2D.get_closest_point_to_segment(q, pts[k - 1], pts[k]).distance_to(q)
					if d2 < bdist: bdist = d2; bpj = pj
	if bpj >= 0: return {"t": "proj", "i": bpj}
	if not editable: return {}
	var best_e := -1; var ed_d := 9.0   # the dashed links between a sensor card and a cell, a cell and a motor card
	var edges: Array = g["edges"]
	for ei in edges.size():
		var epts: PackedVector2Array = edges[ei]["pts"]
		for k in range(1, epts.size()):
			var d3 := Geometry2D.get_closest_point_to_segment(q, epts[k - 1], epts[k]).distance_to(q)
			if d3 < ed_d: ed_d = d3; best_e = ei
	if best_e >= 0: return _link_hit(edges[best_e])
	return {}

## The hit dictionary of a channel link (one entry of the geometry's "edges").
func _link_hit(eo: Dictionary) -> Dictionary:
	var nms: Array = (eo["item"] as Dictionary)["names"]
	return {"t": "ilink" if bool(eo["in"]) else "olink", "name": str(nms[0]), "pop": str(eo["pid"]), "names": nms}

# ---------- card positions ----------
## The offset (model units) the player moved a card by: meta.editor.cards = {"in:<name>" | "out:<name>" | "bus:in:<stem>": [dx, dy]}, relative to where the layout puts it.
func _card_off(key: String) -> Vector2:
	var meta: Variant = circuit.get("meta", {})
	if not (meta is Dictionary): return Vector2.ZERO
	var ed: Variant = (meta as Dictionary).get("editor", {})
	if not (ed is Dictionary): return Vector2.ZERO
	var co: Variant = (ed as Dictionary).get("cards", {})
	if not (co is Dictionary) or not (co as Dictionary).has(key): return Vector2.ZERO
	var a: Variant = (co as Dictionary)[key]
	return Vector2(float(a[0]), float(a[1])) if a is Array and (a as Array).size() >= 2 else Vector2.ZERO

func _set_card_off(key: String, v: Vector2) -> void:
	if not (circuit.get("meta") is Dictionary): circuit["meta"] = {}
	var meta: Dictionary = circuit["meta"]
	if not (meta.get("editor") is Dictionary): meta["editor"] = {}
	var ed: Dictionary = meta["editor"]
	if not (ed.get("cards") is Dictionary): ed["cards"] = {}
	var co: Dictionary = ed["cards"]
	if v.length() < 0.01: co.erase(key)
	else: co[key] = [v.x, v.y]
	if co.is_empty(): ed.erase("cards")

## The key a selected sensor or motor card is moved by ("" when none is selected).
func _sel_card_key() -> String:
	for it in _geo().get("items", []):
		if str(it["type"]) == "head" or str(it["side"]) != str(sel.get("t", "")): continue
		if (it["names"] as Array).has(sel.get("name", "")): return str(it["key"])
	return ""

## The editor-local midpoint of the link a sensor ("in") or motor ("out") card has to the group `pop` (for overlays and tests); INF when there is none.
func link_mid(side: String, name: String, pop: String) -> Vector2:
	for eo in _geo().get("edges", []):
		if bool(eo["in"]) == (side == "in") and str(eo["pid"]) == pop and ((eo["item"] as Dictionary)["names"] as Array).has(name):
			var pts: PackedVector2Array = eo["pts"]
			return _g2s(pts[pts.size() / 2])
	return Vector2.INF

# ---------- input ----------
func _gui_input(e: InputEvent) -> void:
	if circuit.is_empty(): return
	if e is InputEventMouseMotion: _on_motion(e)
	elif e is InputEventMouseButton: _on_button(e)
	elif e is InputEventMagnifyGesture: zoom_at(e.position, e.factor); accept_event()
	elif e is InputEventPanGesture: pan_by(-e.delta * 18.0); accept_event()
	elif e is InputEventScreenTouch or e is InputEventScreenDrag: _on_touch(e)
	elif e is InputEventKey and e.pressed: _on_key_focused(e)
	elif e is InputEventJoypadButton and e.pressed: _on_pad_focused(e)

func _on_motion(e: InputEventMouseMotion) -> void:
	var mode := str(_drag.get("mode", ""))
	if mode == "pan":
		pan_by(e.position - (_drag["last"] as Vector2)); _drag["last"] = e.position
		if _space > 0: _space = 2
		return
	var h := _hit(e.position)
	if h != _hover: _hover = h; queue_redraw()
	if mode == "move":
		var d: Vector2 = (e.position - _drag["last"]) / view_scale; _drag["last"] = e.position
		if editable:
			for id in _drag["ids"]: _move_pop(str(id), d)
			_drag["moved"] = true; _rev += 1
		queue_redraw()
	elif mode == "cardmove":
		if editable:
			if not bool(_drag["moved"]) and (e.position - (_drag["start"] as Vector2)).length() > 4.0: _drag["moved"] = true   # a click is not a move
			if bool(_drag["moved"]):
				var dm: Vector2 = (e.position - (_drag["last"] as Vector2)) / view_scale; _drag["last"] = e.position
				_set_card_off(str(_drag["key"]), _card_off(str(_drag["key"])) + dm); _rev += 1
		queue_redraw()
	elif mode == "connect": _drag["to"] = e.position; queue_redraw()
	elif mode == "band": _drag["to"] = e.position; queue_redraw()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not h.is_empty() else Control.CURSOR_ARROW

func _on_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_LEFT:
			if e.pressed:
				if _zoom_rect().has_point(e.position): fit(); accept_event(); return
				if _space > 0 or (Layout.touch and _hit(e.position).is_empty() and not lesion_mode and tool != "connect"): _drag = {"mode": "pan", "last": e.position}; return
				_press(e.position, e.shift_pressed)
			else: _release(e.position, e.shift_pressed)
		MOUSE_BUTTON_MIDDLE:
			if e.pressed: _drag = {"mode": "pan", "last": e.position}
			elif _drag.get("mode", "") == "pan": _drag = {}
			accept_event()
		MOUSE_BUTTON_RIGHT:
			if e.pressed and not lesion_mode:
				var h := _hit(e.position)
				if not h.is_empty() and editable: select(h); delete_selected()
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				var f := pow(1.12, maxf(e.factor, 1.0) if e.factor > 0.0 else 1.0)
				zoom_at(e.position, f if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / f)
			accept_event()
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			if e.pressed: pan_by(Vector2(40.0 if e.button_index == MOUSE_BUTTON_WHEEL_LEFT else -40.0, 0.0))
			accept_event()

## Two fingers: pinch to zoom, move to pan. (One finger arrives as the mouse.)
func _on_touch(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		if e.pressed: _touch[e.index] = e.position
		else: _touch.erase(e.index)
		_pinch = {}
		if _touch.size() >= 2: _drag = {}
		return
	_touch[e.index] = e.position
	if _touch.size() < 2: return
	var ks := _touch.keys(); var a: Vector2 = _touch[ks[0]]; var b: Vector2 = _touch[ks[1]]
	var mid := (a + b) * 0.5; var dist := maxf(a.distance_to(b), 1.0)
	if not _pinch.is_empty():
		pan_by(mid - (_pinch["mid"] as Vector2))
		zoom_at(mid, dist / float(_pinch["dist"]))
	_pinch = {"mid": mid, "dist": dist}
	accept_event()

## Zoom by `f` about editor-local point `p` (the point under the pointer stays put).
func zoom_at(p: Vector2, f: float) -> void:
	var ns := clampf(view_scale * f, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(ns, view_scale): return
	_fit_pending = false
	var m := (p - view_off) / view_scale
	view_scale = ns; view_off = p - m * view_scale; _zoom_ms = Time.get_ticks_msec()
	view_changed.emit(); queue_redraw()

func pan_by(d: Vector2) -> void:
	if d == Vector2.ZERO: return
	_fit_pending = false; view_off += d; view_changed.emit(); queue_redraw()

func set_zoom(z: float) -> void: zoom_at(size * 0.5, z / view_scale)

func _press(p: Vector2, shift := false) -> void:
	grab_focus(); _kbd = false
	var h := _hit(p)
	if lesion_mode:
		if not h.is_empty() and ["pop", "proj", "in"].has(str(h["t"])):
			if h.has("bus"): _toggle_bus(h); return
			lesion_clicked.emit(h)
		return
	if tool == "connect" and editable:
		if h.is_empty(): _connect_from = {}; select({}); return
		if _connect_from.is_empty():
			if h["t"] == "pop" or h["t"] == "in": _connect_from = h; select(h)
		else:
			_make_link(_connect_from, h); _connect_from = {}
		queue_redraw(); return
	if h.is_empty():
		if not shift: select({})
		_drag = {"mode": "band", "from": p, "to": p, "add": shift}
		return
	if str(h.get("bus", "")) == "head": _toggle_bus(h); return
	if h["t"] == "pop":
		var id := str(h["id"])
		if shift:
			if msel.has(id) and msel.size() > 1:
				msel.erase(id)
				if sel.get("id", "") == id: _set_sel({"t": "pop", "id": msel.keys()[0]})
				queue_redraw(); return
			msel[id] = true; _set_sel({"t": "pop", "id": id}); queue_redraw()
		elif msel.has(id) and msel.size() > 1: _set_sel({"t": "pop", "id": id})   # keep the group: a drag moves all of it
		else: select(h)
		if editable:
			if bool(h.get("rim", false)) and msel.size() <= 1: _drag = {"mode": "connect", "src": h, "from_pt": h["at"], "to": p}
			else: _drag = {"mode": "move", "ids": msel.keys() if msel.has(id) else [id], "last": p, "moved": false}
		return
	if str(h.get("bus", "")) == "bus":
		var r: Rect2 = _g2s_rect(_cards_g[str(h["key"])])
		if editable and ((h["t"] == "in" and p.x > r.end.x - 26.0) or (h["t"] == "out" and p.x < r.position.x + 26.0)):
			select(h); _drag = {"mode": "connect", "src": h, "from_pt": Vector2(r.end.x, r.get_center().y) if h["t"] == "in" else Vector2(r.position.x, r.get_center().y), "to": p}
			return
		select(h)
		if editable: _drag = {"mode": "cardmove", "key": str(h["key"]), "last": p, "start": p, "moved": false, "toggle": h}   # a click opens or folds the bus, a drag moves its card
		else: _toggle_bus(h)
		return
	select(h)
	if h["t"] == "in" and editable and h["name"] != "":
		var r2: Rect2 = _g2s_rect(_cards_g["in:" + str(h["name"])])
		if p.x > r2.end.x - 26.0: _drag = {"mode": "connect", "src": h, "from_pt": Vector2(r2.end.x, r2.get_center().y), "to": p}; return
	if editable and (h["t"] == "in" or h["t"] == "out") and h.has("key"): _drag = {"mode": "cardmove", "key": str(h["key"]), "last": p, "start": p, "moved": false}   # a sensor or motor card is dragged anywhere

func _release(p: Vector2, shift := false) -> void:
	var mode := str(_drag.get("mode", ""))
	if mode == "connect":
		var tgt := _hit(p)
		if not tgt.is_empty(): _make_link(_drag["src"], tgt)
	elif mode == "move" and bool(_drag.get("moved", false)): _drag = {}; commit_now(); moved.emit()
	elif mode == "cardmove":
		if bool(_drag.get("moved", false)): _drag = {}; commit_now(); moved.emit()   # one undo step; saved with the circuit
		elif _drag.has("toggle"): _toggle_bus(_drag["toggle"])
	elif mode == "band":
		var br := Rect2(_drag["from"], Vector2.ZERO).expand(p)
		if br.size.length() > 6.0: _band_select(br, bool(_drag.get("add", false)) or shift)
	_drag = {}; queue_redraw()

## Select every population whose outline the box (editor-local) overlaps by its centre or covers.
func _band_select(br: Rect2, add: bool) -> void:
	var g := _geo(); var q := Rect2(_s2g(br.position), br.size / _k())
	if not add: msel = {}
	var last := ""
	for p in g["pops"]:
		if q.has_point(p["c"]) or q.encloses(p["box"]): msel[p["id"]] = true; last = str(p["id"])
	if last != "": _set_sel({"t": "pop", "id": last})
	elif not add: _set_sel({})
	queue_redraw()

func _toggle_bus(h: Dictionary) -> void:
	var k := str(h.get("key", "")).trim_prefix("bus:")
	if k == "": return
	if _bus_open.has(k): _bus_open.erase(k)
	else: _bus_open[k] = true
	_rev += 1; queue_redraw()

func _make_link(src: Dictionary, dst: Dictionary) -> void:
	if src.is_empty() or dst.is_empty() or not editable: return
	if src["t"] == "pop" and dst["t"] == "pop" and Circuits.has_locked_wiring(circuit): note(Circuits.LOCK_NEW, 6.0); return   # the wiring is given
	if (src["t"] == "in" or dst["t"] == "out") and Circuits.has_locks(circuit): note(Circuits.LOCK_IO, 6.0); return
	if src["t"] == "pop" and dst["t"] == "pop":
		var before: int = circuit["projections"].size(); var idx := Circuits.add_projection(circuit, str(src["id"]), str(dst["id"]))
		select({"t": "proj", "i": idx})
		if circuit["projections"].size() != before: structure_changed.emit()
	elif src["t"] == "in" and dst["t"] == "pop":
		if Circuits.wire_family(circuit, "inputs", str(src["name"]), str(dst["id"])) > 0: structure_changed.emit(); return   # a group of n onto a family of n sensors: sensor k to neuron k
		var names: Array = _bus_names(src)
		var changed := false
		for nm in names: changed = _wire_input(str(nm), str(dst["id"])) or changed
		if changed: structure_changed.emit()
	elif src["t"] == "pop" and dst["t"] == "out":
		if Circuits.wire_family(circuit, "outputs", str(dst["name"]), str(src["id"])) > 0: structure_changed.emit(); return   # a group of n onto a family of n motors: neuron k to motor k
		var changed2 := false
		for nm in _bus_names(dst):
			var ch := _chan("outputs", str(nm))
			if ch.is_empty(): continue
			var tg: Array = ch.get("neurons", [])
			if tg.any(func(x): return Circuits.proj_pop(x) == str(src["id"])): continue
			tg.append(str(src["id"])); ch["neurons"] = tg; changed2 = true
		if changed2: structure_changed.emit()

## The channel names a hit stands for: every member of a bus card, else its one name.
func _bus_names(h: Dictionary) -> Array:
	if str(h.get("bus", "")) != "" and h.has("key"):
		for it in _geo().get("items", []):
			if str(it["key"]) == str(h["key"]): return it["names"]
	return [str(h.get("name", ""))]

func _wire_input(name: String, pid: String) -> bool:
	var ch := _chan("inputs", name)
	if ch.is_empty(): return false
	var tg: Array = ch.get("targets", [])
	for x in tg:
		if Circuits.proj_pop(x) == pid: return false
	if tg.is_empty():   # first connection: a weight that makes that neuron model fire (not a silent 120 pA onto a 20 nS cell)
		var pi := Circuits.pop_index(circuit, pid)
		if pi >= 0: ch["weight"] = Circuits.first_input_weight(circuit, ch, str(circuit["populations"][pi].get("model", "iaf_psc_alpha")))
	tg.append(pid); ch["targets"] = tg; return true

func _move_pop(id: String, d: Vector2) -> void:
	var pi := Circuits.pop_index(circuit, id); if pi < 0: return
	for q in circuit["populations"][pi]["pos"]: q[0] = float(q[0]) + d.x; q[1] = float(q[1]) + d.y

func _set_sel(s: Dictionary) -> void:
	if s == sel: return
	sel = s; selection_changed.emit(sel); queue_redraw()

func select(h: Dictionary) -> void:
	var s := {}
	if not h.is_empty():
		s = {"t": h["t"]}
		for k in ["id", "i", "name", "pop", "names"]:
			if h.has(k): s[k] = h[k]
	msel = {str(s["id"]): true} if str(s.get("t", "")) == "pop" else {}
	if s == sel: queue_redraw(); return
	sel = s; selection_changed.emit(sel); queue_redraw()

## Select every population.
func select_all() -> void:
	msel = {}
	for p in circuit.get("populations", []): msel[str(p.get("id", ""))] = true
	if not msel.is_empty(): _set_sel({"t": "pop", "id": msel.keys().back()})
	queue_redraw()

func selected_pops() -> Array:
	if not msel.is_empty(): return msel.keys()
	return [str(sel["id"])] if str(sel.get("t", "")) == "pop" else []

func delete_selected() -> void:
	if not editable or (sel.is_empty() and msel.is_empty()): return
	if msel.size() > 1:
		var kept_locked := 0
		for id in msel.keys():
			var lp := Circuits.pop_index(circuit, str(id))
			if lp >= 0 and Circuits.is_locked(circuit["populations"][lp]): kept_locked += 1
			else: Circuits.remove_population(circuit, str(id))
		if kept_locked > 0: note(Circuits.LOCK_POP, 6.0)   # the locked ones stay, and the editor says why
		msel = {}; sel = {}; selection_changed.emit(sel); structure_changed.emit(); queue_redraw(); return
	match str(sel.get("t", "")):
		"pop":
			var dp := Circuits.pop_index(circuit, str(sel["id"]))
			if dp >= 0 and Circuits.is_locked(circuit["populations"][dp]): note(Circuits.LOCK_POP, 6.0); return
			Circuits.remove_population(circuit, str(sel["id"]))
		"proj":
			if Circuits.is_locked(circuit["projections"][int(sel["i"])]): note(Circuits.LOCK_PROJ, 6.0); return
			circuit["projections"].remove_at(int(sel["i"]))
		"ilink", "olink":   # one link: the sensor or motor stays, the cell stays, only this connection goes
			if Circuits.has_locks(circuit): note(Circuits.LOCK_IO, 6.0); return
			_unlink(sel)
		"in":
			if not is_free_input(str(sel["name"])): return   # a task's sensors stay
			var keep := []
			for ch in circuit["inputs"]:
				if str(ch.get("name", "")) != str(sel["name"]): keep.append(ch)
			circuit["inputs"] = keep
		_: return
	sel = {}; msel = {}; selection_changed.emit(sel); structure_changed.emit(); queue_redraw()

## Remove the link `l` ({t: "ilink" | "olink", names, pop}): the group `pop` leaves the targets of the sensor (or the neurons of the motor) card, every member of a bus card.
func _unlink(l: Dictionary) -> void:
	var is_in := str(l.get("t", "")) == "ilink"
	var names: Array = l.get("names", [l.get("name", "")])
	for nm in names:
		var ch := _chan("inputs" if is_in else "outputs", str(nm))
		if ch.is_empty(): continue
		var key := "targets" if is_in else "neurons"
		var keep := []
		for x in ch.get(key, []):
			if str(Circuits.proj_pop(x)) != str(l.get("pop", "")): keep.append(x)
		ch[key] = keep

## True for an input the player added (noise): not one of the task's sensors.
func is_free_input(name: String) -> bool:
	if tele != null and tele.task != null and (tele.task.sensor_channels() as PackedStringArray).has(name): return false
	return true

## A free spot right of the existing neurons for a newly added one.
func free_spot() -> Vector2:
	var ns := _neurons(); if ns.is_empty(): return Vector2(300, 240)
	var bb := _bbox(ns); var best := Vector2(bb.end.x + 110.0, bb.get_center().y)
	for k in 40:
		var cand := Vector2(bb.position.x + 70.0 + (k % 6) * 110.0, bb.end.y + 100.0 + (k / 6) * 80.0) if k > 0 else best
		var ok := true
		for n in ns:
			if (n["pos"] as Vector2).distance_to(cand) < 80.0: ok = false; break
		if ok: return cand
	return best

# ---------- clipboard ----------
## Copy the selected groups (with the axons between them) to the bench clipboard. Returns how many groups were copied.
func copy_selection() -> int:
	var ids := selected_pops()
	if ids.is_empty(): return 0
	CircuitClip.clip = CircuitClip.fragment(circuit, ids, false)
	note("Copied %d group%s" % [ids.size(), "" if ids.size() == 1 else "s"])
	return ids.size()

## Paste fragment `f` (the clipboard by default) centred on editor-local point `at` (the canvas centre when off the bench). Returns {ids, dropped} or
## {error}; the pasted groups are selected. One undo step.
func paste_fragment(f: Dictionary = {}, at := Vector2(-1, -1)) -> Dictionary:
	if f.is_empty(): f = CircuitClip.clip
	if not editable: return {"error": "the bench is read-only"}
	if Circuits.has_locks(circuit): note(Circuits.LOCK_PASTE, 6.0); return {"error": "the circuit of this level is given and locked"}
	if not CircuitClip.is_fragment(f) or (f["pops"] as Array).is_empty(): return {"error": "nothing to paste"}
	commit_now()
	var before := _snap(circuit)
	if at.x < 0.0 or not Rect2(Vector2.ZERO, size).has_point(at): at = size * 0.5
	var r := CircuitClip.paste(circuit, f, to_model(at) - CircuitClip.center(f))
	var bad := Circuits.validate(circuit)
	if bad != "":
		var d := Circuits.parse(before); circuit.clear(); circuit.merge(d); _rev += 1; queue_redraw()
		return {"error": bad}
	msel = {}
	for id in r["ids"]: msel[str(id)] = true
	sel = {"t": "pop", "id": str((r["ids"] as Array).back())}
	_rev += 1; selection_changed.emit(sel); structure_changed.emit(); queue_redraw()
	return r

func paste_clip() -> Dictionary:
	var r := paste_fragment({}, get_local_mouse_position())
	if not r.has("error"): note("Pasted %d group%s" % [(r["ids"] as Array).size(), "" if (r["ids"] as Array).size() == 1 else "s"])
	return r

## Ctrl+D: a copy of the selection, offset down and right.
func duplicate_selection() -> Dictionary:
	var ids := selected_pops()
	if ids.is_empty(): return {"error": "nothing selected"}
	var f := CircuitClip.fragment(circuit, ids, false)
	var r := paste_fragment(f, _raw_to_screen(CircuitClip.center(f) + Vector2(60.0, 60.0)))
	if not r.has("error"): note("Duplicated %d group%s" % [ids.size(), "" if ids.size() == 1 else "s"])
	return r

# ---------- keyboard and pad ----------
## The lab's Esc: cancels a wire in progress (keyboard, connect tool, drag). True when there was one.
func cancel_pending() -> bool:
	if not _wire.is_empty() or not _connect_from.is_empty() or not _drag.is_empty():
		_wire = {}; _connect_from = {}; _drag = {}; queue_redraw(); return true
	return false

func _blocked() -> bool:
	return not is_visible_in_tree() or circuit.is_empty() or (blocked.is_valid() and bool(blocked.call()))

func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or _blocked(): return
	var fo := get_viewport().gui_get_focus_owner()
	if fo != null and fo != self and (fo is LineEdit or fo is TextEdit): return
	var ctrl := k.ctrl_pressed or k.meta_pressed
	if k.keycode == KEY_SPACE and not ctrl:
		if k.pressed and not k.echo: _space = 1
		elif not k.pressed:
			if _space == 1: command.emit("run")
			_space = 0
			if _drag.get("mode", "") == "pan": _drag = {}
		get_viewport().set_input_as_handled(); return
	if not k.pressed or k.echo: return
	var done := true
	if ctrl:
		match k.keycode:
			KEY_Z: (redo() if k.shift_pressed else undo())
			KEY_Y: redo()
			KEY_C: copy_selection()
			KEY_V: paste_clip()
			KEY_D: duplicate_selection()
			KEY_A: select_all()
			_: done = false
	else:
		match k.keycode:
			KEY_F: fit()
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD: zoom_at(size * 0.5, 1.25)
			KEY_MINUS, KEY_KP_SUBTRACT: zoom_at(size * 0.5, 0.8)
			KEY_C: command.emit("check")
			KEY_R: command.emit("reset")
			KEY_I: _inspect()
			KEY_DELETE, KEY_BACKSPACE: delete_selected()
			_: done = false
	if done: get_viewport().set_input_as_handled()

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventJoypadButton and e.pressed and e.button_index == JOY_BUTTON_START and not _blocked():
		command.emit("run"); get_viewport().set_input_as_handled()

## Keys while the bench has the focus: the cursor (Tab / arrows), Enter, W, Shift+arrows nudge the selection.
func _on_key_focused(e: InputEventKey) -> void:
	if e.ctrl_pressed or e.meta_pressed or e.alt_pressed: return
	var dir := Vector2.ZERO
	match e.keycode:
		KEY_LEFT: dir = Vector2.LEFT
		KEY_RIGHT: dir = Vector2.RIGHT
		KEY_UP: dir = Vector2.UP
		KEY_DOWN: dir = Vector2.DOWN
	if dir != Vector2.ZERO:
		if e.shift_pressed and editable and not selected_pops().is_empty():
			for id in selected_pops(): _move_pop(str(id), dir * 10.0 / maxf(view_scale, 0.3))
			_rev += 1; commit_now(); moved.emit(); queue_redraw(); accept_event(); return
		if e.shift_pressed and editable and str(sel.get("t", "")) in ["in", "out"] and _sel_card_key() != "":   # Shift + arrows also nudges a selected sensor or motor card
			var ck := _sel_card_key()
			_set_card_off(ck, _card_off(ck) + dir * 10.0 / maxf(view_scale, 0.3)); _rev += 1; commit_now(); moved.emit(); queue_redraw(); accept_event(); return
		if cursor_move(dir): accept_event()
		return
	match e.keycode:
		KEY_TAB: cursor_step(-1 if e.shift_pressed else 1); accept_event()
		KEY_ENTER, KEY_KP_ENTER: cursor_accept(); accept_event()
		KEY_W: cursor_wire(); accept_event()

func _on_pad_focused(e: InputEventJoypadButton) -> void:
	var dir := Vector2.ZERO
	match e.button_index:
		JOY_BUTTON_DPAD_LEFT: dir = Vector2.LEFT
		JOY_BUTTON_DPAD_RIGHT: dir = Vector2.RIGHT
		JOY_BUTTON_DPAD_UP: dir = Vector2.UP
		JOY_BUTTON_DPAD_DOWN: dir = Vector2.DOWN
		JOY_BUTTON_A: cursor_accept(); accept_event(); return
		JOY_BUTTON_X: cursor_wire(); accept_event(); return
		JOY_BUTTON_Y: _inspect(); accept_event(); return
		JOY_BUTTON_LEFT_SHOULDER: zoom_at(size * 0.5, 0.8); accept_event(); return
		JOY_BUTTON_RIGHT_SHOULDER: zoom_at(size * 0.5, 1.25); accept_event(); return
	if dir != Vector2.ZERO and cursor_move(dir): accept_event()

## Everything the cursor can stand on, in reading order: cards left, groups, cards right, then axons. [{h, p (scaled space)}]
func _nav_items() -> Array:
	var g := _geo(); var out := []
	if g.is_empty(): return out
	for it in g["items"]:
		if str(it["side"]) != "in": continue
		out.append({"h": _item_hit(it), "p": (it["rect"] as Rect2).get_center()})
	for p in g["pops"]: out.append({"h": {"t": "pop", "id": p["id"]}, "p": p["c"]})
	for it in g["items"]:
		if str(it["side"]) != "out": continue
		out.append({"h": _item_hit(it), "p": (it["rect"] as Rect2).get_center()})
	var ax: Array = g["axons"]
	for pj in ax.size():
		if (ax[pj] as Dictionary).is_empty(): continue
		var cp: PackedVector2Array = ax[pj]["cp"]
		out.append({"h": {"t": "proj", "i": pj}, "p": Gfx.bez(cp[0], cp[1], cp[2], cp[3], 0.5)})
	if editable:   # the links between a sensor card and a cell, a cell and a motor card: the cursor reaches them like axons
		for eo in g.get("edges", []):
			var epts: PackedVector2Array = eo["pts"]
			out.append({"h": _link_hit(eo), "p": epts[epts.size() / 2]})
	return out

func _item_hit(it: Dictionary) -> Dictionary:
	var h := {"t": str(it["side"]), "name": str((it["names"] as Array)[0]), "key": str(it["key"])}
	if str(it["type"]) != "card": h["bus"] = str(it["type"])
	return h

func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty() or str(a.get("t", "")) != str(b.get("t", "")): return false
	match str(a["t"]):
		"pop": return str(a.get("id", "")) == str(b.get("id", ""))
		"proj": return int(a.get("i", -1)) == int(b.get("i", -2))
		"ilink", "olink": return str(a.get("name", "")) == str(b.get("name", "")) and str(a.get("pop", "")) == str(b.get("pop", "-"))
	return str(a.get("key", a.get("name", ""))) == str(b.get("key", b.get("name", "")))

func _cursor_index(items: Array) -> int:
	for i in items.size():
		if _same(items[i]["h"], _cursor): return i
	return -1

func _cursor_start(items: Array) -> int:
	if not sel.is_empty():
		for i in items.size():
			if _same(items[i]["h"], sel if (not sel.has("name") or str(sel["t"]) in ["ilink", "olink"]) else {"t": sel["t"], "name": sel["name"], "key": str(sel["t"]) + ":" + str(sel["name"])}): return i
	for i in items.size():
		if str(items[i]["h"]["t"]) == "pop": return i
	return 0

## Tab / Shift+Tab: the next / previous element.
func cursor_step(d: int) -> void:
	var items := _nav_items()
	if items.is_empty(): return
	var i := _cursor_index(items)
	i = _cursor_start(items) if i < 0 else posmod(i + d, items.size())
	_set_cursor(items[i]["h"])

## Arrows / D-pad: the nearest element in that direction. False when there is none (the focus may then leave the bench).
func cursor_move(dir: Vector2) -> bool:
	var items := _nav_items()
	if items.is_empty(): return false
	var i := _cursor_index(items)
	if i < 0: _set_cursor(items[_cursor_start(items)]["h"]); return true
	var p0: Vector2 = items[i]["p"]; var best := -1; var bs := INF
	for j in items.size():
		if j == i: continue
		var v: Vector2 = (items[j]["p"] as Vector2) - p0; var l := v.length()
		if l < 1.0: continue
		var cs := v.dot(dir) / l
		if cs < 0.5: continue
		var s := l * (1.0 + 2.0 * (1.0 - cs))
		if str(items[j]["h"]["t"]) in ["proj", "ilink", "olink"]: s *= 1.6   # cells and cards before the axons and links between them
		if s < bs: bs = s; best = j
	if best < 0: return false
	_set_cursor(items[best]["h"]); return true

func _set_cursor(h: Dictionary) -> void:
	_cursor = h; _kbd = true
	var r := _anchor_rect(h)   # keep it in view
	if r.size != Vector2.ZERO:
		var vis := Rect2(Vector2.ZERO, size).grow(-30.0)
		if not vis.encloses(r):
			var d := Vector2.ZERO
			if r.position.x < vis.position.x: d.x = vis.position.x - r.position.x
			elif r.end.x > vis.end.x: d.x = vis.end.x - r.end.x
			if r.position.y < vis.position.y: d.y = vis.position.y - r.position.y
			elif r.end.y > vis.end.y: d.y = vis.end.y - r.end.y
			pan_by(d)
	queue_redraw()

## Enter / A: select the element under the cursor (open or fold a bus), or finish the wire started with W / X.
func cursor_accept() -> void:
	if _cursor.is_empty(): cursor_step(1); return
	if not _wire.is_empty():
		var src := _wire; _wire = {}
		_make_link(src, _cursor); queue_redraw(); return
	if lesion_mode:
		if ["pop", "proj", "in"].has(str(_cursor["t"])) and not _cursor.has("bus"): lesion_clicked.emit(_cursor)
		return
	if _cursor.has("bus"):
		_toggle_bus(_cursor)
		var items := _nav_items()   # the cursor stays on the same family (its head tab or bus card)
		for it in items:
			if str(it["h"].get("bus", "")) != "" and str(it["h"]["key"]) == str(_cursor["key"]): _cursor = it["h"]; break
	select(_cursor)

## W / X: start a wire from the cursor (a group or an input card); Enter / A on the target completes it, Esc / B cancels.
func cursor_wire() -> void:
	if not editable or _cursor.is_empty(): return
	if str(_cursor["t"]) in ["pop", "in"]: _wire = _cursor.duplicate(); note("Wire from %s: move to the target and press Enter (A)" % str(_cursor.get("id", _cursor.get("name", ""))), 4.0)
	queue_redraw()

func _inspect() -> void:
	if _kbd and not _cursor.is_empty(): select(_cursor)
	command.emit("inspect")
