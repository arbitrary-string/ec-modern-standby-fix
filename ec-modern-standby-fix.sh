#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# EC Modern Standby Fix — systemd-sleep hook
#
# Works around firmware (seen on Insyde H2O, possibly others) where
# specific EC RAM bytes governing whether s2idle/Modern Standby actually
# cuts real hardware power are only ever written by Windows booting, and
# are volatile — retained across a shutdown only if AC power stays
# connected the whole time, resetting to a "broken" default on any cold
# boot without AC that hasn't had Windows boot since the last time that
# retention was lost.
#
# Symptom this fixes: `systemctl suspend` (s2idle) appears to succeed at
# the OS level — screen blanks, keyboard backlight off — but the fan
# keeps running and the power/power-button LEDs stay solid instead of
# indicating real sleep, because the EC itself never actually cuts power.
#
# See README.md for the full diagnosis writeup, and docs/DIAGNOSIS.md for
# how to find your own board's offsets/values if it isn't listed below —
# these are raw, undocumented EC RAM addresses with vendor- and
# firmware-specific meaning. The same offset can mean something
# completely different on different EC firmware, so this script refuses
# to write anything at all on a board it doesn't explicitly recognize.

set -eu

case "${1:-}" in
	pre) ;;
	*) exit 0 ;;
esac

BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"

# Each case below is: modprobe ec_sys with write support, then write the
# known-good byte sequence(s) for that exact board. Add your own board
# here only after independently confirming your own offsets/values per
# docs/DIAGNOSIS.md — do not copy another board's values.
case "$BOARD" in
	L55xJNP_N_Mx | X56xWNx)
		modprobe ec_sys write_support=1
		printf '\x01\x0b\x70' | dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=160 count=3 conv=notrunc 2>/dev/null
		printf '\xe0'         | dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=235 count=1 conv=notrunc 2>/dev/null
		;;
	*)
		# Unrecognized board: do nothing. See docs/DIAGNOSIS.md to add yours.
		;;
esac
