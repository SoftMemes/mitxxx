"""Per-frame composition pipeline.

Takes one raw PNG + a canvas spec + a copy block and returns a packaged
marketing screenshot as a PIL Image.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Tuple

from PIL import Image, ImageDraw

import frame
import status_bar
import text_render

Rect = Tuple[int, int, int, int]

GRADIENT_TOP = (163, 31, 52)  # #A31F34 — MIT red
GRADIENT_BOTTOM = (107, 21, 35)  # #6B1523


@dataclass
class CanvasSpec:
    name: str
    size: Tuple[int, int]
    copy_area: Rect
    screen_rect: Rect
    bezel_thickness: int
    screen_corner_radius: int
    phone_style: str
    headline_pt: int
    subhead_pt: int
    status_bar_platform: str
    raw_status_bar_px: int


def _draw_gradient(size: Tuple[int, int]) -> Image.Image:
    w, h = size
    img = Image.new("RGBA", size, (0, 0, 0, 255))
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(GRADIENT_TOP[0] * (1 - t) + GRADIENT_BOTTOM[0] * t)
        g = int(GRADIENT_TOP[1] * (1 - t) + GRADIENT_BOTTOM[1] * t)
        b = int(GRADIENT_TOP[2] * (1 - t) + GRADIENT_BOTTOM[2] * t)
        draw.line([(0, y), (w, y)], fill=(r, g, b, 255))
    return img


def _paste_screen(canvas: Image.Image, raw: Image.Image, screen_rect: Rect, corner_radius: int) -> None:
    """Resize ``raw`` into ``screen_rect`` and paste it onto ``canvas`` with
    rounded-corner clipping so the screenshot hugs the device's rounded
    display."""
    sx, sy, sw, sh = screen_rect
    resized = raw.resize((sw, sh), Image.Resampling.LANCZOS).convert("RGBA")

    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, sw, sh),
        radius=corner_radius,
        fill=255,
    )
    canvas.paste(resized, (sx, sy), mask)


def compose_frame(
    canvas: CanvasSpec,
    raw_png: Path,
    copy: text_render.CopyBlock,
    font_bold: Path,
    font_regular: Path,
) -> Image.Image:
    """Return the composed marketing PNG for one frame."""
    bg = _draw_gradient(canvas.size)

    raw = Image.open(raw_png).convert("RGBA")
    raw = status_bar.paint(
        raw,
        platform=canvas.status_bar_platform,
        bar_height_px=canvas.raw_status_bar_px,
        font_bold=font_bold,
        font_regular=font_regular,
    )

    _paste_screen(bg, raw, canvas.screen_rect, canvas.screen_corner_radius)

    frame.draw_chrome(
        bg,
        screen_rect=canvas.screen_rect,
        bezel_thickness=canvas.bezel_thickness,
        screen_corner_radius=canvas.screen_corner_radius,
        phone_style=canvas.phone_style,
    )

    text_layer = text_render.render(
        copy=copy,
        area=canvas.copy_area,
        canvas_size=canvas.size,
        font_bold=font_bold,
        font_regular=font_regular,
        headline_pt=canvas.headline_pt,
        subhead_pt=canvas.subhead_pt,
    )
    bg.alpha_composite(text_layer)

    return bg
