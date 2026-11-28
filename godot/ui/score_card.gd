class_name ScoreCard
extends Control
## The score read-out, as on the identity's plate (docs/identity/cajal-lab.png): a 96 px rubber-stamp ring with the score in Fraunces (vermilion while it
## fails, viridian once it passes), the earned stars in gamboge, and one row per pass criterion with a mark (✓ ink = met, ✗ vermilion = not met,
## • gamboge = still waiting). The engine's raw score parts sit behind "Details", every one under a human label (ScoreCard.human), never a raw key.
var tele: Telemetry = null
var _was_passed := false
var guilty := ""                   # v0.3 verdict highlight: the score part the failed verdict is about gets a red outline (in Details)
var check_text := ""               # v0.3 instant check: the last Check's result ("Check: 4 of 5 worlds passed, score 82."), the first row of the card
var check_verdict := ""            # ... and what it says to change (the verdict of the first world that missed)
var check_ok := false              # ... the Check passed (its row is marked met)
var lab = null                     # the LabScreen: the buttons that go on after a pass (Next level, Results, Lesion lab, Analysis) call into it
var _acts: HBoxContainer = null    # those buttons, inside the card (the card never changes size: a result must not move the lab)
var _acts_sig := ""
var _pulse := -1.0                 # seconds since the score first passed (the stamp lands)
var details := false               # Details open: the raw parts (human labels) replace the criteria rows
var _details_btn: Button

const RING_R := 48.0               # the stamp ring: 96 px across at 1080p
const MARK_OK := "✓"
const MARK_BAD := "✗"
const MARK_WAIT := "•"

func _ready() -> void:
	custom_minimum_size = Vector2(300, 104 if Layout.phone or Kit.vh < 900.0 else 134); clip_contents = true   # a short window: the stamp shrinks, two criteria rows
	_details_btn = Kit.btn("Details", toggle_details, "ghost", 15 if not Layout.phone else 14, Vector2(0, 0)); Kit.ident(_details_btn, "BtnDetails")
	_details_btn.custom_minimum_size = Vector2(0, 30); _details_btn.tooltip_text = "Every number the score is computed from"
	add_child(_details_btn)
	resized.connect(_place_btn); _place_btn()

## The ways on after a pass, as [text, id, kind, callback]: Next level when there is one, Results, the Lesion lab and Analysis once the level opens them.
func _acts_wanted() -> Array:
	var out := []
	if lab == null or not is_instance_valid(lab) or tele == null or tele.task == null or _bare() or not bool(lab._rec_pass) or lab.lesion_on: return out
	var tid: String = lab.task_id
	var nx := Progress.next_task(tid)
	if nx != "": out.append(["Next level →", "BtnScoreNext", "amber", func(): lab.app.open_lab(nx)])
	if not lab._is_reference(): out.append(["Results", "BtnScoreResults", "panel", func(): lab.layout.histo_show()])
	if lab._lesion_ok(): out.append(["Lesion lab", "BtnScoreLesionLab", "panel", func(): lab.les.open()])
	if LabUnlocks.has(tid, "analysis"): out.append(["Analysis", "BtnScoreAnalysis", "panel", func(): lab._open_analysis()])
	return out

func _sync_actions() -> void:
	var want := _acts_wanted()
	var ids := []
	for a in want: ids.append(str(a[1]))
	var sig := ",".join(ids) + "/" + str(Layout.kind)
	if sig == _acts_sig: return
	_acts_sig = sig
	if _acts != null and is_instance_valid(_acts): _acts.queue_free()
	_acts = null
	if want.is_empty(): queue_redraw(); return
	_acts = HBoxContainer.new(); _acts.add_theme_constant_override("separation", 8); Kit.ident(_acts, "ScoreActions")
	for a in want:
		var b := Kit.btn(str(a[0]), a[3], str(a[2]), 15 if not Layout.phone else 14, Vector2(0, 30)); Kit.ident(b, str(a[1])); _acts.add_child(b)
	add_child(_acts); _place_btn(); queue_redraw()

