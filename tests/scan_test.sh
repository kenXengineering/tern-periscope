#!/bin/sh
# scripts/scan.sh against a session store built in a temp dir, run as the plugin runs it
# (`sh scripts/scan.sh ...`) and under dash when installed: sessions (order, subagent and
# running counts, title cut), sizes, init, agent, size, tail and the usage error.

cd "$(dirname "$0")/.." || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
status=0

# Sets FILE's mtime to MINUTES ago. touch -t takes a calendar stamp, and POSIX date cannot do
# arithmetic, so the epoch is converted to a UTC stamp here (days-to-civil, Hinnant).
ago() {
	stamp=$(awk -v e="$(($(date +%s) - $1 * 60))" 'BEGIN {
		z = int(e / 86400) + 719468; s = e % 86400
		era = int(z / 146097); doe = z - era * 146097
		yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
		doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
		mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
		m = mp < 10 ? mp + 3 : mp - 9; y = yoe + era * 400 + (m <= 2)
		printf "%04d%02d%02d%02d%02d.%02d", y, m, d, int(s / 3600), int(s % 3600 / 60), s % 60
	}')
	TZ=UTC0 touch -t "$stamp" "$2"
}

# A string of N copies of character C.
repeat() {
	awk -v n="$1" -v c="$2" 'BEGIN { s = c; while (length(s) < n) s = s s; print substr(s, 1, n) }'
}

# lines N: N JSON lines; with a second argument K, line K is a session_exit.
lines() {
	i=1
	while [ "$i" -le "$1" ]; do
		if [ "$i" = "${2:-0}" ]; then
			echo '{"type":"custom","customType":"session_exit","recordedAt":"2026-01-01T10:00:00.000Z","kind":"normal"}'
		else
			echo "{\"type\":\"message\",\"id\":\"m$i\",\"message\":{\"role\":\"user\"}}"
		fi
		i=$((i + 1))
	done
}

# --- fixture store ---------------------------------------------------------------------
b=$tmp/bucket
mkdir -p "$b/s1x" "$b/s2" "$b/s3"
title_prefix='{"type":"session","id":"s2","cwd":"/home/u/proj","title":"'
title="$title_prefix$(repeat $((400 - ${#title_prefix})) a)"
printf '%sZ"}\nsecond line\n' "$title" >"$b/s2.jsonl"
lines 3 >"$b/s2/A.jsonl"     # recent, no exit: running
lines 7 3 >"$b/s2/B.jsonl"   # exit is the 5th-last line: ended
lines 7 2 >"$b/s2/D.jsonl"   # exit is the 6th-last line: not seen, running
lines 3 >"$b/s2/C.jsonl"     # 46 min old: not running
ago 46 "$b/s2/C.jsonl"
lines 3 >"$b/s2/E.jsonl"     # 43 min old: running (BSD find rounds age up to whole minutes)
ago 43 "$b/s2/E.jsonl"
lines 3 >"$b/s2/__advisor1.jsonl"
echo note >"$b/s2/notes.txt"
echo '{"type":"session","id":"s1","title":"mid"}' >"$b/s1.jsonl"
lines 3 >"$b/s1x/Q.jsonl"    # belongs to no session file of that name
echo '{"type":"session","id":"s3","title":"old"}' >"$b/s3.jsonl"
lines 3 >"$b/s3/X.jsonl"
TZ=UTC0 touch -t 202601010000 "$b/s3/X.jsonl"
lines 3 >"$b/s3/__advisor.jsonl"
echo readme >"$b/readme.txt"
TZ=UTC0 touch -t 202602010000 "$b/s1.jsonl"
TZ=UTC0 touch -t 202601010000 "$b/s3.jsonl"
touch "$b/s2.jsonl"

sz=$tmp/sizes
mkdir "$sz"
echo hello >"$sz/a.jsonl"
: >"$sz/b.jsonl"
echo x >"$sz/__advisor.jsonl"
echo x >"$sz/c.txt"

in=$tmp/init
mkdir "$in"
{
	echo '{"type":"session_init","task":"first"}'
	echo '{"type":"message","id":"m1"}'
	echo '{"type":"session_init","task":"second"}'
} >"$in/i1.jsonl"
{
	echo '{"type":"message","id":"m1"}'
	echo '{"type":"session_init","task":"late"}'
} >"$in/i2.jsonl"
echo '{"type":"message","text":"{\"type\":\"session_init\"}"}' >"$in/i3.jsonl"

