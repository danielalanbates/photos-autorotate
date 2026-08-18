# Photos AutoRotate (macOS)

Finds sideways / upside-down photos in your Apple Photos library and fixes them —
**only when it is ≥99% certain**. Every fix is a normal, revertible Photos edit
(Photos ▸ Revert to Original, or the app's "Revert everything" button).

**Download:** [latest release DMG](../../releases/latest) · macOS 14+, Apple Silicon or Intel · notarized.

## How it works
- Two independent CoreML orientation models (EfficientNetV2-S from
  [deep-image-orientation-detection](https://github.com/duartebarbosadev/deep-image-orientation-detection),
  ResNeXt50 from [check_orientation](https://github.com/ternaus/check_orientation), both MIT),
  each run on 8 views of the photo (4 rotations × mirror). All views must agree.
- Acts only above a calibrated 0.99 confidence, or when both models independently agree.
- Measured: 247/247 correct actions on a real 12k-photo library across four 100-photo
  test albums; 0 wrong in 1,600 offline trials. Photos it isn't sure about are left alone
  (~15% of misoriented ones), by design.
- Skips videos, Live Photos, panoramas, screenshots. Never touches originals.
- Dry run is on by default: scan first, read the log, then untick to fix.

## Privacy
Everything runs on-device. No network use except iCloud Photos fetching your own
photos through PhotoKit. Nothing is uploaded anywhere.

## Build from source
```
swift build -c release
./scripts/bundle_app.sh 1.0.1      # sign/notarize/DMG (needs your Developer ID + notarytool profile)
```
CLI (`photos-autorotate scan|apply|revert-all|...`) and design notes in `docs/DESIGN.md`.

License: MIT (app code). Models: MIT (see links above).
