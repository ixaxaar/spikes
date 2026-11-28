#!/usr/bin/env bash
# Screenshots and looping clips of real gameplay for the website -> site/assets/media/
#
#   scripts/site-media.sh                         export the game (if needed), take every still and clip
#   ONLY="lamprey heart" scripts/site-media.sh    only these items (names from ITEMS below; clip:heart or still:heart for one kind)
#   KEEP=1 WORK=/some/dir ...                     keep the raw PNGs and frames there for inspection
#   REUSE=1 KEEP=1 WORK=/some/dir ...             re-encode clips from frames already in WORK (change a crop, a CRF)
#   JOBS=4                                        items rendered at once (each is one game under its own Xvfb)
#
# How: the game is exported once (godot --export-release "Linux x86_64"; it needs godot/bin from
# scripts/build-gd.sh, nothing is rebuilt here) and driven by the SP_* hooks at the top of godot/main.gd.
# Stills use SP_SHOT. Clips use Godot's Movie Maker mode (--write-movie --fixed-fps): every frame is
# rendered and written however slow the software renderer is, and the lab simulates in game time, so a
# clip shows the circuit at its true speed (times the lab speed SP_SPEED). Everything runs under
# xvfb-run with the OpenGL renderer and a private XDG_DATA_HOME/XDG_CONFIG_HOME, so the player's saves
# and settings are never touched.
#
# Output per still: <name>.webp (1600 wide) and <name>-800.webp. Per clip: <name>.webm (VP9),
# <name>.mp4 (H.264, the fallback), <name>.gif (small, for READMEs and browsers without video) and
# <name>-poster.webp (the first frame, also what prefers-reduced-motion shows).
# Needs: godot 4.7 + export templates, xvfb-run, ffmpeg (libvpx-vp9, libx264), ImageMagick 7, python3.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); cd "$root"
EXPORT=${EXPORT:-$root/build/site-export}
OUT=${OUT:-$root/site/assets/media}
JOBS=${JOBS:-4}
WORK=${WORK:-$(mktemp -d)}
mkdir -p "$OUT" "$WORK"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT

# ---------- export (once) ----------
if [ ! -x "$EXPORT/base/Spike.x86_64" ]; then
  [ -f godot/bin/libspike_gd_release.so ] || { echo "godot/bin/libspike_gd_release.so missing: run scripts/build-gd.sh first" >&2; exit 1; }
  mkdir -p "$EXPORT/base"
  godot --headless --path godot --import >/dev/null 2>&1 || true
  godot --headless --path godot --export-release "Linux x86_64" "$EXPORT/base/Spike.x86_64" >"$EXPORT/export.log" 2>&1
fi
chmod +x "$EXPORT/base/spike-run"   # the headless scorer behind CHECK; the export copies it without the executable bit
# one hard-linked copy of the export per window size; the size comes from override.cfg next to the binary
for size in 1920x1080; do
  d=$EXPORT/$size
  if [ ! -x "$d/Spike.x86_64" ]; then rm -rf "$d"; cp -al "$EXPORT/base" "$d"; rm -f "$d/override.cfg"; fi
  printf '[display]\nwindow/size/mode=0\nwindow/size/window_width_override=%s\nwindow/size/window_height_override=%s\n' "${size%x*}" "${size#*x}" > "$d/override.cfg.new"
  mv "$d/override.cfg.new" "$d/override.cfg"
done

# Circuits for the CHECK shots: a hand-built copy of the lamprey reference (other numbers and positions, so it is
# not "the reference circuit" and earns stars) and the same circuit without its crossed inhibition (a failing verdict).
python3 - "$root/godot/circuits/lamprey_cpg.json" "$WORK" <<'PY'
import json, sys
src, work = sys.argv[1], sys.argv[2]
c = json.load(open(src))
c["meta"] = {"author": "site-media", "task": "lamprey"}
for p in c["populations"]:
    p["pos"] = [[x + 12, y + 6] for x, y in p.get("pos", [])]
for pr in c["projections"]:
    pr["synapse"]["weight"] = round(pr["synapse"]["weight"] * 1.05, 2)
