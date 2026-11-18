#!/usr/bin/env bash
# tube_watch_test.sh - repeated stationary shots at one spot so you can watch the tube strike.
#
# Homes, moves to START_X/START_Y, then fires SHOTS shots of ON seconds each at DUTY % PWM,
# with a random laser-off gap of DWELL_MIN..DWELL_MAX seconds between shots.
# Laser mode ($32=1) only fires during motion, so $32 is set to 0 for the test and restored.
# Each shot is sent as "M3 S.. G4 P<ON>" + "M5" in one write, so the shot ends on time even if
# this script or the USB link dies.
#
# Usage:   ./tube_watch_test.sh
# Options: DUTY=25 ON=2 SHOTS=10 DWELL_MIN=0.5 DWELL_MAX=3 HOMING=1 START_X=150 START_Y=80
# Ctrl-C sends a Grbl soft reset (laser off immediately) and restores $32.

set -u
PORT=${PORT:-/dev/ttyACM0}
DUTY=${DUTY:-25}; ON=${ON:-2}; SHOTS=${SHOTS:-10}; DWELL_MIN=${DWELL_MIN:-0.5}; DWELL_MAX=${DWELL_MAX:-3}
START_X=${START_X:-150}; START_Y=${START_Y:-80}; HOMING=${HOMING:-1}
FIRING=0; ORIG32=""; OPEN=0

die() { echo "ERROR: $*" >&2; exit 1; }
ask() { local a=""; read -r -p "$1" a </dev/tty; printf '%s' "$a"; }
drain() { local l; while IFS= read -r -t "${1:-0.3}" l <&3; do :; done; }

# Read replies until n "ok"s (or error/ALARM/timeout). Non-ok lines go to $REPLY_LINES.
wait_ok() {
  local n=$1 t=$2 l got=0; REPLY_LINES=""
  while IFS= read -r -t "$t" l <&3; do
    l=${l%$'\r'}
    case "$l" in
      ok)            got=$((got+1)); (( got >= n )) && return 0 ;;
      error*|ALARM*) echo "  Grbl: $l" >&2; return 1 ;;
      '')            ;;
      *)             REPLY_LINES+="$l"$'\n' ;;
    esac
  done
  echo "  Timed out waiting for Grbl" >&2; return 1
}
send() { printf '%s\n' "$1" >&3; wait_ok 1 "${2:-10}"; }   # send LINE [timeout_s]

status() {
  local l; printf '?' >&3
  while IFS= read -r -t 2 l <&3; do l=${l%$'\r'}; [[ $l == \<* ]] && { printf '%s' "$l"; return 0; }; done
  return 1
}

get_setting() {   # get_setting 32 -> prints value
  local k v
  send '$$' >/dev/null 2>&1 || return 1
  while IFS='=' read -r k v; do [[ $k == "\$$1" ]] && { printf '%s' "$v"; return 0; }; done <<<"$REPLY_LINES"
  return 1
}

cleanup() {
  trap - INT TERM HUP EXIT
  trap '' INT HUP
  [[ $OPEN == 1 ]] || exit
  if [[ $FIRING == 1 ]]; then
    printf '\x18' >&3              # soft reset: laser off immediately
    echo; echo "Stopped (soft reset)."
    sleep 1.5; drain 0.5
  fi
  send 'M5' >/dev/null 2>&1
  if [[ -n $ORIG32 ]]; then
    local t v ok=0
    for t in 1 2 3; do
      drain 0.3
      send "\$32=$ORIG32" >/dev/null 2>&1
      v=$(get_setting 32) && [[ ${v%%.*} == "${ORIG32%%.*}" ]] && { ok=1; break; }
      sleep 0.5
    done
    if [[ $ok == 1 ]]; then echo "Restored \$32=$ORIG32 (laser mode)."
    else echo "WARNING: could not confirm laser mode was restored. Send \$32=$ORIG32 NOW." >&2; fi
  fi
  exec 3<&- 3>&-
}

# --- setup ------------------------------------------------------------------
[[ -e $PORT ]] || die "$PORT not found"
fuser -s "$PORT" 2>/dev/null && die "$PORT is in use (close LaserGRBL/LightBurn/picocom first)"
awk -v d="$DUTY" -v t="$ON" -v n="$SHOTS" -v a="$DWELL_MIN" -v b="$DWELL_MAX" \
  'BEGIN{exit !(d>0 && d<=100 && t>0 && t<=3 && n>=1 && n<=50 && a>=0 && b>=a)}' \
  || die "need 0<DUTY<=100, 0<ON<=3, 1<=SHOTS<=50, 0<=DWELL_MIN<=DWELL_MAX"
