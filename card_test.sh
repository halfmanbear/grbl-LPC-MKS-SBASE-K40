#!/usr/bin/env bash
# card_test.sh - end-to-end laser test on a small piece of card (default 60 x 40 mm).
#
# Generates card_test.nc and streams it to Grbl. The job exercises:
#   1. vector engrave  : M4 (dynamic power) square, diagonals and full circle (G2/G3 arcs)
#   2. raster          : bidirectional scanlines with a 10-step power gradient, S changes mid-move
#   3. M0 pause        : program pause, then resume. The laser must NOT fire on the G0 travel
#                        after resuming, only when the next powered G1 starts (tests the resume fix)
#   4. cut             : M3 (constant power) rectangle and circle, CUT_PASSES passes. Done last
#   plus G0 rapids between sections and a return to the card origin.
#
# Card layout (card origin = rear-left corner of the card, +X right, +Y toward the front):
#     X 5-20  Y 5-20   vector square + circle         X 25-55 Y 5-15  raster gradient
#     X 5-25  Y 25-35  cut rectangle                  circle d8 at X40 Y30 cut
#
# Usage:   DRY=1 ./card_test.sh     motion only: laser commands stripped (do this first)
#          ./card_test.sh           real burn
# Options (environment variables, defaults shown):
#   START_X=150 START_Y=80      machine position of the card's rear-left corner (mm)
#   HOMING=1                    home first (0 = already homed)
#   ENGRAVE_S=250 ENGRAVE_F=3000
#   RASTER_SMIN=30 RASTER_SMAX=400 RASTER_F=3000 RASTER_STEP=0.2
#   CUT_S=600 CUT_F=400 CUT_PASSES=1
#   TESTS="vector raster m0 cut"  which sections to run, e.g. TESTS=raster or TESTS="m0"
#                               also: dwell = same two lines as m0, but the pause is M5 + G4 (no M0
#                               hold/resume code), to tell firmware effects from tube start-up
#   DWELL=10                    pause length in seconds for the dwell test
#   M0_TEST=1                   include the M0 pause/resume test (0 = skip)
#   PORT=/dev/ttyACM0
# S is 0-1000: S1 = $35 (17%) ... S1000 = $36 (68%, ~15-16 mA). Card varies a lot: adjust S/F.
# Ctrl-C at any time sends a Grbl soft reset (laser off, motion stops).

set -u
PORT=${PORT:-/dev/ttyACM0}
START_X=${START_X:-150}; START_Y=${START_Y:-80}; HOMING=${HOMING:-1}; DRY=${DRY:-0}
ENGRAVE_S=${ENGRAVE_S:-250}; ENGRAVE_F=${ENGRAVE_F:-3000}
RASTER_SMIN=${RASTER_SMIN:-30}; RASTER_SMAX=${RASTER_SMAX:-400}; RASTER_F=${RASTER_F:-3000}; RASTER_STEP=${RASTER_STEP:-0.2}
CUT_S=${CUT_S:-600}; CUT_F=${CUT_F:-400}; CUT_PASSES=${CUT_PASSES:-1}
M0_TEST=${M0_TEST:-1}; DWELL=${DWELL:-10}
TESTS=" ${TESTS:-vector raster m0 cut} "
[[ $M0_TEST == 1 ]] || TESTS=${TESTS// m0 / }
has() { [[ $TESTS == *" $1 "* ]]; }
CARD_W=60; CARD_H=40
NC="$(dirname "$0")/card_test.nc"

FIRING=0; OPEN=0; G92SET=0

die() { echo "ERROR: $*" >&2; exit 1; }
ask() { local a=""; read -r -p "$1" a </dev/tty; printf '%s' "$a"; }
drain() { local l; while IFS= read -r -t "${1:-0.3}" l <&3; do :; done; }

wait_ok() {   # wait_ok <timeout s>; replies other than ok go to $REPLY_LINES
  local l; REPLY_LINES=""
  while IFS= read -r -t "$1" l <&3; do
    l=${l%$'\r'}
    case "$l" in
      ok)            return 0 ;;
      error*|ALARM*) echo "  Grbl: $l" >&2; return 1 ;;
      '')            ;;
      *)             REPLY_LINES+="$l"$'\n' ;;
    esac
  done
  echo "  Timed out waiting for Grbl" >&2; return 1
}
send() { printf '%s\n' "$1" >&3; wait_ok "${2:-60}" || { echo "  (after: $1)" >&2; return 1; }; }

status() {
  local l; printf '?' >&3
  while IFS= read -r -t 2 l <&3; do l=${l%$'\r'}; [[ $l == \<* ]] && { printf '%s' "$l"; return 0; }; done
  return 1
}

