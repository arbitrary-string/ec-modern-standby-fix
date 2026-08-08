# Finding your own board's values

**Do not copy another board's offsets/values into your own config.**
These are raw, undocumented EC RAM addresses. The same offset can hold
something completely different — a battery calibration value, a fan
curve parameter, anything — on different EC firmware, even from the
same vendor. Writing a value that was correct on someone else's board
into your own EC RAM could do something unpredictable. Always derive
your own values independently using the methodology below, even if your
symptom looks identical.

## Does this even apply to you?

The symptom this class of bug produces: `systemctl suspend` (or closing
the lid) appears to work — the screen goes black, keyboard backlight (if
present) turns off — but:

- The fan keeps running (if it was already running).
- The power LED and/or power-button LED stay solid on, instead of
  blinking/breathing or turning off to indicate sleep.
- The laptop is still warm/drawing meaningful power a while later.

And critically, the specific pattern that points at *this* mechanism
rather than something else: it works reliably right after booting
Windows (even briefly, even without ever actually sleeping in Windows),
and continues working across subsequent Ubuntu reboots **as long as you
never fully lose AC power during a shutdown** — but breaks again the
first time you cold-boot with AC disconnected after a shutdown.

If your symptom doesn't include that specific "works after Windows,
breaks again after an AC-less cold boot" pattern, this probably isn't
the same bug — don't assume this methodology applies.

## Prerequisites

```
sudo apt install acpica-tools   # for reference; not required for this specific method
sudo modprobe ec_sys            # read-only by default — safe
ls /sys/kernel/debug/ec/ec0/io  # should exist; if not, your EC isn't exposed this way
```

## Method: diff EC RAM across controlled known-good/known-broken states

The core idea: dump the full EC RAM contents (`xxd /sys/kernel/debug/ec/ec0/io`,
typically 256 bytes) in a state you've *physically confirmed* is broken,
and again in a state you've *physically confirmed* is working, then diff
them. Do this several times, varying only one thing at a time, to
separate the real signal from noise (battery/AC telemetry, sensor
readings, and internal counters constantly fluctuate in EC RAM for
reasons unrelated to this bug).

1. **Confirm broken, don't assume it.** Cold boot with AC disconnected,
   actually try to suspend, and visually confirm the fan/LEDs don't
   indicate real sleep before you dump anything. Use `./dump-ec.sh
   broken-1`.

2. **Confirm working, don't assume it.** Boot Windows, then warm-reboot
   back into Ubuntu, actually test suspend, confirm it's physically
   working. Dump: `./dump-ec.sh working-windows-primed-1`.

3. **Diff the pair:**
   ```
   diff dumps/*_broken-1.txt dumps/*_working-windows-primed-1.txt
   ```
   Expect many differences — most are noise (battery voltage/current
   readings, adapter identification strings that only populate when AC
   is actually connected, small counters). Don't chase every byte.

4. **Repeat with a matched-condition pair** to cancel out AC-telemetry
   noise specifically: get into the broken state again, dump
   (`broken-2`), then get into the working state again — importantly, on
   **battery power in both dumps**, so any bytes that merely reflect
   "is AC connected right now" read the same in both and drop out of the
   diff. What's left after this second, cleaner diff is a much stronger
   set of candidates.

5. **Look for qualitative jumps, not fluctuation.** Bytes that
   continuously wobble by small amounts between *any* two dumps
   (including two dumps of the supposedly same state) are very likely
   sensor/counter noise, not a real switch. What you're looking for is a
   *hard* difference — e.g. a run of bytes that's all-zero in every
   broken sample and populated with the same fixed value in every
   working sample. That kind of clean, repeated, all-or-nothing pattern
   is a much stronger candidate than a byte that merely differs.

6. **Reproduce more than once before trusting a candidate.** Get a
   second independent broken dump and a second independent working dump
   (fresh reboots each time, not just re-reading the same session) and
   confirm the candidate byte(s) hold the same values again. A pattern
   seen exactly once could be coincidence.

## Confirming causality (not just correlation) — read this before writing anything

A byte correlating with the working/broken split doesn't prove it's
*causing* the behavior — it could be a downstream symptom of whatever
the real switch is. Before trusting a candidate enough to build a fix
around it:

1. Load `ec_sys` **with write support**: `sudo modprobe ec_sys
   write_support=1`. This is a real, if generally low-risk, capability —
   see "Safety notes" below before doing this.
2. In a **confirmed-broken** session (test suspend first, don't assume),
   write your candidate value directly:
   ```
   printf '\xNN' | sudo dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=<offset> count=1 conv=notrunc
   ```
   (`seek=` is the decimal byte offset; convert from hex if needed, e.g.
   `0xa0` = `160`.)
3. Read it back immediately to confirm the write actually took:
   `sudo xxd -s <offset> -l 16 /sys/kernel/debug/ec/ec0/io`.
4. Test suspend again, in the same session, no reboot. If it starts
   working immediately, that's real evidence of causality — the
   candidate isn't just correlated, changing it live changed the actual
   behavior.

If writing your first candidate doesn't fix it, don't assume you're
wrong — you may just need more than one byte. In the reference case in
this repo, one candidate byte held through a write with no effect; a
second one, written on top of the first, was what actually fixed it.
Go back to your diffs and look for other clean, hard-jump candidates you
may have deprioritized.

## Safety notes

- Reading EC RAM (`ec_sys` without `write_support`) is safe — this is a
  standard, widely-used technique for hardware monitoring tools.
- Writing EC RAM is a different risk category. You are directly
  manipulating memory that live firmware reads and acts on, with no
  validation layer in between, and no official documentation confirming
  what any given address does on your specific board. Realistic worst
  case if something's wrong: the write does nothing, or the system needs
  a hard power-off to recover (which should just leave you back at
  "broken suspend," not somewhere worse) — but this isn't a guarantee,
  it's a reasoned judgment based on what worked on one specific board.
  Only write values you've derived yourself via the diffing method
  above, one byte/short run at a time, and always read back immediately
  to confirm.
- Avoid writing to addresses anywhere near data that looks like battery
  charge/voltage/current values, thermal thresholds, or fan control —
  if your diff turns up a candidate near what looks like that kind of
  data, be extra cautious, or skip it in favor of a cleaner candidate
  elsewhere in the dump.

## Contributing your board

If you work through this and confirm a fix for your own board, please
open a PR adding a new `case` entry to `ec-modern-standby-fix.sh`,
including:

1. `cat /sys/class/dmi/id/board_name` and `board_vendor` for your board.
2. The exact offsets/values you found and confirmed causal.
3. Confirmation you tested per "Confirming causality" above, not just a
   correlated diff.
