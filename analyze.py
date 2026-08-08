#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Analyzes collected EC RAM samples (xxd dumps) to find offsets that are
stable within each state (broken/working) but differ between them --
the kind of clean, hard-jump signal that's a real candidate, as opposed
to noisy bytes that fluctuate for unrelated reasons (sensor readings,
counters) even within the same nominal state. See find-my-values.sh.
"""
import sys
import glob
import os


def parse_dump(path):
    """Return a dict of {offset: byte_value} for an xxd dump file."""
    data = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or ':' not in line:
                continue
            addr_part, rest = line.split(':', 1)
            try:
                base = int(addr_part, 16)
            except ValueError:
                continue
            hex_part = rest.strip()
            if '  ' in hex_part:
                hex_part = hex_part.split('  ')[0]
            hex_bytes = hex_part.replace(' ', '')
            for i in range(0, len(hex_bytes), 2):
                byte_str = hex_bytes[i:i + 2]
                if len(byte_str) == 2:
                    offset = base + (i // 2)
                    data[offset] = int(byte_str, 16)
    return data


def load_samples(directory):
    samples = []
    for path in sorted(glob.glob(os.path.join(directory, '*.txt'))):
        samples.append(parse_dump(path))
    return samples


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <broken_dir> <working_dir>", file=sys.stderr)
        sys.exit(1)

    broken_dir, working_dir = sys.argv[1], sys.argv[2]
    broken_samples = load_samples(broken_dir)
    working_samples = load_samples(working_dir)

    if len(broken_samples) < 2 or len(working_samples) < 2:
        print("Need at least 2 samples in each state.", file=sys.stderr)
        sys.exit(1)

    all_offsets = set()
    for s in broken_samples + working_samples:
        all_offsets.update(s.keys())

    strong_candidates = []
    weak_candidates = []

    for offset in sorted(all_offsets):
        broken_vals = [s[offset] for s in broken_samples if offset in s]
        working_vals = [s[offset] for s in working_samples if offset in s]
        if not broken_vals or not working_vals:
            continue

        broken_stable = len(set(broken_vals)) == 1
        working_stable = len(set(working_vals)) == 1
        differs = set(broken_vals) != set(working_vals)

        if not differs:
            continue

        if broken_stable and working_stable:
            strong_candidates.append((offset, broken_vals[0], working_vals[0]))
        else:
            weak_candidates.append((offset, sorted(set(broken_vals)), sorted(set(working_vals))))

    print(f"Loaded {len(broken_samples)} broken sample(s), {len(working_samples)} working sample(s).")
    print()

    if strong_candidates:
        print("STRONG CANDIDATES (identical within each state, differs between states):")
        print(f"{'offset (hex)':<14}{'offset (dec)':<14}{'broken':<10}{'working':<10}")
        for offset, bval, wval in strong_candidates:
            print(f"0x{offset:02x}          {offset:<14}0x{bval:02x}      0x{wval:02x}")
        print()
        print("These are worth testing per README.md's 'Confirming causality'")
        print("section: write each candidate's working-state value into a")
        print("confirmed-broken session with test-candidate, and test suspend")
        print("immediately, no reboot. If one alone doesn't fix it, try layering")
        print("more than one candidate together before giving up on this pair.")
    else:
        print("No strong (fully stable) candidates found. Collect more samples")
        print("(especially varying only one thing at a time, e.g. keeping AC")
        print("state constant across a matched pair) to reduce noise.")

    if weak_candidates:
        print()
        print(f"({len(weak_candidates)} other offset(s) differ but fluctuate within at least")
        print(" one state -- likely sensor/counter noise, not real candidates, but")
        print(" listed for reference if the strong candidates above don't pan out:)")
        for offset, bvals, wvals in weak_candidates:
            bstr = ','.join(f'0x{v:02x}' for v in bvals)
            wstr = ','.join(f'0x{v:02x}' for v in wvals)
            print(f"  0x{offset:02x}: broken=[{bstr}] working=[{wstr}]")


if __name__ == '__main__':
    main()
