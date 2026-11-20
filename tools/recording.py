"""Summarizes a blackbox recording and renders each saved frame with the
board pose the app believed at that moment drawn on top.

usage: .venv/bin/python tools/recording.py samples/recordings/<name> [--every N]

Writes <recording>/review/NNNNNN.jpg plus review.mp4 if ffmpeg is installed,
and prints a timeline of locks, relocks, misses and move reads."""
import json, math, shutil, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

root = Path(sys.argv[1])
every = int(sys.argv[sys.argv.index("--every") + 1]) if "--every" in sys.argv else 1
records = [json.loads(line) for line in open(root / "log.jsonl") if line.strip()]
start = records[0]["wall"]

def stamp(r): return f"{r['wall'] - start:6.1f}s"

# Timeline.
counts = {"found": 0, "missed": 0, "tracked": 0}
for r in records:
    k = r["kind"]
    if k == "detection":
        counts["found" if r["found"] else "missed"] += 1
        counts["tracked"] += r.get("tracked", False)
    elif k in ("lock", "relock", "user", "start", "stop", "state"):
        print(stamp(r), k, {key: v for key, v in r.items() if key not in ("kind", "wall", "t")})
    elif k == "moves" and r["event"] in ("moved", "unclear", "oriented"):
        extra = r.get("san") or r.get("turns") or ""
        print(stamp(r), "moves", r["event"], extra)
print("detections:", counts)

# Overlays.
out = root / "review"
out.mkdir(exist_ok=True)
pose = None
frames = 0
for r in records:
    if r["kind"] == "pose":
        pose = r
    if r["kind"] != "frame" or "image" not in r:
        continue
    frames += 1
    if frames % every:
        continue
    img = Image.open(root / r["image"]).convert("RGB")
    draw = ImageDraw.Draw(img)
    scale = r.get("imageScale", 1)
    K = np.array(r["intrinsics"]).reshape(3, 3) * np.array([[scale], [scale], [1]])
    T = np.array(r["camera"]).reshape(4, 4).T
    Tinv = np.linalg.inv(T)

    def project(world):
        p = Tinv @ np.append(world, 1)
        if -p[2] <= 0.01: return None
        return (K[0, 2] + K[0, 0] * p[0] / -p[2], K[1, 2] - K[1, 1] * p[1] / -p[2])

    if pose:
        yaw = pose["yaw"] + pose.get("quarterTurns", 0) * math.pi / 2
        c, s, side = math.cos(yaw), math.sin(yaw), pose["side"]
        R = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
        center = np.array(pose["center"])
        world = lambda x, z: center + R @ np.array([x, 0, z])
        for i in range(9):
            t = -side / 2 + i * side / 8
            for a, b in [((t, -side / 2), (t, side / 2)), ((-side / 2, t), (side / 2, t))]:
                p, q = project(world(*a)), project(world(*b))
                if p and q: draw.line([p, q], fill=(0, 255, 255), width=2)
        a1 = project(world(-side / 2 + side / 16, side / 2 - side / 16))
        if a1: draw.ellipse([a1[0] - 6, a1[1] - 6, a1[0] + 6, a1[1] + 6], fill=(255, 0, 0))
    draw.rectangle([0, 0, 260, 22], fill=(0, 0, 0))
    draw.text((6, 5), f"{stamp(r)}  {r['tracking']}", fill=(255, 255, 255))
    img.save(out / Path(r["image"]).name, quality=80)

print(f"wrote {frames // every} overlays to {out}")
if shutil.which("ffmpeg"):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(2 / every), "-pattern_type", "glob",
                    "-i", str(out / "*.jpg"), "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                    str(root / "review.mp4")], check=False)
    print("wrote", root / "review.mp4")
