# Photos Auto-Rotate — design & verification (2026-08-17)

Goal: sift the whole Apple Photos library and fix misoriented photos, acting
ONLY when ≥99% sure. Prefer skipping over guessing. Everything is
non-destructive (PhotoKit edits with our own PHAdjustmentData; `revert-all`
restores originals; Photos' own "Revert to Original" also works).

## Pipeline
1. `LibraryScanner` — PHAsset fetch (skips videos, Live Photos, panoramas,
   screenshots); loads a ~768px copy *as Photos displays it* via
   `PHImageManager.requestImage` (network allowed, 20s timeout; serves
   downscaled derivatives for iCloud-only assets), falling back to local
   original data (never network).
2. `CoreMLOrientationClassifier` — EfficientNetV2-S 4-class (0/90/180/270 CW
   correction) from duartebarbosadev/deep-image-orientation-detection (MIT,
   98.82% val). Converted with `scripts/convert_model.py` (softmax + ImageNet
   norm baked in). Parity vs PyTorch verified (`scripts/verify_model.py`,
   max diff 0.003).
   * Trained with label_smoothing=0.1 → softmax saturates at ~0.925. We
     divide by that ceiling (calibration) so 0.99 is reachable.
   * **8-view consensus (TTA):** image at 4 rotations × {plain, mirrored}.
     Every view must map back to the SAME correction, else skip.
     Confidence = min calibrated prob over the 8 views (weakest link).
3. `VisionOrientationClassifier` — faces/text heuristic. **Veto only**
   (never acts alone): if it's ≥0.6 confident and disagrees, skip.
4. `DecisionEngine` — act iff consensus exists AND confidence ≥ 0.99 AND no
   Vision veto.
5. `PhotoKitRotator` — applies rotation, stamps adjustment data, ledgers it.

## Measured (scripts/bench_precision.py)
300 real photos dumped from Daniel's library, random known rotation, 3 seeds
= 900 trials: **677 acted, 0 wrong (precision 1.000), recall 0.75.**
4-view-only (no mirror) had 1 error in 300 (a gravity-less tattoo close-up
at 0.997); adding mirrored views drops that image to 0.70 → skipped.
Bench excludes the Vision veto (real pipeline is stricter).

Full library dry-run (320 photos): 1 flagged — that same tattoo photo,
before the mirror views were added; 0 after.

## Live album bench (Daniel's pass/fail metric)
`bench-setup --album "AutoRotate Review" --n 100 [--append]` picks editable
people/animal/building photos, adds them to the album, scrambles each by a
random known rotation; `apply --album ...` runs the real pipeline;
`bench-score` compares. 2026-08-17: n=100, acted 59, correct 59, wrong 0
(precision 1.000), 10 skipped-but-needed (recall 0.855). PASS.
Run 2 (seed 99, HDR/portrait assets included after the 3302 fix): n=100,
acted 65, correct 65, wrong 0, 11 skipped. PASS. Skipped leftovers were
reverted to original afterwards.
Run 3 (seed 2024, Vision veto disabled): n=100, acted 57, correct 57, wrong 0,
14 skipped (recall 0.80). PASS. Cumulative: 181/181 actions correct.
Vision face/text veto was found to veto CORRECT 0.99+ model calls with wrong
answers (0.7-0.9 conf) -> disabled by default (DecisionEngine).

## SOLVED: PHPhotosError 3302 on portrait/HDR photos
Third-party edits on any asset whose original carries EXIF Orientation != 1
(all portrait iPhone shots; also correlated with HDR/cloud-only, which were
red herrings) failed `performChanges` with 3302 "asset resource validation
failed". Root cause (found by disassembling Photos.framework
`-[PHAssetChangeRequest _validateImageURLForAssetMutation:error:]`): the
validator reads the rendered file's image properties and rejects an EXIF
Orientation that disagrees with the pixels. CIImage copies the source EXIF
(6) into the rendered JPEG even after `.oriented()` bakes the pixels upright.
Fix: `settingProperties` with Orientation=1 (and TIFF orientation) before
writing; also carry the HDR gain map (`.auxiliaryHDRGainMap` ->
`.hdrGainMapImage`) so ISO-HDR photos keep their HDR. Verified on 2397C7F3,
D5DF0560 (HDR+portrait), 2EA8B0F4, 3FF89480.

## Gotchas
* `MLModel(contentsOf:)` needs .mlmodelc — we compile the .mlpackage at
  runtime and cache next to it (no Xcode coremlcompiler on this Mac).
* `DispatchQueue.asyncAfter` inside `withCheckedContinuation` crashed at
  closure entry (Swift 6.3.3) — use `withTimeout` (Task.sleep race).
* coremltools needs Python ≤3.12 (3.14 venv has no native libs).
* First run prompts for Photos access; the CLI is unbundled so the grant is
  keyed to the terminal app.

## Commands
scan [--limit N] · apply [--min-confidence 0.99] [--yes] · revert-all ·
revert <id> · list · status <id> · rotate <id> <deg> (debug) ·
classify-file <files…> (debug, no Photos access)
