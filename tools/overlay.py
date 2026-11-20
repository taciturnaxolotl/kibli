"""Draws the saved board pose (grid) onto each capture's frame, to see
whether the locked board actually sits on the real one.
usage: .venv/bin/python tools/overlay.py [capture dirs...]"""
import json, sys, math
import numpy as np
from PIL import Image, ImageDraw

def project(m, world):
    K = np.array(m["intrinsics"]).reshape(3, 3)
    T = np.array(m["cameraTransform"]).reshape(4, 4).T  # stored column-major
    p = np.linalg.inv(T) @ np.append(world, 1)
    if -p[2] <= 0.01: return None
    return (K[0, 2] + K[0, 0] * p[0] / -p[2], K[1, 2] - K[1, 1] * p[1] / -p[2])

for d in sys.argv[1:]:
    m = json.load(open(f"{d}/meta.json"))
    img = Image.open(f"{d}/frame.jpg").convert("RGB")
    draw = ImageDraw.Draw(img)
    b = m.get("board")
    if b:
        yaw = b["yaw"] + b["quarterTurns"] * math.pi / 2
        c, s, side = math.cos(yaw), math.sin(yaw), b["side"]
        R = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
        center = np.array(b["center"])
        def world(x, z): return center + R @ np.array([x, 0, z])
        for i in range(9):
            t = -side / 2 + i * side / 8
            for a, bb in [((t, -side / 2), (t, side / 2)), ((-side / 2, t), (side / 2, t))]:
                p, q = project(m, world(*a)), project(m, world(*bb))
                if p and q: draw.line([p, q], fill=(0, 255, 255), width=3)
        a1 = project(m, world(-side / 2 + side / 16, side / 2 - side / 16))
        if a1: draw.ellipse([a1[0] - 10, a1[1] - 10, a1[0] + 10, a1[1] + 10], fill=(255, 0, 0))
        if m.get("tablePlaneY") is not None:
            draw.text((20, 20), f"surface {100 * (b['center'][1] - m['tablePlaneY']):.1f}cm above table", fill=(255, 255, 0))
    if b:
        pts = [project(m, world(x, z)) for x in (-side, side) for z in (-side, side)]
        pts = [p for p in pts if p]
        if pts:
            xs, ys = [p[0] for p in pts], [p[1] for p in pts]
            img = img.crop((max(min(xs), 0), max(min(ys), 0), min(max(xs), img.width), min(max(ys), img.height)))
    img.thumbnail((700, 700))
    img.save(f"/tmp/ov_{d.rstrip('/').split('/')[-1]}.jpg", quality=70)
