#!/usr/bin/env python3
"""Dump raw 16-view outputs (A x8, B x8) for scrambled images -> JSONL."""
import argparse, random, subprocess, tempfile, json
from pathlib import Path
from PIL import Image, ImageOps
ROOT = Path(__file__).resolve().parent.parent; BIN = ROOT / ".build/debug/photos-autorotate"
ap = argparse.ArgumentParser(); ap.add_argument("src"); ap.add_argument("--n", type=int, default=320); ap.add_argument("--seed", type=int, default=7); ap.add_argument("--out", required=True)
a = ap.parse_args()
files = sorted(p for p in Path(a.src).iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
random.seed(a.seed); random.shuffle(files); files = files[: a.n]
work = Path(tempfile.mkdtemp(prefix="raw_")); truth = {}
for i, f in enumerate(files):
    im = ImageOps.exif_transpose(Image.open(f)).convert("RGB"); r = random.choice([0, 90, 180, 270])
    out = work / f"s{i:03d}.jpg"; im.rotate(-r, expand=True).save(out, quality=90); truth[str(out)] = ((360 - r) % 360, f.name)
res = subprocess.run([str(BIN), "classify-file", "--raw", "--model", str(ROOT / "models/OrientationClassifier.mlpackage"), "--model-b", str(ROOT / "models/OrientationClassifierB.mlpackage"), *truth.keys()], capture_output=True, text=True).stdout
n = 0
with open(a.out, "a") as fh:
    for line in res.splitlines():
        if not line.startswith("RAW\t"): continue
        _, path, ra, rb = line.split("\t")
        fh.write(json.dumps({"truth": truth[path][0], "file": truth[path][1], "A": json.loads(ra), "B": json.loads(rb)}) + "\n"); n += 1
import shutil; shutil.rmtree(work, ignore_errors=True)
print("wrote", n)
