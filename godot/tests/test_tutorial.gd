extends SceneTree
## Headless test of Plate 0's first-run logic (ui/tutorial.gd): a fresh save starts the tutorial at step 1 on Play, a skipped or finished tutorial never
## restarts (also after the save is read again from disk), the mode picker is owed exactly until a mode was chosen, a save with progress is not "fresh",
## Reset starts over, and the step table is honest (the twelve steps say what the owner wrote, no digits in the text, every action step can be done for the player and
## starts the pad's focus on a control, the wiring steps name the pad's buttons).
##   scripts/tutorial_test.sh   (ctest `tutorial`): XDG_DATA_HOME points at a scratch folder so the real save is never touched
##   godot --headless --path godot -s tests/test_tutorial.gd     prints "TUTORIAL OK" or "TUTORIAL FAIL: ..." (exit 1); refuses to run without XDG_DATA_HOME

var fails := 0
var checks := 0

class FakeApp extends Node:
	var lab_keep := {}
	var cur := "title"
	var calls: Array = []
	var screen = null
	var pad = null
	func open_lab(t: String, _r := false, _b := false) -> void: calls.append("lab:" + t); cur = "lab"
	func show_screen(id: String, _back := false, _snap := false) -> void: calls.append("screen:" + id); cur = id

func _check(ok: bool, msg: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("TUTORIAL FAIL: ", msg)

func _wipe() -> void:
	for dir in ["user://", "user://circuits", "user://logs"]:
		var d := DirAccess.open(dir)
		if d == null: continue
		for f in d.get_files(): DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))
	SaveIO.forget_state(); Progress._loaded = false; Progress._best = {}; Progress._mode = "standard"; Progress._meta = {}

## What a restart of the game does: forget memory, read progress.cfg again.
func _reread() -> void: Progress._loaded = false; Progress._best = {}; Progress._mode = "standard"; Progress._meta = {}

func _init() -> void:
	if OS.get_environment("XDG_DATA_HOME") == "":
		print("TUTORIAL SKIP: XDG_DATA_HOME is not set (run scripts/tutorial_test.sh); not touching the real save"); quit(77); return
	for h in SaveIO.HOOKS: OS.unset_environment(h)
	OS.unset_environment("SP_NOAUTOSAVE"); OS.unset_environment("SP_ALLOW_SAVE")
	Settings.no_save = false
	_wipe()
	_flags()
	_flow()
	_table()
	print("TUTORIAL %s checks=%d fails=%d" % ["OK" if fails == 0 else "FAILED", checks, fails])
	quit(0 if fails == 0 else 1)

func _flags() -> void:
	_check(Tutorial.pending(), "a fresh save has a pending tutorial")
	_check(not Tutorial.picker_pending(), "a fresh save owes no mode picker before the tutorial ran")
	Progress.meta_put("tutorial", "skipped")
	_check(not Tutorial.pending(), "a skipped tutorial is not pending")
	_check(Tutorial.picker_pending(), "a skipped tutorial with no mode chosen owes the picker")
	_reread()
	_check(not Tutorial.pending(), "a skipped tutorial is still skipped after the save is read again from disk")
	_check(Tutorial.picker_pending(), "the owed picker survives a restart")
	Progress.meta_put("mode_picked", true)
	_reread()
	_check(not Tutorial.picker_pending(), "after a mode was chosen the picker is not owed, also after a restart")
	_check(str(Progress.meta_get("tutorial", "")) == "skipped", "the flag value is kept")
	_wipe()
	Progress.record("m_threshold", 60.0, true, 1)   # an older save with progress and no flags: never auto-starts
	_reread()
	_check(not Tutorial.pending(), "a save with progress does not start the tutorial")
	_wipe()
	Progress.meta_put("tutorial", "done"); Progress.meta_put("mode_picked", true); Progress.meta_put("tip_reflex", true)
	Progress.set_mode("researcher")   # saving the mode must keep the flags
	_reread()
	_check(str(Progress.meta_get("tutorial", "")) == "done" and bool(Progress.meta_get("tip_reflex", false)) and Progress.mode() == "researcher", "saving the mode keeps the seen flags")
	Progress.reset()
	_check(Tutorial.pending(), "Reset progress makes the tutorial pending again")
	_wipe()