func _acts_h() -> float: return _acts.get_combined_minimum_size().y if _acts != null and is_instance_valid(_acts) and not _acts.is_queued_for_deletion() else 0.0

func _place_btn() -> void:
	if _details_btn == null: return
	var ms := _details_btn.get_combined_minimum_size(); _details_btn.size = Vector2(ms.x, 30.0)
	_details_btn.position = Vector2(size.x - _details_btn.size.x - 8.0, 6.0)
	if _acts != null and is_instance_valid(_acts):
		var am := _acts.get_combined_minimum_size(); _acts.size = am
		_acts.position = Vector2(maxf(size.x - am.x - 8.0, 4.0), size.y - am.y - 5.0)

func toggle_details() -> void:
	details = not details
	_details_btn.text = "Hide details" if details else "Details"; _place_btn(); queue_redraw()

func min_text_px() -> float: return float(Kit.fs(14)) * Kit.ppl
func attach(t: Telemetry) -> void: tele = t
func _process(dt: float) -> void:
	var p := tele != null and bool(tele.score.get("passed", false))
	if p and not _was_passed: _pulse = 0.0
	_was_passed = p
	if _pulse >= 0.0:
		_pulse += dt
		if _pulse > 1.4: _pulse = -1.0
	if _details_btn != null: _details_btn.visible = tele != null and tele.task != null and not _bare()
	_sync_actions()
	if is_visible_in_tree(): queue_redraw()

func _bare() -> bool:
	return tele != null and tele.task != null and (tele.sim == null or (tele.circuit is Dictionary and Circuits.neuron_count(tele.circuit) == 0))

# ---------------------------------------------------------------- human labels
## Words the engine abbreviates in its score-part keys.
const PART_WORDS := {"net": "network", "mf": "mean-field prediction", "mae": "mean error", "err": "error", "pct": "", "hz": "", "ms": "", "s": "", "mm": "",
	"rad": "", "bpm": "", "mmhg": "", "kc": "KC", "apl": "APL", "dan": "dopamine cells", "mbon": "output cells", "ia": "Ia", "ib": "Ib", "ii": "II",
	"ach": "ACh", "ne": "NE", "da": "DA", "co2": "CO2", "paco2": "arterial CO2", "hr": "heart rate", "ve": "ventilation", "sa": "SA", "cv": "variability",
	"rmssd": "RMSSD", "sdnn": "SDNN", "iv": "interval", "eff": "effective", "seg2": "segment 2", "ab": "AB", "pd": "PD", "lp": "LP", "py": "PY",
	"hn": "HN", "he": "HE", "ava": "AVA", "avb": "AVB", "avd": "AVD", "pvc": "PVC", "epg": "EPG", "max": "largest", "min": "smallest", "abs": "absolute"}
## Whole keys with a better name than their words.
const PART_NAMES := {"criteria_met": ["conditions met", ""], "criteria": ["conditions", ""], "criteria_total": ["conditions", ""],
	"conditions_met": ["conditions met", ""], "conditions_total": ["conditions", ""], "mae_bpm": ["mean heart-rate error", "bpm"],
	"in_band": ["time in band", ""], "fire_ok": ["fires when it should", ""], "silent_ok": ["silent when it should be", ""],
	"no_spikes": ["silent", ""], "run_value": ["score of the run", ""], "run_passed": ["run passed", ""], "submitted": ["answer submitted", ""],
	"wrong_guesses": ["wrong guesses", ""], "probes": ["probes used", ""], "burst_threshold": ["spikes that make a burst", ""], "motor_spikes": ["motor spikes", ""],
	"false_triggers": ["false withdrawals", ""], "agreement_pct": ["agreement", "%"], "osc_rad": ["oscillation", "rad"]}
