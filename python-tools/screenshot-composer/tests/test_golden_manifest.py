"""Byte-identity check for packaged screenshots.

Recomposes every (canvas, locale, frame) from the committed raw PNGs and
asserts each output matches the SHA-256 recorded in ``golden_manifest.json``.

Regenerating the manifest is an intentional act: run the composer, copy the
printed hashes back into the JSON, and commit both the packaged PNGs and the
new manifest in the same PR.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest
import yaml

TOOL_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = TOOL_DIR.parent.parent
sys.path.insert(0, str(TOOL_DIR))

import compose  # noqa: E402
from text_render import CopyBlock  # noqa: E402

TEMPLATES = TOOL_DIR / "templates"
FONT_BOLD = TEMPLATES / "fonts" / "Inter-Bold.ttf"
FONT_REGULAR = TEMPLATES / "fonts" / "Inter-Regular.ttf"
RAW_ROOT = REPO_ROOT / "dart" / "app" / "screenshots"


def _load_canvases() -> dict:
    return yaml.safe_load((TEMPLATES / "canvases.yaml").read_text())["canvases"]


def _canvas_spec(name: str) -> compose.CanvasSpec:
    spec = _load_canvases()[name]
    return compose.CanvasSpec(
        name=name,
        size=tuple(spec["size"]),
        copy_area=tuple(spec["copy_area"]),
        screen_rect=tuple(spec["screen_rect"]),
        bezel_thickness=int(spec["bezel_thickness"]),
        screen_corner_radius=int(spec["screen_corner_radius"]),
        phone_style=spec["phone_style"],
        headline_pt=int(spec["headline_pt"]),
        subhead_pt=int(spec["subhead_pt"]),
        status_bar_platform=spec["platform"],
        raw_status_bar_px=int(spec["raw_status_bar_px"]),
        raw_test_banner_y=int(spec["raw_test_banner_y"]),
        raw_test_banner_h=int(spec["raw_test_banner_h"]),
    )


def _manifest() -> dict[str, str]:
    return json.loads((TOOL_DIR / "tests" / "golden_manifest.json").read_text())


def _copy_for(locale: str) -> dict[str, CopyBlock]:
    data = yaml.safe_load((TEMPLATES / "copy" / f"{locale}.yaml").read_text())
    return {k: CopyBlock(headline=v["headline"], subhead=v["subhead"]) for k, v in data.items()}


def _entries():
    manifest = _manifest()
    for rel, digest in sorted(manifest.items()):
        # ios|android / canvas / locale / <slot>_<stem>.png
        parts = Path(rel).parts
        platform, canvas, locale, fname = parts
        # Strip the "NN_" slot prefix to recover the raw stem.
        stem = Path(fname).stem.split("_", 1)[1]
        yield platform, canvas, locale, stem, digest


@pytest.mark.parametrize("platform,canvas,locale,stem,digest", list(_entries()))
def test_packaged_hash_matches(platform: str, canvas: str, locale: str, stem: str, digest: str, tmp_path: Path) -> None:
    spec = _canvas_spec(canvas)
    raw_platform = _load_canvases()[canvas]["raw_source_platform"]
    raw_png = RAW_ROOT / raw_platform / "raw" / f"{stem}.png"
    assert raw_png.exists(), f"Missing raw PNG: {raw_png}"

    copy_map = _copy_for(locale)
    img = compose.compose_frame(
        canvas=spec,
        raw_png=raw_png,
        copy=copy_map[stem],
        font_bold=FONT_BOLD,
        font_regular=FONT_REGULAR,
    )

    tmp = tmp_path / "out.png"
    img.save(tmp, format="PNG", optimize=True)
    actual = hashlib.sha256(tmp.read_bytes()).hexdigest()
    assert actual == digest, (
        f"Hash mismatch for {platform}/{canvas}/{locale}/{stem}.png\n"
        f"  expected: {digest}\n"
        f"  actual:   {actual}\n"
        "If this change is intentional, regenerate golden_manifest.json."
    )
