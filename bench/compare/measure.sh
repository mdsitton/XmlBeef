#!/bin/bash
# Repeating a benchmark cell until its fresh-process runs agree (sourced by run.sh and run-typed.sh).
#
# Each harness already samples one process until its samples converge (60% within ±10% of their
# median, KdlBeef's and TomlBeef's rule). Between processes the figure still moves with the machine's
# load, memory layout and clocks, so a cell is rerun in fresh processes until it settles: at least
# REPEATS runs (default 3), then on until REPEATS of the runs lie within ±TOLERANCE percent (default 5)
# of the runs' median, at most MAX_REPEATS runs (default 9). The cell is the median of all its runs;
# one that never settled is marked `~` (its spread was above the tolerance: noisy, compare with care).
# No quiet machine is assumed: a loaded one takes more runs, not a refusal.

REPEATS="${REPEATS:-3}"
MAX_REPEATS="${MAX_REPEATS:-9}"
TOLERANCE="${TOLERANCE:-5}"

# The median of the values (one per line on stdin)
median() {
	sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

# Whether at least REPEATS of the values (arguments) lie within ±TOLERANCE% of their median
settled() { # values...
	local m
	m=$(printf '%s\n' "$@" | median)
	printf '%s\n' "$@" | awk -v m="$m" -v t="$TOLERANCE" -v need="$REPEATS" '
		{ d = $1 - m; if (d < 0) d = -d; if (m > 0 && d <= m * t / 100) n++ }
		END { exit !(n >= need) }'
}

# Runs the command (a function printing one MB/s figure, or FAIL / DNF / n/a, which end the cell)
# until the runs settle; prints the median, marked `~` when they did not
settle() { # command args...
	local values=() value r
	for ((r = 0; r < MAX_REPEATS; r++)); do
		value=$("$@")
		case "$value" in
		FAIL | DNF | n/a)
			echo "$value"
			return
			;;
		esac
		values+=("$value")
		if ((${#values[@]} >= REPEATS)) && settled "${values[@]}"; then
			printf '%s\n' "${values[@]}" | median
			return
		fi
	done
	echo "$(printf '%s\n' "${values[@]}" | median)~"
}
