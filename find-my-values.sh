#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# find-my-values.sh — guided helper for finding your own board's EC RAM
# values, per docs/DIAGNOSIS.md. Automates the mechanical parts
# (collecting samples, analyzing them for real signal vs noise, safely
# writing/reading back candidates) -- it can't do the physical part for
# you: you still have to actually reboot, actually test suspend, and
# actually confirm with your own eyes whether the fan/LEDs indicate
# real sleep before collecting each sample.
#
# Usage:
#   ./find-my-values.sh collect broken|working
#   ./find-my-values.sh status
#   ./find-my-values.sh analyze
#   ./find-my-values.sh test-candidate <offset hex, e.g. 0xa0> <hex bytes, e.g. 010b70>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLES_DIR="$SCRIPT_DIR/samples"

usage() {
	cat <<'EOF'
Usage:
  ./find-my-values.sh collect broken|working
  ./find-my-values.sh status
  ./find-my-values.sh analyze
  ./find-my-values.sh test-candidate <offset hex> <hex bytes>

Workflow:
  1. Cold boot with AC disconnected. Actually TEST suspend and visually
     confirm the fan/LEDs don't indicate real sleep -- don't assume.
     Then:  ./find-my-values.sh collect broken

  2. Get into a known-working state (e.g. boot Windows, then warm-reboot
     into Ubuntu). Actually TEST suspend and confirm it's really working.
     Then:  ./find-my-values.sh collect working

  3. Repeat steps 1-2 at least twice each, via fresh independent reboots
     each time (not just re-running collect in the same session). More
     independent samples = more confidence, and rules out one-off
     coincidences.

  4. ./find-my-values.sh analyze
     Prints candidate byte offsets, ranked by how clean the signal is.

  5. For each strong candidate (starting with the cleanest), reproduce
     the broken state again, then:
       ./find-my-values.sh test-candidate 0xNN <hex-bytes-from-working-state>
     and test suspend immediately, no reboot. If one candidate alone
     doesn't fix it, keep it applied and layer the next candidate on
     top before testing again.

See README.md and docs/DIAGNOSIS.md for the full background and safety
notes before writing anything.
EOF
}

cmd_collect() {
	local state="${1:-}"
	if [ "$state" != broken ] && [ "$state" != working ]; then
		usage
		exit 1
	fi

	echo "About to save an EC RAM sample labeled '$state'."
	echo "Make sure you have ALREADY physically tested suspend and confirmed"
	echo "it is really $state (fan/LED behavior), not just assumed."
	read -r -p "Continue? [y/N] " REPLY
	case "$REPLY" in
		[Yy]*) ;;
		*) exit 1 ;;
	esac

	mkdir -p "$SAMPLES_DIR/$state"
	sudo modprobe ec_sys
	local ts out n
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	out="$SAMPLES_DIR/$state/${ts}.txt"
	sudo xxd /sys/kernel/debug/ec/ec0/io > "$out"
	echo "Saved: $out"
	n="$(find "$SAMPLES_DIR/$state" -name '*.txt' | wc -l)"
	echo "You now have $n sample(s) in state '$state'."
	if [ "$n" -lt 2 ]; then
		echo "Collect at least one more, from a fresh independent reboot, before analyzing."
	fi
}

cmd_status() {
	local state n
	for state in broken working; do
		n=0
		[ -d "$SAMPLES_DIR/$state" ] && n="$(find "$SAMPLES_DIR/$state" -name '*.txt' 2>/dev/null | wc -l)"
		echo "$state: $n sample(s)"
	done
}

cmd_analyze() {
	local nb nw
	nb=0; nw=0
	[ -d "$SAMPLES_DIR/broken" ] && nb="$(find "$SAMPLES_DIR/broken" -name '*.txt' | wc -l)"
	[ -d "$SAMPLES_DIR/working" ] && nw="$(find "$SAMPLES_DIR/working" -name '*.txt' | wc -l)"
	if [ "$nb" -lt 2 ] || [ "$nw" -lt 2 ]; then
		echo "Need at least 2 samples in each state (have broken=$nb working=$nw)." >&2
		echo "Run 'collect broken' / 'collect working' more, from fresh independent reboots." >&2
		exit 1
	fi

	if ! command -v python3 >/dev/null; then
		echo "python3 is required for analysis but wasn't found." >&2
		exit 1
	fi

	python3 "$SCRIPT_DIR/analyze.py" "$SAMPLES_DIR/broken" "$SAMPLES_DIR/working"
}

cmd_test_candidate() {
	local offset_arg="${1:-}"
	local hex_value="${2:-}"
	if [ -z "$offset_arg" ] || [ -z "$hex_value" ]; then
		usage
		exit 1
	fi
	if [ $(( ${#hex_value} % 2 )) -ne 0 ]; then
		echo "hex value must have an even number of hex digits (one pair per byte)" >&2
		exit 1
	fi

	local offset=$(( offset_arg ))
	local count=$(( ${#hex_value} / 2 ))

	echo "About to write $count byte(s) ('$hex_value') to EC RAM offset $offset_arg ($offset decimal)."
	echo "Make sure you are CURRENTLY in a confirmed-broken suspend session."
	echo "See docs/DIAGNOSIS.md 'Safety notes' before continuing if you haven't already."
	read -r -p "Proceed? [y/N] " REPLY
	case "$REPLY" in
		[Yy]*) ;;
		*) exit 1 ;;
	esac

	sudo modprobe ec_sys write_support=1
	if [ "$(cat /sys/module/ec_sys/parameters/write_support)" != "Y" ]; then
		echo "FATAL: can't enable ec_sys kernel module write support"
		exit 1
	fi

	echo "Before:"
	sudo xxd -s "$offset" -l 16 /sys/kernel/debug/ec/ec0/io

	local printf_bytes="" i
	for (( i = 0; i < ${#hex_value}; i += 2 )); do
		printf_bytes="${printf_bytes}\\x${hex_value:$i:2}"
	done

	# shellcheck disable=SC2059
	printf "$printf_bytes" | sudo dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek="$offset" count="$count" conv=notrunc 2>/dev/null

	echo "After:"
	sudo xxd -s "$offset" -l 16 /sys/kernel/debug/ec/ec0/io
	echo
	echo "Now test suspend. If it works, this candidate is confirmed causal."
	echo "If not, it may need to be combined with another candidate -- try"
	echo "writing the next one on top without undoing this one first."
}

case "${1:-}" in
	collect) cmd_collect "${2:-}" ;;
	status) cmd_status ;;
	analyze) cmd_analyze ;;
	test-candidate) cmd_test_candidate "${2:-}" "${3:-}" ;;
	*) usage; exit 1 ;;
esac
