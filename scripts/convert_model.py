#!/usr/bin/env python3
"""Convert the duartebarbosadev/deep-image-orientation-detection PyTorch
checkpoint (EfficientNetV2-S, 4-class 0/90/180/270 orientation classifier,
98.82% validation accuracy, MIT licensed) into a CoreML .mlpackage with a
softmax head, so Swift gets calibrated probabilities directly.

Usage: venv/bin/python scripts/convert_model.py
"""
import sys
from pathlib import Path

import torch
import torch.nn as nn
import coremltools as ct

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "models" / "src_repo"))
sys.path.insert(0, str(ROOT / "models" / "src_repo" / "src"))

import config  # noqa: E402
from model import get_orientation_model  # noqa: E402

CKPT = ROOT / "models" / "orientation_model_v2_0.9882.pth"
OUT = ROOT / "models" / "OrientationClassifier.mlpackage"
IMAGE_SIZE = config.IMAGE_SIZE  # 384


MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)


class WithPreprocessAndSoftmax(nn.Module):
    """Bakes ImageNet normalization + softmax into the traced graph so the
    CoreML input can just be raw 0-1 RGB pixels."""
    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, x):
        x = (x - MEAN) / STD
        return torch.softmax(self.base(x), dim=1)


def main():
    print(f"Loading checkpoint {CKPT}")
    base = get_orientation_model(pretrained=False)
    state = torch.load(CKPT, map_location="cpu")
    if isinstance(state, dict) and "model_state_dict" in state:
        state = state["model_state_dict"]
    base.load_state_dict(state)
    base.eval()

    wrapped = WithPreprocessAndSoftmax(base).eval()

    example = torch.rand(1, 3, IMAGE_SIZE, IMAGE_SIZE)
    traced = torch.jit.trace(wrapped, example)

    # Swift hands over raw 0-255 RGB pixels; scale=1/255 maps to [0,1] and
    # exact ImageNet normalization happens inside the traced graph above.
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                              scale=1.0 / 255.0, bias=[0, 0, 0], color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="output")],
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "4-class photo orientation classifier (0/90/180/270 CW correction), EfficientNetV2-S, 98.82% val accuracy. Source: github.com/duartebarbosadev/deep-image-orientation-detection (MIT)."
    mlmodel.save(str(OUT))
    print(f"Saved {OUT}")


if __name__ == "__main__":
    main()
