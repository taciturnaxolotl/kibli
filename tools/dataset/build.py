"""Builds a per-square training set for occupancy and piece classifiers.

Every source is turned into the same thing: the board warped flat with a8 at
the top-left, cut into 64 crops of one square plus a quarter-square margin,
grayscale, 32x32, each labelled with what stands on it.

Sources (any that are present are used):
  samples/datasets/chessred/chessred2k.zip + annotations.json
      ChessReD2K, phone photos at many angles with board corners
      (CC BY-NC-SA 4.0, research use only)
  samples/datasets/samryan18/labeled_preprocessed/*.png
      boards already warped flat, FEN in the file name (MIT)

usage: .venv/bin/python tools/dataset/build.py [--limit N]
writes samples/datasets/squares.npz with arrays
  crops  uint8 [N, 32, 32]
  label  int8  [N]  0 empty, 1..12 piece (see PIECES)
  source int8  [N]  index into SOURCES
  group  int32 [N]  board id, so train/test splits keep whole boards together
"""
import io, json, sys, zipfile
from pathlib import Path
import numpy as np
from PIL import Image
import cv2

ROOT = Path(__file__).resolve().parents[2] / "samples" / "datasets"
CROP = 32
MARGIN = 0.25
PIECES = ["empty", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]
SOURCES = ["chessred2k", "samryan18"]
WARP = 8 * 64  # flattened board size in pixels before cropping

limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None


def crops_from_flat(flat):
    """flat: grayscale board image, a8 top-left, WARP x WARP plus margin padding."""
    sq = WARP // 8
    pad = int(sq * MARGIN)
    out = np.zeros((64, CROP, CROP), np.uint8)
    for rank in range(8):
        for file in range(8):
            row = (7 - rank) * sq + pad
            col = file * sq + pad
            patch = flat[row - pad: row + sq + pad, col - pad: col + sq + pad]
            out[rank * 8 + file] = cv2.resize(patch, (CROP, CROP), interpolation=cv2.INTER_AREA)
    return out


def warp(gray, a8, h8, h1, a1):
    sq = WARP // 8
    pad = int(sq * MARGIN)
    dst = np.float32([[pad, pad], [pad + WARP, pad], [pad + WARP, pad + WARP], [pad, pad + WARP]])
    H = cv2.getPerspectiveTransform(np.float32([a8, h8, h1, a1]), dst)
    return cv2.warpPerspective(gray, H, (WARP + 2 * pad, WARP + 2 * pad), borderMode=cv2.BORDER_REPLICATE)


def fen_labels(placement):
    labels = np.zeros(64, np.int8)
    for row, text in enumerate(placement.split("/")):
        file = 0
        for ch in text:
            if ch.isdigit():
                file += int(ch)
                continue
            labels[(7 - row) * 8 + file] = PIECES.index(ch)
            file += 1
    return labels


crops, labels, sources, groups = [], [], [], []
group = 0

# ChessReD2K.
zip_path = ROOT / "chessred" / "chessred2k.zip"
ann_path = ROOT / "chessred" / "annotations.json"
if zip_path.exists() and ann_path.exists() and zip_path.stat().st_size == 4680150747:
    ann = json.load(open(ann_path))
    images = {im["id"]: im for im in ann["images"]}
    categories = {c["id"]: c["name"] for c in ann["categories"]}
    name_to_label = {
        "white-pawn": "P", "white-knight": "N", "white-bishop": "B", "white-rook": "R", "white-queen": "Q", "white-king": "K",
        "black-pawn": "p", "black-knight": "n", "black-bishop": "b", "black-rook": "r", "black-queen": "q", "black-king": "k",
    }
    pieces_by_image = {}
    for p in ann["annotations"]["pieces"]:
        pieces_by_image.setdefault(p["image_id"], []).append(p)
    with zipfile.ZipFile(zip_path) as zf:
        members = {Path(n).name: n for n in zf.namelist() if n.lower().endswith(".jpg")}
        corner_records = ann["annotations"]["corners"][:limit] if limit else ann["annotations"]["corners"]
        for i, rec in enumerate(corner_records):
            im = images[rec["image_id"]]
            member = members.get(im["file_name"])
            if member is None:
                continue
            gray = np.array(Image.open(io.BytesIO(zf.read(member))).convert("L"))
            c = rec["corners"]
            # Corners are named from white's side: top-left is a8.
            flat = warp(gray, c["top_left"], c["top_right"], c["bottom_right"], c["bottom_left"])
            lab = np.zeros(64, np.int8)
            for p in pieces_by_image.get(im["id"], []):
                pos = p["chessboard_position"]
                lab[(int(pos[1]) - 1) * 8 + ord(pos[0]) - 97] = PIECES.index(name_to_label[categories[p["category_id"]]])
            crops.append(crops_from_flat(flat))
            labels.append(lab)
            sources.append(np.full(64, 0, np.int8))
            groups.append(np.full(64, group, np.int32))
            group += 1
            if i % 200 == 0:
                print(f"chessred2k {i}/{len(corner_records)}", flush=True)

# samryan18: already flat, a8 top-left, FEN ranks separated by dashes.
for i, path in enumerate(sorted((ROOT / "samryan18" / "labeled_preprocessed").glob("*.png"))):
    if limit and i >= limit:
        break
    gray = np.array(Image.open(path).convert("L"))
    sq = WARP // 8
    pad = int(sq * MARGIN)
    board = cv2.resize(gray, (WARP, WARP), interpolation=cv2.INTER_AREA)
    flat = cv2.copyMakeBorder(board, pad, pad, pad, pad, cv2.BORDER_REPLICATE)
    crops.append(crops_from_flat(flat))
    labels.append(fen_labels(path.stem.split("_")[0].replace("-", "/")))
    sources.append(np.full(64, 1, np.int8))
    groups.append(np.full(64, group, np.int32))
    group += 1

crops = np.concatenate(crops)
labels = np.concatenate(labels)
sources = np.concatenate(sources)
groups = np.concatenate(groups)
np.savez_compressed(ROOT / "squares.npz", crops=crops, label=labels, source=sources, group=groups)
for s, name in enumerate(SOURCES):
    mask = sources == s
    print(f"{name}: {mask.sum() // 64} boards, {mask.sum()} squares, {(labels[mask] > 0).mean():.0%} occupied")
