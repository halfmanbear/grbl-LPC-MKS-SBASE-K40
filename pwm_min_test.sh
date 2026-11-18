#!/usr/bin/env bash
# pwm_min_test.sh - find the lowest PWM duty that fires the K40 tube, to choose $35.
#
# Homes ($H), moves to START_X/START_Y (machine coordinates, rear-left = 0,0), then burns a
# ladder of short lines at rising S values: each line runs +X (right), the next one is GAP mm
# further in +Y (toward the front).
# $35 is set to 0 for the test so duty is exactly S / $30 * $36, and restored afterwards.
#
# Usage:   ./pwm_min_test.sh
# Options (environment variables):
#   PORT=/dev/ttyACM0  S_START=10  S_END=300  S_STEP=10
#   LEN=15 (mm line length)  GAP=2 (mm between lines)  FEED=600 (mm/min)
#   PAUSE=1 (wait for Enter before each line, so you can read the mA meter; 0 = run straight through)
#   START_X=150 START_Y=80 (mm, pattern's rear-left corner; default is mid-bed)
#   HOMING=1 (home before moving; 0 = skip homing, machine must already be homed)
#
# Ctrl-C at any time sends a Grbl soft reset (laser off, motion stops) and restores $35.

set -u
PORT=${PORT:-/dev/ttyACM0}
S_START=${S_START:-10}; S_END=${S_END:-300}; S_STEP=${S_STEP:-10}
LEN=${LEN:-15}; GAP=${GAP:-2}; FEED=${FEED:-600}; PAUSE=${PAUSE:-1}
START_X=${START_X:-150}; START_Y=${START_Y:-80}; HOMING=${HOMING:-1}

FIRING=0; ORIG35=""; OPEN=0

die() { echo "ERROR: $*" >&2; exit 1; }
ask() { local a=""; read -r -p "$1" a </dev/tty; printf '%s' "$a"; }

# --- serial helpers ---------------------------------------------------------
drain() { local l; while IFS= read -r -t "${1:-0.3}" l <&3; do :; done; }

# Send one line; collect replies until ok/error/ALARM. Replies (minus "ok") go to $REPLY_LINES.
send() {
  local l; REPLY_LINES=""
  printf '%s\n' "$1" >&3
  while IFS= read -r -t 60 l <&3; do
    l=${l%$'\r'}
    case "$l" in
      ok)        return 0 ;;
      error*)    echo "  Grbl: $l  (after: $1)" >&2; return 1 ;;
      ALARM*)    echo "  Grbl: $l  (after: $1)" >&2; return 1 ;;
      '')        ;;
      *)         REPLY_LINES+="$l"$'\n' ;;
    esac
  done
  echo "  No reply from Grbl (after: $1)" >&2; return 1
}

status() {
  local l; printf '?' >&3
  while IFS= read -r -t 2 l <&3; do
    l=${l%$'\r'}; [[ $l == \<* ]] && { printf '%s' "$l"; return 0; }
  done; return 1
}

