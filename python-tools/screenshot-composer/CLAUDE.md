# screenshot-composer

Turns the raw Patrol screenshots at
`dart/app/screenshots/{android,ios}/raw/` into packaged App Store / Play Store
marketing screenshots (tilted device frame + MIT-red gradient + headline).
Populates `dart/app/fastlane/metadata/` so `fastlane upload_screenshots` can
publish them.

See `specs/automate-screenshots.md` for the why and the device-matrix
decisions. The raw-capture side (`screenshots_test.dart` +
`scripts/integration.sh`) is maintained separately.

## Architecture

- `cli.py` — Click entrypoint; iterates canvases × locales × frames.
- `compose.py` — per-frame pipeline (gradient → status bar → perspective →
  bezel → text → `UNOFFICIAL` wordmark on frame 1).
- `perspective.py` — computes the 8-float PIL `PERSPECTIVE` coefficients from
  a source rectangle onto a tilted destination quadrilateral; 2× supersample
  + LANCZOS downsample to kill UI-edge aliasing.
- `frame.py` — draws the tilted phone bezel + Gaussian-blur drop shadow.
- `status_bar.py` — paints a synthetic 9:41 status bar over the top strip of
  the raw PNG (so the real emulator time / signal / battery do not leak).
- `text_render.py` — rasterises Inter-Bold headline + Inter-Regular subhead
  with word-wrap into a canvas-coords copy area.
- `fastlane_sync.py` — copies packaged PNGs into the
  `fastlane/metadata/` tree with the slot prefixes `supply` / `deliver`
  expect.

## Templates

- `templates/canvases.yaml` — per-canvas geometry: output size, status-bar
  height on the raw PNG, copy area rectangle, tilted screen quadrilateral,
  bezel thickness, headline/subhead point sizes. Adding a canvas = adding an
  entry; no code change.
- `templates/copy/en-US.yaml` — headline + subhead per frame. Values start
  as `TODO:` placeholders; owner must replace before the first upload.
- `templates/fonts/Inter-{Bold,Regular}.ttf` — OFL-1.1, committed via Git
  LFS. `LICENSE-OFL.txt` lives alongside.

Adding a locale = dropping `templates/copy/<locale>.yaml` with the same keys
as `en-US.yaml`. The composer iterates over every `copy/*.yaml` it finds.

## Usage

From the repo root:

```bash
# Compose everything (all canvases, all locales).
python3 python-tools/screenshot-composer/cli.py

# Compose a single canvas, single locale.
python3 python-tools/screenshot-composer/cli.py --canvas=android_phone --locale=en-US

# Also copy into dart/app/fastlane/metadata/.
python3 python-tools/screenshot-composer/cli.py --sync-fastlane

# Fail if any copy line still begins with "TODO:".
python3 python-tools/screenshot-composer/cli.py --strict
```

`dart/app/scripts/screenshots.sh` chains `integration.sh screenshots` with
the composer's `--sync-fastlane` invocation for the "one command, fresh
store screenshots" case.

## Tests

```bash
python-tools/.venv/bin/python -m pytest python-tools/screenshot-composer/tests/
```

- `test_perspective.py` — algebraic checks on the homography.
- `test_golden_manifest.py` — recomposes every packaged PNG and asserts its
  SHA-256 matches `tests/golden_manifest.json`. Any geometry / font / copy
  change flips hashes; intentional changes ship the updated manifest in the
  same PR.

## Regenerating the golden manifest

When a change intentionally alters pixel output (new canvas, tweaked
geometry, finalised copy):

```bash
# Produce new PNGs.
python-tools/.venv/bin/python python-tools/screenshot-composer/cli.py
# Rewrite manifest from the new outputs.
python-tools/.venv/bin/python -c "
import hashlib, json
from pathlib import Path
root = Path('dart/app/screenshots/packaged')
m = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
     for p in sorted(root.rglob('*.png'))}
Path('python-tools/screenshot-composer/tests/golden_manifest.json') \
    .write_text(json.dumps(m, indent=2, sort_keys=True) + '\n')
"
```

Commit both the regenerated PNGs (LFS) and the new manifest.
