# Changelog

## [Unreleased]

### Added
- **The Atlas wing** (fourth tab on the campaign map, opens after chapter I): levels built on measured wiring that cannot be edited.
- **Chapter "Reading wiring"** on the touch circuit of *C. elegans* (Cook et al. 2019): test a shortest route by silencing the classes off it; bet on the null model under which the feed-forward loop is over-represented; bet on which interneuron class can be lost; diagnose a worm that does not back up.
- **Chapter "A ring from wiring"** on the measured wiring of the fly compass (148 cells, 9,487 connections of the hemibrain; Scheffer et al. 2020): set the sign of three cell types so the ring holds a bump where a cue puts it; bet on how many directions the wiring can hold (it rests at about six of sixteen); set the strength of the ring-wide inhibition; diagnose a compass that holds no bump by recording.
- **Wiring tab in Analysis:** the connection matrix by cell type, a path finder with a "without" picker, and three null models for the motif census with the shuffled distribution drawn.
- **Prediction bets:** commit to an answer before the run; wrong bets and extra instrument reads cost points.
- **Silencing control:** a cell type that a level lets you switch off has an active / silenced switch.
- `make play` downloads the newest CI build and starts it.

### Changed
- **A run starts only when you press Run** (button, Space or Start). Opening a level and editing the circuit never start one. An edit during a run stops it at the start; the Run button turns amber until you run the new circuit. Run plays a finished run again; Reset goes back to the start and waits.
- **No card after a run.** The result is on the score card, which carries Next level, Results, Lesion lab and Analysis after a pass. Check writes its result on the score card, not in a toast. The first-pass celebration is a toast and a glow along the path; it no longer slows the run, zooms the bench or stamps over it. The Test x5 result card stays.
- **The tutorial is rewritten** in plain words: 12 steps (add a cell, wire it, press Run, read the plots, raise the weight, reach a pass, Check, read the result, switch a cell to inhibitory, hints) and the mode picker. The pointers and the mode picker are in the same plain style.

### Fixed
- Sensor and motor cards can be dragged anywhere on the bench (mouse, touch, Shift + arrow); they stay, are saved with the circuit and undo.
- A link from a sensor to a cell, or from a cell to a motor, can be selected (click, touch, keyboard or pad cursor) and removed, one at a time, with Delete or the inspector's Disconnect. Locked levels keep their links.
- The scripted-event row (the "tap" chip on Excitation and the like) is always there while a level has events, so the panels under it no longer jump when an event starts.
- The tutorial and the mode picker can be done with a gamepad alone: the focus starts on the right control, never lands on a dimmed one, and every button and lit control is reachable.

### Known gaps
- The Atlas chapter has no map plate yet and its map nodes sit close together.
- Locked levels still show the add and connect buttons (they explain why they do nothing) and a neuron-count challenge that does not apply.
- The worm levels are results of this model (every synapse excitatory, weights from synapse counts); the cards say so. Tail touch is not modelled.
- The compass levels are results of this model (point cells, fitted gains): the wiring holds a bump where it is put but rests at about six headings and does not turn reliably, so there is no turning level; the state-space view is not in yet.

## [0.5.2] - 2026-11-23 — Windows

### Added
- **Windows build (x86_64).** `spike-windows-x86_64.zip` holds `Spike.exe`, the extension DLL and `spike-run.exe`, linked statically (only Windows system DLLs are needed). NEST is built natively with MinGW-w64 (MSYS2 UCRT64) from the same pinned commit plus a small patch (`scripts/patches/0001-nest-mingw.patch`) for the places NEST assumes a 64-bit `long`. Built and smoke-tested on a GitHub Windows runner with the same checks as Linux, plus a circuit under a path with accents and spaces. The golden checksums of the engine tests match Linux. Scripts: `scripts/build-windows.sh`, `scripts/package-windows.sh`; notes in `docs/BUILD.md`.
- The release workflow now builds Linux, macOS and Windows and publishes only if all three passed.

### Known gaps
- Windows and macOS builds were tested headless on GitHub's runners only; nobody has played them on a real desktop yet. Tell us what breaks.
- Windows: only the three golden circuits were compared bit for bit with Linux. Random seeds of 2,147,484 and above take a patched path in NEST that no test exercises yet.
- The Windows exe is unsigned (SmartScreen warns); the macOS app is not notarized; no Intel Mac build.
- The gaps listed under 0.5.0 still stand.

