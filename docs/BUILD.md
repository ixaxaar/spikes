# Building, testing and the command line

## Build

Requirements: a C++20 compiler, CMake 3.24+, Ninja or Make, GSL (`libgsl-dev`, **static** `libgsl.a` is linked), Python 3 with venv, and for the game Godot 4.7.2.
Pinned: NEST commit (`scripts/build-nest.sh`), NESTML 9.0.1 (`scripts/build-nestml.sh`), godot-cpp `godot-4.5-stable` (`scripts/build-gd.sh`), Godot 4.7.2 (`Dockerfile`).

**One command, clean Ubuntu 24.04:**
```
docker build -t spike-build .          # toolchain image: Godot, pinned NEST (static + PyNEST), NESTML venv, godot-cpp. Cold ~1.5 h, then cached
docker run --rm -v "$PWD":/src spike-build scripts/build-all.sh --tests   # engine, release extension, spike-run, tests (NEST etc. come from the image)
docker run --rm -v "$PWD":/src spike-build scripts/package.sh             # build/spike-linux-x86_64.zip, smoke-tested
```

**Without Docker**, `scripts/build-all.sh [--tests] [--debug] [--pynest]` runs the steps below in order; each is incremental:

1. **NEST** (pinned commit, static libraries for the engine):
   ```
   scripts/build-nest.sh             # engine libs -> third_party/nest-build
   scripts/build-nest.sh --pynest    # also build and install NEST + PyNEST -> third_party/nest-install
   ```
   `--pynest` needs python3, cython and numpy. Use the same `SPIKE_OPENMP` value for both (default OFF) so the engine and PyNEST agree.
2. **NESTML models:** `scripts/build-nestml.sh` (venv with the pinned NESTML in `third_party/nestml-venv`). Without it Heart, Breathing and Peristalsis cannot load.
3. **Engine and tests:**
   ```
   cmake -S . -B build && cmake --build build -j
   ```
4. **GDExtension and runner:** `scripts/build-gd.sh` (debug) or `scripts/build-gd.sh release`. It clones godot-cpp at the pinned tag on first use and copies `libspike_gd_<mode>.so` **and `spike-run`** to `godot/bin` (git-ignored), where the extension looks for the runner behind CHECK. GSL is linked statically (`-DSPIKE_STATIC_GSL=OFF` for the shared library); the extension and `spike-run` have `$ORIGIN` rpath.

### Package a release

`scripts/package.sh` builds the release extension, exports the Linux preset from `godot/export_presets.cfg` (needs the Godot 4.7.2 editor and its export templates), and writes `build/spike-linux-x86_64.zip`: `Spike.x86_64`, `Spike.pck` (carries `res://circuits` and `res://catalog`), `libspike_gd_release.so`, `spike-run`, plus loose `circuits/` and `catalog/` that `spike-run` and the histogram viewer read. It then extracts the zip into an empty directory, scrubs the environment (no `spike-run` on `PATH`, no `SPIKE_*`), and runs the exported binary headless: the full `SP_SMOKE` test, `tests/check_export.gd` (CHECK scores a reference circuit through the bundled `spike-run`), and the bundled `spike-run` alone. It targets glibc 2.39 / Ubuntu 24.04 or newer; build in an older image to run on older systems.

### macOS

Built only on GitHub's Apple Silicon runners (`.github/workflows/build-macos.yml`, reusable with `workflow_call`; artifact `spike-macos-arm64` holds `spike-macos-arm64.zip` and its `.sha256`). `scripts/build-macos.sh` builds NEST (static, same pinned commit, read out of `scripts/build-nest.sh`), the NESTML sources, godot-cpp and the release extension `libspike_gd_release.dylib` plus `spike-run`, with Homebrew for cmake, ninja, GSL (static `libgsl.a`) and Python. The NEST tree is cached by `actions/cache`, keyed on the OS image, the NEST pin and the hash of that script. `scripts/package-macos.sh` exports the "macOS" preset with the Godot 4.7.2 editor and macOS template, puts the extension and `spike-run` in `Spike.app/Contents/Frameworks` and `circuits/`, `catalog/`, `README.md` in `Contents/Resources`, ad-hoc signs the bundle, zips it with `ditto`, and runs the same smoke test as the Linux package (extracted zip, scrubbed environment, `otool -L` showing only system libraries).

The app is ad-hoc signed and not notarized (no Apple developer account), so macOS blocks the first launch of a downloaded copy: open System Settings, Privacy & Security, and choose Open Anyway (on macOS 14 and older: right-click `Spike.app`, Open); or run `xattr -dr com.apple.quarantine Spike.app` once in a terminal.

