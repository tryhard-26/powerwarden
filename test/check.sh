#!/bin/sh
# e2e: burner capped to 25%, must resume after SIGTERM and after SIGKILL+restart
set -e
PW=$1 D=$(mktemp -d)
trap 'kill $B $P 2>/dev/null; rm -rf $D' EXIT
echo 'int main(void){for(volatile unsigned long i=0;;i++);}' | xcrun clang -x c -o $D/pwburn -
printf 'pwburn 25 - stop\n' > $D/c
cs() { ps -o time= -p $B | awk -F: '{print $1*60+$2}'; }
$D/pwburn & B=$!
$PW -c $D/c & P=$!
sleep 8; a=$(cs); sleep 4; b=$(cs)
u=$(echo "($b-$a)/4*100" | bc -l | cut -d. -f1)
echo "cpu ${u}% (budget 25)"
[ "$u" -lt 40 ] || { echo FAIL: not throttled; exit 1; }
kill $P; wait $P || true; sleep 0.3
ps -o state= -p $B | grep -q T && { echo FAIL: left stopped; exit 1; }
$PW -c $D/c & P=$!; sleep 2; kill -9 $P; wait $P 2>/dev/null || true
kill -STOP $B
$PW -c $D/c & P=$!; sleep 0.5
ps -o state= -p $B | grep -q T && { echo FAIL: stale stop kept; exit 1; }
echo ok
