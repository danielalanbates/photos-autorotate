# photos-autorotate
macOS CLI that scans the Apple Photos library and rotates misoriented photos
only when ≥99% confident (measured 0 errors / 677 actions). See docs/DESIGN.md.

    swift build
    .build/debug/photos-autorotate scan            # dry run + JSON report
    .build/debug/photos-autorotate apply --yes     # rotate ≥0.99 only
    .build/debug/photos-autorotate revert-all      # undo everything we did

Model: `scripts/venv/bin/python scripts/convert_model.py` (needs the .pth
from the upstream GitHub release in models/).