### Windows

Windows x86_64 is built and smoke-tested entirely on a GitHub `windows-latest` runner (`.github/workflows/build-windows.yml`: `workflow_call` and `workflow_dispatch`); it uploads the artifact `spike-windows-x86_64` (`spike-windows-x86_64.zip` and its `.sha256`). Nothing here needs a Windows machine of your own, and the Linux scripts and image are not involved.

- **Toolchain.** MSYS2 UCRT64 (MinGW-w64 GCC, CMake, Ninja, GSL, Python). NESTML runs on the runner's native CPython (the generated C++ does not depend on the platform). The three pins are read out of the Linux scripts (`NEST_REF`, `NESTML_VERSION`, `GODOT_CPP_TAG`) and the Dockerfile (Godot 4.7.2), so each stays in one place.
- **`scripts/build-windows.sh`** (MSYS2 UCRT64 shell): NEST static libraries, the NESTML sources, godot-cpp, then `godot/bin/spike_gd_release.dll` and `godot/bin/spike-run.exe`. Both are linked with `-static -static-libgcc -static-libstdc++` and GSL statically, and the script fails if either imports `libgcc`, `libstdc++`, `libwinpthread`, `libgsl` or an `msys-` DLL: only Windows system DLLs. The NEST build tree is cached by the workflow (key: NEST pin + hash of the script and the patches).
- **`scripts/package-windows.sh`**: exports the "Windows x86_64" preset with the Godot 4.7.2 Windows editor and its release templates, adds the DLL, `spike-run.exe`, `circuits/`, `catalog/` and `README.md` beside `Spike.exe` (`Spike.console.exe` is the same game with a console), writes `build/spike-windows-x86_64.zip`, then extracts it into an empty directory and runs it with a scrubbed environment (PATH is only the Windows system directories): the `SP_SMOKE` headless run, `SP_CHECK_EXPORT`, `spike-run.exe --list-tasks` (30+ tasks), the reflex reference through the bundled `spike-run.exe`, the import check, and two Windows-only checks (a circuit under a path with accents, and parallel seeds equal to sequential seeds). The workflow also runs `test_golden`, the Linux golden spike checksums, on the Windows build.
- **What differs from Linux in the code.** `gdext/src/bridge.cpp` and `engine/src/spike_run.cpp` have `#ifdef _WIN32` branches next to the unchanged POSIX code: the extension starts `spike-run.exe` with `CreateProcessW` (stdout through a pipe, stderr to a temp file, a job object so Cancel kills the whole tree, no console window); `spike-run` has no `fork`, so each seed runs in a child process, the same executable started with an internal `--spike-worker <index>`. `spike-run.exe` carries a manifest that makes UTF-8 its code page, so accented user names in paths work.
- **What was patched in NEST** (`scripts/patches/0001-nest-mingw.patch`, applied only by `build-windows.sh`; every hunk is explained at the top of the file). Almost all of it is one cause: `long` is 32 bits on Windows. `Time::compute_max` cast a 9e16 double to `long` (every `Time` saturated to infinity, so every simulation died in `init_moduli`); the RNG seed range check shifted a 32-bit `long` by 32 (and could not hold seeds above 2^31, which now arrive as negative longs and are cast back to `uint32_t`); the connect-from-arrays integer check used `1L << 31`; the exit-code constants and a `std::max(2UL, size_t)` and a non-MPI `communicate` overload did not compile; `gethostname` (Winsock) becomes `GetComputerNameA`; the `NEST_EXITCODE_*` defines that CMake cannot probe on Windows get the Linux values. Not a patch: everything that includes NEST headers is compiled with `-mno-ms-bitfields` (MinGW lays out bit-fields like MSVC, which breaks `SpikeData`'s size check). In the engine, integers beyond 2^31 inside a circuit are turned into floats on load, so a huge index cannot wrap into range. `test_golden` (the Linux checksums) passes on the Windows build.
- **Unsigned.** `Spike.exe` is not code-signed, so Windows SmartScreen shows "Windows protected your PC": choose More info, then Run anyway.

## Run the game

```
godot --path godot
```
(or open `godot/` in the Godot editor). Choose Play, pick a level on the campaign map and press Build: you get an empty bench with the level's sensor and motor cards. Add a neuron, drag from a sensor card to it and from it to a motor card, set the weights, and press Run or Check. The lab starts with only the essentials (Run / Pause, Reset, Check, Brief, the add-neuron palette and Connect); the speed, difficulty, Test x5, lesions, analysis and files are in the More menu, and some tools appear only once the campaign reaches a level that needs them. The reference circuit opens after you pass a level, or at any time in Guided mode.

The look is the "Cajal Plate" identity ([docs/IDENTITY.md](docs/IDENTITY.md)): ink and Golgi stain on paper. Screenshots: `scripts/shots.sh` writes them to `docs/screenshots/`.

## Tests

```
ctest --test-dir build --output-on-failure -j"$(nproc)"   # everything below
scripts/smoke.sh                  # headless Godot smoke test (not a ctest entry; package.sh and CI run it)
GOLDEN_UPDATE=1 build/engine/test_golden   # deliberately regenerate golden checksums
```

Every `engine/tests/*.cpp` is one ctest entry named after the file, except the two split ones below. A test that needs something that is missing exits with 77, which ctest reports as skipped, not passed.

| ctest name | What it checks | Needs |
|---|---|---|
| `test_*` (engine, body, structure, synapses, modulators, golden, determinism, hardening, theory, population_vector, spike_inputs, catalog, ...) | The engine, the body models, circuit loading and its limits (`test_hardening`), golden spike checksums (per build) | the build only |
| `test_nestml_sa_node`, `_butera`, `_icc`, `test_nestml_parity` | NESTML cells against analytic or NEST references; engine against PyNEST spikes | NESTML cells generated (skip otherwise); parity also needs PyNEST built with `--pynest` |
| `analysis_*` | Motif census, rates, CV, synchrony, bursts, HRV, PRC | the build only |
| `tasks_*_test` (micro, autonomic, heart, spinal, bestiary, theory, boss_dx, modes, honest, novice, fixes, gauges, physics, circuits, diagnosis_order, dx_fixes, rules) | Every level's reference passes, mechanism checks, verdicts and hints, diagnosis order and probes, modes, a scripted novice per level | NESTML cells for the heart, breathing and gut levels |
| `tasks_rules_test` | Rules that hold across every level, from the data: par = the reference circuit's neurons + a declared slack, a half-neurons variant rounds up, every off-spine level declares its parent, every model a reference uses has a parts-bin card that is open on that level, the neuron limits of the game and of the Python package equal the engine's | the build only |
| `tasks_cheap_test_a` ... `_f` | The table of cheap circuits that must fail, one entry per rows file so none times out | NESTML cells |
| `tasks_quick_full_test_0` ... `_3` | The quick and the full episode of every reference over several seeds in each mode (tasks k, k+4, ...) | NESTML cells |
| `fuzz_circuits` | The hostile-circuit corpus in `engine/tests/fuzz`: every case must end with status 0 or 1 inside a time and memory limit | spike-run |
| `evidence_circuits` | Circuits from `engine/tests/fixtures` that once broke something | spike-run |
| `python_pytest` | The Python package, parity with the engine and with the C++ motif census; sets `SPIKE_REQUIRE_NEST=1`, so missing PyNEST fails | PyNEST (`--pynest`) |
| `interaction_graph_static` | `godot/tests/interaction_graph.json` and its generated diagram agree (`tools/graph/render.py --check`) | python3 |
| `ui_graph` | Walks the UI interaction graph in headless Godot ([INTERACTION-GRAPH.md](INTERACTION-GRAPH.md)) | godot and the extension (skips without) |
| `save_io` | The save layer (`godot/tests/test_save.gd`): atomic writes, backups, damaged, truncated or future saves, hostile circuit files, export and import, read-only folder | godot only (the extension is not loaded) |
| `godot_editor` | The circuit editor (`test_editor.gd`): undo and redo, layout of a large circuit, clipboard, import, the keyboard cursor | godot only |
| `tutorial` | the tutorial's first-run logic (`test_tutorial.gd`) | godot only |
| `godot_polish` | Lab chrome logic (`test_polish.gd`): time labels, score parts, latches | godot only |
| `godot_wiring` | The Analysis screen's wiring matrix, path finder and null-model bench (`test_wiring.gd`) | godot and the extension (skips without) |
| `godot_atlas` | The Atlas worm chapter's game side (`test_atlas.gd`): wing gating, glossary, silencing control, bet panel, right and wrong bets through the engine | godot and the extension (skips without) |
| `art_specimens` | The lab's specimen layers match the plate drawings they are cut from (`tools/art/check_specimens.py`) | pycairo (skips without) |

The seven Godot tests share one project folder (`godot/`), so they take a ctest resource lock and run one after another even with `-j`. Plain `pytest python` skips the PyNEST tests when PyNEST is absent.

## Python quick start

```
pip install -e python[test]
export SPIKE_PYNEST=$PWD/third_party/nest-install/lib/python3.*/site-packages   # if not found automatically
```
```python
import spike
net = spike.build("python/examples/ei_net.json")
sp = spike.run(net, 1000.0)
```
See [python/README.md](python/README.md).

## Command line

`build/engine/spike-run circuit.json 1000` prints one JSON line per spike.

`build/engine/spike-run --task <id> [--circuit file.json] [--seed n | --seeds 1,2,3] [--lesion pre>post*k] [--require any|all]` scores a circuit on a task headless, with the same loop and seeding as the game (a seed also reseeds the circuit), and prints the score JSON. Without `--circuit` it uses the task's reference circuit (found through `$SPIKE_CIRCUITS_DIR`, or a `circuits/` or `godot/circuits/` folder above the working directory or the executable). `--lesion` scales every projection `pre`->`post` by `k` (0 deletes it). `spike-run --list-tasks` prints the task ids (79 today), and `spike-run --list-variants <task>` prints the ids a task accepts for `--variant` (a diagnosis case's candidates, a challenge variant). Bad values (a non-numeric seed, an unknown `--mode` or `--variant`, a seed outside 1..4000000, a deeply nested file) end with a message and exit status 2 (usage) or 1 (load / run error), never a core dump. `--threads n` is accepted for OpenMP builds only: the shipped NEST is built without threads, so use 1. The exit status is 3 when `--require` fails, which is how CI and `scripts/smoke.sh` check that every reference circuit passes.

