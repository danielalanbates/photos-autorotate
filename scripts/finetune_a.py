#!/usr/bin/env python3
"""Domain-adapt model A (EfficientNetV2-S orientation classifier) on the user's
own correctly-oriented photos. Self-supervised: each image yields 4 labeled
rotations (x optional mirror). Only the last stage + head are trained; 224px
input, small batch, MPS. Memory watchdog aborts if free RAM gets tight.

usage: venv/bin/python scripts/finetune_a.py --train DIR --exclude DIR --out models/orientation_A_ft.pth
"""
import argparse, os, random, sys, time, psutil
from pathlib import Path
import torch, torch.nn as nn
from torch.utils.data import Dataset, DataLoader
from PIL import Image, ImageOps
ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "models/src_repo"), str(ROOT / "models/src_repo/src")]
from model import get_orientation_model  # noqa

ap = argparse.ArgumentParser()
ap.add_argument("--train", required=True); ap.add_argument("--exclude", default=None)
ap.add_argument("--out", required=True); ap.add_argument("--epochs", type=int, default=4)
ap.add_argument("--size", type=int, default=224); ap.add_argument("--bs", type=int, default=16)
ap.add_argument("--lr", type=float, default=2e-4); ap.add_argument("--max-images", type=int, default=2500)
a = ap.parse_args()

excl = set(p.name for p in Path(a.exclude).iterdir()) if a.exclude else set()
files = [p for p in sorted(Path(a.train).iterdir()) if p.suffix.lower() in (".png", ".jpg", ".jpeg") and p.name not in excl]
random.seed(0); random.shuffle(files); files = files[: a.max_images]
print(f"train images: {len(files)} (excluded {len(excl)} eval images)")

MEAN = torch.tensor([0.485, 0.456, 0.406]).view(3, 1, 1); STD = torch.tensor([0.229, 0.224, 0.225]).view(3, 1, 1)
class DS(Dataset):
    def __init__(s, files): s.files = files
    def __len__(s): return len(s.files) * 4
    def __getitem__(s, i):
        f = s.files[i // 4]; k = i % 4               # k = CW quarter turns applied; label = correction = (4-k)%4
        im = ImageOps.exif_transpose(Image.open(f)).convert("RGB")
        if random.random() < 0.5: im = ImageOps.mirror(im)   # mirror BEFORE rotation: label unchanged
        # random-resized-crop-ish: scale short side to size+~10%, random crop
        w, h = im.size; sc = a.size * random.uniform(1.0, 1.25) / min(w, h)
        im = im.resize((max(a.size, int(w * sc)), max(a.size, int(h * sc))))
        w, h = im.size; x0 = random.randint(0, w - a.size); y0 = random.randint(0, h - a.size)
        im = im.crop((x0, y0, x0 + a.size, y0 + a.size))
        im = im.rotate(-90 * k, expand=True)
        t = torch.from_numpy(__import__("numpy").asarray(im).copy()).permute(2, 0, 1).float() / 255
        return (t - MEAN) / STD, (4 - k) % 4

dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
m = get_orientation_model(pretrained=False)
st = torch.load(ROOT / "models/orientation_model_v2_0.9882.pth", map_location="cpu"); m.load_state_dict(st.get("model_state_dict", st))
# freeze everything except last feature stage + head
for p in m.parameters(): p.requires_grad = False
trainable = []
for name, p in m.named_parameters():
    if name.startswith("features.6") or name.startswith("features.7") or name.startswith("classifier"):
        p.requires_grad = True; trainable.append(p)
print("trainable params:", sum(p.numel() for p in trainable))
m.to(dev).train()
opt = torch.optim.AdamW(trainable, lr=a.lr, weight_decay=1e-4)
crit = nn.CrossEntropyLoss(label_smoothing=0.1)
dl = DataLoader(DS(files), batch_size=a.bs, shuffle=True, num_workers=2, drop_last=True)
steps = a.epochs * len(dl); sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps, pct_start=0.1)
t0 = time.time(); step = 0
for ep in range(a.epochs):
    tot = cor = 0; loss_acc = 0
    for x, y in dl:
        if psutil.virtual_memory().available < 1.2e9:
            print("WATCHDOG: low free memory, saving and aborting"); torch.save(m.state_dict(), a.out); sys.exit(2)
        x, y = x.to(dev), y.to(dev)
        out = m(x); loss = crit(out, y)
        opt.zero_grad(); loss.backward(); opt.step(); sched.step(); step += 1
        tot += y.numel(); cor += (out.argmax(1) == y).sum().item(); loss_acc += loss.item()
        if step % 50 == 0: print(f"ep{ep} step{step}/{steps} loss {loss_acc/50:.3f} acc {cor/tot:.3f} {time.time()-t0:.0f}s", flush=True); loss_acc = 0
    torch.save(m.state_dict(), a.out); print(f"epoch {ep} done, acc {cor/tot:.4f}, saved {a.out}", flush=True)
print("done")
