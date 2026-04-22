"""Rasterise headline + subhead into a transparent PNG strip, with simple
word-wrapping into a bounded copy area.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Tuple

from PIL import Image, ImageDraw, ImageFont

HEADLINE_COLOR = (255, 255, 255, 255)
SUBHEAD_COLOR = (244, 217, 221, 255)  # #F4D9DD


@dataclass
class CopyBlock:
    headline: str
    subhead: str


def _wrap(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, max_w: int) -> list[str]:
    words = text.split()
    if not words:
        return []
    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        candidate = f"{current} {word}"
        w = draw.textlength(candidate, font=font)
        if w <= max_w:
            current = candidate
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def render(
    copy: CopyBlock,
    area: Tuple[int, int, int, int],  # (x, y, w, h) in canvas coords
    canvas_size: Tuple[int, int],
    font_bold: Path,
    font_regular: Path,
    headline_pt: int,
    subhead_pt: int,
) -> Image.Image:
    """Return an RGBA overlay the size of the full canvas, with wrapped
    headline + subhead rendered at the given area."""
    overlay = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    x, y, w, h = area

    headline_font = ImageFont.truetype(str(font_bold), size=headline_pt)
    subhead_font = ImageFont.truetype(str(font_regular), size=subhead_pt)

    headline_lines = _wrap(draw, copy.headline, headline_font, w)
    subhead_lines = _wrap(draw, copy.subhead, subhead_font, w)

    cur_y = y
    # Use the font's ascender+descender metrics for a leading that does not
    # depend on the specific glyphs in the string (so localised copy does not
    # change line pitch).
    h_asc, h_desc = headline_font.getmetrics()
    headline_line_h = int((h_asc + h_desc) * 1.05)
    s_asc, s_desc = subhead_font.getmetrics()
    subhead_line_h = int((s_asc + s_desc) * 1.15)

    for line in headline_lines:
        draw.text((x, cur_y), line, fill=HEADLINE_COLOR, font=headline_font)
        cur_y += headline_line_h

    cur_y += int(headline_line_h * 0.4)  # gap between headline and subhead

    for line in subhead_lines:
        draw.text((x, cur_y), line, fill=SUBHEAD_COLOR, font=subhead_font)
        cur_y += subhead_line_h

    # Bound-check — if the rendered block overflows the area, we still write
    # it, but the caller can inspect overlay.getbbox() to detect.
    _ = h
    return overlay
