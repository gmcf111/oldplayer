#!/usr/bin/env python3
"""
gen_icons.py — render the app icon into the PNG sizes iOS 6-9 expect.

iOS 6/7 (pre-asset-catalog) icons live as flat files in the app bundle,
declared in Info.plist via CFBundleIconFiles. Required sizes for
iPhone/iPad (non-Retina + Retina @2x):

  Icon.png            57x57    (iPhone)
  Icon@2x.png        114x114   (iPhone Retina)
  Icon-72.png         72x72    (iPad)
  Icon-72@2x.png     144x144   (iPad Retina)

The rendering is a dependency-light re-implementation of Resources/icon.svg:
a blue rounded square plus a bold white play triangle drawn with Pillow.
CI runs this same script (Pillow is installed there), so the icons are
reproducible without checking binaries into the repo.

Usage: python3 tools/gen_icons.py <output_dir>
"""

import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.stderr.write("gen_icons: Pillow is required (pip install pillow)\n")
    sys.exit(1)

BLUE = (31, 111, 214, 255)     # #1F6FD6
WHITE = (255, 255, 255, 255)

# (filename, pixel size)
ICONS = [
    ("Icon.png", 57),
    ("Icon@2x.png", 114),
    ("Icon-72.png", 72),
    ("Icon-72@2x.png", 144),
    ("Icon-60@2x.png", 120),    # iOS 7+ spot if the app runs on newer devices
    ("Icon-76.png", 76),
    ("Icon-76@2x.png", 152),
]


def render(size):
    """Blue rounded square + white play triangle, supersampled for edges."""
    ss = 4  # supersample factor
    big = size * ss
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    radius = int(big * 0.1875)  # matches 96/512 in the SVG
    try:
        draw.rounded_rectangle([0, 0, big - 1, big - 1], radius=radius, fill=BLUE)
    except AttributeError:  # Pillow < 8.2 fallback
        draw.rectangle([0, 0, big - 1, big - 1], fill=BLUE)

    # Triangle points scaled from the 512x512 SVG viewBox.
    def s(v):
        return v / 512.0 * big

    draw.polygon(
        [(s(196), s(140)), (s(196), s(372)), (s(396), s(256))],
        fill=WHITE,
    )

    return img.resize((size, size), Image.LANCZOS)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "Resources"
    os.makedirs(outdir, exist_ok=True)
    for name, size in ICONS:
        path = os.path.join(outdir, name)
        render(size).save(path, "PNG")
        print("gen_icons: wrote %s (%dx%d)" % (path, size, size))


if __name__ == "__main__":
    main()
