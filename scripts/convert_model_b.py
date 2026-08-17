#!/usr/bin/env python3
"""Second, independent orientation model for the ensemble: ternaus/check_orientation
(swsl_resnext50_32x4d, MIT, trained on Open Images). 224x224 input, ImageNet
normalization + softmax baked in. Output: OrientationClassifierB.mlpackage."""
import torch, torch.nn as nn, coremltools as ct
from pathlib import Path
from check_orientation.pre_trained_models import create_model
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "models" / "OrientationClassifierB.mlpackage"
MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1); STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
class W(nn.Module):
    def __init__(s, b): super().__init__(); s.b = b
    def forward(s, x): return s.b((x - MEAN) / STD)
base = create_model("swsl_resnext50_32x4d").eval()   # already ends in Softmax
w = W(base).eval()
traced = torch.jit.trace(w, torch.rand(1, 3, 224, 224))
m = ct.convert(traced, inputs=[ct.ImageType(name="input", shape=(1, 3, 224, 224), scale=1/255.0, bias=[0, 0, 0], color_layout=ct.colorlayout.RGB)],
               outputs=[ct.TensorType(name="output")], minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram")
m.short_description = "Orientation classifier B (ensemble second opinion): ternaus/check_orientation swsl_resnext50_32x4d, MIT."
m.save(str(OUT)); print("saved", OUT)