json.dump(c, open(f"{work}/lamprey-mine.json", "w"), indent=1)
c["projections"] = [pr for pr in c["projections"] if not (pr["pre"].startswith("CC") and pr["post"].startswith("E_"))]
json.dump(c, open(f"{work}/lamprey-noinh.json", "w"), indent=1)
PY

# ---------- the list ----------
# still  <name> <size> <env...>
# clip   <name> <size> <fps> <frames rendered> <first frame kept> <crop WxH+X+Y or -> <output width> <env...>
#        Frames first..(rendered-1) make the loop: every clip stops before the end of its episode (where the result card opens).
#        Each clip opens on a level that is already running, so the loop starts mid-rhythm.
# wiki   <name> <size> <crop WxH+X+Y or -> <env...> [@PINS=x,y;x,y...]   a figure for a wiki page -> site/wiki-src/img/<name>.webp
#        (the images listed in site/wiki-src/IMAGES.md; @PINS draws numbered call-outs at those screen pixels before the crop)
# @WORK@ in an env value is replaced by the work directory.
ITEMS=$(cat <<'LIST'
still title          1920x1080 SP_SCREEN=title SP_SHOT_AT=2
still lab-lamprey    1920x1080 SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=6000 SP_SHOT_AT=3
still baroreflex     1920x1080 SP_SCREEN=lab SP_TASK=baroreflex SP_REF=1 SP_SPEED=2 SP_SIM_UNTIL=14000 SP_SHOT_AT=3
still heart          1920x1080 SP_SCREEN=lab SP_TASK=heart_autonomic SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=25000 SP_SHOT_AT=3
still limb           1920x1080 SP_SCREEN=lab SP_TASK=stretch_reflex SP_REF=1 SP_SPEED=2 SP_SIM_UNTIL=5500 SP_SHOT_AT=3
still leech          1920x1080 SP_SCREEN=lab SP_TASK=leech_heart SP_REF=1 SP_SPEED=2 SP_SIM_UNTIL=12000 SP_SHOT_AT=3
still compass        1920x1080 SP_SCREEN=lab SP_TASK=fly_compass SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=6000 SP_SHOT_AT=3
still phase          1920x1080 SP_SCREEN=lab SP_TASK=d_class SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=3000 SP_SHOT_AT=3
still crab           1920x1080 SP_SCREEN=lab SP_TASK=crab_pyloric SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=6000 SP_SHOT_AT=3
still check-pass     1920x1080 SP_SCREEN=lab SP_TASK=lamprey SP_CIRCUIT=@WORK@/lamprey-mine.json SP_SPEED=1 SP_CHECK=1 SP_SHOT_AT=14
still check-fail     1920x1080 SP_SCREEN=lab SP_TASK=lamprey SP_CIRCUIT=@WORK@/lamprey-noinh.json SP_SPEED=1 SP_CHECK=1 SP_SHOT_AT=14
still map-body       1920x1080 SP_SCREEN=tasks SP_CHAPTER=heart SP_UNLOCK_ALL=1 SP_PROGRESS=m_pacemaking:3:96,m_coupling:2:88,heart_pacemaker:3:93 SP_SHOT_AT=2
still map-bestiary   1920x1080 SP_SCREEN=tasks SP_CHAPTER=leech SP_UNLOCK_ALL=1 SP_PROGRESS=l_burst:3:95,l_rebound:2:86 SP_SHOT_AT=2
still map-theory     1920x1080 SP_SCREEN=tasks SP_CHAPTER=dynamics SP_UNLOCK_ALL=1 SP_PROGRESS=d_class:3:94 SP_SHOT_AT=2
still diagnosis      1920x1080 SP_SCREEN=lab SP_TASK=dx_crab SP_SPEED=1 SP_SIM_UNTIL=6000 SP_SHOT_AT=3
still diagnosis2     1920x1080 SP_SCREEN=lab SP_TASK=dx_compass SP_SPEED=1 SP_SIM_UNTIL=6000 SP_SHOT_AT=3
still lesion         1920x1080 SP_SCREEN=lab SP_TASK=leech_heart SP_REF=1 SP_SPEED=2 SP_LESION=sweep SP_SIM_UNTIL=9000 SP_SHOT_AT=3
still parts          1920x1080 SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_PARTS=1 SP_UNLOCK_ALL=1 SP_SIM_UNTIL=3000 SP_SHOT_AT=3
still notebook       1920x1080 SP_SCREEN=notebook SP_PROGRESS=m_threshold:3:97,m_excitation:3:95,m_convergence:2:90,reflex:3:96,m_inhibition:3:94,m_subtraction:2:88,worm:2:84,m_adaptation:3:93,m_half_centre:3:95,lamprey:3:97 SP_SHOT_AT=2
still real           1920x1080 SP_SCREEN=real SP_SHOT_AT=2
still analysis       1920x1080 SP_SCREEN=analysis SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_SHOT_AT=7
still tutorial       1920x1080 SP_TUTORIAL=1 SP_TUT_STEP=6 SP_SHOT_AT=30
still editor-large   1920x1080 SP_SCREEN=lab SP_TASK=fly_mb SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=1500 SP_SHOT_AT=3
still end-card       1920x1080 SP_SCREEN=lab SP_TASK=lamprey SP_CIRCUIT=@WORK@/lamprey-mine.json SP_SPEED=2 SP_SHOT_AT=16
still map-fresh      1920x1080 SP_SCREEN=tasks SP_SHOT_AT=2
clip  lamprey        1920x1080 20 200 90  -                  1280 SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1
clip  heart          1920x1080 20 300 120 744x420+1160+76   744  SP_SCREEN=lab SP_TASK=heart_autonomic SP_REF=1 SP_SPEED=2
clip  baroreflex     1920x1080 20 200 40  744x420+1160+76   744  SP_SCREEN=lab SP_TASK=baroreflex SP_REF=1 SP_SPEED=4
clip  limb           1920x1080 20 180 20  744x420+1160+76   744  SP_SCREEN=lab SP_TASK=stretch_reflex SP_REF=1 SP_SPEED=1
clip  leech          1920x1080 20 278 120 -                  1280 SP_SCREEN=lab SP_TASK=leech_heart SP_REF=1 SP_SPEED=1
clip  compass        1920x1080 20 176 40  1556x756+344+70   1280 SP_SCREEN=lab SP_TASK=fly_compass SP_REF=1 SP_SPEED=1
clip  phase          1920x1080 20 1160 1000 744x420+1160+76  744  SP_SCREEN=lab SP_TASK=d_class SP_REF=1 SP_SPEED=0.05
clip  raster         1920x1080 20 140 10  744x226+1160+700  744  SP_SCREEN=lab SP_TASK=crab_pyloric SP_REF=1 SP_SPEED=1
clip  check          1920x1080 20 200 10  -                  1280 SP_SCREEN=lab SP_TASK=lamprey SP_CIRCUIT=@WORK@/lamprey-mine.json SP_SPEED=1 SP_CHECK=1
wiki  first-hour-lab        1920x1080 -                SP_SCREEN=lab SP_TASK=m_threshold SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=2500 SP_SHOT_AT=3
wiki  lab-annotated         1920x1080 -                SP_SCREEN=lab SP_TASK=reflex SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=5200 SP_SHOT_AT=3 @PINS=1200,40;300,92;700,330;1110,1000;1860,150;1500,372;1420,512;1870,780;1870,1030
wiki  end-card              1920x1080 620x390+660+352  SP_SCREEN=lab SP_TASK=lamprey SP_CIRCUIT=@WORK@/lamprey-mine.json SP_SPEED=1 SP_SHOT_AT=14
wiki  campaign-invertebrates 1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=invertebrates SP_PROGRESS=m_threshold:3:97,m_excitation:2:90 SP_SHOT_AT=2
wiki  campaign-spinal       1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=spinal SP_UNLOCK_ALL=1 SP_SHOT_AT=2
wiki  campaign-heart        1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=heart SP_UNLOCK_ALL=1 SP_SHOT_AT=2
wiki  campaign-breathing    1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=breathing SP_UNLOCK_ALL=1 SP_SHOT_AT=2
wiki  campaign-autonomic    1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=autonomic SP_UNLOCK_ALL=1 SP_SHOT_AT=2
wiki  bestiary-worm         1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=worm SP_SHOT_AT=2
wiki  bestiary-leech        1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=leech SP_SHOT_AT=2
wiki  bestiary-aplysia      1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=aplysia SP_SHOT_AT=2
wiki  bestiary-fly-compass  1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=fly_compass SP_SHOT_AT=2
wiki  bestiary-fly-mb       1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=fly_mb SP_SHOT_AT=2
wiki  bestiary-crab         1920x1080 1252x830+54+218 SP_SCREEN=tasks SP_CHAPTER=crab SP_SHOT_AT=2
wiki  theory-dynamics       1920x1080 744x420+1160+76 SP_SCREEN=lab SP_TASK=d_class SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=3000 SP_SHOT_AT=3
wiki  theory-rates          1920x1080 744x420+1160+76 SP_SCREEN=lab SP_TASK=r_oscillate SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=2000 SP_SHOT_AT=0.5
wiki  theory-memory         1920x1080 744x420+1160+76 SP_SCREEN=lab SP_TASK=h_complete SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=1500 SP_SHOT_AT=0.5
wiki  theory-tuning         1920x1080 744x420+1160+76 SP_SCREEN=lab SP_TASK=t_decode SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=1500 SP_SHOT_AT=0.5
wiki  bodies-limb           1920x1080 744x420+1160+76 SP_SCREEN=lab SP_TASK=stretch_reflex SP_REF=1 SP_SPEED=2 SP_SIM_UNTIL=5500 SP_SHOT_AT=3
LIST
)

