#!/usr/bin/env python3
"""Pixel diff of two screenshot folders (Python standard library only).

Usage: ios-gate-pixdiff.py <previous-dir> <current-dir> [threshold-percent]

For every PNG in <current-dir>, compares it with the PNG of the same name in
<previous-dir> and prints the share of pixels that differ (any channel by
more than a small tolerance). Images whose share is above the threshold
(default 2.0 %), or whose size changed, are marked CHANGED; images new in
this build or missing from it are listed too. Exit status: 0 when nothing is
above the threshold, 1 otherwise (the caller decides what that means).
"""
import os
import struct
import sys
import zlib

TOLERANCE = 8  # per channel, out of 255: ignores antialiasing noise


def read_png(path):
    """(width, height, channels, rows) for 8-bit, non-interlaced PNGs."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, palette = 8, [], None
    width = height = depth = ctype = interlace = None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"PLTE":
            palette = chunk
        elif kind == b"IDAT":
            idat.append(chunk)
        elif kind == b"IEND":
            break
    if depth != 8 or interlace:
        raise ValueError(f"unsupported PNG (bit depth {depth}, interlace {interlace})")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(height):
        ftype = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if ftype == 1:
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 255
        elif ftype == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif ftype == 3:
            for x in range(stride):
                left = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 255
        elif ftype == 4:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = prev[x]
                c = prev[x - channels] if x >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
        rows.append(bytes(line))
        prev = line
    if ctype == 3:  # palette: expand to RGB
        rows = [b"".join(palette[v * 3:v * 3 + 3] for v in r) for r in rows]
        channels = 3
    return width, height, channels, rows


def diff_share(a, b):
    wa, ha, ca, ra = a
    wb, hb, cb, rb = b
    if (wa, ha) != (wb, hb):
        return None
    n = min(ca, cb, 3)  # colour channels only
    differing = 0
    for y in range(ha):
        la, lb = ra[y], rb[y]
        if la == lb:
            continue
        for x in range(wa):
            pa, pb = x * ca, x * cb
            for c in range(n):
                if abs(la[pa + c] - lb[pb + c]) > TOLERANCE:
                    differing += 1
                    break
    return 100.0 * differing / (wa * ha)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    prev_dir, cur_dir = sys.argv[1], sys.argv[2]
    threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
    cur = sorted(f for f in os.listdir(cur_dir) if f.endswith(".png"))
    prev = set(f for f in os.listdir(prev_dir) if f.endswith(".png"))
    surprising = 0
    for name in cur:
        if name not in prev:
            print(f"  NEW        {name} (no image of that name in the previous build)")
            continue
        try:
            share = diff_share(read_png(os.path.join(prev_dir, name)), read_png(os.path.join(cur_dir, name)))
        except ValueError as e:
            print(f"  UNREADABLE {name}: {e}")
            surprising += 1
            continue
        if share is None:
            print(f"  CHANGED    {name}: size changed")
            surprising += 1
        elif share > threshold:
            print(f"  CHANGED    {name}: {share:.2f}% of pixels differ (threshold {threshold}%)")
            surprising += 1
        elif share > 0:
            print(f"  same       {name}: {share:.2f}% of pixels differ")
        else:
            print(f"  same       {name}: identical")
    for name in sorted(prev - set(cur)):
        print(f"  MISSING    {name} (in the previous build, not this one)")
    print(f"  {surprising} image(s) above {threshold}% of {len(cur)} compared")
    return 1 if surprising else 0


if __name__ == "__main__":
    sys.exit(main())
