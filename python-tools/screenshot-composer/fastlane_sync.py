"""Copy packaged screenshots into the Fastlane metadata tree.

Layout produced:
    dart/app/fastlane/metadata/<locale>/screenshots/iPhone 6.9 Display/
        1_0_01_onboarding.png
        2_0_02_list_selection.png
        ...
    dart/app/fastlane/metadata/android/<locale>/images/phoneScreenshots/
        1_01_onboarding.png
        2_02_list_selection.png
        ...

`deliver` (iOS) interprets the leading "N_0_" as "slot N, language 0";
`supply` (Play) just wants files in display order, alphabetic ordering
works because we prefix with 1_, 2_, ...
"""
from __future__ import annotations

import shutil
from pathlib import Path
from typing import Iterable

IOS_CANVAS_TO_FASTLANE_DEVICE = {
    "iphone_6_9": "iPhone 6.9 Display",
}


def sync(
    packaged_root: Path,
    metadata_root: Path,
    canvases: Iterable[str],
    locales: Iterable[str],
) -> list[Path]:
    """Copy packaged PNGs into the Fastlane metadata tree. Returns the list
    of destination paths written."""
    written: list[Path] = []
    for canvas in canvases:
        for locale in locales:
            if canvas.startswith("iphone"):
                dst_dir = _ios_destination(metadata_root, canvas, locale)
                prefix_style = "ios"
                src_dir = packaged_root / "ios" / canvas / locale
            else:
                dst_dir = _android_destination(metadata_root, canvas, locale)
                prefix_style = "android"
                src_dir = packaged_root / "android" / canvas / locale
            if not src_dir.is_dir():
                continue
            dst_dir.mkdir(parents=True, exist_ok=True)
            # Wipe stale files in the destination so old slot ordering does
            # not linger.
            for existing in dst_dir.glob("*.png"):
                existing.unlink()
            for idx, src in enumerate(sorted(src_dir.glob("*.png")), start=1):
                if prefix_style == "ios":
                    new_name = f"{idx}_0_{src.name}"
                else:
                    new_name = f"{idx}_{src.name}"
                dst = dst_dir / new_name
                shutil.copyfile(src, dst)
                written.append(dst)
    return written


def _ios_destination(metadata_root: Path, canvas: str, locale: str) -> Path:
    device = IOS_CANVAS_TO_FASTLANE_DEVICE.get(canvas)
    if device is None:
        raise ValueError(f"No Fastlane device mapping for iOS canvas '{canvas}'")
    return metadata_root / locale / "screenshots" / device


def _android_destination(metadata_root: Path, canvas: str, locale: str) -> Path:
    # Play only accepts 'phone' / 'tablet' slots; canvas name ignored beyond
    # that. v1 only ships the `android_phone` canvas -> phoneScreenshots.
    subdir = "phoneScreenshots"
    return metadata_root / "android" / locale / "images" / subdir
