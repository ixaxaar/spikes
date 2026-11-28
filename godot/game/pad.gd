class_name Pad
extends Node
## Navigation layer for gamepads and keyboards. The UI is mouse-first; this adds a "nav mode" (on at the first pad input or navigation key,
## off at the first mouse move) in which every control is focusable, D-pad / arrows move the focus ring, A / Enter presses, B / Esc backs out.
## Sticks are removed from ui_* so they never fight the game's own movement bindings.
var app
var active := false
var hint: PanelContainer
var hint_lbl: Label
var _refocus := 0.0
const NAV_ACTIONS := ["ui_left", "ui_right", "ui_up", "ui_down", "ui_accept", "ui_cancel", "ui_focus_next", "ui_focus_prev"]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in ["ui_left", "ui_right", "ui_up", "ui_down"]:
		for ev in InputMap.action_get_events(a):
			if ev is InputEventJoypadMotion: InputMap.action_erase_event(a, ev)
	for pair in [["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B]]:
		var jb := InputEventJoypadButton.new(); jb.button_index = pair[1]
		if not InputMap.action_has_event(pair[0], jb): InputMap.action_add_event(pair[0], jb)
	hint = PanelContainer.new(); hint.visible = false; hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_stylebox_override("panel", Kit.sb(Kit.PANEL_HI, Kit.LINE, 1, 10, 12, true))
	hint_lbl = Kit.label("D-PAD  MOVE      A  SELECT      B  BACK", 16, Kit.TEXT); hint.add_child(hint_lbl)
	hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM); hint.grow_horizontal = Control.GROW_DIRECTION_BOTH; hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hint.offset_bottom = -12; hint.z_index = 100
	app.root.add_child(hint)

func set_active(on: bool) -> void:
	if on == active: return
	active = on; Kit.pad_mode = on
	_apply_focus_modes(app.root)
	if not on: app.get_viewport().gui_release_focus()
	else: ensure_focus(true)
	hint.visible = on and app.show_hint()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if on and _last_pad else Input.MOUSE_MODE_VISIBLE

var _last_pad := false
func _apply_focus_modes(n: Node) -> void:
	for c in n.find_children("*", "Control", true, false):
		if c is Kit.Stepper or c is HSlider or (c is BaseButton and not (c.get_parent() is Kit.Stepper)):
			(c as Control).focus_mode = Control.FOCUS_ALL if Kit.pad_mode else Control.FOCUS_NONE

func _input(e: InputEvent) -> void:
	if e is InputEventJoypadButton or (e is InputEventJoypadMotion and absf(e.axis_value) > 0.55):
		_last_pad = true; set_active(true)
	elif e is InputEventMouseMotion and (e as InputEventMouseMotion).relative.length() > 2.0: _last_pad = false; set_active(false)
	elif e is InputEventMouseButton or e is InputEventScreenTouch: _last_pad = false; set_active(false)
	elif e is InputEventKey and e.pressed and not e.echo:
		for a in NAV_ACTIONS:
			if e.is_action(a): _last_pad = false; set_active(true); break
	hint_lbl.text = "D-PAD  MOVE      A  SELECT      B  BACK" if _last_pad else "ARROWS  MOVE      ENTER  SELECT      ESC  BACK"
	if (e is InputEventJoypadButton and e.pressed and e.button_index == JOY_BUTTON_B) or (e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_ESCAPE):
		app.back(); get_viewport().set_input_as_handled()
	elif e is InputEventJoypadButton and e.pressed and e.button_index in [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]: ensure_focus(false)

func _process(dt: float) -> void:
	if not active: return
	_refocus -= dt
	if _refocus <= 0.0:
		_refocus = 0.25; ensure_focus(false)

func _focusable(c: Control) -> bool:
	return c.focus_mode == Control.FOCUS_ALL and c.is_visible_in_tree() and not (c is BaseButton and (c as BaseButton).disabled)

## Make sure something is focused. `force` re-picks even if something already is.
func ensure_focus(force: bool) -> void:
	var cur: Control = app.get_viewport().gui_get_focus_owner()
	if app.tutorial != null and app.tutorial.wants_focus():   # the tutorial or the mode picker is up: the focus stays on what it lights (never on a dimmed control)
		if force or cur == null or not app.tutorial.focus_ok(cur): app.tutorial.focus_now()
		return
	if cur != null and not force and app.tutorial != null and app.tutorial.is_ancestor_of(cur): return   # the tutorial banner keeps its focus
	var host: Control = app.current_screen()
	if host == null: host = app.root
	if cur != null and not force and cur.is_visible_in_tree() and host.is_ancestor_of(cur): return
	if host.has_method("default_focus"):
		var d: Control = host.default_focus()
		if d != null and _focusable(d): d.grab_focus(); return
	for c in host.find_children("*", "Control", true, false):
		if _focusable(c) and (c is BaseButton or c is Kit.Stepper or c is HSlider): (c as Control).grab_focus(); return