export SP_RUN=1 SP_NOAUTOSAVE=1 SP_NODISPLAY=1 SP_NOTHROTTLE=1 SP_BUDGET_US=${SP_BUDGET_US:-400000}
WIKI_IMG=${WIKI_IMG:-$root/site/wiki-src/img}
FONT_PIN=$root/godot/assets/fonts/Fraunces.ttf
export EXPORT OUT WORK WIKI_IMG FONT_PIN

run_one() {   # one line of ITEMS
  set -euo pipefail
  local line=${1//@WORK@/$WORK}
  read -r kind name size rest <<<"$line"
  local d=$WORK/$kind-$name
  if [ -n "${REUSE:-}" ] && [ -d "$d" ]; then :; else rm -rf "$d"; fi   # REUSE=1: keep frames and shots already in WORK
  mkdir -p "$d/xdg" "$d/cfg"
  local srv=$(( 200 + $(printf '%s' "$kind-$name" | cksum | cut -d' ' -f1) % 600 ))
  local bin=$EXPORT/$size/Spike.x86_64
  local xv=(xvfb-run -n "$srv" -s "-screen 0 ${size}x24")
  if [ "$kind" = still ] || [ "$kind" = wiki ]; then
    local crop=- pins=""
    if [ "$kind" = wiki ]; then read -r crop rest <<<"$rest"; fi
    case " $rest " in *" @PINS="*) pins=${rest##*@PINS=}; pins=${pins%% *}; rest=${rest/@PINS=$pins/} ;; esac
    # shellcheck disable=SC2086
    [ -f "$d/shot.png" ] || (cd "$EXPORT/$size" && env XDG_DATA_HOME="$d/xdg" XDG_CONFIG_HOME="$d/cfg" $rest SP_SHOT="$d/shot.png" \
      timeout 300 "${xv[@]}" "$bin" --rendering-driver opengl3 >"$d/log" 2>&1) || true
    [ -f "$d/shot.png" ] || { echo "MISSING $name (log: $d/log)"; return 0; }
    if [ "$kind" = still ]; then
      magick "$d/shot.png" -filter Lanczos -resize 1600x -quality 82 -define webp:method=6 "$OUT/$name.webp"
      magick "$d/shot.png" -filter Lanczos -resize 800x -quality 80 -define webp:method=6 "$OUT/$name-800.webp"
      echo "still $name $(du -k "$OUT/$name.webp" | cut -f1) KB"
    else
      local src=$d/shot.png
      if [ -n "$pins" ]; then   # numbered call-outs, lettered like the game's plates: x,y;x,y;... in screen pixels
        local draw=() k=0 xy
        IFS=';' read -ra xy <<<"$pins"
        for p in "${xy[@]}"; do
          k=$((k + 1)); local px=${p%,*} py=${p#*,}
          draw+=(-fill '#B8461B' -stroke none -draw "circle $((px + 3)),$((py + 3)) $((px + 25)),$((py + 3))")
          draw+=(-fill '#FFFBF2' -stroke '#231C17' -strokewidth 3 -draw "circle $px,$py $((px + 22)),$py")
          draw+=(-stroke none -fill '#231C17' -font "$FONT_PIN" -pointsize 26 -gravity NorthWest -annotate "+$((px - (k > 9 ? 15 : 8)))+$((py - 17))" "$k")
        done
        magick "$src" "${draw[@]}" "$d/pinned.png"; src=$d/pinned.png
      fi
      local cr=(); [ "$crop" != - ] && cr=(-crop "$crop" +repage)
      mkdir -p "$WIKI_IMG"
      magick "$src" "${cr[@]}" -filter Lanczos -resize '1600x>' -quality 82 -define webp:method=6 "$WIKI_IMG/$name.webp"
      echo "wiki $name $(du -k "$WIKI_IMG/$name.webp" | cut -f1) KB"
    fi
  else
    local fps total first crop width envs
    read -r fps total first crop width envs <<<"$rest"
    local last; last=$d/f$(printf %08d $((total - 1))).png
    # shellcheck disable=SC2086
    [ -f "$last" ] || (cd "$EXPORT/$size" && env XDG_DATA_HOME="$d/xdg" XDG_CONFIG_HOME="$d/cfg" $envs \
      timeout 2400 "${xv[@]}" "$bin" --rendering-driver opengl3 --write-movie "$d/f.png" --fixed-fps "$fps" --quit-after "$total" >"$d/log" 2>&1) || true
    [ -f "$last" ] || { echo "SHORT $name (log: $d/log)"; return 0; }
    local vf="scale=${width}:-2:flags=lanczos" gw=$(( width < 640 ? width : 640 ))
    if [ "$crop" != - ]; then   # WxH+X+Y -> ffmpeg's w:h:x:y
      local cw=${crop%%x*} rest2=${crop#*x}; local ch=${rest2%%+*} cxy=${rest2#*+}
      vf="crop=${cw}:${ch}:${cxy%%+*}:${cxy#*+},$vf"
    fi
    local in=(-framerate "$fps" -start_number "$first" -i "$d/f%08d.png" -frames:v $((total - first)))
    ffmpeg -v error -y "${in[@]}" -vf "$vf" -frames:v 1 "$d/poster.png"
    magick "$d/poster.png" -quality 80 -define webp:method=6 "$OUT/$name-poster.webp"
    ffmpeg -v error -y "${in[@]}" -vf "$vf,format=yuv420p" -c:v libvpx-vp9 -b:v 0 -crf "${CRF_VP9:-36}" -row-mt 1 -deadline good -cpu-used 1 -an "$OUT/$name.webm"
    ffmpeg -v error -y "${in[@]}" -vf "$vf,format=yuv420p" -c:v libx264 -preset slow -crf "${CRF_264:-26}" -tune animation -movflags +faststart -an "$OUT/$name.mp4"
    ffmpeg -v error -y "${in[@]}" -vf "fps=10,${vf/scale=${width}/scale=${gw}},split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$OUT/$name.gif"
    echo "clip $name webm $(du -k "$OUT/$name.webm" | cut -f1) KB, mp4 $(du -k "$OUT/$name.mp4" | cut -f1) KB, gif $(du -k "$OUT/$name.gif" | cut -f1) KB"
  fi
}
export -f run_one

sel=$ITEMS
if [ -n "${ONLY:-}" ]; then
  sel=$(for n in $ONLY; do   # a name, or clip:<name> / still:<name> for one kind
    k="still|clip|wiki"; case $n in *:*) k=${n%%:*}; n=${n#*:} ;; esac
    grep -E "^($k) +$n " <<<"$ITEMS" || echo "unknown item $n" >&2
  done)
fi
printf '%s\n' "$sel" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}
echo "media in $OUT: $(du -sh "$OUT" | cut -f1)"
