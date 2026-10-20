#!/usr/bin/env python3
"""Merge the two self-snapshots taken on a 1x display: <name>.png (layers redrawn at 2x: sharp text, but some
images come out empty) and <name>__full.png (everything, softer text). Regions where the two differ and the sharp
shot is flat (an image went missing) are copied from the full shot. Usage: merge_snapshot_2x.py <dir>
(rewrites <name>.png, removes <name>__full.png). Needs numpy and scipy."""
import sys
from pathlib import Path
import numpy as np
from PIL import Image
from scipy import ndimage

for full in sorted(Path(sys.argv[1]).glob("*__full.png")):
    sharp = full.with_name(full.name.replace("__full", ""))
    a = np.asarray(Image.open(full).convert("RGBA")).astype(np.int16)
    b = np.asarray(Image.open(sharp).convert("RGBA")).astype(np.int16)
    if a.shape != b.shape:
        print("size mismatch", sharp.name); continue
    diff = np.abs(a[..., :3] - b[..., :3]).max(axis=2) > 24
    lab, n = ndimage.label(ndimage.binary_dilation(diff, iterations=6))
    out = b.copy(); used = 0
    for i, sl in enumerate(ndimage.find_objects(lab), 1):
        if sl is None: continue
        y0, y1 = max(sl[0].start - 4, 0), sl[0].stop + 4
        x0, x1 = max(sl[1].start - 4, 0), sl[1].stop + 4
        rb = b[y0:y1, x0:x1, :3]
        flat = (np.abs(rb - np.median(rb.reshape(-1, 3), axis=0)).max(axis=2) < 6).mean()
        if flat > 0.97:                              # 銳利版這一塊幾乎是空的 → 圖片不見了，用完整版
            out[y0:y1, x0:x1] = a[y0:y1, x0:x1]; used += 1
    Image.fromarray(out.astype(np.uint8), "RGBA").save(sharp); full.unlink()
    print(f"{sharp.name}: {used}/{n} regions from full shot")