stty -F "$PORT" 115200 cs8 -cstopb -parenb raw -echo -hupcl || die "stty failed"
exec 3<>"$PORT"; OPEN=1
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
drain 1.5

st=""; for _ in 1 2 3; do st=$(status) && break; drain 1; done
[[ -n $st ]] || die "no status reply from Grbl"
echo "Status: $st"
[[ $st == "<Idle"* || $st == "<Alarm"* ]] || die "Grbl must be Idle or Alarm (not running a job)"
[[ $HOMING == 1 || $st == "<Idle"* ]] || die "Grbl is in Alarm; run with HOMING=1 (default) or home first"

m32=$(get_setting 32) || die "could not read \$32"
v34=$(get_setting 34) || die "could not read \$34"
v30=$(get_setting 30); v35=$(get_setting 35); v36=$(get_setting 36)
awk -v v="$v34" 'BEGIN{exit !(v+0 == 0)}' || die "\$34 is $v34; set \$34=0 first."
v130=$(get_setting 130); v131=$(get_setting 131)
awk -v x="$START_X" -v y="$START_Y" -v xm="$v130" -v ym="$v131" 'BEGIN{exit !(x>=0 && y>=0 && x<=xm && y<=ym)}' \
  || die "START_X/START_Y ($START_X,$START_Y) outside work area 0-$v130 x 0-$v131"
# S for the requested duty: duty = $35 + ($36-$35) * S/$30
S=$(awk -v d="$DUTY" -v smax="$v30" -v lo="$v35" -v hi="$v36" 'BEGIN{
  if (d < lo || d > hi) exit 1; printf "%d", (d-lo)/(hi-lo)*smax + 0.5 }') \
  || die "DUTY=$DUTY% is outside \$35..\$36 ($v35..$v36%)"
duty=$(awk -v s="$S" -v smax="$v30" -v lo="$v35" -v hi="$v36" 'BEGIN{printf "%.1f", lo+(hi-lo)*s/smax}')

# --- home and move to the firing position ------------------------------------
echo
if [[ $HOMING == 1 ]]; then echo "Next: home (\$H, rear-left), then move to X$START_X Y$START_Y. Laser stays off."
else echo "Next: move to X$START_X Y$START_Y (no homing). Laser stays off."; fi
[[ $(ask 'Bed clear and head free to move? [y/N] ') == [yY]* ]] || { echo "Cancelled."; exit 0; }
FIRING=1                                   # Ctrl-C during motion -> soft reset
if [[ $HOMING == 1 ]]; then echo "Homing..."; send '$H' 120 || die "homing failed"; fi
send "G21 G90 G53 G0 X$START_X Y$START_Y" 60 || exit 1
send 'G4 P0.01' 60 || exit 1               # wait until the move has finished
FIRING=0
st=$(status) && echo "At: $st"

cat <<EOF

Tube watch test
  power    : S$S = ${duty}% PWM duty   (\$35=$v35, \$36=$v36)
  shots    : $SHOTS x ${ON} s, random ${DWELL_MIN}-${DWELL_MAX} s laser-off gap between shots
  The head does not move: every shot hits the same spot (about $(awk -v n="$SHOTS" -v t="$ON" 'BEGIN{print n*t}') s total burn).
  Put a ceramic tile or thick wood block under the head. Water flowing, extraction on,
  lid closed, laser enabled at the PSU. Note the shot number of any weak / noisy shot.

EOF
[[ $(ask 'Type FIRE to start: ') == FIRE ]] || { echo "Cancelled."; exit 0; }

# --- fire -------------------------------------------------------------------
if [[ ${m32%%.*} == 1 ]]; then
  ORIG32=1
  send '$32=0' || die "could not disable laser mode"
fi
FIRING=1
for (( i=1; i<=SHOTS; i++ )); do
  printf '%s  shot %2d/%d  ON %s s ... ' "$(date +%T)" "$i" "$SHOTS" "$ON"
  printf 'M3 S%s G4 P%s\nM5\n' "$S" "$ON" >&3        # M5 is queued before the shot starts
  wait_ok 2 "$(awk -v t="$ON" 'BEGIN{print t+5}')" || { echo; echo "Shot did not complete normally." >&2; exit 1; }
  echo "off"
  if (( i < SHOTS )); then
    gap=$(awk -v a="$DWELL_MIN" -v b="$DWELL_MAX" -v r="$RANDOM" 'BEGIN{srand(r); printf "%.1f", a+(b-a)*rand()}')
    printf '          gap %s s\n' "$gap"
    sleep "$gap"
  fi
done
FIRING=0
echo "Done: $SHOTS shots."