## [0.5.1] - 2026-11-22 — macOS

### Added
- **macOS build (Apple Silicon).** `spike-macos-arm64.zip` holds `Spike.app` with the extension, `spike-run` and the circuits inside the bundle. Built and smoke-tested on GitHub's arm64 runners with the same checks as the Linux zip (every screen, CHECK through the bundled `spike-run`, no non-system libraries). Ad-hoc signed, not notarized: the first launch needs Open Anyway in System Settings, Privacy & Security, or `xattr -dr com.apple.quarantine Spike.app`. Scripts: `scripts/build-macos.sh`, `scripts/package-macos.sh`; notes in `docs/BUILD.md`.
- **One release, several platforms.** `release.yml` builds each platform in its own job and publishes only if all of them passed. The site's download cards link to the zip for each system.

### Changed
- The repository moved to `github.com/blackmetaltech/spikes`; links, the toolchain image and the site follow it.

### Known gaps
- No Windows build yet (the port is in progress; NEST has no official Windows build). No Intel Mac build.
- The macOS build passes the same tests as Linux, but its spikes have not been compared bit for bit with the Linux build.
- The gaps listed under 0.5.0 still stand.

## [0.5.0] - 2026-11-22 — The Bestiary, the Theory wing, and stars that mean something

0.5 adds two new wings to the campaign (design: `docs/DESIGN-0.5.md`, `docs/DESIGN-THEORY.md`), turns diagnosis into a second core loop, and was followed by two enhancement waves that hardened the engine and the save files, rewrote the circuit editor, added a tutorial and made the stars mean something. The campaign now has 79 levels. The 0.6 Theory notes that were kept as "Unreleased" are folded in here: there is no separate 0.6.

### Added
- **The Bestiary wing** (six chapters, 18 levels and 7 diagnosis cases), one chapter per model organism, notes in `docs/circuits/bestiary_a.md` and `bestiary_b.md`:
  - **Worm** (*C. elegans*): `w_latch`, `w_switch`, `worm_touch`, `dx_worm`. `worm_touch` is wired from the real touch circuit (Cook et al. 2019 synapse counts through the OpenWorm ConnectomeToolbox `cect`, `tools/connectome/worm.py`).
  - **Leech**: `l_burst`, `l_rebound`, `leech_heart`, `dx_leech`.
  - **Sea slug** (*Aplysia*): `a_depress`, `a_facilitate`, `aplysia_gill`, `dx_aplysia`.
  - **Fly compass**: `c_ring`, `c_shift`, `fly_compass`, `dx_compass`.
  - **Fly mushroom body**: `k_sparse`, `k_depress`, `fly_mb`, `dx_mb_apl`, `dx_mb_dan`.
  - **Crab** (stomatogastric ganglion): `s_pacemaker`, `s_phase`, `crab_pyloric`, `dx_crab`, with the new NESTML cell `stg_cell` (after the Liu/Prinz model family, game conductances) and a parts-bin card.
  - Engine, add-only: `Structure::modulation` and `ChannelStructure::modulator`, `ProjectionInfo::dopamine_source`, `Engine::output_spiked`, synapse parameter modulation, `spike_generator` and `sinusoidal_poisson` inputs, the `population_vector` ring output. Lab: depressing synapses and a modulation row, a ring readout, ring-closing segment wiring, random sparse wiring, a dopamine-gated synapse, a compass dial.
  - Engraved plates for the Bestiary and Theory chapters (`tools/art/plates.py`), and specimen views in the lab: fly compass, crab triphasic record, leech heart tubes and bursts, *Aplysia* gill, crawling worm, mushroom body Kenyon field.