const UNIT_TOKENS := {"ms": "ms", "s": "s", "mm": "mm", "rad": "rad", "hz": "Hz", "bpm": "bpm", "mmhg": "mmHg", "pct": "%", "deg": "deg", "ml": "mL"}

## [label, unit] for a score-part key: a readable label with no underscore, no unit token in the middle and no bare abbreviation. Unit tokens are
## pulled out wherever they sit ("net_hz_l1" -> "network rate, level 1" Hz), window and level indices read as words ("forward_e4_hz" -> "forward rate,
## window E4"), the rest goes through the body views' names (BodyViews.pretty).
static func human(key: String) -> Array:
	var lk := key.to_lower()
	if PART_NAMES.has(lk): return PART_NAMES[lk]
	if BodyViews.NAMES.has(lk): return BodyViews.NAMES[lk]
	var tk := Array(lk.split("_", false)); var unit := ""
	if tk.size() >= 2 and tk[tk.size() - 2] == "l" and tk[tk.size() - 1] == "min": unit = "L/min"; tk = tk.slice(0, tk.size() - 2)
	var words := []; var tail := []; var rate := false
	for t in tk:
		var w := str(t)
		if UNIT_TOKENS.has(w):
			if unit == "": unit = str(UNIT_TOKENS[w])
			if w == "hz": rate = true
			continue
		var re := RegEx.new(); re.compile("^([a-z])(\\d+)$")
		var m := re.search(w)
		if m != null:
			var letter := m.get_string(1); var num := int(m.get_string(2))
			if letter == "l": tail.append("level %d" % num)
			elif letter == "k" or letter == "q": tail.append("case %d" % (num + 1))
			else: tail.append("window %s" % w.to_upper())
			continue
		if w.is_valid_int(): tail.append(w); continue
		words.append(str(BodyViews.WORDS.get(w, PART_WORDS.get(w, w))))
	words = words.filter(func(x): return str(x) != "")
	if words.is_empty():
		var bp := BodyViews.pretty(key); return [str(bp[0]).replace("_", " "), str(bp[1]) if unit == "" else unit]
	var label := " ".join(words)
	if rate and not label.contains("rate"): label += " rate"
	if not tail.is_empty(): label += ", " + ", ".join(tail)
	return [label.replace("_", " "), unit]

## "label value unit" for a part (no doubled units, the tasks' -1 sentinel as "not measured").
static func part_text(key: String, v) -> String:
	var h := human(key)
	if v is String: return "%s  %s" % [h[0], v]
	var x := float(v)
	if is_equal_approx(x, -1.0): return "%s  not measured" % h[0]
	var s := BodyViews.num(x, key); var u := str(h[1])
	return "%s  %s" % [h[0], s if u == "" else (s + u if u == "%" else "%s %s" % [s, u])]

# ---------------------------------------------------------------- criteria
## One row per pass criterion: [{mark: "ok"|"bad"|"wait", text}]. The verdict sentence first (it is the criterion the engine names), then every judged
## trace (Task::bands(): in its band or not, read through Telemetry.display), then the parts that are pass flags (*_ok) and the count of conditions met.
static func criteria(t: Telemetry) -> Array:
	var out := []
	if t == null or t.task == null: return out
	var sc: Dictionary = t.score
	var passed := bool(sc.get("passed", false)); var done := t.finished
	var tid := str(t.task.id())
	var verdict := Circuits.cap_verdict(str(sc.get("verdict", "")), t.circuit, tid)
	if verdict == "" or verdict == "Running.": verdict = "Running: the verdict comes when the episode ends." if not done else "No verdict."
	out.append({"mark": "ok" if passed else ("bad" if done else "wait"), "text": verdict})
	var info := Campaign.info(tid)
	for b in info.get("bands", []):
		var name := str(b["name"]); var v := t.display(name); var h := human(name)
		var label := str(BodyViews.pretty(name)[0]) if BodyViews.NAMES.has(name.to_lower()) else str(h[0])
		if is_nan(v): out.append({"mark": "wait", "text": "%s: measuring…" % label})
		else:
			var inb := v >= float(b["lo"]) and v <= float(b["hi"])
			out.append({"mark": "ok" if inb else ("bad" if t.t_ms > 1000.0 else "wait"), "text": "%s %s the green band" % [label, "inside" if inb else "outside"]})
	var parts: Dictionary = sc.get("parts", {})
	for k in parts:
		var ks := str(k)
		if ks.ends_with("_ok"): out.append({"mark": "ok" if float(parts[k]) > 0.5 else ("bad" if done else "wait"), "text": str(human(ks)[0]).capitalize()})
	for pair in [["criteria_met", "criteria"], ["conditions_met", "conditions_total"], ["criteria_met", "criteria_total"]]:
		if parts.has(pair[0]) and parts.has(pair[1]) and float(parts[pair[1]]) > 0.0:
			var m := int(parts[pair[0]]); var n := int(parts[pair[1]])
			out.append({"mark": "ok" if m >= n else ("bad" if done else "wait"), "text": "Conditions met: %d of %d" % [m, n]}); break
	return out

