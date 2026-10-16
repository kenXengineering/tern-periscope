#!/bin/sh
# Cheap, read-only probes of omp's session store for the Periscope plugin. The plugin
# runs this through tern.process.run, off the Luau worker, because Luau has no stat,
# no seek and a 2 s per-call budget.
#
#   scan.sh sessions BUCKET        newest-first main sessions: "TAB name TAB subagent-count TAB running-count TAB title-line"
#   scan.sh sizes DIR              "now EPOCH", then "SIZE TAB NAME" per agent transcript
#   scan.sh init DIR NAME...       per agent: "@@ TAB NAME" + its session_init line
#   scan.sh agent DIR NAME...      per agent: "@@ TAB NAME" + agent.awk's digest
#   scan.sh size FILE              the file's size in bytes
#   scan.sh tail FILE N            the file's last N lines
#
# Needs only POSIX sh, awk, grep, head, ls, wc, tail, date, cut, tr, find.

here=$(cd "$(dirname "$0")" && pwd)
cmd=$1
dir=$2
shift 2

case "$cmd" in
sessions)
	now=$(date +%s)
	echo "now $now"
	# ls -t sorts by mtime: the session written last is first.
	ls -t "$dir" 2>/dev/null | while IFS= read -r name; do
		case "$name" in
		*.jsonl)
			# subagent transcripts live in the directory named like the session
			n=0
			for f in "$dir/${name%.jsonl}"/*.jsonl; do
				[ -f "$f" ] || continue
				case "${f##*/}" in
				__advisor*) ;;
				*) n=$((n + 1)) ;;
				esac
			done
			# running = written in the last 45 min (STALE_MS in lib/agents.luau) and no session_exit at the end
			r=0
			if [ "$n" -gt 0 ]; then
				r=$(find "$dir/${name%.jsonl}" -maxdepth 1 -name '*.jsonl' ! -name '__advisor*' -mmin -45 2>/dev/null |
					while IFS= read -r f; do tail -n 5 "$f" | grep -q session_exit || echo x; done | wc -l | tr -d ' ')
			fi
			printf '%s\t%s\t%s\t%s\n' "$name" "$n" "$r" "$(head -n 1 "$dir/$name" | cut -c1-400)"
			;;
		esac
	done | head -n 50
	;;
sizes)
	echo "now $(date +%s)"
	for f in "$dir"/*.jsonl; do
		[ -f "$f" ] || continue
		name=${f##*/}
		case "$name" in
		__advisor*) continue ;;
		esac
		printf '%s\t%s\n' "$(wc -c <"$f" | tr -d ' ')" "$name"
	done
	;;
init)
	for name in "$@"; do
		printf '@@\t%s\n' "$name"
		grep -m 1 '^{"type":"session_init"' "$dir/$name"
	done
	;;
size)
	# DIR is a file here.
	wc -c <"$dir" | tr -d ' '
	;;
tail)
	# DIR is a file; the first argument is how many lines.
	tail -n "${1:-400}" "$dir"
	;;
agent)
	for name in "$@"; do
		printf '@@\t%s\n' "$name"
		awk -f "$here/agent.awk" "$dir/$name"
	done
	;;
*)
	echo "usage: scan.sh sessions|sizes|init|agent|size|tail DIR [NAME...]" >&2
	exit 2
	;;
esac