ag=$tmp/agent
mkdir "$ag"
cp tests/fixtures/awk/exit-signal.jsonl tests/fixtures/awk/calls.jsonl "$ag/"

lines 7 >"$tmp/seven"

# --- expectations ------------------------------------------------------------------------
printf 's2.jsonl\t5\t3\t%s\ns1.jsonl\t0\t0\t{"type":"session","id":"s1","title":"mid"}\ns3.jsonl\t1\t0\t{"type":"session","id":"s3","title":"old"}\n' "$title" >"$tmp/exp.sessions"
printf '6\ta.jsonl\n0\tb.jsonl\n' >"$tmp/exp.sizes"
{
	printf '@@\ti1.jsonl\n{"type":"session_init","task":"first"}\n'
	printf '@@\ti2.jsonl\n{"type":"session_init","task":"late"}\n'
	printf '@@\ti3.jsonl\n'
} >"$tmp/exp.init"
{
	printf '@@\tcalls.jsonl\n'
	cat tests/fixtures/awk/calls.expected
	printf '@@\texit-signal.jsonl\n'
	cat tests/fixtures/awk/exit-signal.expected
} >"$tmp/exp.agent"
printf '{"type":"message","id":"m6","message":{"role":"user"}}\n{"type":"message","id":"m7","message":{"role":"user"}}\n' >"$tmp/exp.tail"
echo 'usage: scan.sh sessions|sizes|init|agent|size|tail DIR [NAME...]' >"$tmp/exp.usage"

# --- checks ------------------------------------------------------------------------------
# same LABEL EXPECTED ACTUAL
same() {
	if diff -u "$2" "$3"; then
		echo "ok   $sh $1"
	else
		echo "FAIL $sh $1"
		status=1
	fi
}

# with_now LABEL EXPECTED ARGS...: line 1 must be "now EPOCH" taken during the run, the rest EXPECTED.
with_now() {
	label=$1 exp=$2
	shift 2
	before=$(date +%s)
	"$sh" scripts/scan.sh "$@" >"$tmp/out"
	after=$(date +%s)
	now=$(sed -n '1s/^now \([0-9][0-9]*\)$/\1/p' "$tmp/out")
	if [ -n "$now" ] && [ "$now" -ge "$before" ] && [ "$now" -le "$after" ]; then
		echo "ok   $sh $label: now line"
	else
		echo "FAIL $sh $label: bad now line: $(sed -n 1p "$tmp/out")"
		status=1
	fi
	sed 1d "$tmp/out" >"$tmp/rest"
	same "$label" "$exp" "$tmp/rest"
}

for sh in sh dash; do
	command -v "$sh" >/dev/null || {
		echo "skip $sh (not installed)"
		continue
	}
	with_now "sessions" "$tmp/exp.sessions" sessions "$b" 45
	with_now "sessions, missing bucket" /dev/null sessions "$tmp/nope" 45
	with_now "sizes" "$tmp/exp.sizes" sizes "$sz"

	"$sh" scripts/scan.sh init "$in" i1.jsonl i2.jsonl i3.jsonl >"$tmp/out"
	same "init" "$tmp/exp.init" "$tmp/out"

	"$sh" scripts/scan.sh agent "$ag" calls.jsonl exit-signal.jsonl >"$tmp/out"
	same "agent" "$tmp/exp.agent" "$tmp/out"

	"$sh" scripts/scan.sh size "$sz/a.jsonl" >"$tmp/out"
	echo 6 | same "size" - "$tmp/out"
	"$sh" scripts/scan.sh size "$sz/b.jsonl" >"$tmp/out"
	echo 0 | same "size, empty file" - "$tmp/out"

	"$sh" scripts/scan.sh tail "$tmp/seven" 2 >"$tmp/out"
	same "tail" "$tmp/exp.tail" "$tmp/out"

	"$sh" scripts/scan.sh bogus "$tmp" >"$tmp/out" 2>"$tmp/err"
	code=$?
	if [ "$code" -eq 2 ] && [ ! -s "$tmp/out" ]; then
		echo "ok   $sh unknown subcommand: exit 2"
	else
		echo "FAIL $sh unknown subcommand: exit $code, stdout: $(cat "$tmp/out")"
		status=1
	fi
	same "unknown subcommand: usage" "$tmp/exp.usage" "$tmp/err"
done
exit "$status"