## Custom cells and the parts bin
- `scripts/build-nestml.sh [--pynest]` generates the NESTML cells (`models/nestml/*.nestml`: SA-node pacemaker, Butera burster, ICC slow wave) into `third_party/nestml-gen/`, which CMake compiles into libspike. The generator injects a step-count / minimum-step guard and a non-finite state check into every cell's integration loop (so a strong input ends the run with an error instead of stalling), which is why a tree generated before that change must be regenerated (`rm -rf third_party/nestml-gen; scripts/build-nestml.sh`; `build-all.sh` does this on a clean tree). Without it those models are unavailable and their tests skip; a circuit that uses them then fails to load. See `docs/models/`. For PyNEST, build with `--pynest` too.
- `build/engine/spike-catalog` probes every parts-bin model and writes `catalog/thumbs.json` (f–I points and V_m traces) for the game's model cards.
- Body physics (muscle, joint, heart, lungs, eye, gut) is documented in `docs/body/`.
- New tasks register themselves: add `engine/src/tasks/<id>.cpp` ending with `SPIKE_REGISTER_TASK( <id>, <order>, "<circuit>.json", make_<id> )`; the file stem must equal the id.

## Website

The public site, https://spike.blackmetal.tech/, is the static folder `site/`: a landing page (`index.html`, `base.css`, `home.css`, `app.js`, no framework, no CDN) and a wiki in `site/wiki/` built from the Markdown in `site/wiki-src/`. `.github/workflows/pages.yml` builds the wiki and deploys `site/` to GitHub Pages on every push to master that touches `site/**`, `tools/site/**` or the workflow (or by hand: Actions > pages > Run workflow).

