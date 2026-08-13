#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
KNOWN_BOARDS=(
    "L55xJNP_N_Mx"
    "X56xWNx"
)

echo "Detected board: $BOARD"
echo

SUPPORTED=0
for b in "${KNOWN_BOARDS[@]}"; do
	[ "$b" = "$BOARD" ] && SUPPORTED=1
done

if [ "$SUPPORTED" = 1 ]; then
	echo "This board is in the known-supported list."
else
	echo "WARNING: '$BOARD' is not in the known-supported board list ($KNOWN_BOARDS)."
	echo "The hook will still install, but it only ever writes EC RAM for boards"
	echo "explicitly listed in ec-modern-standby-fix.sh — it will do nothing at all"
	echo "on unrecognized hardware like yours, so installing it now is safe but"
	echo "won't fix anything by itself."
	echo
	echo "If you have the same symptom (suspend 'succeeds' but fan/LEDs never"
	echo "indicate real sleep), see docs/DIAGNOSIS.md for how to find your own"
	echo "board's offsets/values and contribute them back."
	echo
	read -r -p "Install anyway? [y/N] " REPLY
	case "$REPLY" in
		[Yy]*) ;;
		*) exit 1 ;;
	esac
fi

sudo install -m 0755 "$SCRIPT_DIR/ec-modern-standby-fix.sh" /usr/lib/systemd/system-sleep/ec-modern-standby-fix.sh
echo
echo "Installed to /usr/lib/systemd/system-sleep/ec-modern-standby-fix.sh"
echo "Will apply automatically before every suspend, on supported boards only."
echo "Run ./uninstall.sh to remove."
