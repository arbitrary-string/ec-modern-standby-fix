# Investigation notes: how this was actually found

This is the story of tracking down the `L55xJNP_N_Mx` values in this
repo, kept in full (including a real dead end) because the methodology
and the ACPI-level findings may be useful to anyone investigating a
similar symptom on different hardware, even though the specific
mechanism documented here (`S0ID`) turned out not to be the actual
cause.

## System

- BIOS: Insyde `InsydeH2O`, version `1.07.03LS1(d)`
- Board: Clevo/Tongfang barebone `L55xJNP_N_Mx`
- Relevant ACPI device: `PEPD` (`\_SB.PEPD`, `_HID: INT33A1`)

## The dead end: `S0ID` and the `PEPD` ACPI device

The board's DSDT exposes a `PEPD` device (`_HID: INT33A1`,
Microsoft-compatible "System Power Management Controller", `_CID:
PNP0D80`) implementing Microsoft's **PEP (Platform Extension Plugin)**
model — the standard mechanism Windows Modern Standby uses to negotiate
power constraints with firmware, which Linux's generic `_DSM`/LPS0
support (`drivers/acpi/x86/s2idle.c`) also speaks, since it's a
documented, OS-agnostic ACPI interface (GUID
`c4eb40a0-6cd2-11e2-bcfd-0800200c9a66`).

`PEPD`'s `_STA` method (every OS checks this before binding to a device
or calling any of its methods) is:

```c
Method (_STA, 0, NotSerialized)
{
    If ((S0ID == One))
    {
        PSOP ()
        Return (0x0F)      // fully present & functioning
    }
    Return (Zero)           // device does not exist
}
```

If the global flag `S0ID` isn't `1`, `PEPD` reports itself as completely
nonexistent, and no OS will ever call any of its `_DSM` functions —
including a second, vendor-specific `_DSM` GUID
(`11e00d56-ce64-47ce-837b-1f898f9aa461`) also present on this device,
whose functions 7/8 ("Modern Standby Entry/Exit") call helper methods
that set an EC flag and notify it of Modern Standby transitions.

`S0ID` itself is an 8-bit field inside `GNVS` (Global NVS), a
`SystemMemory` OperationRegion — i.e. a byte the BIOS/SMM writes
directly into fixed physical memory, not something any ACPI method
sets. Confirmed by grepping every decompiled ACPI table (DSDT + ~50
SSDTs) for any assignment to `S0ID`: zero results. The only place this
value can be set, given nothing in AML writes it, is inside an SMI
(System Management Interrupt) handler — genuinely invisible,
closed-source BIOS code. Found the generic SMI trigger
(`OperationRegion (SPRT, SystemIO, 0xB2, 0x02)`) but all 26 call sites
across the DSDT write the same generic "go process my request" value to
it, with the actual command encoded in a separate parameter register
whose meaning isn't determinable from AML alone.

Early testing suggested a clean pattern: `S0ID = 1` (and suspend
working) after either AC power being connected at boot, or booting
Windows once. Later testing broke this cleanly — `S0ID` was found to
read `1`, and `PEPD` was confirmed bound (visible via a `Duplicate LPS0
_DSM functions` kernel log line), in sessions where suspend was *still*
completely broken. That ruled out `S0ID` as the actual switch: it
controls something upstream and necessary-but-not-sufficient — likely
just whether the ACPI-level Modern Standby notification pathway exists
at all — while something else entirely determines whether the EC really
cuts power.

No fix was attempted at the `S0ID`/SMI level: guessing at undocumented
SMM command parameters is a fundamentally different, much higher risk
category than the documented `_DSM` calls used elsewhere in ACPI, with
no way to know what an incorrect value might do and no OS-level
visibility or recovery if something went wrong.

## The real mechanism: EC RAM, not ACPI

Abandoned the ACPI-level approach and diffed raw EC RAM instead (see
[DIAGNOSIS.md](DIAGNOSIS.md) for the general method). This worked:

- **Offset `0xa0`** (160 decimal): `01 0b 70` in every confirmed-working
  session, `00 00 00` in every confirmed-broken one. Reproducible across
  4 independent samples.
- **Offset `0xeb`** (235 decimal): `e0` in Windows-primed-working
  sessions specifically, `a0` in both broken sessions *and* in an
  AC-connected-working session with no Windows involved — this one
  tracks "did Windows boot this power cycle," not "does suspend work"
  in general, but still turned out to be necessary.

Confirmed causal, not just correlated, by writing both values live (via
`ec_sys` with `write_support=1`) to a running, confirmed-broken session
and testing suspend immediately, no reboot: writing `0xa0` alone had no
effect; writing `0xeb` on top of it fixed suspend immediately.

## The corrected causal model for AC/Windows

The clean-looking early pattern ("AC at boot" or "Windows boot" both
independently produce a working state) doesn't hold up as two
independent triggers. The actual behavior: **only Windows booting
writes these EC RAM bytes from a blank state.** AC power's role is pure
*retention* — the memory holding these bytes is volatile, and needs
continuous power to keep its value. If AC stays connected through a
subsequent shutdown, values Windows already wrote earlier survive into
the next cold boot. Disconnect AC across a shutdown — even once — and
the retention is lost, resetting to the broken default regardless of
prior Windows history.

(The very first test in this investigation, "cold boot with AC
connected works, no Windows involved," was almost certainly not AC
initializing anything — the machine had very likely already been
booted into Windows at some point in its life before testing began, so
that result was retention of an already-good prior state, not fresh
initialization by AC.)

## Why a systemd-sleep hook rather than a boot-time service

Considered writing the fix once at boot instead of before every
suspend. Rejected in favor of the pre-suspend hook: since this relies on
reverse-engineered, undocumented EC behavior with no official
specification, there's no way to be confident nothing else could touch
this memory during a running session. Reapplying immediately before
every suspend is essentially free (a couple of trivial writes to
already-loaded kernel state) and protects against any such
runtime-reset scenario a boot-once fix wouldn't catch.