func _flow() -> void:
	var app := FakeApp.new(); get_root().add_child(app)
	var tut := Tutorial.new(); tut.app = app; get_root().add_child(tut)
	var lab := LabScreen.new(); lab.task_id = Tutorial.TASK
	# fresh save: Play starts the tutorial in the lab on m_threshold, at step 1
	tut.on_play()
	_check(app.calls == ["lab:" + Tutorial.TASK], "Play on a fresh save opens the lab on %s (got %s)" % [Tutorial.TASK, str(app.calls)])
	tut.lab_opened(lab)
	_check(tut.active and tut.step == 1, "a fresh save starts at step 1 (active=%s step=%d)" % [str(tut.active), tut.step])
	_check(tut.step_id() == "s1", "the graph id of step 1 is s1")
	_check(Progress.mode() == "guided", "the tutorial runs in Guided mode")
	# skip it: done for good, the mode comes back, the picker is owed, Play no longer restarts it
	tut.on_back()   # what Esc does
	_check(not tut.active, "Esc leaves the tutorial")
	_check(str(Progress.meta_get("tutorial", "")) == "skipped", "a skipped tutorial is recorded")
	_check(Progress.mode() == "standard", "skipping puts the previous mode back")
	_check(tut.picker_open, "skipping on a first run shows the mode picker")
	_check(not bool(Progress.meta_get("sensor_opened", false)), "skipping keeps the sensor ring of m_threshold (the card was never opened)")
	tut.on_back()   # Esc on the picker keeps the mode and continues
	_check(not tut.picker_open and bool(Progress.meta_get("mode_picked", false)), "Esc on the picker keeps the mode and counts as chosen")
	app.calls.clear(); app.cur = "title"
	tut.on_play()
	_check(app.calls == ["screen:tasks"], "Play after a skipped tutorial goes to the map, not to the tutorial (got %s)" % str(app.calls))
	_reread()
	app.calls.clear(); tut.on_play()
	_check(app.calls == ["screen:tasks"] and not tut.active, "... also after a restart of the game")
	# replay from the map, then finish: done, picker shows again, no restart
	app.calls.clear(); tut.begin()
	_check(app.calls == ["lab:" + Tutorial.TASK], "the map's Tutorial button replays it")
	var lab2 := LabScreen.new(); lab2.task_id = Tutorial.TASK
	tut.lab_opened(lab2)
	_check(tut.active and tut.step == 1, "a replay starts at step 1")
	for i in range(1, 9): tut._next()   # step 11 needs the real editor (the UI graph walks it, also with a gamepad alone)
	_check(tut.step == 9, "Next walks the steps")
	tut._back()
	_check(tut.step == 8, "Back a step goes back")
	tut._finish("done", true)
	_check(not tut.active and str(Progress.meta_get("tutorial", "")) == "done" and tut.picker_open, "finishing marks it done and shows the picker")
	tut._pick("guided")
	_check(Progress.mode() == "guided" and not tut.picker_open, "the picker sets the mode")
	app.calls.clear(); tut.on_play()
	_check(app.calls == ["screen:tasks"], "a finished tutorial does not restart on Play")
	# closing the lab mid-tutorial ends it (nothing waits for a screen that is gone)
	var lab3 := LabScreen.new(); lab3.task_id = Tutorial.TASK
	tut.begin(); tut.lab_opened(lab3)
	_check(tut.active, "replay again")
	tut.lab_closed(lab3)
	_check(not tut.active, "leaving the lab ends the tutorial")
	for n in [tut, app, lab, lab2, lab3]: n.free()
	_wipe()

const SPEC := [
	"This is the bench. On the left is a sensor. It sends a signal in. On the right is a motor. It shows what comes out. You build the cells in between.",
	"Add a cell. Press + Excitatory.",
	"Connect the sensor to the cell. Drag from the right edge of the sensor onto the cell.",
	"Connect the cell to the motor. Drag from the edge of the cell onto the motor.",
	"Press Run. Nothing runs until you press it.",
	"Top plot: each tick is one spike. A spike is the cell firing. Bottom line: the cell's voltage. It went up, but not far enough to fire. So there are no spikes yet.",
	"Make the signal stronger. Click the sensor. Drag the weight slider up. Press Run. Repeat until the cell fires.",
	"The goal: fire on the big step, not on the small blip. Too strong and it fires on both. Change the weight, press Run, and read the score on the right. Repeat until it says passed.",
	"Press Check. It tests your circuit five times, each with different noise.",
	"The result is on the right. A pass earns a star. Passing all five tests and using few cells earns more.",
	"I added a second cell. Select it and press E / I. Now it is inhibitory: it pushes other cells down instead of up.",
	"Stuck? Hint gives a nudge. Brief says what the level wants. Press Finish.",
]

func _table() -> void:
	var tut := Tutorial.new()
	var steps := tut._steps()
	_check(Tutorial.STEP_COUNT == 12 and steps.size() == 12, "the tutorial has twelve lab steps (the mode picker is the thirteenth)")
	for i in mini(steps.size(), SPEC.size()): _check(str((steps[i] as Dictionary)["text"]) == SPEC[i], "step %d says what the owner wrote: %s" % [i + 1, str((steps[i] as Dictionary)["text"])])
	_check(steps.size() == Tutorial.STEP_COUNT, "the step table has %d lab steps (got %d)" % [Tutorial.STEP_COUNT, steps.size()])
	var re := RegEx.new(); re.compile("[0-9]")
	for i in steps.size():
		var st: Dictionary = steps[i]; var t := str(st.get("text", ""))
		_check(t != "", "step %d has text" % (i + 1))
		_check(re.search(t) == null, "step %d text has no digits (the honesty rule): %s" % [i + 1, t])
		if st.has("pad"): _check(re.search(str(st["pad"])) == null, "step %d pad text has no digits: %s" % [i + 1, str(st["pad"])])
		if str(st.get("kind", "")) == "act":
			_check(st.has("done") and st.has("do"), "step %d is an action step: it has a condition and a way to do it for the player" % (i + 1))
			_check(str(st.get("focus", "")) != "" and st.has("pad"), "step %d is an action step: the pad's focus starts on its control and its text names the pad's buttons" % (i + 1))
		else: _check(str(st.get("kind", "")) == "next", "step %d is Next or an action" % (i + 1))
		_check(not ("pad" in st) or str(st["pad"]) != str(st["text"]), "step %d has a pad text that differs from the mouse text" % (i + 1))
	for i in [2, 3]:   # the wires: the bench's own pad flow, X starts a wire and A ends it
		var pt := str((steps[i] as Dictionary).get("pad", ""))
		_check(pt.contains("press X") and pt.contains("press A"), "step %d names X and A for the pad: %s" % [i + 1, pt])
	for t in Tutorial.TIPS:
		_check(re.search(str(Tutorial.TIPS[t]["text"])) == null, "the pointer for %s has no digits" % t)
	tut.free()
