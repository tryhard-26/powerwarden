#!/bin/sh
# e2e: rule parse, stop cap (1 + 2 procs), bg on/release, dry run, resume on TERM and KILL+restart
set -e
PW=$1 D=$(mktemp -d) B= B2= P=
trap 'kill $B $B2 $P 2>/dev/null; rm -rf $D' EXIT
fail() { echo "FAIL: $*"; exit 1; }
echo 'int main(void){for(volatile unsigned long i=0;;i++);}' | xcrun clang -x c -o $D/pwburn -
cs() { ps -o time= -p "$@" | awk -F: '{s+=$1*60+$2} END {print s}'; }
st() { ps -o state= -p $B; }
pri() { ps -o pri= -p $B | tr -d ' '; }
run() { $PW "$@" -c $D/c & P=$!; }
stop_pw() { kill $P; wait $P || true; sleep 0.3; }
pct() { a=$(cs "$@"); sleep 4; b=$(cs "$@"); echo "($b-$a)*25" | bc -l | cut -d. -f1; }

rej() {
	printf '%s\n' "$1" > $D/c; shift
	$PW "$@" -c $D/c 2>/dev/null & P=$!
	i=0; while kill -0 $P 2>/dev/null && [ $((i+=1)) -le 50 ]; do sleep 0.2; done # 1st exec after codesign can stall
	kill -0 $P 2>/dev/null && fail "accepted rule/flags"
	rc=0; wait $P || rc=$?; [ $rc = 2 ] || fail "exit $rc, want 2"
}
rej 'x abc - stop'; rej 'x 10 - zap'; rej 'x - - stop'; rej 'x 10 - stop junk'
rej 'x -5 - stop'; rej '"" 10 - stop'; rej '"x 10 - stop'; rej 'x 10 - stop' -H 0
echo "parse: ok"

printf 'pwburn 25 - stop\n' > $D/c
$D/pwburn & B=$!
run; sleep 4; u=$(pct $B)
echo "stop 1 proc: ${u}% (budget 25)"
[ "$u" -ge 15 ] && [ "$u" -le 32 ] || fail "stop cap"
stop_pw; st | grep -q T && fail "left stopped after TERM"

printf 'pwburn 50 - stop\n' > $D/c
$D/pwburn & B2=$!
run; sleep 4; u=$(pct $B $B2)
echo "stop 2 procs: ${u}% (budget 50 total)"
[ "$u" -ge 35 ] && [ "$u" -le 62 ] || fail "group cap"
stop_pw; kill $B2; wait $B2 2>/dev/null || true; B2=

run; sleep 2; kill -9 $P; wait $P 2>/dev/null || true
kill -STOP $B; run; sleep 0.5
st | grep -q T && fail "stale SIGSTOP kept after restart"
stop_pw; echo "kill -9 recovery: ok"

kill -STOP $B; run -n; sleep 1.5; stop_pw
st | grep -q T || fail "dry run touched proc"
kill -CONT $B; echo "dry run: ok"

printf 'pwburn 50 - bg\n' > $D/c
run -H 2; sleep 2.5
[ "$(pri)" = 4 ] || fail "bg not applied, pri $(pri)"
kill -STOP $B; sleep 3.5
[ "$(pri)" != 4 ] || fail "bg not released when calm"
kill -CONT $B; sleep 2.5
[ "$(pri)" = 4 ] || fail "bg not reapplied"
stop_pw
[ "$(pri)" != 4 ] || fail "bg left on after TERM"
echo "bg: ok"
echo ok