declare -A SET
read_settings() {
  local k v; send '$$' || return 1
  while IFS='=' read -r k v; do [[ $k == \$* ]] && SET[${k#\$}]=$v; done <<<"$REPLY_LINES"
  [[ -n ${SET[32]:-} ]]
}

cleanup() {
  trap - INT TERM HUP EXIT
  trap '' INT HUP
  [[ $OPEN == 1 ]] || exit
  if [[ $FIRING == 1 ]]; then
    printf '\x18' >&3                      # soft reset: laser off, motion stops immediately
    echo; echo "Stopped (soft reset). Re-home with \$H before the next job."
    sleep 1.5; drain 0.5
  fi
  send 'M5' 5 >/dev/null 2>&1
  [[ $G92SET == 1 ]] && send 'G92.1' 5 >/dev/null 2>&1   # clear the temporary card origin
  exec 3<&- 3>&-
}

# --- G-code generation --------------------------------------------------------

gen() {
  echo "; card_test.nc - generated $(date '+%Y-%m-%d %H:%M') by card_test.sh"
  echo "; origin = card rear-left corner (set with G92 by the script). +X right, +Y toward front."
  echo "G21 G90 G17 G94"
  echo "M5"

  if has vector; then
  echo "; --- 1. vector engrave, M4 dynamic power ---"
  echo "G0 X5 Y5"
  echo "M4 S$ENGRAVE_S"
  echo "G1 X20 Y5 F$ENGRAVE_F"
  echo "G1 X20 Y20"
  echo "G1 X5 Y20"
  echo "G1 X5 Y5"
  echo "G1 X20 Y20"            # diagonal
  echo "G0 X20 Y5"
  echo "G1 X5 Y20"             # other diagonal
  echo "G0 X7.5 Y12.5"
  echo "G2 X17.5 Y12.5 I5 J0"  # half circle clockwise
  echo "G2 X7.5 Y12.5 I-5 J0"  # second half
  echo "G0 X10 Y12.5"
  echo "G3 X10 Y12.5 I2.5 J0"  # full circle counter-clockwise, one block
  echo "M5"
  fi

  if has raster; then
  echo "; --- 2. raster gradient, M4, bidirectional, 10 power steps ---"
  awk -v x0=25 -v w=3 -v n=10 -v y0=5 -v h=10 -v dy="$RASTER_STEP" \
      -v smin="$RASTER_SMIN" -v smax="$RASTER_SMAX" -v f="$RASTER_F" 'BEGIN{
    lines = int(h/dy + 0.5)
    print "M4 S0"
    for (j = 0; j < lines; j++) {
      y = y0 + j*dy
      if (j % 2 == 0) {
        printf "G0 X%.3f Y%.3f\n", x0, y
        for (k = 0; k < n; k++) printf "G1 X%.3f S%d F%d\n", x0 + (k+1)*w, smin + k*(smax-smin)/(n-1), f
      } else {
        printf "G0 X%.3f Y%.3f\n", x0 + n*w, y
        for (k = n-1; k >= 0; k--) printf "G1 X%.3f S%d F%d\n", x0 + k*w, smin + k*(smax-smin)/(n-1), f
      }
    }
    print "M5"
  }'
  fi

  if has m0; then
    echo "; --- 3. M0 pause test: laser must stay off on the G0 after resume ---"
    echo "M4 S$ENGRAVE_S"
    echo "G0 X25 Y18"
    echo "G1 X40 Y18 F$ENGRAVE_F"     # short line before the pause
    echo "M0"
    echo "G0 X25 Y20"                  # travel after resume: must NOT mark
    echo "G1 X40 Y20 F$ENGRAVE_F"     # powered line after resume: must mark
    echo "M5"
  fi

  if has dwell; then
    echo "; --- 3b. dwell comparison: same as M0 test but a plain laser-off wait ---"
    echo "M4 S$ENGRAVE_S"
    echo "G0 X25 Y18"
    echo "G1 X40 Y18 F$ENGRAVE_F"
    echo "M5"
    echo "G4 P$DWELL"                 # laser off for DWELL s, no hold/resume involved
    echo "M4 S$ENGRAVE_S"
    echo "G0 X25 Y20"
    echo "G1 X40 Y20 F$ENGRAVE_F"
    echo "M5"
  fi

  if has cut; then
  echo "; --- 4. cut, M3 constant power, $CUT_PASSES pass(es) ---"
  local p
  for (( p=1; p<=CUT_PASSES; p++ )); do
    echo "; pass $p"
    echo "G0 X5 Y25"
    echo "M3 S$CUT_S"
    echo "G1 X25 Y25 F$CUT_F"
    echo "G1 X25 Y35"
    echo "G1 X5 Y35"
    echo "G1 X5 Y25"
    echo "G0 X36 Y30"
    echo "G2 X36 Y30 I4 J0"           # d8 circle
    echo "M5"
  done
  fi

  echo "; --- end ---"
  echo "M5"
  echo "G0 X0 Y0"
}

# --- setup ------------------------------------------------------------------
gen > "$NC" || die "could not write $NC"
if [[ $DRY == 1 ]]; then
  # Motion only: drop every M3/M4 and S word so the laser is never enabled.
  sed -i -E 's/ ?M[34]( |$)/ /g; s/ ?S[0-9.]+//g; s/[[:space:]]+$//' "$NC"
  sed -i '1a ; DRY RUN: laser commands removed' "$NC"
fi
NLINES=$(grep -cv '^;' "$NC")
echo "Wrote $NC ($NLINES commands)."

[[ -e $PORT ]] || die "$PORT not found"
fuser -s "$PORT" 2>/dev/null && die "$PORT is in use (close LaserGRBL/LightBurn/picocom first)"
stty -F "$PORT" 115200 cs8 -cstopb -parenb raw -echo -hupcl || die "stty failed"
exec 3<>"$PORT"; OPEN=1
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
drain 1.5

st=""; for _ in 1 2 3; do st=$(status) && break; drain 1; done
[[ -n $st ]] || die "no status reply from Grbl"
echo "Status: $st"
[[ $st == "<Idle"* || $st == "<Alarm"* ]] || die "Grbl must be Idle or Alarm"
[[ $HOMING == 1 || $st == "<Idle"* ]] || die "Grbl is in Alarm; run with HOMING=1"

read_settings || die "could not read settings"
[[ ${SET[32]%%.*} == 1 ]] || die "\$32 laser mode is off; refusing to run."
awk -v v="${SET[34]}" 'BEGIN{exit !(v+0 == 0)}' || die "\$34 is ${SET[34]}; set \$34=0 first."
awk -v x="$START_X" -v y="$START_Y" -v w="$CARD_W" -v h="$CARD_H" -v xm="${SET[130]}" -v ym="${SET[131]}" \
  'BEGIN{exit !(x>=0 && y>=0 && x+w<=xm && y+h<=ym)}' \
  || die "card area X$START_X+$CARD_W Y$START_Y+$CARD_H is outside the work area (0-${SET[130]} x 0-${SET[131]})"

cat <<EOF

Card test $( [[ $DRY == 1 ]] && echo "(DRY RUN: no laser)" )   sections:${TESTS% }
  card      : ${CARD_W} x ${CARD_H} mm, rear-left corner at machine X$START_X Y$START_Y
  engrave   : M4 S$ENGRAVE_S F$ENGRAVE_F
  raster    : M4 S$RASTER_SMIN-$RASTER_SMAX F$RASTER_F, ${RASTER_STEP} mm line spacing
  M0 test   : $( has m0 && echo yes || echo no )
  cut       : M3 S$CUT_S F$CUT_F x $CUT_PASSES pass(es)

EOF
[[ $(ask "Home (if enabled) and move to the card corner? Bed clear? [y/N] ") == [yY]* ]] || { echo "Cancelled."; exit 0; }

FIRING=1
if [[ $HOMING == 1 ]]; then echo "Homing..."; send '$H' 120 || exit 1; fi
send "G21 G90 G53 G0 X$START_X Y$START_Y" || exit 1
send 'G4 P0.01' || exit 1
FIRING=0

if [[ $DRY != 1 ]]; then
  cat <<EOF

Head is over the card's rear-left corner. Place a ${CARD_W} x ${CARD_H} mm card with its
rear-left corner under the head, focused. Water flowing, extraction/air on, lid closed,
laser enabled at the PSU. Ctrl-C stops everything at once.
EOF
  [[ $(ask 'Type FIRE to start: ') == FIRE ]] || { echo "Cancelled."; exit 0; }
else
  [[ $(ask 'Start dry run? [y/N] ') == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

# --- stream -------------------------------------------------------------------
send 'G92 X0 Y0' || exit 1; G92SET=1          # card corner becomes 0,0 for the job
FIRING=1
n=0; t0=$(date +%s)
while IFS= read -r line; do
  line=${line%%;*}; line=${line%$'\r'}
  [[ -z ${line// } ]] && continue
  n=$((n+1))
  if [[ $line =~ ^M0$ ]]; then
    printf '%s\n' "$line" >&3
    # Grbl only answers "ok" to M0 after it is resumed. Wait for the hold, then ask.
    for _ in $(seq 1 40); do s=$(status) && [[ $s == "<Hold"* ]] && break; sleep 0.25; done
    printf '\a\n\n'
    echo "=================== PAUSED at M0 ==================="
    echo "  $s"
    echo "  Check NOW: laser off, mA meter at 0."
    echo "  After resume: head travels (G0) to X25 Y20 with NO marking,"
    echo "  then burns a line at Y20 parallel to the Y18 line."
    echo "  >>> Press Enter to resume (cycle start) <<<"
    echo "===================================================="
    read -r _ </dev/tty
    printf '~' >&3
    wait_ok 60 || exit 1
    continue
  fi
  printf '\r  line %d/%d  %-40s' "$n" "$NLINES" "$line"
  send "$line" || exit 1
done < "$NC"
send 'G4 P0.01' 300 || exit 1                   # wait for the last motion to finish
FIRING=0
echo
echo "Done in $(( $(date +%s) - t0 )) s."
cat <<EOF

Check the card:
  - square, diagonals and both circles closed and evenly engraved (arcs OK, M4 OK)
  - raster: 10 distinct steps light->dark, both line directions aligned (no zig-zag offset)
  - M0: no mark on the travel to X25 Y20; second line at Y20 present
  - cut: rectangle and circle cut through (raise CUT_S / CUT_PASSES or lower CUT_F if not)
EOF
