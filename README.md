# ec-modern-standby-fix

Fixes a class of bug on some Insyde H2O (and possibly other vendor)
laptop firmware where `s2idle`/Modern Standby suspend appears to work at
the OS level — screen blanks, keyboard backlight off — but the EC never
actually cuts real power: the fan keeps running, and the power/power-button
LEDs stay solid instead of indicating real sleep.

The telltale pattern: it works reliably right after booting Windows
(even briefly), and keeps working across subsequent Ubuntu reboots *as
long as AC power is never fully disconnected during a shutdown* — but
breaks again the moment you cold-boot with AC disconnected after a
shutdown. If that's not your exact symptom, this probably isn't your
bug — see [docs/DIAGNOSIS.md](docs/DIAGNOSIS.md) for how to check.

## Background

On the one board this has been diagnosed on so far (Clevo/Tongfang
barebone `L55xJNP_N_Mx`, Insyde H2O firmware), the root cause turned out
to be two bytes in EC RAM that gate whether the embedded controller
actually engages real hardware low-power behavior during suspend.
Windows' driver stack writes these bytes during its own boot; this
board's own firmware never writes them itself unless AC power happens
to already be connected at boot *and* the EC has previously been primed
by Windows (AC alone from a truly blank state does nothing — its role
is retention across a shutdown, not initialization). Disconnect AC
across a shutdown and the values reset to a broken default, requiring
Windows to boot again to restore them.

This was found by directly diffing EC RAM contents between physically-confirmed
working and broken sessions (not by any official documentation — none
appears to be publicly available for this class of firmware), and
confirmed to be causal, not just correlated, by writing the candidate
bytes live to a running broken session and watching suspend immediately
start working with no reboot involved. Full write-up of that specific
investigation (including the ACPI-level detour that turned out to be a
red herring) is in [docs/S0ID-INVESTIGATION.md](docs/S0ID-INVESTIGATION.md).

## What this does

A `systemd-sleep` hook (`ec-modern-standby-fix.sh`) that writes the
known-good EC RAM values immediately before every suspend attempt, on
boards explicitly listed in the script. **It does nothing at all on
unrecognized hardware** — see [Safety](#safety) below.

## Install

```
git clone https://github.com/arbitrary-string/ec-modern-standby-fix.git
cd ec-modern-standby-fix
./install.sh
```

Requires the `ec_sys` kernel module (standard, in-tree on any modern
Linux kernel) and `dd`/`printf` (present on any system already).

To remove: `./uninstall.sh`.

## Is your board supported?

Currently: `L55xJNP_N_Mx` only. Check yours:

```
cat /sys/class/dmi/id/board_name
```

If it's not in `ec-modern-standby-fix.sh`, the installer will warn you
and the hook will safely do nothing on your hardware. **Do not** copy
another board's offsets into your own config — these are undocumented,
vendor-specific EC addresses and the same offset can mean something
completely different on different firmware. Instead, use
[`find-my-values.sh`](find-my-values.sh), a guided helper that automates
the tedious parts of finding your own board's values (collecting
samples, filtering real signal from sensor/counter noise, safely testing
candidates) — see [docs/DIAGNOSIS.md](docs/DIAGNOSIS.md) for the full
walkthrough and the reasoning behind each step. It can't do the physical
part for you (you still have to actually reboot and actually confirm
suspend behavior with your own eyes), but everything else is one
command each:

```
./find-my-values.sh collect broken     # after confirming suspend is broken
./find-my-values.sh collect working    # after confirming suspend works
# repeat each 1-2 more times via fresh independent reboots, then:
./find-my-values.sh analyze
./find-my-values.sh test-candidate 0xNN <hex-bytes>   # confirms causality live, no reboot
```

## Safety

Writing to EC RAM is a real, if generally low-risk, capability — you're
directly manipulating memory that live firmware reads and acts on, with
no official documentation confirming what any given address does. This
project's safety approach:

- The fix only ever activates on a DMI-matched board list, refusing to
  do anything on hardware it doesn't recognize (same philosophy as
  [clevo-acpi-dkms](https://github.com/arbitrary-string/clevo-acpi-dkms),
  applied more conservatively since this writes memory rather than
  loading a curated kernel driver).
- Every value in this repo was derived by diffing real EC RAM dumps
  across physically-confirmed working/broken states, then confirmed
  causal (not just correlated) by a live write-and-test before ever
  being added here — see [docs/DIAGNOSIS.md](docs/DIAGNOSIS.md) for the
  exact methodology, useful if you want to find your own board's values.
- Reading EC RAM (without write support) is always safe and is a
  standard technique used by many hardware monitoring tools.

## License

GPL-2.0-or-later — see [LICENSE](LICENSE).