declare -A SET
read_settings() {
  send '$$' || die "could not read settings"
  local k v
  while IFS='=' read -r k v; do [[ $k == \$* ]] && SET[${k#\$}]=$v; done <<<"$REPLY_LINES"
}

cleanup() {
  trap - INT TERM HUP EXIT
  trap '' INT HUP              # finish the restore even if Ctrl-C is pressed again or the terminal closes
  [[ $OPEN == 1 ]] || exit
  if [[ $FIRING == 1 ]]; then
    printf '\x18' >&3          # soft reset: laser off, motion stops immediately
    echo; echo "Stopped (soft reset). Position may be lost: re-home with \$H before the next job."
    sleep 1.5; drain 0.5
  fi
  send 'M5' >/dev/null 2>&1
  if [[ -n $ORIG35 ]]; then
    local t k v ok=0
    for t in 1 2 3; do              # retry and verify: a reset can leave stray replies in the buffer
      drain 0.3
      send "\$35=$ORIG35" >/dev/null 2>&1
      SET[35]=""
      if send '$$' 2>/dev/null; then
        while IFS='=' read -r k v; do [[ $k == '$35' ]] && SET[35]=$v; done <<<"$REPLY_LINES"
      fi
      awk -v a="${SET[35]:-x}" -v b="$ORIG35" 'BEGIN{exit !(a+0 == b+0 && a != "x")}' && { ok=1; break; }
      sleep 0.5
    done
    if [[ $ok == 1 ]]; then echo "Restored \$35=$ORIG35"
    else echo "WARNING: could not confirm \$35 was restored. Send \$35=$ORIG35 manually." >&2; fi
  fi
  exec 3<&- 3>&-
}

# --- setup ------------------------------------------------------------------
[[ -e $PORT ]] || die "$PORT not found"
fuser -s "$PORT" 2>/dev/null && die "$PORT is in use (close LaserGRBL/LightBurn/picocom first)"
stty -F "$PORT" 115200 cs8 -cstopb -parenb raw -echo -hupcl || die "stty failed"
exec 3<>"$PORT"; OPEN=1
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
drain 1.5                       # discard any start-up banner

st=""; for _ in 1 2 3; do st=$(status) && break; drain 1; done
[[ -n $st ]] || die "no status reply from Grbl"
echo "Status: $st"
[[ $st == "<Idle"* || $st == "<Alarm"* ]] || die "Grbl must be Idle or Alarm (not running a job)"
[[ $HOMING == 1 || $st == "<Idle"* ]] || die "Grbl is in Alarm; run with HOMING=1 or home first"

read_settings
[[ ${SET[32]%%.*} == 1 ]] || die "\$32 laser mode is off. M3 would fire while stationary; refusing to run."
awk -v v="${SET[34]}" 'BEGIN{exit !(v+0 == 0)}' || die "\$34 (PWM off) is ${SET[34]}; set \$34=0 first."
SMAX=${SET[30]}; DMAX=${SET[36]}; ORIG35_SAVE=${SET[35]}
awk -v v="$ORIG35_SAVE" 'BEGIN{exit !(v+0 > 0)}' || die "\$35 is ${SET[35]}, probably left over from an interrupted test. Set \$35 to its working value (e.g. \$35=21) first."

duty() { awk -v s="$1" -v smax="$SMAX" -v dmax="$DMAX" 'BEGIN{printf "%.2f", s/smax*dmax}'; }

(( S_STEP > 0 && S_START > 0 && S_END <= ${SMAX%%.*} )) || die "bad S range (need S_STEP>0, S_START>0, S_END<=\$30)"
N=$(( (S_END - S_START) / S_STEP + 1 ))
(( N > 0 )) || die "bad S range"

# Check the pattern fits inside soft limits ($130/$131) from the start position.
awk -v x="$START_X" -v y="$START_Y" -v len="$LEN" -v ext="$(( N * GAP ))" -v xm="${SET[130]}" -v ym="${SET[131]}" 'BEGIN{
  if (x<0 || y<0 || x+len>xm || y+ext>ym) {
    printf "Pattern would leave the work area: X%s-%s Y%s-%s (limits 0-%s x 0-%s).\n", x, x+len, y, y+ext, xm, ym
    exit 1 } }' || die "change START_X/START_Y or shrink LEN/GAP/S range"

# --- home and move to the start position --------------------------------------
echo
if [[ $HOMING == 1 ]]; then
  echo "Next: home (\$H, rear-left), then move to X$START_X Y$START_Y. Laser stays off."
else
  echo "Next: move to X$START_X Y$START_Y (no homing). Laser stays off."
fi
[[ $(ask 'Bed clear and head free to move? [y/N] ') == [yY]* ]] || { echo "Cancelled."; exit 0; }
FIRING=1                                   # Ctrl-C during motion -> soft reset
if [[ $HOMING == 1 ]]; then
  echo "Homing..."
  send '$H' || die "homing failed"
fi
send "G21 G90 G53 G0 X$START_X Y$START_Y" || exit 1
send 'G4 P0.01' || exit 1                  # wait until the move has finished
FIRING=0
st=$(status) && echo "At: $st"

cat <<EOF

PWM minimum test
  S values   : $S_START to $S_END step $S_STEP  ($N lines)
  duty range : $(duty "$S_START")% to $(duty "$S_END")%   (\$30=$SMAX, \$36=$DMAX%, \$35 temporarily 0)
  pattern    : ${LEN} mm lines in +X (right), ${GAP} mm apart in +Y (toward front),
               about ${LEN} x $(( N * GAP )) mm, rear-left corner at X$START_X Y$START_Y
  feed       : $FEED mm/min, M3 constant power

Before continuing:
  - scrap material (card or plywood, about 40 x 80 mm) under the head, focused
  - water flowing, extraction and air assist on, lid closed
  - laser enabled at the PSU, hand near the emergency stop
Watch the mA meter on each line. Ctrl-C stops everything at once.

EOF
[[ $(ask 'Type FIRE to start: ') == FIRE ]] || { echo "Cancelled."; exit 0; }

# --- test -------------------------------------------------------------------
send '$35=0' || die "could not set \$35=0"
ORIG35=$ORIG35_SAVE
send 'G21 G91' || exit 1
send 'M3 S0'   || exit 1          # laser mode: no output until a G1 move with power

FIRING=1
i=0
for (( s=S_START; s<=S_END; s+=S_STEP )); do
  i=$((i+1))
  if [[ $PAUSE == 1 ]]; then
    r=$(ask "Line $i/$N  S=$s  duty=$(duty "$s")%  - Enter to fire, q to stop: ")
    [[ $r == q* ]] && break
  else
    echo "Line $i/$N  S=$s  duty=$(duty "$s")%"
  fi
  send "G1 X$LEN S$s F$FEED" || exit 1
  send "G0 X-$LEN Y$GAP"     || exit 1
  send 'G4 P0.01'            || exit 1   # wait until the motion has finished
done
send 'M5'; send 'G90'
FIRING=0
echo
echo "Pattern done. Lines run from S=$S_START (first, rear) toward the front."

# --- result -----------------------------------------------------------------
low=$(ask 'Lowest S that marked reliably (Enter to skip): ')
if [[ $low =~ ^[0-9]+$ ]]; then
  d=$(duty "$low")
  sug=$(awk -v d="$d" 'BEGIN{v=int(d)-1; if (v<0) v=0; print v}')
  echo "S=$low is ${d}% duty. Suggested \$35=$sug (just below the firing threshold)."
  r=$(ask "Set \$35=$sug now? [y/N] ")
  if [[ $r == [yY]* ]]; then
    send "\$35=$sug" && { echo "Set \$35=$sug"; ORIG35=""; }
  fi
fi