## The raw parts for Details: [key, text] in the engine's order, with the neuron budget and the run's spike rate.
static func detail_items(t: Telemetry) -> Array:
	var out := []
	if t == null or t.task == null: return out
	var parts: Dictionary = (t.score.get("parts", {}) as Dictionary)
	var tid := str(t.task.id())
	if Progress.budget(tid) > 0: out.append(["neurons", "neurons  %d of %d" % [Circuits.neuron_count(t.circuit), Progress.budget(tid)]])
	for k in parts: out.append([str(k), part_text(str(k), parts[k])])
	if t.sim != null and t.t_ms > 200.0:
		var hz := t.spike_rate_hz(); out.append(["energy", "spikes in the circuit  %s /s" % (str(int(roundf(hz))) if hz >= 10.0 else "%.1f" % hz)])
	return out

# ---------------------------------------------------------------- drawing
func _draw() -> void:
	var fz := Kit.fs(14); var f := Fonts.regular; var fb := Fonts.bold
	draw_rect(Rect2(Vector2.ZERO, size), Kit.CARD)
	var r := minf(RING_R, size.y * 0.5 - 8.0); var c := Vector2(14.0 + r, size.y * 0.5)
	var sc: Dictionary = tele.score if tele != null else {}
	var v := float(sc.get("value", 0.0)); var passed := bool(sc.get("passed", false)); var has_task := tele != null and tele.task != null
	var bare := has_task and _bare()   # nothing runs, or nothing is built: no score, no criteria met (a vacuous criterion is not a result)
	if bare: v = 0.0; passed = false
	if not passed: v = minf(v, 99.0)   # 100 is a pass: a run still short of it never reads 100, not even rounded up
	v = floorf(v) if not passed else roundf(v)
	var col := Kit.success() if passed else Kit.RED
	# the stamp ring: lands when the run first passes
	var k := clampf(_pulse / 0.35, 0.0, 1.0) if _pulse >= 0.0 else 1.0
	_stamp_ring(c, r, "%d" % int(v) if has_task and not bare else "–", ("PASSED" if passed else "SCORE") if has_task and not bare else "", col if has_task and not bare else Kit.TEXT_SOFT, k, not (has_task and not bare))
	var x := c.x + r + 18.0; var w := size.x - x - 12.0
	# header: status, check result, stars (22 px gamboge), Details
	var status := "NO TASK"
	if has_task:
		status = "PASSED" if passed else ("RUNNING" if (tele.running and not tele.finished) else ("FINISHED: NOT PASSED" if tele.finished else ("PRESS RUN" if tele.t_ms <= 0.0 else "PAUSED")))
		if tele.sim == null or bare: status = "BUILD A CIRCUIT"
	var scol := Kit.success() if passed else (Kit.TEXT_SOFT if status in ["RUNNING", "PAUSED", "PRESS RUN", "BUILD A CIRCUIT", "NO TASK"] else Kit.RED)
	var sw := fb.get_string_size(status, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x + 16.0
	var hy := 10.0
	draw_rect(Rect2(x, hy, sw, float(fz) + 8.0), Color(scol, 0.08)); draw_rect(Rect2(x, hy, sw, float(fz) + 8.0), scol, false, 1.4)
	draw_string(fb, Vector2(x + 8, hy + float(fz) + 1.0), status, HORIZONTAL_ALIGNMENT_LEFT, sw, fz, Kit.legible(scol))
	var btn_w := (_details_btn.size.x + 14.0) if _details_btn != null and _details_btn.visible else 0.0
	var stars_x := size.x - btn_w - 3.0 * 25.0 - 8.0
	if has_task:
		var st := int(Progress.best(str(tele.task.id()))["stars"])
		for i in 3: draw_star(Vector2(stars_x + 12.0 + 25.0 * float(i), hy + float(fz) * 0.5 + 4.0), 11.0, Kit.GAMBOGE if i < st else Color(Kit.LINE, 0.95))
	var top := hy + float(fz) + 16.0
	if not has_task: return
	if bare:
		draw_multiline_string(f, Vector2(x, top + float(fz)), "Add neurons and wire a sensor to a motor: the score starts when something runs.", HORIZONTAL_ALIGNMENT_LEFT, w, fz, 2, Kit.TEXT_SOFT)
		return
	var line_h := float(fz) + 9.0
	var rows_max := maxi(1, int((size.y - top - 4.0 - (_acts_h() + 6.0 if _acts_h() > 0.0 else 0.0)) / line_h))
	if details: _draw_details(x, top, w, rows_max, passed)
	else: _draw_criteria(x, top, w, rows_max, line_h)

func _draw_criteria(x: float, top: float, w: float, rows_max: int, line_h: float) -> void:
	var fz := Kit.fs(14); var f := Fonts.regular; var fm := Fonts.bold
	var rows := criteria(tele)
	if check_verdict != "" and check_text != "": rows.push_front({"mark": "wait", "text": check_verdict})
	if check_text != "": rows.push_front({"mark": "ok" if check_ok else "bad", "text": check_text})   # the Check result leads: the card is where it is read
	var y := top
	for i in mini(rows.size(), rows_max):
		var row: Dictionary = rows[i]; var m := str(row["mark"])
		var glyph := MARK_OK if m == "ok" else (MARK_BAD if m == "bad" else MARK_WAIT)
		var gc := Kit.INK if m == "ok" else (Kit.RED if m == "bad" else Kit.legible(Kit.GAMBOGE))
		draw_string(fm, Vector2(x, y + float(fz)), glyph, HORIZONTAL_ALIGNMENT_LEFT, 20, fz + 2, gc)
		var txt := str(row["text"])
		var last := i == mini(rows.size(), rows_max) - 1
		if i == 0 and rows.size() == 1 and rows_max >= 2:   # the verdict alone: give it two lines
			draw_multiline_string(f, Vector2(x + 22.0, y + float(fz)), txt, HORIZONTAL_ALIGNMENT_LEFT, w - 22.0, fz, 2, Kit.TEXT)
			return
		var more := "+%d more" % (rows.size() - rows_max); var mw := Fonts.italic.get_string_size(more, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x + 4.0   # measured: a phone's larger text cut "+1 more" to "+1 mor"
		draw_string(f, Vector2(x + 22.0, y + float(fz)), _fit(f, txt, w - 22.0 - (mw + 6.0 if last and rows.size() > rows_max else 0.0), fz), HORIZONTAL_ALIGNMENT_LEFT, w - 22.0, fz, Kit.TEXT if i == 0 else Kit.TEXT_SOFT)
		if last and rows.size() > rows_max: draw_string(Fonts.italic, Vector2(x + w - mw, y + float(fz)), more, HORIZONTAL_ALIGNMENT_RIGHT, mw, fz, Kit.TEXT_SOFT)
		y += line_h

func _draw_details(x: float, top: float, w: float, rows_max: int, passed: bool) -> void:
	var fz := Kit.fs(14); var f := Fonts.regular
	var px := x; var py := top + float(fz) + 2.0; var row := 0
	for it in detail_items(tele):
		var s := str(it[1]); var tw := minf(f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x + 16.0, w)
		if px + tw > x + w:
			row += 1
			if row >= rows_max: break
			px = x; py += float(fz) + 12.0
		var bad := str(it[0]) == guilty and not passed
		draw_style_box(Kit.sb(Color(Kit.RED, 0.10) if bad else Color("#FBF7EE"), Kit.RED if bad else Kit.LINE, 2 if bad else 1, 2, 0, false), Rect2(px, py - float(fz) - 4.0, tw, float(fz) + 8.0))
		draw_string(f, Vector2(px + 8, py), _fit(f, s, tw - 12.0, fz), HORIZONTAL_ALIGNMENT_LEFT, tw, fz, Kit.TEXT); px += tw + 6.0

## The stamp: a double ink ring with the score in Fraunces inside (44 px at full size), a small-caps word above it; slightly rotated; `k` 0..1 lands it.
## `empty`: a dashed pale ring (nothing scored yet).
func _stamp_ring(c: Vector2, r: float, big: String, word: String, col: Color, k: float, empty: bool) -> void:
	var sk := lerpf(1.35, 1.0, k); var a := clampf(k * 1.4, 0.0, 1.0)
	draw_set_transform(c, -0.12, Vector2(sk, sk))
	if empty:
		for i in 24:
			var a0 := TAU * float(i) / 24.0
			draw_arc(Vector2.ZERO, r - 2.0, a0, a0 + TAU / 48.0, 4, Color(col, 0.7), 2.0, true)
	else:
		draw_arc(Vector2.ZERO, r - 2.0, 0.0, TAU, 64, Color(col, a), 3.0, true)
		draw_arc(Vector2.ZERO, r - 8.0, 0.0, TAU, 64, Color(col, a * 0.9), 1.2, true)
	var bz := Kit.fs(int(44.0 * r / RING_R))
	var bw := Fonts.display_heavy.get_string_size(big, HORIZONTAL_ALIGNMENT_LEFT, -1, bz).x
	draw_string(Fonts.display_heavy, Vector2(-bw * 0.5, bz * 0.36 + (4.0 if word != "" else 0.0)), big, HORIZONTAL_ALIGNMENT_LEFT, -1, bz, Color(col, a))
	if word != "":
		var tz := Kit.fs(12); var tw := Fonts.display.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, tz).x
		draw_string(Fonts.display, Vector2(-tw * 0.5, -r * 0.42), word, HORIZONTAL_ALIGNMENT_LEFT, -1, tz, Color(col, a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## `s` shortened at a word boundary with "…" until it fits `w`.
static func _fit(font: Font, s: String, w: float, fz: int) -> String:
	if font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x <= w: return s
	var words := s.split(" "); var t := ""
	for wd in words:
		var nt := (t + " " + wd) if t != "" else wd
		if font.get_string_size(nt + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fz).x > w: break
		t = nt
	return (t + "…") if t != "" else ""

static func draw_star_on(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + float(i) * PI / 5.0; var rr := r if i % 2 == 0 else r * 0.45
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	ci.draw_colored_polygon(pts, col)

func draw_star(c: Vector2, r: float, col: Color) -> void: draw_star_on(self, c, r, col)

static func _fmt(v: float) -> String:
	if absf(v) >= 100.0 or is_equal_approx(v, roundf(v)): return "%d" % int(roundf(v))
	return "%.1f" % v if absf(v) >= 1.0 else "%.2f" % v
