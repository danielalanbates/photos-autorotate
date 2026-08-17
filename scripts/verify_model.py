"""Sanity check: CoreML vs PyTorch on a test image at 0/90/180/270."""
import sys; from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path[:0]=[str(ROOT/"models/src_repo"),str(ROOT/"models/src_repo/src")]
import torch, numpy as np, coremltools as ct
from PIL import Image
import config; from model import get_orientation_model
img=Image.open(sys.argv[1]).convert("RGB")
S=config.IMAGE_SIZE
ml=ct.models.MLModel(str(ROOT/"models/OrientationClassifier.mlpackage"))
base=get_orientation_model(pretrained=False)
st=torch.load(ROOT/"models/orientation_model_v2_0.9882.pth",map_location="cpu")
base.load_state_dict(st.get("model_state_dict",st)); base.eval()
M=torch.tensor([0.485,0.456,0.406]).view(1,3,1,1); SD=torch.tensor([0.229,0.224,0.225]).view(1,3,1,1)
for rot in (0,90,180,270):
    im=img.rotate(-rot,expand=True).resize((S,S))
    x=torch.from_numpy(np.asarray(im)).permute(2,0,1).float()[None]/255
    with torch.no_grad(): pt=torch.softmax(base((x-M)/SD),1)[0].numpy()
    cm=ml.predict({"input":im})["output"][0]
    print(f"rot {rot:3}: torch argmax={pt.argmax()} p={pt.max():.3f} | coreml argmax={cm.argmax()} p={cm.max():.3f} | maxdiff={abs(pt-cm).max():.4f}")
