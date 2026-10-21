#!/usr/bin/env python3
"""Merge the two self-snapshots taken on a 1x display: <name>.png (layers redrawn at 2x: sharp text, but some
images such as the Osmi mark come out empty) and <name>__full.png (everything, softer text).
Per 8x8 block: where the sharp shot is flat but the full shot has detail (a missing image), the full shot's pixels are used.
Usage: merge_snapshot_2x.py <dir>   (rewrites <name>.png, removes <name>__full.png). Needs numpy and Pillow."""
import sys
from pathlib import Path
import numpy as np
from PIL import Image

B = 8
for full in sorted(Path(sys.argv[1]).glob("*__full.png")):
    sharp = full.with_name(full.name.replace("__full", ""))
    a = np.asarray(Image.open(full).convert("RGBA")).astype(np.float32)
    b = np.asarray(Image.open(sharp).convert("RGBA")).astype(np.float32)
    if a.shape != b.shape:
        print("size mismatch", sharp.name); continue
    h, w = (a.shape[0] // B) * B, (a.shape[1] // B) * B
    def block_std(x):
        g = x[:h, :w, :3].mean(axis=2)
        blk = g.reshape(h // B, B, w // B, B).swapaxes(1, 2).reshape(h // B, w // B, B * B)
        return blk.std(axis=2)
    sa, sb = block_std(a), block_std(b)
    use = (sb < 2.5) & (sa > 6)                      # 銳利版這一塊是平的，完整版有細節 → 圖片不見了
    out = b.copy()
    mask = np.kron(use, np.ones((B, B), dtype=bool))
    out[:h, :w][mask] = a[:h, :w][mask]
    Image.fromarray(out.astype(np.uint8), "RGBA").save(sharp); full.unlink()
    print(f"{sharp.name}: {int(use.sum())} blocks from full shot")
