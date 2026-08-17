#!/usr/bin/env python3
"""Offline A+B ensemble analysis. Writes per-item records (truth, A, B) to a
JSONL so rules can be evaluated without re-running inference."""
import argparse, random, re, subprocess, tempfile, json
from pathlib import Path
from PIL import Image, ImageOps
ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug/photos-autorotate"
ap = argparse.ArgumentParser(); ap.add_argument("src"); ap.add_argument("--n", type=int, default=320); ap.add_argument("--seed", type=int, default=7); ap.add_argument("--out", required=True)
a = ap.parse_args()
files = sorted(p for p in Path(a.src).iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
random.seed(a.seed); random.shuffle(files); files = files[: a.n]
work = Path(tempfile.mkdtemp(prefix="ens_")); truth = {}
for i, f in enumerate(files):
    im = ImageOps.exif_transpose(Image.open(f)).convert("RGB"); r = random.choice([0, 90, 180, 270])
    out = work / f"s{i:03d}.jpg"; im.rotate(-r, expand=True).save(out, quality=90); truth[str(out)] = ((360 - r) % 360, f.name)
res = subprocess.run([str(BIN), "classify-file", "--model", str(ROOT / "models/OrientationClassifier.mlpackage"), "--model-b", str(ROOT / "models/OrientationClassifierB.mlpackage"), *truth.keys()], capture_output=True, text=True).stdout
recs = {}; cur = None; pendingB = None
for line in res.splitlines():
    m = re.match(r"\s+B consensus: rotate (\d+)° CW conf ([\d.]+)", line)
    if m: pendingB = (int(m.group(1)), float(m.group(2))); continue
    if line.strip() == "B consensus: NONE": pendingB = None; continue
    if line.startswith(str(work)):
        cur = line.strip(); recs[cur] = {"truth": truth[cur][0], "file": truth[cur][1], "B": pendingB, "A": None}; continue
    m = re.match(r"\s+consensus: rotate (\d+)° CW, calibrated confidence ([\d.]+)", line)
    if m and cur: recs[cur]["A"] = (int(m.group(1)), float(m.group(2)))
with open(a.out, "a") as fh:
    for r in recs.values(): fh.write(json.dumps(r) + "\n")
print("wrote", len(recs), "records to", a.out)
