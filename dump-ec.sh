#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Dumps EC RAM to a timestamped, labeled file for later comparison.
# Read-only — safe to run anytime, does not require write_support.
#
# Usage: ./dump-ec.sh <label>
# Example: ./dump-ec.sh working-ac-connected-coldboot
#
# See docs/DIAGNOSIS.md for the full methodology this is meant to
# support: take dumps in matched pairs of known-good vs known-broken
# states, controlling for one variable at a time, and diff them.

set -euo pipefail

if [ $# -ne 1 ]; then
	echo "usage: $0 <label>" >&2
	exit 1
fi

LABEL="$1"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dumps"
mkdir -p "$OUT_DIR"

sudo modprobe ec_sys

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$OUT_DIR/${TIMESTAMP}_${LABEL}.txt"

sudo xxd /sys/kernel/debug/ec/ec0/io > "$OUT_FILE"
echo "Wrote $OUT_FILE"
echo
echo "Board: $(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
echo "AC online: $(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo unknown)"
