#!/usr/bin/env python3
"""Turn an SVG into a Stamp JSON entry.

Output matches gui_stamp.lua:
  [ { "name": "...", "strokes": [ [ [x, 0, z], ... ], ... ] } ]

x/z are offsets from the drawing center, in BAR world units.
SVG y grows downward and is mapped to world z.

Usage:
  python svg_to_stamp.py art.svg -o stamp.json --width 800
  python svg_to_stamp.py art.svg --merge LuaUI/Config/gui_stamps.json --width 500

--width is the stamp width in world units. Height follows the SVG aspect ratio.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def num(value: str | None, default: float = 0.0) -> float:
    if not value:
        return default
    m = re.match(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", value.strip())
    return float(m.group(0)) if m else default


def tokenize(d: str) -> list[str]:
    return re.findall(r"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?", d or "")


def cubic(p0, p1, p2, p3, steps: int) -> list[tuple[float, float]]:
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        x = u**3 * p0[0] + 3 * u**2 * t * p1[0] + 3 * u * t**2 * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u**2 * t * p1[1] + 3 * u * t**2 * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def quad(p0, p1, p2, steps: int) -> list[tuple[float, float]]:
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        x = u**2 * p0[0] + 2 * u * t * p1[0] + t**2 * p2[0]
        y = u**2 * p0[1] + 2 * u * t * p1[1] + t**2 * p2[1]
        pts.append((x, y))
    return pts


def arc(p0, rx, ry, phi_deg, large, sweep, p1, steps: int) -> list[tuple[float, float]]:
    """SVG elliptical arc (endpoint form) to points, per SVG spec F.6.5."""
    x1, y1 = p0
    x2, y2 = p1
    if (x1, y1) == (x2, y2):
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return [(x2, y2)]
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cp * dx + sp * dy
    y1p = -sp * dx + cp * dy
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    num_ = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(max(num_ / den, 0)) if den else 0
    if bool(large) == bool(sweep):
        coef = -coef
    cxp = coef * rx * y1p / ry
    cyp = -coef * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2

    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    n = max(2, int(math.ceil(steps * abs(dt) / (math.pi / 2))))
    pts = []
    for i in range(1, n + 1):
        t = t1 + dt * i / n
        ex, ey = rx * math.cos(t), ry * math.sin(t)
        pts.append((cp * ex - sp * ey + cx, sp * ex + cp * ey + cy))
    pts[-1] = (x2, y2)
    return pts


def rdp(points: list[tuple[float, float]], tol: float) -> list[tuple[float, float]]:
    """Ramer-Douglas-Peucker simplification (iterative)."""
    n = len(points)
    if n <= 2 or tol <= 0:
        return points
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    tol_sq = tol * tol
    while stack:
        first, last = stack.pop()
        ax, ay = points[first]
        bx, by = points[last]
        dx, dy = bx - ax, by - ay
        len_sq = dx * dx + dy * dy
        max_d, idx = -1.0, -1
        for i in range(first + 1, last):
            px, py = points[i][0] - ax, points[i][1] - ay
            if len_sq == 0:
                d = px * px + py * py
            else:
                t = max(0.0, min(1.0, (px * dx + py * dy) / len_sq))
                ex, ey = px - t * dx, py - t * dy
                d = ex * ex + ey * ey
            if d > max_d:
                max_d, idx = d, i
        if idx >= 0 and max_d > tol_sq:
            keep[idx] = True
            stack.append((first, idx))
            stack.append((idx, last))
    return [p for p, k in zip(points, keep) if k]


def flatten_path(d: str, curve_steps: int) -> list[list[tuple[float, float]]]:
    tokens = tokenize(d)
    i = 0
    cx = cy = 0.0
    sx = sy = 0.0
    cmd = ""
    prev_cubic = None
    prev_quad = None
    strokes: list[list[tuple[float, float]]] = []
    cur: list[tuple[float, float]] = []

    def take(n: int) -> list[float]:
        nonlocal i
        vals = [float(tokens[i + k]) for k in range(n)]
        i += n
        return vals

    def start(x: float, y: float) -> None:
        nonlocal cur
        if len(cur) >= 2:
            strokes.append(cur)
        cur = [(x, y)]

    while i < len(tokens):
        tok = tokens[i]
        if re.match(r"[A-Za-z]", tok):
            cmd = tok
            i += 1
            if cmd in "Zz" and cur:
                cur.append((sx, sy))
                strokes.append(cur)
                cur = []
                cx, cy = sx, sy
            continue
        if cmd in "Mm":
            x, y = take(2)
            if cmd == "m":
                x, y = cx + x, cy + y
            start(x, y)
            cx, cy = sx, sy = x, y
            cmd = "L" if cmd == "M" else "l"
            prev_cubic = prev_quad = None
        elif cmd in "Ll":
            x, y = take(2)
            if cmd == "l":
                x, y = cx + x, cy + y
            cur.append((x, y))
            cx, cy = x, y
            prev_cubic = prev_quad = None
        elif cmd in "Hh":
            x = take(1)[0]
            if cmd == "h":
                x += cx
            cur.append((x, cy))
            cx = x
            prev_cubic = prev_quad = None
        elif cmd in "Vv":
            y = take(1)[0]
            if cmd == "v":
                y += cy
            cur.append((cx, y))
            cy = y
            prev_cubic = prev_quad = None
        elif cmd in "Cc":
            x1, y1, x2, y2, x, y = take(6)
            if cmd == "c":
                x1, y1, x2, y2, x, y = cx + x1, cy + y1, cx + x2, cy + y2, cx + x, cy + y
            cur.extend(cubic((cx, cy), (x1, y1), (x2, y2), (x, y), curve_steps))
            prev_cubic = (x2, y2)
            prev_quad = None
            cx, cy = x, y
        elif cmd in "Ss":
            x2, y2, x, y = take(4)
            if cmd == "s":
                x2, y2, x, y = cx + x2, cy + y2, cx + x, cy + y
            if prev_cubic:
                x1, y1 = 2 * cx - prev_cubic[0], 2 * cy - prev_cubic[1]
            else:
                x1, y1 = cx, cy
            cur.extend(cubic((cx, cy), (x1, y1), (x2, y2), (x, y), curve_steps))
            prev_cubic = (x2, y2)
            prev_quad = None
            cx, cy = x, y
        elif cmd in "Qq":
            x1, y1, x, y = take(4)
            if cmd == "q":
                x1, y1, x, y = cx + x1, cy + y1, cx + x, cy + y
            cur.extend(quad((cx, cy), (x1, y1), (x, y), curve_steps))
            prev_quad = (x1, y1)
            prev_cubic = None
            cx, cy = x, y
        elif cmd in "Tt":
            x, y = take(2)
            if cmd == "t":
                x, y = cx + x, cy + y
            if prev_quad:
                x1, y1 = 2 * cx - prev_quad[0], 2 * cy - prev_quad[1]
            else:
                x1, y1 = cx, cy
            cur.extend(quad((cx, cy), (x1, y1), (x, y), curve_steps))
            prev_quad = (x1, y1)
            prev_cubic = None
            cx, cy = x, y
        elif cmd in "Aa":
            rx, ry, ang, large, sweep, x, y = take(7)
            if cmd == "a":
                x, y = cx + x, cy + y
            cur.extend(arc((cx, cy), rx, ry, ang, large, sweep, (x, y), curve_steps))
            prev_cubic = prev_quad = None
            cx, cy = x, y
        else:
            i += 1
    if len(cur) >= 2:
        strokes.append(cur)
    return strokes


def pairs(text: str) -> list[tuple[float, float]]:
    vals = [float(v) for v in re.findall(r"[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?", text or "")]
    return [(vals[i], vals[i + 1]) for i in range(0, len(vals) - 1, 2)]


def circle(cx: float, cy: float, r: float, steps: int) -> list[tuple[float, float]]:
    return [
        (cx + r * math.cos(2 * math.pi * i / steps), cy + r * math.sin(2 * math.pi * i / steps))
        for i in range(steps + 1)
    ]


def collect(elem: ET.Element, curve_steps: int, include_rects: bool) -> list[list[tuple[float, float]]]:
    skip = {"defs", "clipPath", "mask", "symbol", "marker", "pattern", "metadata"}
    hidden: set[int] = set()
    for node in elem.iter():
        if local(node.tag) in skip:
            for child in node.iter():
                hidden.add(id(child))
    strokes: list[list[tuple[float, float]]] = []
    for node in elem.iter():
        if id(node) in hidden:
            continue
        tag = local(node.tag)
        if tag == "path":
            strokes.extend(flatten_path(node.get("d", ""), curve_steps))
        elif tag == "polyline":
            pts = pairs(node.get("points", ""))
            if len(pts) >= 2:
                strokes.append(pts)
        elif tag == "polygon":
            pts = pairs(node.get("points", ""))
            if len(pts) >= 2:
                strokes.append(pts + [pts[0]])
        elif tag == "line":
            strokes.append([
                (num(node.get("x1")), num(node.get("y1"))),
                (num(node.get("x2")), num(node.get("y2"))),
            ])
        elif tag == "rect" and include_rects:
            x, y = num(node.get("x")), num(node.get("y"))
            w, h = num(node.get("width")), num(node.get("height"))
            strokes.append([(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)])
        elif tag == "circle":
            strokes.append(circle(num(node.get("cx")), num(node.get("cy")), num(node.get("r")), curve_steps * 2))
        elif tag == "ellipse":
            cx, cy = num(node.get("cx")), num(node.get("cy"))
            rx, ry = num(node.get("rx")), num(node.get("ry"))
            strokes.append([
                (cx + rx * math.cos(2 * math.pi * i / (curve_steps * 2)),
                 cy + ry * math.sin(2 * math.pi * i / (curve_steps * 2)))
                for i in range((curve_steps * 2) + 1)
            ])
    strokes = [s for s in strokes if len(s) >= 2 and len({(round(p[0], 2), round(p[1], 2)) for p in s}) >= 2]
    if len(strokes) < 2:
        return strokes
    xs = [p[0] for s in strokes for p in s]
    ys = [p[1] for s in strokes for p in s]
    span = max(max(xs) - min(xs), max(ys) - min(ys), 1.0)
    kept = []
    for s in strokes:
        sx = [p[0] for p in s]
        sy = [p[1] for p in s]
        w = max(sx) - min(sx)
        h = max(sy) - min(sy)
        near_origin = max(abs(p[0]) for p in s) < span * 0.02 and max(abs(p[1]) for p in s) < span * 0.02
        if near_origin and w < span * 0.05 and h < span * 0.05:
            continue
        kept.append(s)
    return kept or strokes


def to_blueprint(strokes: list[list[tuple[float, float]]], name: str, width: float, tolerance: float) -> dict:
    xs = [p[0] for s in strokes for p in s]
    ys = [p[1] for s in strokes for p in s]
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    span = max(maxx - minx, 1e-6)
    scale = width / span
    cx = (minx + maxx) / 2
    cy = (miny + maxy) / 2
    out = []
    for stroke in strokes:
        world = [((x - cx) * scale, (y - cy) * scale) for x, y in stroke]
        world = rdp(world, tolerance)  # tolerance is in world units
        out.append([[round(x, 2), 0, round(z, 2)] for x, z in world])
    return {"name": name, "strokes": out}


def main() -> None:
    ap = argparse.ArgumentParser(description="Convert an SVG into a Stamp JSON entry")
    ap.add_argument("svg")
    ap.add_argument("-o", "--output", help="write a one-stamp JSON file")
    ap.add_argument("--merge", help="append into an existing stamp.json")
    ap.add_argument("--name", help="stamp name (default: svg filename)")
    ap.add_argument("--width", type=float, default=600, help="stamp width in BAR world units")
    ap.add_argument("--curve-steps", type=int, default=32, help="samples per curve before simplification")
    ap.add_argument("--tolerance", type=float, default=2.0,
                    help="max deviation in world units when simplifying (lower = more detail, more marks)")
    ap.add_argument("--include-rects", action="store_true", help="also trace <rect> elements; these are often bounding boxes")
    args = ap.parse_args()

    svg_path = Path(args.svg)
    root = ET.parse(svg_path).getroot()
    strokes = collect(root, args.curve_steps, args.include_rects)
    if not strokes:
        raise SystemExit("no drawable path/line/rect/circle geometry found")
    bp = to_blueprint(strokes, args.name or svg_path.stem, args.width, args.tolerance)
    segs = sum(max(len(s) - 1, 0) for s in bp["strokes"])
    print(f"{segs} line segments after simplification", file=__import__("sys").stderr)

    if args.merge:
        dest = Path(args.merge)
        data = json.loads(dest.read_text(encoding="utf-8")) if dest.exists() and dest.stat().st_size else []
        if not isinstance(data, list):
            raise SystemExit("merge target is not a JSON list")
        data.append(bp)
        dest.write_text(json.dumps(data), encoding="utf-8")
        print(f"appended '{bp['name']}' ({len(bp['strokes'])} strokes) to {dest}")
    else:
        text = json.dumps([bp])
        if args.output:
            Path(args.output).write_text(text, encoding="utf-8")
            print(f"wrote {args.output}: {len(bp['strokes'])} strokes, width {args.width}")
        else:
            print(text)


if __name__ == "__main__":
    main()
