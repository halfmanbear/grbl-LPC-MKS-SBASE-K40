#!/usr/bin/env bash
# laser_pulse_test.sh - fire the laser stationary for a short, fixed time to read the mA meter.
#
# Laser mode ($32=1) only fires during G1 motion, so this briefly sets $32=0, sends
#   M3 S<S> G4 P<SECS>   and   M5
# in ONE write, so Grbl already has M5 buffered before firing starts: the pulse ends after SECS
# even if this script or the USB link dies. $32 is restored and verified afterwards.
#
# Homes ($H) and moves to START_X/START_Y (machine coordinates, default mid-bed) before firing.
#
# Usage:   ./laser_pulse_test.sh            (S=1000 for 1 s: full power = $36 duty)
#          S=500 SECS=0.5 ./laser_pulse_test.sh
#          HOMING=0 ./laser_pulse_test.sh   (already homed: skip $H)
#          START_X=100 START_Y=50 ./laser_pulse_test.sh
# Ctrl-C sends a Grbl soft reset (laser off immediately) and restores $32.

set -u
PORT=${PORT:-/dev/ttyACM0}
S=${S:-1000}; SECS=${SECS:-1}
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
awk -v s="$S" -v t="$SECS" 'BEGIN{exit !(s>0 && s<=1000 && t>0 && t<=3)}' || die "need 0 < S <= 1000 and 0 < SECS <= 3"
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

Stationary laser pulse
  power    : S$S  = about ${duty}% PWM duty   (\$35=$v35, \$36=$v36)
  duration : ${SECS} s, head does not move
  This burns a spot/hole where the head is now. Put thick scrap (wood block or
  ceramic tile) under the head. Water flowing, extraction on, lid closed, laser
  enabled at the PSU. Watch the mA meter.

EOF
[[ $(ask 'Type FIRE to fire: ') == FIRE ]] || { echo "Cancelled."; exit 0; }

# --- fire -------------------------------------------------------------------
if [[ ${m32%%.*} == 1 ]]; then
  ORIG32=1
  send '$32=0' || die "could not disable laser mode"
fi
FIRING=1
printf 'M3 S%s G4 P%s\nM5\n' "$S" "$SECS" >&3        # M5 is queued before the pulse starts
if wait_ok 2 "$(awk -v t="$SECS" 'BEGIN{print t+5}')"; then
  FIRING=0
  echo "Pulse done."
else
  echo "Pulse did not complete normally." >&2
  exit 1                                             # cleanup sends soft reset
fi
