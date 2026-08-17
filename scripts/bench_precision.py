#!/usr/bin/env python3
"""Precision benchmark for the full decision gate.

Takes a directory of correctly-oriented photos (e.g. dumps from `scan` with
PAR_DUMP=<dir>, which are the images exactly as Photos displays them),
applies a random known rotation to each, runs `photos-autorotate classify-file`
(4-view consensus + label-smoothing calibration) and reports:

  acted      = images where consensus confidence >= threshold
  correct    = acted AND predicted correction == truth
  precision  = correct / acted        <-- must be >= 0.99
  recall     = correct / total        (how many misoriented photos we'd fix)

Usage: venv/bin/python scripts/bench_precision.py <src_dir> [--n 200] [--threshold 0.99]
"""
import argparse, os, random, re, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug/photos-autorotate"
MODEL = ROOT / "models/OrientationClassifier.mlpackage"

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("--n", type=int, default=200)
ap.add_argument("--threshold", type=float, default=0.99); ap.add_argument("--seed", type=int, default=7)
a = ap.parse_args()

files = sorted(p for p in Path(a.src).iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
random.seed(a.seed); random.shuffle(files); files = files[: a.n]
work = Path(tempfile.mkdtemp(prefix="bench_"))
truth = {}
for i, f in enumerate(files):
    im = ImageOps.exif_transpose(Image.open(f)).convert("RGB")
    r = random.choice([0, 90, 180, 270])           # CW rotation applied
    out = work / f"s{i:03d}.jpg"
    im.rotate(-r, expand=True).save(out, quality=90)
    truth[str(out)] = (360 - r) % 360              # CW correction needed

res = subprocess.run([str(BIN), "classify-file", "--model", str(MODEL), *truth.keys()],
                     capture_output=True, text=True).stdout
acted = correct = wrong = 0; wrong_list = []
cur = None
for line in res.splitlines():
    if line.startswith(str(work)): cur = line.strip(); continue
    m = re.match(r"\s+consensus: rotate (\d+)° CW, calibrated confidence ([\d.]+)", line)
    if m and cur:
        pred, conf = int(m.group(1)), float(m.group(2))
        if conf >= a.threshold:
            acted += 1
            if pred == truth[cur]: correct += 1
            else: wrong += 1; wrong_list.append((cur, truth[cur], pred, conf))
n = len(truth)
print(f"n={n} acted={acted} correct={correct} wrong={wrong}")
print(f"precision={correct/acted if acted else float('nan'):.4f}  recall={correct/n:.4f}  skipped={n-acted}")
for w in wrong_list: print("  WRONG:", w)
print("workdir:", work)
