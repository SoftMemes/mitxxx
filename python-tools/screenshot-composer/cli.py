#!/usr/bin/env python3
"""Compose raw Patrol screenshots into store-ready marketing screenshots.

Reads raw PNGs from ``dart/app/screenshots/{android,ios}/raw/`` and writes
packaged screenshots to ``dart/app/screenshots/packaged/<platform>/<canvas>/
<locale>/``. Optionally syncs the packaged tree into Fastlane metadata.

Usage (from repo root):

    python3 python-tools/screenshot-composer/cli.py
    python3 python-tools/screenshot-composer/cli.py --canvas=android_phone
    python3 python-tools/screenshot-composer/cli.py --sync-fastlane
    python3 python-tools/screenshot-composer/cli.py --strict
"""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Iterable

import click
import yaml

TOOL_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOL_DIR))

import compose  # noqa: E402
import fastlane_sync  # noqa: E402
from text_render import CopyBlock  # noqa: E402

REPO_ROOT = TOOL_DIR.parent.parent
TEMPLATES = TOOL_DIR / "templates"
FONT_BOLD = TEMPLATES / "fonts" / "Inter-Bold.ttf"
FONT_REGULAR = TEMPLATES / "fonts" / "Inter-Regular.ttf"

DEFAULT_RAW_ROOT = REPO_ROOT / "dart" / "app" / "screenshots"
DEFAULT_OUT_ROOT = DEFAULT_RAW_ROOT / "packaged"
DEFAULT_FASTLANE_ROOT = REPO_ROOT / "dart" / "app" / "fastlane" / "metadata"


def _load_canvases() -> dict[str, compose.CanvasSpec]:
    data = yaml.safe_load((TEMPLATES / "canvases.yaml").read_text())
    out: dict[str, compose.CanvasSpec] = {}
    for name, spec in data["canvases"].items():
        out[name] = compose.CanvasSpec(
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
    return out


def _raw_source_platform_for(canvas_name: str, canvases_data: dict) -> str:
    return canvases_data["canvases"][canvas_name]["raw_source_platform"]


def _load_copy(locale: str) -> dict[str, CopyBlock]:
    path = TEMPLATES / "copy" / f"{locale}.yaml"
    data = yaml.safe_load(path.read_text())
    return {k: CopyBlock(headline=v["headline"], subhead=v["subhead"]) for k, v in data.items()}


def _available_locales() -> list[str]:
    return sorted(p.stem for p in (TEMPLATES / "copy").glob("*.yaml"))


def _fonts_or_die() -> None:
    for f in (FONT_BOLD, FONT_REGULAR):
        if not f.exists():
            raise click.ClickException(
                f"Missing font file: {f}\n"
                "Fetch Inter-{Bold,Regular}.ttf from the rsms/inter OFL release and commit them."
            )


def _atomic_write_png(img, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    img.save(tmp, format="PNG", optimize=True)
    os.replace(tmp, path)


@click.command()
@click.option(
    "--canvas",
    default="all",
    help="Canvas key from canvases.yaml, or 'all' (default).",
)
@click.option("--locale", default="all", help="Locale, or 'all' (default).")
@click.option(
    "--sync-fastlane",
    is_flag=True,
    default=False,
    help="After compose, copy packaged PNGs into dart/app/fastlane/metadata/.",
)
@click.option(
    "--strict",
    is_flag=True,
    default=False,
    help="Fail if any copy value still starts with 'TODO:'.",
)
@click.option(
    "--raw-root",
    type=click.Path(file_okay=False, path_type=Path),
    default=DEFAULT_RAW_ROOT,
    show_default=True,
)
@click.option(
    "--out",
    "out_root",
    type=click.Path(file_okay=False, path_type=Path),
    default=DEFAULT_OUT_ROOT,
    show_default=True,
)
@click.option(
    "--fastlane-root",
    type=click.Path(file_okay=False, path_type=Path),
    default=DEFAULT_FASTLANE_ROOT,
    show_default=True,
)
def main(
    canvas: str,
    locale: str,
    sync_fastlane: bool,
    strict: bool,
    raw_root: Path,
    out_root: Path,
    fastlane_root: Path,
) -> None:
    """Compose packaged marketing screenshots from raw captures."""
    _fonts_or_die()

    canvases_data = yaml.safe_load((TEMPLATES / "canvases.yaml").read_text())
    canvas_specs = _load_canvases()
    canvas_names: Iterable[str] = (
        list(canvas_specs.keys()) if canvas == "all" else [canvas]
    )
    for name in canvas_names:
        if name not in canvas_specs:
            raise click.BadParameter(f"Unknown canvas '{name}'. Known: {sorted(canvas_specs)}")

    locales: Iterable[str] = _available_locales() if locale == "all" else [locale]

    had_todo = False

    for locale_name in locales:
        copy_map = _load_copy(locale_name)
        if strict:
            for stem, block in copy_map.items():
                if block.headline.startswith("TODO:") or block.subhead.startswith("TODO:"):
                    click.echo(f"[{locale_name}] {stem}: copy still TODO", err=True)
                    had_todo = True

        for canvas_name in canvas_names:
            spec = canvas_specs[canvas_name]
            raw_platform = _raw_source_platform_for(canvas_name, canvases_data)
            src_dir = raw_root / raw_platform / "raw"
            if not src_dir.is_dir():
                raise click.ClickException(f"Raw PNG directory missing: {src_dir}")

            missing = [s for s in copy_map if not (src_dir / f"{s}.png").exists()]
            if missing:
                raise click.ClickException(
                    f"Raw PNG missing for copy keys {missing} under {src_dir}"
                )

            out_dir = out_root / ("ios" if raw_platform == "ios" else "android") / canvas_name / locale_name
            click.echo(f"Composing {canvas_name}/{locale_name} -> {out_dir}")

            out_dir.mkdir(parents=True, exist_ok=True)
            for stale in out_dir.glob("*.png"):
                stale.unlink()

            for slot_idx, (stem, copy_block) in enumerate(copy_map.items(), start=1):
                raw_png = src_dir / f"{stem}.png"
                img = compose.compose_frame(
                    canvas=spec,
                    raw_png=raw_png,
                    copy=copy_block,
                    font_bold=FONT_BOLD,
                    font_regular=FONT_REGULAR,
                )
                out_path = out_dir / f"{slot_idx:02d}_{stem}.png"
                _atomic_write_png(img, out_path)
                click.echo(f"  wrote {out_path.relative_to(REPO_ROOT)}")

    if sync_fastlane:
        written = fastlane_sync.sync(
            packaged_root=out_root,
            metadata_root=fastlane_root,
            canvases=list(canvas_names),
            locales=list(locales),
        )
        click.echo(f"Synced {len(written)} screenshot(s) into {fastlane_root}")

    if strict and had_todo:
        raise click.ClickException("One or more copy entries still start with 'TODO:'. Abort.")


if __name__ == "__main__":
    main()
