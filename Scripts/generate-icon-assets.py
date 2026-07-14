#!/usr/bin/env python3
"""Regenerate the AppIcon.icon SVG layers for the "Press" mark.

The mark is an install arrow pressing a shallow dish into a puck — the
parametric geometry mirrors the winning prototype in
``Store/icon-prototypes.html`` (concept id ``press``), in the same 1024-point
Icon Composer canvas. Two layers are emitted so the glass treatment can be
tuned per element in Icon Composer:

- ``disk.svg``  — the drive body, one solid sheet
- ``band.svg``  — the bottom band, a solid sheet overlapping the body's foot
  (the glass boundary between the sheets draws the seam)
- ``dot.svg``   — the status light, on the band's vertical middle
- ``arrow.svg`` — the install arrow, its stroke-rounded corners pre-flattened

Strokes are pre-flattened to filled outlines (``shapely.buffer``, round
joins) because Icon Composer mangles stroked paths. Colors are explicit —
Icon Composer's translucency/glass are expected to do the lighting work.

Run from the repo root after changing the geometry:

    python3 Scripts/generate-icon-assets.py
"""

import math
from pathlib import Path

from shapely.geometry import Polygon
from shapely.ops import unary_union

VB = 1024
C = VB / 2

ASSETS = Path(__file__).resolve().parent.parent / "Rilmazafone" / "Resources" / "AppIcon.icon" / "Assets"

# Mixed values carry the energy: the slab is white — the color every mounted
# disk image wears on macOS, the recognition hook — and the arrow is dark
# berry ink (hue family of the background) doing the pressing.
SLAB_FILL = "#ffffff"
ARROW_FILL = "#3d0a24"
DOT_FILL = "#3d0a24"

# Rounding radius applied to the arrow's corners (half the prototype's
# 30 px stroke, which drew the same rounding on screen).
ARROW_ROUND = 15.0


def superellipse(cx, cy, a, b, n, steps=240):
    """|x/a|^n + |y/b|^n = 1 sampled as a point list."""
    pts = []
    for i in range(steps):
        t = (i / steps) * math.tau
        co, si = math.cos(t), math.sin(t)
        pts.append((
            cx + a * math.copysign(abs(co) ** (2 / n), co),
            cy + b * math.copysign(abs(si) ** (2 / n), si),
        ))
    return Polygon(pts)


def path_d(geom):
    """Serialize a polygon or multipolygon (with holes) to an SVG path."""
    def ring(coords):
        return "M" + "L".join(f"{x:.2f} {y:.2f}" for x, y in coords) + "Z"

    parts = geom.geoms if geom.geom_type == "MultiPolygon" else [geom]
    return "".join(
        ring(p.exterior.coords) + "".join(ring(i.coords) for i in p.interiors)
        for p in parts
    )


def svg(paths):
    body = "\n  ".join(
        f'<path d="{path_d(geom)}" fill="{fill}" fill-rule="evenodd"/>'
        for geom, fill in paths
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {VB} {VB}">\n'
        f"  {body}\n</svg>\n"
    )


# --- the arrow --------------------------------------------------------------

shaft = Polygon([(C - 58, 122), (C + 58, 122), (C + 58, 338), (C - 58, 338)])
head = Polygon([(C - 156, 338), (C + 156, 338), (C, 566)])
arrow = unary_union([shaft, head]).buffer(ARROW_ROUND, join_style="round")

# --- the drive --------------------------------------------------------------
# Flat and front-facing (Liquid Glass views elements from the top — no
# perspective ellipses): the portrait rounded body of Apple's external-drive /
# mounted-volume icon. Every element is a SOLID sheet — no cutouts. Liquid
# Glass composes stacked sheets and renders the boundaries itself: the band
# overlapping the body's foot draws the seam, the light sits on the band,
# the arrow lies over the body's top.

body = superellipse(C, 618, 254, 272, 4.5)   # spans y 346…890
SEAM_Y = 772                                  # band = seam…bottom, ≈118 pt tall
BAND_MID = (SEAM_Y + 890) / 2

band_half = Polygon([(C - 300, SEAM_Y), (C + 300, SEAM_Y),
                     (C + 300, 900), (C - 300, 900)])
band = body.intersection(band_half)
dot = superellipse(C + 254 - 58, BAND_MID, 18, 18, 2)

# --- emit -------------------------------------------------------------------

ASSETS.mkdir(parents=True, exist_ok=True)
(ASSETS / "disk.svg").write_text(svg([(body, SLAB_FILL)]))
(ASSETS / "band.svg").write_text(svg([(band, SLAB_FILL)]))
(ASSETS / "dot.svg").write_text(svg([(dot, DOT_FILL)]))
(ASSETS / "arrow.svg").write_text(svg([(arrow, ARROW_FILL)]))
for name in ("disk.svg", "band.svg", "dot.svg", "arrow.svg"):
    print(f"wrote {ASSETS / name}")
