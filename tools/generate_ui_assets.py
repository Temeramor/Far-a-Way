#!/usr/bin/env python3
"""Generate Far a Way's modular pixel-art UI textures.

Requires Pillow: python -m pip install Pillow
Run from the project root or any other working directory:
    python tools/generate_ui_assets.py

The script builds intermediate layers in memory and writes only the four composite button-state
textures consumed by the game.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageChops

PROJECT_DIR = Path(__file__).resolve().parents[1]
OUT_DIR = PROJECT_DIR / "assets" / "ui"
W, H = 128, 48
MOSS_H = 16

PALETTES = {
    "primary": {
        "face": "#B48A4B", "face_alt": "#C49A58", "face_shadow": "#896333",
        "outer": "#211A14", "frame_dark": "#51351D", "frame": "#BE8835",
        "frame_light": "#F0C86E", "detail": "#D8A84C",
        "moss_dark": "#273A22", "moss": "#47683A", "moss_light": "#78964B",
        "moss_high": "#A3B968", "pressed_face": "#4B3525",
    },
    "secondary": {
        "face": "#244844", "face_alt": "#2A5148", "face_shadow": "#18342F",
        "outer": "#141D19", "frame_dark": "#293A2E", "frame": "#9B874A",
        "frame_light": "#D1BD75", "detail": "#AA985C",
        "moss_dark": "#213923", "moss": "#3F6535", "moss_light": "#6D9143",
        "moss_high": "#9AAF59", "pressed_face": "#193631",
    },
    "hover": {
        "face": "#D2B978", "face_alt": "#DCC887", "face_shadow": "#A7864A",
        "outer": "#19251B", "frame_dark": "#5B512E", "frame": "#F1D47F",
        "frame_light": "#FFF0B4", "detail": "#E9C45F",
        "moss_dark": "#2D4828", "moss": "#4D7538", "moss_light": "#81A84B",
        "moss_high": "#B9D16B", "pressed_face": "#AD945A",
    },
    "pressed": {
        "face": "#453426", "face_alt": "#4D3929", "face_shadow": "#32261C",
        "outer": "#171612", "frame_dark": "#382919", "frame": "#98702D",
        "frame_light": "#C99A47", "detail": "#AD8039",
        "moss_dark": "#1C2D1D", "moss": "#34502C", "moss_light": "#53713A",
        "moss_high": "#78934C", "pressed_face": "#32261C",
    },
}


def px(draw: ImageDraw.ImageDraw, points, fill, width=1):
    draw.line(points, fill=fill, width=width, joint="curve")


def draw_surface(state: str, palette: dict[str, str]) -> Image.Image:
    """Only the wooden/painted face; transparent everywhere outside the face."""
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    face = palette["pressed_face"] if state == "pressed" else palette["face"]

    draw.polygon([(7, 8), (120, 8), (120, 38), (118, 41), (9, 41), (7, 38)], fill=face)
    draw.rectangle((8, 9, 119, 17), fill=palette["face_alt"])
    draw.rectangle((8, 18, 119, 37), fill=face)
    draw.rectangle((8, 38, 119, 40), fill=palette["face_shadow"])

    # Restrained timber grain: it reads as aged wood but leaves the text area calm.
    grain = palette["frame_dark"]
    for x1, y, x2 in [(21, 19, 29), (43, 33, 54), (78, 21, 88), (98, 34, 106)]:
        draw.line((x1, y, x2, y), fill=grain)
    draw.point((34, 25), fill=palette["detail"])
    draw.point((91, 29), fill=palette["detail"])
    draw.point((63, 36), fill=grain)

    if state == "hover":
        draw.line((14, 14, 113, 14), fill=palette["frame_light"])
        draw.point((16, 16), fill=palette["moss_high"])
        draw.point((111, 16), fill=palette["moss_high"])
    elif state == "pressed":
        draw.line((10, 13, 117, 13), fill=palette["frame_dark"])
        draw.line((10, 38, 117, 38), fill=palette["frame_light"])
    return image


def draw_vine_corner(draw: ImageDraw.ImageDraw, palette: dict[str, str], x: int, y: int, sx: int, sy: int) -> None:
    """Stepped leaf-scroll flourish at one frame corner."""
    brass, bright, shadow = palette["frame"], palette["frame_light"], palette["frame_dark"]

    def pt(a: int, b: int) -> tuple[int, int]:
        return (x + a * sx, y + b * sy)

    points = [pt(0, 11), pt(0, 7), pt(3, 4), pt(8, 4), pt(10, 6)]
    px(draw, points, shadow)
    px(draw, [pt(0, 10), pt(1, 7), pt(4, 5), pt(8, 5)], brass)
    draw.point(pt(8, 4), fill=bright)
    px(draw, [pt(3, 10), pt(5, 8), pt(7, 8), pt(8, 10), pt(7, 12), pt(5, 12), pt(4, 11)], brass)
    draw.point(pt(5, 9), fill=bright)
    a, b = pt(2, 12), pt(3, 13)
    draw.rectangle((min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1])), fill=shadow)


def draw_side_gems(draw: ImageDraw.ImageDraw, palette: dict[str, str]) -> None:
    """Faceted brass diamonds, visibly attached to the left and right frame rails."""
    outer, shadow = palette["outer"], palette["frame_dark"]
    brass, bright, detail = palette["frame"], palette["frame_light"], palette["detail"]

    # Left stud: a dark cutout, two warm-gold facets and a tiny top glint.
    draw.polygon([(0, 24), (4, 16), (13, 24), (4, 32)], fill=outer)
    draw.polygon([(1, 24), (4, 18), (11, 24), (4, 30)], fill=shadow)
    draw.polygon([(2, 24), (4, 19), (9, 24), (4, 29)], fill=brass)
    draw.polygon([(3, 23), (4, 20), (7, 23), (4, 25)], fill=detail)
    draw.polygon([(3, 22), (4, 20), (5, 22), (4, 23)], fill=bright)
    draw.polygon([(4, 25), (8, 24), (4, 28)], fill=shadow)
    draw.point((4, 21), fill=bright)

    # Right stud is mirrored so the frame can be reused at any button width.
    draw.polygon([(127, 24), (123, 16), (114, 24), (123, 32)], fill=outer)
    draw.polygon([(126, 24), (123, 18), (116, 24), (123, 30)], fill=shadow)
    draw.polygon([(125, 24), (123, 19), (118, 24), (123, 29)], fill=brass)
    draw.polygon([(124, 23), (123, 20), (120, 23), (123, 25)], fill=detail)
    draw.polygon([(124, 22), (123, 20), (122, 22), (123, 23)], fill=bright)
    draw.polygon([(123, 25), (119, 24), (123, 28)], fill=shadow)
    draw.point((123, 21), fill=bright)


def draw_frame(state: str, palette: dict[str, str]) -> Image.Image:
    """Ornate border layer with a transparent middle, independent from the button face."""
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    outer, dark = palette["outer"], palette["frame_dark"]
    brass, bright = palette["frame"], palette["frame_light"]

    # Separate rails leave the center transparent so the surface can be replaced.
    draw.polygon([(4, 0), (123, 0), (127, 4), (124, 8), (4, 8), (0, 4)], fill=outer)
    draw.polygon([(0, 4), (4, 0), (8, 5), (8, 39), (4, 47), (0, 43)], fill=outer)
    draw.polygon([(127, 4), (123, 0), (120, 5), (120, 39), (124, 47), (127, 43)], fill=outer)
    draw.polygon([(8, 39), (120, 39), (127, 43), (123, 47), (4, 47), (0, 43)], fill=outer)

    # Stepped double bevel gives the rail a carved brass edge rather than a plain box.
    px(draw, [(5, 7), (8, 4), (119, 4), (122, 7)], brass)
    px(draw, [(5, 8), (5, 38), (8, 42), (119, 42), (122, 39), (122, 8)], brass)
    px(draw, [(8, 11), (8, 37), (10, 39), (117, 39), (119, 37), (119, 11)], dark)
    px(draw, [(12, 12), (116, 12)], palette["detail"])
    px(draw, [(12, 36), (116, 36)], dark)

    # Upper leaf-scrolls and bottom curls; the moss layer sits mostly between them.
    draw_vine_corner(draw, palette, 4, 3, 1, 1)
    draw_vine_corner(draw, palette, 123, 3, -1, 1)
    draw_side_gems(draw, palette)
    px(draw, [(4, 36), (7, 40), (12, 40), (14, 38), (12, 36)], dark)
    px(draw, [(5, 36), (8, 39), (12, 39), (13, 38)], brass)
    draw.point((9, 37), fill=bright)
    px(draw, [(123, 36), (120, 40), (115, 40), (113, 38), (115, 36)], dark)
    px(draw, [(122, 36), (119, 39), (115, 39), (114, 38)], brass)
    draw.point((118, 37), fill=bright)

    for x, y in [(14, 15), (113, 15), (17, 34), (110, 34)]:
        draw.rectangle((x, y, x + 1, y + 1), fill=bright)
        draw.point((x + 1, y + 1), fill=dark)

    if state == "pressed":
        draw.line((10, 13, 117, 13), fill=dark)
        draw.line((10, 38, 117, 38), fill=bright)
    elif state == "hover":
        draw.line((14, 14, 113, 14), fill=bright)
        draw.point((16, 16), fill=palette["moss_high"])
        draw.point((111, 16), fill=palette["moss_high"])

    return image


def draw_moss_strip(palette: dict[str, str], brighter: bool = False) -> Image.Image:
    """A gently undulating, non-repeating pixel-moss edge with a few dangling shoots."""
    image = Image.new("RGBA", (W, MOSS_H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    dark, mid, light, hi = palette["moss_dark"], palette["moss"], palette["moss_light"], palette["moss_high"]

    # Low-frequency contour: only small height changes, avoiding spiky grass silhouettes.
    top = [
        (12, 6), (16, 5), (20, 5), (23, 4), (27, 5), (31, 5),
        (35, 4), (39, 3), (43, 4), (47, 5), (51, 5), (55, 4),
        (59, 4), (63, 5), (67, 5), (71, 4), (75, 3), (79, 4),
        (83, 5), (87, 5), (91, 4), (95, 4), (99, 5), (103, 5),
        (107, 4), (111, 5), (116, 6),
    ]
    draw.polygon(top + [(116, 9), (12, 9)], fill=dark)

    # The moss body is offset by one pixel, so the edge reads as layered clumps.
    inner = [(x, min(y + 1, 7)) for x, y in top]
    draw.polygon(inner + [(114, 8), (14, 8)], fill=mid)

    # Tiny, clustered colour flecks create pixel texture without a noisy full-coverage pattern.
    flecks = [
        (17, 5, light), (19, 6, mid), (22, 4, hi if brighter else light),
        (25, 5, light), (29, 6, dark), (33, 5, light), (36, 4, hi if brighter else light),
        (40, 4, light), (44, 5, mid), (48, 6, light), (52, 5, hi if brighter else light),
        (56, 4, light), (60, 5, dark), (64, 6, light), (68, 5, light),
        (72, 4, hi if brighter else light), (76, 3, light), (80, 5, light),
        (84, 6, dark), (88, 5, light), (92, 4, hi if brighter else light),
        (96, 5, light), (100, 6, mid), (104, 5, light), (108, 4, hi if brighter else light),
        (112, 6, light),
    ]
    for x, y, colour in flecks:
        draw.point((x, y), fill=colour)
        if x % 3 == 1 and y < 6:
            draw.point((x + 1, y + 1), fill=mid)

    # Moss tendrils hang unevenly from the lip; each uses stepped, tapered pixels.
    shoots = [
        (19, 6, 3, light), (28, 6, 5, mid), (37, 5, 3, light),
        (46, 6, 4, dark), (55, 5, 3, light), (64, 6, 5, mid),
        (73, 5, 4, light), (82, 6, 3, dark), (91, 5, 5, mid),
        (101, 6, 3, light), (110, 6, 4, mid),
    ]
    for x, y, length, colour in shoots:
        draw.line((x, y, x, min(MOSS_H - 3, y + length - 1)), fill=colour)
        if length >= 4:
            draw.point((x + 1, y + length - 2), fill=light)
        draw.point((x, min(MOSS_H - 2, y + length)), fill=dark if colour != dark else mid)

    # Sparse leaf pixels give each state subtle variation but leave the centre quiet for text.
    for x, y in [(32, 7), (42, 6), (59, 7), (78, 6), (97, 7), (106, 6)]:
        draw.point((x, y), fill=light if brighter else mid)

    # Taper the ends under the frame's corner scrolls and gems.
    alpha = image.getchannel("A")
    mask = Image.new("L", (W, MOSS_H), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rectangle((18, 0, 109, MOSS_H - 1), fill=255)
    for x in range(12, 18):
        mask_draw.line((x, 0, x, MOSS_H - 1), fill=int(255 * (x - 11) / 7))
    for x in range(110, 117):
        mask_draw.line((x, 0, x, MOSS_H - 1), fill=int(255 * (116 - x) / 7))
    image.putalpha(ImageChops.multiply(alpha, mask))
    return image




def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Compose intermediate face, frame and moss layers in memory; do not export them separately.
    faces: dict[str, Image.Image] = {}
    frames: dict[str, Image.Image] = {}
    mosses: dict[str, Image.Image] = {}
    for state, palette in PALETTES.items():
        faces[state] = draw_surface(state, palette)
        frames[state] = draw_frame(state, palette)
        mosses[state] = draw_moss_strip(palette, brighter=(state == "hover"))


    # Preserve the existing Godot-facing paths, composing each state from the layers.
    state_files = {
        "button_primary.png": "primary",
        "button_secondary.png": "secondary",
        "button_hover.png": "hover",
        "button_pressed.png": "pressed",
    }
    for filename, state in state_files.items():
        composite = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        composite = Image.alpha_composite(composite, faces[state])
        composite = Image.alpha_composite(composite, frames[state])
        # The moss covers the upper rail but tapers away from its carved corner scrolls.
        composite.alpha_composite(mosses[state], (0, 0))
        path = OUT_DIR / filename
        composite.save(path, optimize=True)
        print(f"Generated composite {path.relative_to(PROJECT_DIR)}")

    print("Far a Way UI button textures generated.")


if __name__ == "__main__":
    main()
