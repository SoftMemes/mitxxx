"""Renders a flat (face-on) phone bezel around an axis-aligned screen rect,
with a platform-appropriate chrome element (iPhone Dynamic Island or Android
centered punch-hole camera) and a Gaussian-blur drop shadow beneath.
"""
from __future__ import annotations

from typing import Tuple

from PIL import Image, ImageDraw, ImageFilter

Rect = Tuple[int, int, int, int]  # (x, y, w, h)

BEZEL_COLOR = (10, 10, 12, 255)
BEZEL_HIGHLIGHT = (40, 40, 44, 255)
SHADOW_COLOR = (0, 0, 0, 150)
SHADOW_BLUR_PX = 40
SHADOW_OFFSET = (0, 30)
DYNAMIC_ISLAND_COLOR = (6, 6, 8, 255)
PUNCH_HOLE_COLOR = (6, 6, 8, 255)


def _rect_from_xywh(r: Rect) -> Tuple[int, int, int, int]:
    x, y, w, h = r
    return (x, y, x + w, y + h)


def draw_chrome(
    canvas: Image.Image,
    screen_rect: Rect,
    bezel_thickness: int,
    screen_corner_radius: int,
    phone_style: str,
) -> None:
    """Composite a drop shadow, a phone bezel ring, and platform-specific
    chrome (Dynamic Island / punch hole) onto ``canvas``.

    The caller has already placed the screenshot inside ``screen_rect`` with
    matching rounded corners; this function draws *around* and *on top of* it.
    """
    sx, sy, sw, sh = screen_rect

    outer = (
        sx - bezel_thickness,
        sy - bezel_thickness,
        sx + sw + bezel_thickness,
        sy + sh + bezel_thickness,
    )
    outer_radius = screen_corner_radius + bezel_thickness

    # Drop shadow: a filled rounded rect, blurred, offset below the device.
    shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow_layer)
    sdraw.rounded_rectangle(outer, radius=outer_radius, fill=SHADOW_COLOR)
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(SHADOW_BLUR_PX))
    shifted = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shifted.paste(shadow_layer, SHADOW_OFFSET, shadow_layer)
    canvas.alpha_composite(shifted)

    # Bezel ring: filled rounded outer rect minus filled rounded inner rect.
    bezel_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(bezel_layer)
    bdraw.rounded_rectangle(outer, radius=outer_radius, fill=BEZEL_COLOR)
    bdraw.rounded_rectangle(
        (sx, sy, sx + sw, sy + sh),
        radius=screen_corner_radius,
        fill=(0, 0, 0, 0),
    )
    # Subtle highlight stroke along the very outer edge so the bezel reads as
    # a physical device and not a black sticker glued to the background.
    bdraw.rounded_rectangle(
        outer,
        radius=outer_radius,
        outline=BEZEL_HIGHLIGHT,
        width=2,
    )
    canvas.alpha_composite(bezel_layer)

    # Platform chrome — drawn on top of the screen area.
    if phone_style == "iphone":
        _draw_dynamic_island(canvas, screen_rect)
    elif phone_style == "android":
        _draw_punch_hole(canvas, screen_rect)


def _draw_dynamic_island(canvas: Image.Image, screen_rect: Rect) -> None:
    sx, sy, sw, _sh = screen_rect
    pill_w = int(sw * 0.26)
    pill_h = int(sw * 0.064)
    top_gap = int(sw * 0.024)
    cx = sx + sw // 2
    top = sy + top_gap
    box = (cx - pill_w // 2, top, cx + pill_w // 2, top + pill_h)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        box, radius=pill_h // 2, fill=DYNAMIC_ISLAND_COLOR
    )
    canvas.alpha_composite(layer)


def _draw_punch_hole(canvas: Image.Image, screen_rect: Rect) -> None:
    sx, sy, sw, _sh = screen_rect
    diameter = int(sw * 0.046)
    top_gap = int(sw * 0.024)
    cx = sx + sw // 2
    top = sy + top_gap
    box = (cx - diameter // 2, top, cx + diameter // 2, top + diameter)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(box, fill=PUNCH_HOLE_COLOR)
    canvas.alpha_composite(layer)
