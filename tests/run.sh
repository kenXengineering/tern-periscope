#!/bin/sh
# Runs every automated test and exits non-zero when one fails. Needs luau, sh and awk.
#
#   tests/*_test.luau   lib/*.luau unit tests, against the fake `tern` in tests/tern_stub.luau
#   tests/*_test.sh     shell tests (agent.awk, scan.sh); run with sh from the repository root

cd "$(dirname "$0")/.." || exit 1
command -v luau >/dev/null || {
	echo "luau not found (https://github.com/luau-lang/luau/releases)" >&2
	exit 1
}
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
status=0

# The luau CLI gives each required module its own globals, so a test cannot set `tern` for
# lib/. The copies the tests load get it as a local on line 1, keeping error line numbers right.
mkdir "$tmp/lib" && cp -R tests "$tmp/tests" || exit 1
for f in lib/*.luau; do
	{
		printf 'local tern = require("../tests/tern_stub").tern '
		cat "$f"
	} >"$tmp/lib/${f##*/}"
done
for t in "$tmp"/tests/*_test.luau; do
	[ -f "$t" ] || continue
	echo "== ${t##*/}"
	(cd "$tmp" && luau "tests/${t##*/}") || status=1
done

for t in tests/*_test.sh; do
	[ -f "$t" ] || continue
	echo "== ${t##*/}"
	sh "$t" || status=1
done

if [ "$status" -eq 0 ]; then echo "all tests passed"; else echo "TESTS FAILED"; fi
exit "$status"
