#!/usr/bin/env bash
# Retake the documentation screenshots -> docs/screenshots/<screen>-<WxH>.png  (sizes: desktop 1920x1080, phone 844x390 landscape)
# Without a display (CI, containers) or with SP_SHOTS_GL=1 it renders through xvfb-run and the OpenGL renderer.
# ONLY="title lab" limits the screens; SS=2 renders at double size and downsamples with Lanczos; SIZES="1920x1080" limits the sizes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); cd "$root"
[ -n "${SP_NOBUILD:-}" ] || scripts/build-gd.sh >/dev/null   # SP_NOBUILD=1: use the extension as built (another job may be rebuilding it)
cd godot
godot --headless --path . --import >/dev/null 2>&1
out=${OUT:-$root/docs/screenshots}; mkdir -p "$out"   # OUT=<dir> writes the shots elsewhere
SS=${SS:-1}
tmp=$(mktemp -d); trap 'rm -rf "$tmp" override.cfg' EXIT
# a level never starts a run by itself; the shots show one running (SP_RUN starts it at once)
export SP_RUN=1 SP_NOAUTOSAVE=1 SP_NODISPLAY=1 SP_NOTHROTTLE=1 SP_BUDGET_US=${SP_BUDGET_US:-200000}
im=$(command -v magick || command -v convert || true)
run_godot() {
  if [ -z "${DISPLAY:-}" ] || [ "${SP_SHOTS_GL:-0}" = 1 ]; then
    env "$@" xvfb-run -a -s "-screen 0 $((1920*SS))x$((1080*SS))x24" godot --path . --rendering-driver opengl3 >/dev/null 2>&1 || true
  else
    env "$@" godot --path . >/dev/null 2>&1 || true
  fi
}
shot() {   # shot <name> <WxH> <env assignments...>
  local name=$1 size=$2; shift 2
  local w=${size%x*} h=${size#*x}
  printf '[display]\nwindow/size/mode=0\nwindow/size/window_width_override=%s\nwindow/size/window_height_override=%s\n' $((w*SS)) $((h*SS)) > override.cfg
  local png=$tmp/$name-$size.png
  run_godot SP_SHOT_AT="${SP_SHOT_AT:-1.5}" "$@" SP_SHOT="$png"
  [ -f "$png" ] || { echo "MISSING $name-$size"; return 1; }
  if [ "$SS" != 1 ] && [ -n "$im" ]; then "$im" "$png" -filter Lanczos -resize "${w}x${h}!" "$out/$name-$size.png"; else cp "$png" "$out/$name-$size.png"; fi
  echo "wrote $out/$name-$size.png"
}
ONLY=${ONLY:-"title real tasks tasks-invertebrates tasks-spinal tasks-heart tasks-breathing tasks-autonomic parts lab-first lab-more lab-baro histo lab-lesion lab-sandbox real-heart real-breathing real-stretch view-heart view-dash view-lungs view-eye view-gut view-limb lab-lamprey lab-worm lab-reflex lab-edit lab-world lab-scopes lab-empty lab-overlay lab-adv lab-menu analysis settings settings-game notebook notebook-concepts credits"}
PHONE_ONLY=" lab-world lab-scopes lab-menu "
for size in ${SIZES:-1920x1080 844x390}; do
  for s in $ONLY; do
    [[ "$PHONE_ONLY" == *" $s "* && "$size" != 844x390 ]] && continue
    case $s in
      v3-campaign) shot v3-campaign $size SP_SCREEN=tasks SP_CHAPTER=invertebrates SP_PROGRESS=${SP_PROGRESS:-m_threshold:3:97,m_excitation:3:95,m_convergence:2:88,reflex:2:91} ;;
      v3-micro) shot v3-micro $size SP_SCREEN=lab SP_TASK=m_half_centre SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=2500 SP_SHOT_AT=3 ;;
      v3-hint) shot v3-hint $size SP_SCREEN=lab SP_TASK=m_inhibition SP_SPEED=1 SP_FAILS=2 SP_HINT=3 SP_VERDICT=1 SP_SHOT_AT=4 ;;
      v3-histo) shot v3-histo $size SP_SCREEN=lab SP_TASK=reflex SP_REF=1 SP_SPEED=50 SP_SIM_UNTIL=20000 SP_HISTO=1 SP_SHOT_AT=4 ;;
      v3-dx) shot v3-dx $size SP_SCREEN=lab SP_TASK=dx_horner SP_SPEED=5 SP_SIM_UNTIL=8000 SP_DXPICK=HYP\>EW SP_DXSUBMIT=1 SP_SHOT_AT=4 ;;
      v3-celeb) shot v3-celeb $size SP_SCREEN=lab SP_TASK=m_threshold SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=3000 SP_CELEB=1 SP_SHOT_AT=2.5 ;;
      v3-boss) shot v3-boss $size SP_SCREEN=lab SP_TASK=boss_autonomic_exam SP_REF=1 SP_SPEED=10 SP_SIM_UNTIL=70000 SP_LABTAB=world SP_SHOT_AT=4 ;;
      title) shot title $size SP_SCREEN=title ;;
      lab-first) shot lab-first $size SP_SCREEN=lab SP_TASK=m_threshold SP_SPEED=1 SP_SHOT_AT=2 ;;   # level 1 as a new player sees it (progressive disclosure)
      lab-baro) shot lab-baro $size SP_SCREEN=lab SP_TASK=baroreflex SP_UNLOCK_ALL=1 SP_SPEED=1 SP_SHOT_AT=2 ;;
      lab-more) shot lab-more $size SP_SCREEN=lab SP_TASK=m_threshold SP_SPEED=1 SP_MENU=1 SP_SHOT_AT=2 ;;
      histo) shot histo $size SP_SCREEN=lab SP_TASK=reflex SP_REF=1 SP_SPEED=50 SP_SIM_UNTIL=20000 SP_HISTO=1 SP_SHOT_AT=4 ;;
      histo-empty) shot histo-empty $size SP_SCREEN=lab SP_TASK=m_threshold SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=3000 SP_HISTO=1 SP_SHOT_AT=3 ;;
      real) shot real $size SP_SCREEN=real ;;
      tasks-invertebrates) shot tasks-invertebrates $size SP_SCREEN=tasks SP_CHAPTER=invertebrates SP_UNLOCK_ALL=1 ;;
      tasks-breathing) shot tasks-breathing $size SP_SCREEN=tasks SP_CHAPTER=breathing SP_UNLOCK_ALL=1 ;;
      settings) shot settings $size SP_SCREEN=settings SP_TAB=Display ;;
      tasks) shot tasks $size SP_SCREEN=tasks SP_PROGRESS=${SP_PROGRESS:-reflex:3:96,worm:2:84,lamprey:1:71} ;;
      tasks-spinal) shot tasks-spinal $size SP_SCREEN=tasks SP_CHAPTER=spinal SP_PROGRESS=${SP_PROGRESS:-reflex:3:96,worm:2:84,lamprey:1:71} ;;
      tasks-heart) shot tasks-heart $size SP_SCREEN=tasks SP_CHAPTER=heart SP_UNLOCK_ALL=1 SP_PROGRESS=${SP_PROGRESS:-reflex:3:96,worm:2:84,lamprey:1:71} ;;
      tasks-autonomic) shot tasks-autonomic $size SP_SCREEN=tasks SP_CHAPTER=autonomic SP_UNLOCK_ALL=1 ;;
      parts) shot parts $size SP_SCREEN=parts SP_PROGRESS=${SP_PROGRESS:-reflex:3:96,worm:2:84,lamprey:1:71} ;;   # SP_CATALOG=<thumbs.json> shows another catalogue
      lab-lesion) shot lab-lesion $size SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_LESION=sweep SP_LESIONS=pop:E_L SP_SHOT_AT=3 ;;
      lab-sandbox) shot lab-sandbox $size SP_SCREEN=lab SP_TASK= SP_CIRCUIT=$root/circuits/lamprey_cpg.json SP_SPEED=1 SP_SIM_UNTIL=4000 SP_MODDIALS=1 SP_SHOT_AT=3 ;;
      real-heart) shot real-heart $size SP_SCREEN=lab SP_TASK=heart_pacemaker SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=8000 SP_LABTAB=world SP_SHOT_AT=3 ;;   # tasks the engine has supplied (campaign chapters spinal / heart / breathing)
      real-breathing) shot real-breathing $size SP_SCREEN=lab SP_TASK=breathing SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=12000 SP_LABTAB=world SP_SHOT_AT=3 ;;
      real-stretch) shot real-stretch $size SP_SCREEN=lab SP_TASK=stretch_reflex SP_REF=1 SP_SPEED=2 SP_SIM_UNTIL=5500 SP_LABTAB=world SP_SHOT_AT=3 ;;
      view-heart) shot view-heart $size SP_MOCK=1 SP_SCREEN=lab SP_TASK=mock_heart SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=18000 SP_LABTAB=world SP_SHOT_AT=3 ;;   # synthetic body-system tasks (game/mock_task.gd)
      view-dash) shot view-dash $size SP_MOCK=1 SP_SCREEN=lab SP_TASK=mock_dash SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=24000 SP_LABTAB=world SP_SHOT_AT=3 ;;
      view-lungs) shot view-lungs $size SP_MOCK=1 SP_SCREEN=lab SP_TASK=mock_lungs SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=26000 SP_LABTAB=world SP_SHOT_AT=3 ;;
      view-eye) shot view-eye $size SP_MOCK=1 SP_SCREEN=lab SP_TASK=mock_eye SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=6500 SP_LABTAB=world SP_SHOT_AT=3 ;;
      view-gut) shot view-gut $size SP_MOCK=1 SP_SCREEN=lab SP_TASK=mock_gut SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=20000 SP_LABTAB=world SP_SHOT_AT=3 ;;
      view-limb) shot view-limb $size SP_MOCK=1 SP_SCREEN=lab SP_TASK=mock_limb SP_REF=1 SP_SPEED=5 SP_SIM_UNTIL=6500 SP_LABTAB=world SP_SHOT_AT=3 ;;
      lab-lamprey) shot lab-lamprey $size SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=6000 SP_SHOT_AT=3 ;;
      lab-worm) shot lab-worm $size SP_SCREEN=lab SP_TASK=worm SP_REF=1 SP_SPEED=20 SP_SIM_UNTIL=40000 SP_SHOT_AT=3 ;;
      lab-reflex) shot lab-reflex $size SP_SCREEN=lab SP_TASK=reflex SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=5200 SP_SHOT_AT=3 ;;
      lab-edit) shot lab-edit $size SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_SEL=proj:3 SP_SIM_UNTIL=6000 SP_SHOT_AT=3 ;;
      lab-world) shot lab-world $size SP_SCREEN=lab SP_TASK=worm SP_REF=1 SP_SPEED=20 SP_SIM_UNTIL=40000 SP_LABTAB=world SP_SHOT_AT=3 ;;
      lab-scopes) shot lab-scopes $size SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_SIM_UNTIL=6000 SP_LABTAB=scopes_only SP_SHOT_AT=3 ;;
      lab-empty) shot lab-empty $size SP_SCREEN=lab SP_TASK=reflex SP_SPEED=1 SP_SHOT_AT=2 ;;
      lab-overlay) shot lab-overlay $size SP_SCREEN=lab SP_TASK=reflex SP_REF=1 SP_SPEED=50 SP_SIM_UNTIL=20000 SP_SHOT_AT=3 ;;
      lab-adv) shot lab-adv $size SP_SCREEN=lab SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_SEL=pop:E_L SP_ADV=1 SP_SIM_UNTIL=3000 SP_SHOT_AT=3 ;;
      lab-menu) shot lab-menu $size SP_SCREEN=lab SP_TASK=reflex SP_REF=1 SP_SPEED=1 SP_MENU=1 SP_SIM_UNTIL=3000 SP_SHOT_AT=3 ;;
      analysis) shot analysis $size SP_SCREEN=analysis SP_TASK=lamprey SP_REF=1 SP_SPEED=1 SP_SHOT_AT=7 ;;
      settings-game) shot settings-game $size SP_SCREEN=settings SP_TAB=Game ;;
      notebook) shot notebook $size SP_SCREEN=notebook SP_PROGRESS=${SP_PROGRESS:-reflex:3:96,worm:2:84,lamprey:1:71} ;;
      notebook-concepts) shot notebook-concepts $size SP_SCREEN=notebook SP_NB_TAB=Concepts SP_PROGRESS=${SP_PROGRESS:-reflex:3:96,worm:2:84,lamprey:1:71} ;;
      credits) shot credits $size SP_SCREEN=credits ;;
      *) echo "unknown screen $s" >&2; exit 2 ;;
    esac
  done
done