- **The Theory wing** (four chapters, 12 levels): `d_class`, `d_phasic`, `d_switch` (dynamics, with a V-w phase-plane view from the cell's live parameters); `r_oscillate`, `r_choose`, `r_meanfield` (rate models and a siegert mean-field prediction, with a rates view); `h_complete`, `h_two`, `h_learn` (attractor memory, one level with STDP-written weights, with a pattern view); `t_tuned`, `t_sharpen`, `t_decode` (tuning and the population vector, with a tuning dial). A spike-triggered-average tab in the Analysis screen. Engine, add-only: `Engine::neuron_state`, `input_weight`, `input_value`, `output_value`; input kinds `rate_drive` and `tuned_poisson`; output kind `rate_value`; rate neurons and `siegert_neuron` as populations with `rate_connection_*` and `diffusion_connection` (J, K) projections; `spike/theory.h`; `spike-run --sample/--set/--phase`. See `docs/CIRCUIT-FORMAT.md`.
- **Diagnosis as a second core loop:** cases are scored on the probes you used and on wrong guesses, the candidate order does not depend on the answer, no finding names the answer, probes are counted and shown, Reveal appears after repeated misses. `spike-run --list-variants <task>` lists the candidates (used by the smoke test, which submits every candidate and expects exactly one to pass).
- **A new micro-puzzle, `m_tonic`** (tonic drive, a bias current), after `m_adaptation`: 20 micro-puzzles now. Briefs that need a bias say so, and the lab's default cell fails every micro-puzzle with a verdict that names the concept.
- **Plate 0, an interactive tutorial,** and a **mode picker** on the first run, with one-step pointers.
- **A rewritten circuit editor:** undo and redo, zoom and pan with fit, multi-select, copy and paste, bus cards and ensembles, keyboard and gamepad building with a cursor, three solution slots per level (A, B, C), JSON copy and paste, and an Import from a level you have passed. The controls are listed in Settings > Controls.
- **Honest scoring and stars:** CHECK runs five worlds; star 1 is a pass, star 2 is all five worlds in Standard or Researcher, star 3 is a per-level challenge with its text on the level card; Guided mode stops at two stars; a Researcher pass earns a seal kept apart from the stars; a diagnosis case's third star needs the right answer after a probe. The save file is version 2, with a migration of version-1 files. Cheat-proofing in the scorers: a functional weight floor in every graph helper, an input guard (no undeclared or recorded inputs), owned stimuli, token-wiring rows in the cheap-circuit tables, adapting-cell and burster whitelists.
- **A score stamp** with criteria rows and a Details panel in human words, and a lean end card.
- **Campaign gating and "Needs":** the Bestiary and Theory wings open after the Invertebrates spine; Sea slug waits for Heart's `m_neuromodulation`, Crab for the Leech spine, Fly mushroom body for the Sea slug spine (Guided drops these in-wing waits); every level card has "Needs" chips for the concepts it uses. `posture` is a branch off the spinal spine, like `reach`, and the spinal boss scores its hold and reach phases apart. The map has a wing selector, a Continue button and numbered spine pins.
- **An atomic save layer** (`SaveIO`): atomic writes, backups, quarantine of a damaged file, save versions, circuit validation with player-visible errors, a bench history you can restore, the reference lock kept in the autosave, a CHECK timeout and snapshot, diagnosis persistence, a flush on close, save export and import (a zip that carries the solution slots), Reset progress, a log folder.
- **Engine safety limits:** the GSL error handler is off, a NESTML stall guard, parse-time budgets, a cap on dc input to NESTML cells, per-projection synapse copies, and a hostile-circuit fuzz corpus and evidence circuits as ctests; `spike-run` rejects bad values with a message and exit status 1 or 2, never a core dump.
- **Interaction graph** of the UI (`godot/tests/interaction_graph.json`, `docs/INTERACTION-GRAPH.md`): stable control ids, a headless walk (`ui_graph`) and a completeness check; ctests for the save layer, the editor, the tutorial, the lab chrome and the specimen art. The Godot tests take a resource lock and run one after another.
- **CI image:** a prebuilt toolchain image (NEST static plus PyNEST, NESTML venv, godot-cpp) is published to GHCR; `ci.yml` pulls it, skips docs-only pushes and cancels superseded runs.
- **The website and wiki:** a landing page, a 31-page player wiki built from `site/wiki-src/` by `tools/site/build.py`, gameplay media and a GitHub Pages workflow.

### Changed
- **Body views** are drawn larger and more carefully (a limb on a trunk, lungs with a cardiac notch and the bronchial trees, a heart clear of the caption, the gut legend, the reflex arc as sensory neuron, ganglion and motor neuron); a fit guard keeps tiles and gauges inside their boxes at 1366x768 and with large text.
- **Rasters and traces:** one label line per group, rate-heat rows for large circuits, a voltage axis clamped to -90..+40 mV with a note, min/max envelopes for dense traces. One value per signal: a motor channel reads its `<channel>_hz` readout over a 500 ms window, and a measuring state replaces a bar parked at zero.
- **Colour:** blue means inhibition only (the Prussian-blue button is retired).
- **Reference circuits** of `stretch_reflex`, `reach`, `boss_spinal_sprint`, `baroreflex`, the autonomic exam, `worm_touch`, `fly_compass` and others were retuned over seeds 1-10 and 101-105 so the five-world CHECK passes. The `stretch_reflex` reference has 4 interneurons per side (par 54), and `dx` patients were regenerated.
- **Breathing** is a deliberately short chapter (one micro-puzzle, one task, one diagnosis case).
- **Playtest fixes** (`research/PLAYTEST-0.5.md`): a circuit counts as a copy of the reference only when it equals the reference file exactly or the REFERENCE button filled the bench; structure checks accept a self-excitation loop (`w_latch`, `worm_touch`) and turning one way (`worm`); CHECK runs the quick episode (the spinal boss about 5 s, the autonomic exam about 5 s, worm and lamprey under 1 s); verdicts and hints of tiers 1-3 carry no numbers for every task; verdicts follow the parts; gauges are all fed and a missing readout shows a dash; toasts queue; a half-wired scripted circuit no longer passes.
- **Versions:** the game, the Python package and CMake now all say 0.5.0.

### Fixed
- Documentation: the SA-node cell beats at about 99 per minute with no autonomic input and about 67 with ACh 0.5 (measured with `spike-run`); `docs/models`, `docs/body/heart.md` and the wiki now agree, and the heart module's own fallback rule (105) is said to be a different thing. The gut docs now say the module defaults to 12 segments and the peristalsis level uses 8.
- An empty bench scores 0.
- Several tuning, diagnosis and compass fixes (`t_tuned` judged by weights, `t_sharpen` steady across seeds, mean-subtracted STA, compass overshoot called "too strong", `dx_leech` patient robust on every seed, `dx_aplysia` findings no longer name the answer).
- **Parts bin:** cards for `iaf_cond_alpha` (the spinal levels, the lamprey) and for the generic `izhikevich` cell (a, b, c and d free), so a player can build what the reference circuits build. `tasks_rules_test` checks that every model a reference uses has a card that is open on that level.
- **Group size:** the "neurons in group" stepper offers every size a reference uses (it had no 16, which the compass chapter asks for) and keeps a size loaded from a file.
- **+ Noise** is offered in the sandbox only. On a level it added an input the level does not declare, which the honesty guard (rightly) refuses and caps at 49; undeclared stimulus is a cheat, so the button is gone from levels and the verdict now says plainly why a run with a stimulus of its own cannot pass.
- **Stars:** the brief panel's star line and the Check tooltip describe the current rules (five worlds, the challenge, the recipe, Guided at two stars). The SA-node card says about 99 beats per minute (about 67 with ACh 0.5).
- **Briefs** of `worm`, `peristalsis` and five micro-puzzles (`m_wave`, `m_reciprocal`, `m_timed_bursts`, `m_recurrent`, `m_feedforward`) keep the goal and the idea; the wiring is in the hint ladder and the recipe.
- **Par** is the neuron count of the level's reference circuit plus a declared slack (`Task::par_slack`, stated on the level card). Twelve levels had a par below their reference (reflex 16 to 23, lamprey 16 to 18, stretch reflex 54 to 60, posture 54 to 56, reach 55 to 56, breathing 26 to 28, and the micro-puzzles m_reciprocal, m_recurrent, m_negative_feedback, m_feedforward, m_wave, m_divergent). The micro-puzzles' third star is now a looser challenge.
- **Half the neurons** rounds up in the lab as it does in the engine (the lab rounded down); the lab asks the engine.
- **Parents** of Posture and Reach (and of every diagnosis case) are declared by the engine (`Task::parent`), not guessed by the map.
- **Neuron limit:** the game refuses more than the engine's 20000 neurons in total (it refused more than 2000, and 400 in a group); the number comes from the engine.
- **Python package:** a missing seed is 1 (it was 0, which NEST refuses and the engine never uses), and it mirrors the engine's load limits; it says plainly that the Theory wing's inputs and populations are not supported yet.
- Dead and stale: `Task::Challenge::no_modulators` (never set) is removed; comments in `spinal_limb.h` and `tasks_cheap_test.cpp` corrected.
- **Visuals:** venous blood and the right heart are slate, hatched the other way (blue is for inhibition only); a small bench no longer drops an ordinary circuit to the 15% zoom floor with its cards cut off (the cards narrow first); the notebook card no longer follows the player into the next tutorial step; on a phone the chapter plates show the band that holds the pins instead of a small picture, and the view chip is one word.

### Known gaps
- **`leech_heart` teaches release only.** The level now tests escape versus release with a small test current and reads which one the circuit shows, but no cell in the parts bin makes a robust escape oscillator (it needs an h-current cell), so the escape branch of the check has never run on a real circuit.
- **Two spinal references are not fully seed-proof.** On seeds the tuning never saw, in Researcher mode, the spinal boss reference passes about 90% of full episodes and `stretch_reflex` about 93 to 98%; both pass all of seeds 1-30 and 101-105 in every mode. A brief-only scripted novice no longer solves `stretch_reflex` (its earlier passes came from an estimator artefact that is now fixed).
- **No counterfactual mechanism check:** structure checks look at the wiring and the behaviour, but nothing yet re-runs a circuit with the mechanism removed to prove it matters.
- **The fly connectome excerpt is not real synapse data.** The compass and the mushroom body follow published cell types; only `worm_touch` is wired from a real connectome.
- **The Python package lacks the Theory wing's input and population kinds** (`rate_drive`, `tuned_poisson`, rate populations): it now refuses such a circuit with a plain message (see `python/README.md`); those circuits run in the game and `spike-run` only.
- **Phone layout has rough spots.**
- **No Windows build:** NEST and godot-cpp are not cross-built, and the runner has POSIX-only parts. Desktop Linux only, glibc 2.39 or newer.

## [0.4.0] - 2026-11-18 — Honest puzzles, shippable game

0.4 answers the harsh review (`docs/REVIEW-HARSH.md`, requirements in `docs/REQ-0.4.md`): every level now checks the mechanism it teaches, and the game builds, exports and runs CHECK from a zip.

### Added
- **Mechanism checks on all 41 levels.** Tasks read the circuit structure (`Engine::structure()`, `has_path`, `has_loop`, `has_loop_via`) and the verdict names the missing part, e.g. no coupling between pacemaker cells, or a baroreflex without both limbs.
- **Cheap circuits that must fail:** empty bench, single cell, zero weights, reference without the mechanism, max every weight, and the review's cheap circuits, for every level (`tasks_cheap_test_{a,b,c}`). Diagnosis cases test that every wrong and unknown answer fails.
- **Recipes kept apart.** Verdicts and hint tiers 1-3 carry no numbers (a test scans them); numbers live only in `recipe()`.
- **Faster CHECK:** seeds run in parallel processes and most tasks have a shorter quick episode (`Task::set_quick`).
- **Cajal Plate identity** (`docs/IDENTITY.md`): paper and ink, Golgi sienna and Prussian blue, Fraunces / Atkinson Hyperlegible / IBM Plex Mono, atlas-plate maps. No Godot splash.
- **UI honesty:** reference hidden until passed (or Guided), reference lock is a structural fingerprint, histograms labelled as generated variants, an in-game "What is real" page, progressive disclosure in the lab.
- **Citations** checked against PubMed / Crossref with DOIs (`catalog/citations.json`, `tools/citations/check.py`); wrong ones fixed.
- **Shipping:** levels and catalogue inside the Godot project, Linux export preset, `spike-run` bundled, static GSL, `scripts/build-all.sh`, `scripts/package.sh`, Dockerfile and CI workflow.

### Fixed
- NEST aborted on huge conductances. Weights are now limited at load (500 nS / 10000 pA) and a failed step latches a fault instead of crashing.

### Known gaps
- A brief-only scripted novice cannot solve posture and reach; the spinal boss and seven heart/autonomic levels (which need bias currents) have no novice test yet.
- CHECK is over the 3 s target for breathing (6.8 s), peristalsis (4.5 s), baroreflex (3-4 s), reach (3.2 s) and renshaw (about 3 s).
- The Dockerfile and CI workflow have never run; no Windows build; the Linux build needs glibc >= 2.39.
- 34 citations (books, older papers) are unverified; the online checker mode is untested.
- m_reciprocal and m_wave are nearly trivial. Some heart-map leader lines cross the drawing; population labels overlap on dense circuits.

## [0.3.0] - 2026-11-17 — Learning curve

0.3 turns the campaign into a learning ladder (design in `docs/DESIGN-0.3.md`): one new idea per level, a hint for when you are stuck, and a reason to come back after three stars.

### Added
- **19 micro-puzzles.** Each one isolates a single concept, from threshold, excitation and convergence to divergent command. They use 1-4 neurons and run for 3-5 s, and they come just before the task that needs that concept. A scripted beginner, using the lab's own default cell and weights, passes each one in 1-5 runs.
- **Two boss levels.** The spinal sprint combines posture, pushes, reaches and Renshaw cells. The autonomic exam is a whole day (rest, standing, exercise, a threat, recovery) with heart, blood pressure, pupil and breathing all scored.
- **Six diagnosis cases:** clonus, vagotomy, orthostatic hypotension, CCHS, Horner's syndrome and achalasia. You get the patient's circuit with a hidden lesion and its symptoms. You probe it with the scopes and the lesion lab, pick the lesion, and get a "why not" explanation for every wrong guess.
- **Difficulty modes.** Modes change tolerance, noise and perturbation strength, never the circuit's structure.
  - **Guided:** the recipe is shown in the brief, and hints are free.
  - **Standard:** SHOW RECIPE caps that level at 2 stars, and hints unlock after 2 failed runs.
  - **Researcher:** no recipe, no hints, and a pass only counts from TEST x5.
- **Hint ladder.** Tier 1 names the concept, tier 2 outlines the faulty part of your circuit, tier 3 gives a partial recipe. After a failed run, the guilty element glows.
- **Challenge variants.** There are two per task, for example half the neurons, double noise, a heavier load, a stronger haemorrhage or a fainter threat.
- **Post-solve histograms** of neurons, energy and quality, with your own target pinned on top. They are seeded from generated passing variants (see `docs/HISTOGRAMS.md`), not from other players.
- **Lab notebook.** Every pass unlocks a true, cited finding, and a concept glossary with citations sits alongside.
- **Sound.**
  - Spike clicks like a real electrophysiology monitor (warm for excitatory cells, cool for inhibitory ones, rate-limited).
  - Heartbeat, breath, muscle twitches, gut sounds and UI sounds.
  - Four volume sliders.
- **Feel.** A first-pass celebration, surprise toasts, instant CHECK (headless scoring in a few seconds), skip to the next event, and a default speed set from the measured throughput.
- **Campaign.**
  - The map shows a main path plus branches.
  - A chapter opens when the previous chapter's main path, or the one two before it, is passed.
  - Concept chips show what each level introduces and what it uses.
  - Opt-in local play log, exportable as JSON.
- **Engine.**
  - Seeded per-connection weight spread (`weight_cv`, `weight_sd`) on any projection, with PyNEST parity.
  - Async headless scoring with seed pinning and cancel.
  - Per-task default sensor weights, default cell type and recipe.
  - New task contract: level kind, concepts, modes, variants, hints, metrics, pacing, diagnosis and notebook.

### Changed
- Every level opens on the cell type its puzzle and verdicts assume. Briefs explain the concept only; the numbers live in the recipe.
- **Reflex:** the task now needs convergence, so a single cell cannot pass it.
- **Renshaw:** it measures your own circuit's response to input volleys, so removing the Renshaw cells fails.
- **Posture:** the verdict reads which way the limb is off.
- **Big tasks:** they list the concepts their micro-puzzles taught as used, not new.
- **Adapting preset:** retuned so it actually adapts (tau_w 500 ms).

### Known gaps
- **Reach is a branch, not on the main path.** No beginner circuit has passed it reliably yet; the best is 3 of 6 seeds.
- **Histograms are generated, not real players.** The slow levels (bosses, fight-or-flight, autonomic heart rate) have only 11-19 samples.
- **Renshaw loophole:** a circuit that lowers tremor by another route through the noise path could still pass.
- **Unverified glossary citations:** several were written from memory and still need a physiologist's check.
- **Untested on hardware:** surprise toasts have not fired in testing, and the new sounds have not had a listening pass.
- **Builds:** a shipped build must put `spike-run` next to the extension for CHECK to work. Desktop Linux only, and NEST runs on one thread.

## [0.2.0] - 2026-11-16 — Body systems

The game widens from three small circuits to a campaign of eleven vertebrate-physiology tasks, with real effectors, new cell types and neuromodulators.

### Added
- **Campaign.** Five chapters on an anatomical map: Invertebrates (the three 0.1 tasks), Spinal cord, Heart, Breathing, Autonomic. A chapter opens when half of the one before it is passed, and the tasks inside a chapter unlock in order.

  | Chapter | Tasks |
  |---|---|
  | Invertebrates | `reflex`, `worm`, `lamprey` |
  | Spinal cord | `stretch_reflex`, `renshaw`, `posture`, `reach` |
  | Heart | `heart_pacemaker`, `heart_autonomic`, `baroreflex` |
  | Breathing | `breathing` |
  | Autonomic | `pupil`, `peristalsis`, `fight_or_flight` |

  Each task has a reference circuit, lesions that fail the way the biology predicts, a timeline of scripted perturbations with score bands, and a body view (limb, heart, lungs, eye, gut or dashboard).
- **Body physics** in `engine/src/body/`, documented in `docs/body/`: Hill-type muscle, a single-joint limb, heart and circulation with baroreceptors, lungs with CO2 chemoreception, eye and pupil, a peristaltic gut chain.
- **Parts bin.** Every NEST neuron model as a card with its key parameters, units and a live f-I or V_m thumbnail from the engine (`catalog/thumbs.json`, written by `spike-catalog`). Parts unlock with the chapters.
- **NESTML cells**, compiled into the static build (`scripts/build-nestml.sh`): SA-node pacemaker, Butera respiratory burster, ICC slow-wave oscillator. A spike-parity test checks them against PyNEST.
- **Neuromodulators** NE, ACh and DA as engine channels (`Engine::set_modulator`, `modulator`), a `modulation` table in the circuit format, per-model default modulation for the NESTML cells, and a `"modulator"` output kind that releases them from spikes. Sandbox dials work on any circuit.
- **Lesion lab.** After a pass, cut synapses or silence populations on a re-run and get a lesion table (CSV and Markdown export).
- **Sandbox.** All parts, no task, scopes and analysis.
- **Analysis in the game:** 4-node motif census (199 classes, with a work-limit guard that refuses graphs too big to randomise in reasonable time), heart-rate variability (SDNN, RMSSD, pNN50, LF/HF), phase-response curves from the task's scripted perturbations, burst detection, and an energy readout. HRV, PRC and bursts re-run the circuit on the task and keep every spike (RECORD). The same analyses are in Python (`spike.hrv`, `spike.prc`, `spike.bursts`, the 4-node census in `spike.motifs`).
- **Stars.** 1 pass, 2 pass on all 5 TEST seeds, 3 the same within the neuron par and the energy budget (mean spikes per second per neuron, `Progress.ENERGY_HZ`; the budget is 1.6 x what the reference circuit spends). TEST x5 reseeds the world and the circuit and records the mean score, not the best. A circuit that is an edited copy of a reference circuit is "reference-derived" and earns no stars.
- **`spike-run --task <id>`** scores a circuit headless, with the game's own loop: `spike-run --task heart_pacemaker --seeds 1,2,3 [--circuit file.json] [--lesion pre>post*k] [--require any|all]` prints the score JSON (value, passed, verdict, parts, neurons, spikes, rate per neuron) and exits non-zero when the `--require` condition fails. `spike-run --list-tasks` lists the task ids. `scripts/smoke.sh` uses it to check every reference circuit.
- **Smoke test.** For every real task: the empty bench's channel kinds equal the reference circuit's, a minimal circuit moves the task's modulators, the real body view has its readouts, and the reference passes headless.
- **GDExtension.** `SpikeSim` binds `set_modulator`, `modulator`, `modulator_names`, `bursts_json`, `prc_json`, `prc_experiment_json`, `hrv_json`, `motif4_json`, `motif4_json_edges`; `SpikeTask` binds `channel_kinds()`.

### Changed
- The game needs Godot 4.7 (the extension declares compatibility from 4.5).
- The `Telemetry` modulator dial calls `SpikeSim.set_modulator` directly; the fallbacks that created a `SpikeTask` per frame are gone.
- Task order on the campaign map comes from the engine's registry; the map only keeps positions.

### Known gaps
- **Reach is hard from an empty bench.** A beginner-built circuit passes about 2 of 6 seeds. The reference relies on spread synapse weights and cell parameters the editor cannot set yet. Planned for 0.3: a weight-spread control.
- **Renshaw does not enforce its lesson.** A stretch-reflex circuit with no Renshaw cells can still pass, because the control tremor curve was measured on the reference, not on the player's own circuit.
- **Sensor weights.** The first connection from a dc sensor uses one generic weight. A per-task default is planned.
Also deferred to 0.3 (see `docs/REQ-0.2.md`):
- **Editor synapses:** the editor offers `static_synapse` only. STDP, dopamine STDP, Tsodyks, gap junctions and quantal STP still load from circuit files but cannot be added in the game.
- **"Biologically faithful" star** (motif similarity to the reference): not implemented. The 3- and 4-node census is in the game, the comparison is not.
- **Muscle from motor-unit spike trains:** the tasks drive the muscle from pool rates, as `docs/body/muscle.md` describes.
- A researcher cannot build tasks in Python; score circuits with `spike-run --task`.
- Desktop Linux only, one NEST thread, no audio (unchanged from 0.1).

## [0.1.0] - 2026-11-16 — First circuit

The first release: wire spiking neurons into circuits that make a body do something.

### Added
- **NEST built in.** The NEST simulator runs inside the game through a C++ engine. It runs in closed loop: every 1 ms the game sets sensor inputs, runs NEST and reads the spikes back, at about 3 µs of overhead per step. Results are deterministic, checked with golden spike checksums.
- **Circuit files.** A circuit is a versioned JSON file using NEST model and parameter names. The same file runs in the game, in the `spike-run` command and in PyNEST, with spike-for-spike parity.
- **Three tasks**, each with a reference circuit, lesions that fail the way the biology predicts, and plain-language verdicts:
  - **Reflex arc:** detect a touch through the noise, by convergence.
  - **Lamprey swimmer:** a half-centre oscillator with crossed inhibition and adaptation.
  - **Worm chemotaxis:** steer by the difference between the ASEL and ASER sensory neurons.
- **Lab.** Build a circuit with NEST models and presets, connect neurons with weight, delay and synapse model, and edit neuron parameters in an advanced panel. Add noise inputs. Watch the live world, the spike raster, voltage traces and output rates, and get a score.
  - **TEST x5** runs your circuit on 5 seeds.
  - You earn up to 3 stars: pass, pass on all 5 seeds, and stay under the neuron budget.
  - An end-of-episode card suggests what to try next.
  - Progress is saved, tasks are ordered and unlock in turn, and circuits load and save as JSON.
- **Analysis:**
  - **Motif census:** all 13 three-node connection patterns, numbered as in Milo et al., against degree-preserving random rewiring. It works on populations or on individual neurons, and warns when the random comparison is too weak to mean anything.
  - **Firing statistics:** firing rates, ISI CV, Golomb χ and PSTH.
- **`spike` Python package.** It builds the same network in PyNEST, with motif and statistics tools and an example notebook.
- **Layouts.** Desktop and phone.

### Known gaps
- Desktop Linux build only. Windows, macOS and Android packaging are not done yet.
- NEST is built without OpenMP, so it runs on one thread.
- There is no audio.
- The editor does not offer plastic synapses (STDP, Tsodyks). Circuits that already use them still load.
- On a phone, the tasks screen needs scrolling.
