#!/bin/sh
# scripts/agent.awk under every installed awk (awk required; gawk, mawk when present):
# each tests/fixtures/awk/*.jsonl must digest to its sibling .expected, and a generated
# transcript with lines of hundreds of KB must digest to the inline expectation below.

cd "$(dirname "$0")/.." || exit 1
command -v awk >/dev/null || {
	echo "awk not found" >&2
	exit 1
}
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
status=0

# check IMPL JSONL EXPECTED: digest JSONL with IMPL and diff it against EXPECTED.
check() {
	if "$1" -f scripts/agent.awk "$2" >"$tmp/out" && diff -u "$3" "$tmp/out"; then
		echo "ok   $1 ${2##*/}"
	else
		echo "FAIL $1 ${2##*/}"
		status=1
	fi
}

# A string of N copies of character C.
repeat() {
	awk -v n="$1" -v c="$2" 'BEGIN { s = c; while (length(s) < n) s = s s; print substr(s, 1, n) }'
}

# Long lines: a 300 KB tool call and a 600 KB tool result, then a normal assistant turn.
ts() { printf '2026-01-01T10:00:0%s.000Z' "$1"; }
{
	echo '{"type":"session_init","agent":"task","task":"Fixture","timestamp":"2026-01-01T09:59:00.000Z"}'
	echo "{\"type\":\"message\",\"id\":\"u1\",\"timestamp\":\"$(ts 1)\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
	echo "{\"type\":\"message\",\"id\":\"a2\",\"timestamp\":\"$(ts 2)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"c1\",\"name\":\"bash\",\"arguments\":{}}],\"stopReason\":\"toolUse\",\"usage\":{\"totalTokens\":10,\"cost\":{\"total\":0.5}}}}"
	echo "{\"type\":\"custom\",\"customType\":\"tool_execution_start\",\"startedAt\":\"$(ts 3)\",\"toolName\":\"bash\",\"args\":{\"command\":\"$(repeat 300000 x)\"}}"
	echo "{\"type\":\"message\",\"id\":\"r4\",\"timestamp\":\"$(ts 4)\",\"message\":{\"role\":\"toolResult\",\"content\":[{\"type\":\"text\",\"text\":\"$(repeat 600000 y)\"}]}}"
	echo "{\"type\":\"message\",\"id\":\"a5\",\"timestamp\":\"$(ts 5)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"stopReason\":\"stop\",\"usage\":{\"totalTokens\":20,\"cost\":{\"total\":0.25}}}}"
} >"$tmp/long.jsonl"
# tool args are cut to 400 chars: {"command":" (12) + 388 x
{
	printf 'stats\t1\t2\t0.750000\t20\t%s\n' "$(ts 1)"
	printf 'e\tm\tuser\t%s\t\n' "$(ts 1)"
	printf 'e\tm\tassistant\t%s\ttoolUse|bash\n' "$(ts 2)"
	printf 'e\tc\ttool_execution_start\t%s\tbash|{"command":"%s\n' "$(ts 3)" "$(repeat 388 x)"
	printf 'e\tm\ttoolResult\t%s\t\n' "$(ts 4)"
	printf 'e\tm\tassistant\t%s\tstop|\n' "$(ts 5)"
} >"$tmp/long.expected"

for impl in awk gawk mawk; do
	command -v "$impl" >/dev/null || {
		echo "skip $impl (not installed)"
		continue
	}
	for f in tests/fixtures/awk/*.jsonl; do
		check "$impl" "$f" "${f%.jsonl}.expected"
	done
	check "$impl" "$tmp/long.jsonl" "$tmp/long.expected"
done
exit "$status"
