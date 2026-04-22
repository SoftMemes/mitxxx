"""Renders a synthetic 9:41 status bar strip over the top of the raw
screenshot before it is fed into the perspective transform.

The real emulator status bar (time, cell signal, real battery %, unread
notification dots) leaks device state into the marketing screenshot; this
module paints a clean platform-appropriate strip over it.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

TIME_TEXT = "9:41"
ANDROID_BAR_COLOR = (255, 255, 255, 255)
ANDROID_FG = (26, 26, 26, 255)
IOS_BAR_COLOR = (255, 255, 255, 255)
IOS_FG = (10, 10, 10, 255)


def _font(font_path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(font_path), size=size)


def mask_test_banner(raw: Image.Image, banner_y: int, banner_h: int) -> Image.Image:
    """Remove the red "screenshots_test capture store screenshots" banner that
    Flutter's LiveTestWidgetsFlutterBinding paints over every live-test frame.

    Samples the app's background color from two rows below the banner and
    fills the banner strip with that color, preserving whatever surface sat
    underneath (AppBar red, onboarding pale pink, etc).
    """
    if banner_h <= 0:
        return raw
    result = raw.convert("RGBA").copy()
    sample_y = min(banner_y + banner_h + 2, result.height - 1)
    sample_x = result.width // 2
    sample = result.getpixel((sample_x, sample_y))
    ImageDraw.Draw(result).rectangle(
        (0, banner_y, result.width, banner_y + banner_h),
        fill=sample,
    )
    return result


def paint(
    raw: Image.Image,
    platform: str,
    bar_height_px: int,
    font_bold: Path,
    font_regular: Path,
) -> Image.Image:
    """Return a copy of ``raw`` with the top ``bar_height_px`` overlaid with a
    synthetic status bar. ``platform`` is 'ios' or 'android'."""
    result = raw.convert("RGBA").copy()
    w = result.size[0]

    bar = Image.new("RGBA", (w, bar_height_px), ANDROID_BAR_COLOR if platform == "android" else IOS_BAR_COLOR)
    draw = ImageDraw.Draw(bar)
    fg = ANDROID_FG if platform == "android" else IOS_FG

    # Time — left on Android, centered pill on iOS.
    time_font = _font(font_bold, size=int(bar_height_px * 0.52))
    time_bbox = draw.textbbox((0, 0), TIME_TEXT, font=time_font)
    tw = time_bbox[2] - time_bbox[0]
    th = time_bbox[3] - time_bbox[1]
    if platform == "android":
        tx = int(bar_height_px * 0.6)
    else:
        # Dynamic-island aware: iOS centers the clock on the left half.
        tx = int(w * 0.12)
    ty = (bar_height_px - th) // 2 - time_bbox[1]
    draw.text((tx, ty), TIME_TEXT, fill=fg, font=time_font)

    # Right-side cluster: wifi + battery, drawn as simple vector shapes.
    right_pad = int(bar_height_px * 0.6)
    icon_h = int(bar_height_px * 0.42)
    gap = int(bar_height_px * 0.25)
    bat_w = int(icon_h * 2.1)
    bat_x2 = w - right_pad
    bat_x1 = bat_x2 - bat_w
    bat_y1 = (bar_height_px - icon_h) // 2
    bat_y2 = bat_y1 + icon_h
    # Battery body
    draw.rounded_rectangle(
        (bat_x1, bat_y1, bat_x2, bat_y2),
        radius=int(icon_h * 0.25),
        outline=fg,
        width=max(2, int(icon_h * 0.1)),
    )
    # Battery fill
    inset = max(3, int(icon_h * 0.18))
    draw.rounded_rectangle(
        (bat_x1 + inset, bat_y1 + inset, bat_x2 - inset, bat_y2 - inset),
        radius=int(icon_h * 0.12),
        fill=fg,
    )
    # Battery nub
    nub_w = max(2, int(icon_h * 0.15))
    nub_h = int(icon_h * 0.4)
    draw.rounded_rectangle(
        (bat_x2 + 2, bat_y1 + (icon_h - nub_h) // 2, bat_x2 + 2 + nub_w, bat_y1 + (icon_h - nub_h) // 2 + nub_h),
        radius=1,
        fill=fg,
    )

    # Wifi — three concentric arcs. Simplified as stacked filled pie slices.
    wifi_size = int(icon_h * 1.3)
    wifi_x2 = bat_x1 - gap
    wifi_x1 = wifi_x2 - wifi_size
    wifi_y2 = bat_y2 + int(icon_h * 0.1)
    wifi_y1 = wifi_y2 - wifi_size
    for scale in (1.0, 0.66, 0.33):
        s = int(wifi_size * scale)
        cx = (wifi_x1 + wifi_x2) // 2
        cy = wifi_y2
        draw.pieslice(
            (cx - s, cy - s, cx + s, cy + s),
            start=220,
            end=320,
            fill=fg,
        )
        # Punch a hole back through with background color.
        hole = int(s * 0.75)
        draw.pieslice(
            (cx - hole, cy - hole, cx + hole, cy + hole),
            start=220,
            end=320,
            fill=ANDROID_BAR_COLOR if platform == "android" else IOS_BAR_COLOR,
        )
    # Solid dot for the center.
    dot = int(icon_h * 0.14)
    cx = (wifi_x1 + wifi_x2) // 2
    cy = wifi_y2
    draw.ellipse((cx - dot, cy - dot, cx + dot, cy + dot), fill=fg)

    result.paste(bar, (0, 0), bar)
    # Silence the unused-parameter lint while keeping the API consistent.
    _ = font_regular
    return result