- **Build and preview locally:**
  ```
  python3 tools/site/build.py --check    # site/wiki/*.html, site/wiki/search.json, site/sitemap.xml; fails on broken links
  python3 -m http.server -d site 8000    # http://localhost:8000/
  ```
  `build.py` needs only the Python standard library. The generated files are git-ignored; the workflow builds them. How to write a page, and the Markdown it supports: `site/wiki-src/README.md`.
- **Media** (`site/assets/media/`: stills, looping WebM/MP4 clips with GIF fallbacks and posters; `site/wiki-src/img/`: the wiki's captures) are committed and made from the exported game by `scripts/site-media.sh`. It exports the game once (needs `godot/bin` from `scripts/build-gd.sh release` and the Godot export templates), then runs it under `xvfb-run` with the OpenGL renderer and a private `XDG_DATA_HOME`, driven by the `SP_*` hooks in `godot/main.gd`. Clips use Godot's movie mode (`--write-movie`, fixed frame rate), so every frame is rendered and the circuit runs at its true speed even on a software renderer. `ONLY="clip:heart still:lesion"` redoes some items; `KEEP=1 WORK=<dir>` keeps the raw frames and `REUSE=1` re-encodes from them (to change a crop). A full run takes about 30 minutes on 24 cores. Needs ffmpeg (libvpx-vp9, libx264), ImageMagick 7 and xvfb-run.
- **Derived assets** (`tools/site/assets.sh`): the Bestiary and Theory plates as WebP (from `godot/assets/plates`), the web fonts (`tools/site/fonts.py`: the game's Fraunces subset to WOFF2, Atkinson Hyperlegible and IBM Plex Mono copied unchanged, all SIL OFL with their licences alongside), the paper texture (`tools/site/paper.py`), the icons and the social card `og.jpg` (cut from the title still, so run it after `site-media.sh`). Needs ImageMagick, fontTools + brotli, numpy and Pillow.
- **First-time setup on GitHub:** Settings > Pages > Build and deployment > Source: **GitHub Actions**. Then push to master or run the pages workflow. The site lives under `/spikes/`, so every link in it is relative.

## CI

`.github/workflows/ci.yml` runs every step inside a prebuilt toolchain image, so a run only compiles the engine, extension and tests (about 15-25 minutes) instead of NEST (about 1.5 hours cold).

- **The image.** `Dockerfile` builds Godot 4.7.2 and, under `/opt/spike-prebuilt/third_party`, the pinned NEST (source, static libs, PyNEST install; `SPIKE_OPENMP=OFF`), the pinned NESTML venv and godot-cpp, using the same `scripts/build-nest.sh`, `build-nestml.sh --venv-only` and `build-gd.sh fetch` as a local build. `SPIKE_PREBUILT=/opt/spike-prebuilt` is set in the image; the build scripts then symlink those trees into `third_party/` instead of building, but only if the stamp of the prebuilt NEST (`<commit> openmp=<value>`) matches the pin and `SPIKE_OPENMP` in the checkout. Otherwise, and on any machine without the image, they build locally exactly as before (`SPIKE_NO_PREBUILT=1` forces that).
- **Publishing.** `.github/workflows/toolchain.yml` builds the image and pushes `ghcr.io/blackmetaltech/spike-build:<tag>` (and `latest`) with `GITHUB_TOKEN`. `<tag>` is `scripts/toolchain-tag.sh`: a hash of `Dockerfile`, `scripts/prebuilt.sh`, `build-nest.sh`, `build-nestml.sh` and `build-gd.sh`. The workflow runs on pushes to master that touch those files, or by hand (Actions > toolchain > Run workflow); it does nothing if the tag already exists (tick "force" to rebuild).
- **Using it.** `ci.yml` computes the same tag and pulls the image. If it is missing it fails at once with a message to run the toolchain workflow, then re-run the job; it does not build the image itself, so a forgotten publish costs seconds, not 1.5 hours. This also happens on the first push that changes a pin, because both workflows start together: re-run ci after the toolchain run finishes.
- **Budget.** Pushes that only touch `docs/**` (including `docs/readme/**`), `research/**` or `*.md` do not run CI. Pushes run on master only (other branches run through their pull request, so a commit is not built twice); a newer push to the same ref cancels the older run. The NEST `actions/cache` is gone.
- **Bumping a pin.** Edit `NEST_REF` in `scripts/build-nest.sh`, `NESTML_VERSION` in `build-nestml.sh`, `GODOT_CPP_TAG` in `build-gd.sh` or `GODOT_VERSION` in the `Dockerfile`, commit, push, wait for the toolchain workflow (it starts by itself on master), then re-run ci if it failed for the missing image.
- **First-time setup on GitHub.** Run the toolchain workflow once. The package is created private and linked to the repository, so Actions in this repository can pull it with `GITHUB_TOKEN`; for pull requests from forks, or to pull it elsewhere, set the package to public (Packages > spike-build > Package settings > Change visibility).
- **Run CI locally.** `scripts/ci-local.sh [checkout-dir]` runs the same build, ctest, pytest, smoke and package steps in the image (`spike-build:<tag>`, taken from a local build, else pulled, else built) and prints `STEP <name> FAILED` for any failure. Use a clean checkout or worktree (for example `git worktree add ../spikes-ci`) for a faithful run.

## Releasing

`.github/workflows/release.yml` builds and publishes the Linux binary.

1. Set the version in `godot/project.godot` (`config/version`), `python/pyproject.toml`, `python/spike/__init__.py` and the CMake project, and add a `## [<version>]` entry to `CHANGELOG.md`.
2. Wait for `ci` to pass on `master`.
3. Tag and push: `git tag v<version> && git push origin v<version>`. The workflow refuses a tag that does not match `config/version` or has no changelog entry.
4. The workflow builds in the toolchain image, runs `scripts/package.sh` (which smoke-tests the zip: every screen, and CHECK through the bundled `spike-run`), and publishes a GitHub Release with `spike-linux-x86_64.zip`, its `.sha256`, and the changelog entry as notes.

The website's download buttons (`site/app.js`) read the latest release and link straight to the zip, so nothing on the site needs editing for a release. Running the workflow by hand (Actions > release > Run workflow) builds and uploads the zip as an artifact without publishing anything.
