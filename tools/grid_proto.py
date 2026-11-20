"""Prototype of the top-down checkerboard grid finder.

In the app the camera image is rectified onto the ARKit table plane, so the
board appears as a square grid with unknown rotation, scale and offset only.
Here we fake that rectification from hand-picked rim corners, then throw away
everything we know about the board (random rotation and offset, wide window
including rim, table, hands) and see whether the finder recovers the playing
area.
"""
import sys
import numpy as np
import cv2

MM_PER_PX = 2.0
WINDOW_MM = 1000.0
RIM_MM = 420.0  # assumed outer rim size, only used to fake the plane

# Outer rim corners on the 1050x1400 working images: left, far, right, near.
CORNERS = {
    "IMG_1329": [(112, 822), (432, 658), (848, 730), (580, 1055)],
    "IMG_1330": [(128, 810), (465, 630), (850, 735), (608, 1045)],
    "IMG_1332": [(128, 805), (460, 635), (822, 730), (560, 1035)],
    "IMG_1333": [(115, 765), (405, 580), (815, 655), (605, 970)],
    "IMG_1334": [(130, 825), (425, 612), (782, 708), (555, 1050)],
}


def fake_rectify(gray, corners, rot_deg, offset_mm):
    """World mm (board rim centered at origin) -> top-down image."""
    h = RIM_MM / 2
    world = np.float32([[-h, -h], [h, -h], [h, h], [-h, h]])
    img_to_world = cv2.getPerspectiveTransform(np.float32(corners), world)
    n = int(WINDOW_MM / MM_PER_PX)
    c, s = np.cos(np.radians(rot_deg)), np.sin(np.radians(rot_deg))
    # top-down px -> world mm: rotate, scale, translate
    td_to_world = np.array([
        [c * MM_PER_PX, -s * MM_PER_PX, 0],
        [s * MM_PER_PX, c * MM_PER_PX, 0],
        [0, 0, 1],
    ])
    centre = np.array([n / 2, n / 2, 1])
    t = td_to_world @ centre
    td_to_world[0, 2] = offset_mm[0] - t[0]
    td_to_world[1, 2] = offset_mm[1] - t[1]
    world_to_img = np.linalg.inv(img_to_world)
    td_to_img = world_to_img @ td_to_world
    out = cv2.warpPerspective(gray, td_to_img, (n, n), flags=cv2.WARP_INVERSE_MAP | cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_CONSTANT, borderValue=-1)
    return out, td_to_world


def find_grid(img, valid):
    """Returns (theta, period_px, origin_xy_px) of the best 8x8 checker window."""
    g = img.astype(np.float32)
    g = np.where(valid, g, np.nan)
    fill = np.nanmean(g)
    g0 = np.where(valid, g, fill)

    gx = cv2.Sobel(g0, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(g0, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.hypot(gx, gy) * valid
    ang = np.arctan2(gy, gx)
    z = np.sum(mag * np.exp(4j * ang))
    theta0 = np.angle(z) / 4

    best = None
    for dtheta in np.radians(np.arange(-4, 4.01, 1.0)):
        theta = theta0 + dtheta
        res = score_at_angle(g0, valid, theta)
        if res and (best is None or res[0] > best[0]):
            best = (res[0], theta) + res[1:]
    return best


def rotate(img, theta, border):
    n = img.shape[0]
    m = cv2.getRotationMatrix2D((n / 2, n / 2), np.degrees(theta), 1.0)
    return cv2.warpAffine(img, m, (n, n), flags=cv2.INTER_LINEAR, borderValue=border), m


def score_at_angle(g0, valid, theta):
    r, m = rotate(g0, theta, float(np.mean(g0)))
    v, _ = rotate(valid.astype(np.float32), theta, 0)
    v = v > 0.99
    gx = np.abs(cv2.Sobel(r, cv2.CV_32F, 1, 0, ksize=3)) * v
    gy = np.abs(cv2.Sobel(r, cv2.CV_32F, 0, 1, ksize=3)) * v
    px = gx.sum(axis=0)
    py = gy.sum(axis=1)
    px = px - cv2.blur(px.reshape(1, -1), (31, 1)).ravel()
    py = py - cv2.blur(py.reshape(1, -1), (31, 1)).ravel()

    def acf(sig):
        sig = sig - sig.mean()
        f = np.fft.rfft(sig, n=2 * len(sig))
        a = np.fft.irfft(f * np.conj(f))[: len(sig)]
        return a / a[0]

    a = acf(px) + acf(py)
    lo, hi = int(22 / MM_PER_PX), int(70 / MM_PER_PX)
    lags = np.arange(lo, hi)
    period0 = lags[np.argmax(a[lo:hi])]

    ii = cv2.integral(r * v)
    iv = cv2.integral(v.astype(np.float32))
    best = None
    for period in np.arange(period0 - 1.5, period0 + 1.51, 0.5):
        for ox in np.arange(0, period, 2.0):
            for oy in np.arange(0, period, 2.0):
                s = window_score(ii, iv, period, ox, oy, r.shape[0])
                if s and (best is None or s[0] > best[0]):
                    best = (s[0], period, ox + s[1] * period, oy + s[2] * period, m)
    return best


def window_score(ii, iv, p, ox, oy, n):
    nx = int((n - ox) // p)
    ny = int((n - oy) // p)
    if nx < 8 or ny < 8:
        return None
    xs = ox + np.arange(nx + 1) * p
    ys = oy + np.arange(ny + 1) * p
    inset = 0.2 * p
    x0 = np.round(xs[:-1] + inset).astype(int)
    x1 = np.round(xs[1:] - inset).astype(int)
    y0 = np.round(ys[:-1] + inset).astype(int)
    y1 = np.round(ys[1:] - inset).astype(int)
    S = ii[y1[:, None], x1[None, :]] - ii[y0[:, None], x1[None, :]] - ii[y1[:, None], x0[None, :]] + ii[y0[:, None], x0[None, :]]
    C = iv[y1[:, None], x1[None, :]] - iv[y0[:, None], x1[None, :]] - iv[y1[:, None], x0[None, :]] + iv[y0[:, None], x0[None, :]]
    area = (x1 - x0)[None, :] * (y1 - y0)[:, None]
    ok = C > 0.7 * area
    mean = np.where(ok, S / np.maximum(C, 1), np.nan)

    # Neighbour contrasts; on a checkerboard they alternate in sign.
    dh = mean[:, 1:] - mean[:, :-1]
    dv = mean[1:, :] - mean[:-1, :]
    thr = 12.0
    # parity sign: +1 if cell (r, c) should be lighter than its right/below neighbour
    rr, cc = np.mgrid[0:ny, 0:nx]
    par = np.where((rr + cc) % 2 == 0, 1.0, -1.0)
    hv = np.nan_to_num(np.sign(-dh) * (np.abs(dh) > thr)) * par[:, :-1]
    vv = np.nan_to_num(np.sign(-dv) * (np.abs(dv) > thr)) * par[:-1, :]

    best = None
    for polarity in (1, -1):
        h = hv * polarity
        v = vv * polarity
        # 8x8 window: 8 rows x 7 horizontal pairs, 7 rows x 8 vertical pairs
        Hc = cv2.integral(h.astype(np.float32))
        Vc = cv2.integral(v.astype(np.float32))
        for r0 in range(ny - 7):
            for c0 in range(nx - 7):
                sh = Hc[r0 + 8, c0 + 7] - Hc[r0, c0 + 7] - Hc[r0 + 8, c0] + Hc[r0, c0]
                sv = Vc[r0 + 7, c0 + 8] - Vc[r0, c0 + 8] - Vc[r0 + 7, c0] + Vc[r0, c0]
                s = sh + sv
                if best is None or s > best[0]:
                    best = (s, c0, r0)
    return best


def homography_from_corners(corners):
    unit = np.float32([[0, 0], [8, 0], [8, 8], [0, 8]])
    return cv2.getPerspectiveTransform(unit, np.float32(corners))


def edge_samples():
    """Board-unit sample points on interior lines, with normals and expected sign."""
    ts = np.linspace(0.15, 0.85, 6)
    pts, normals, signs = [], [], []
    for i in range(1, 8):
        for j in range(8):
            for t in ts:
                # vertical line x=i, between cells (i-1, j) and (i, j)
                pts.append((i, j + t)); normals.append((1, 0)); signs.append(1 if (i + j) % 2 else -1)
                # horizontal line y=i, between cells (j, i-1) and (j, i)
                pts.append((j + t, i)); normals.append((0, 1)); signs.append(1 if (i + j) % 2 else -1)
    return np.float32(pts), np.float32(normals), np.float32(signs)


EDGE_PTS, EDGE_N, EDGE_SIGN = edge_samples()


def edge_score(img, corners, polarity, delta=0.08):
    H = homography_from_corners(corners)
    a = cv2.perspectiveTransform((EDGE_PTS + EDGE_N * delta)[None], H)[0]
    b = cv2.perspectiveTransform((EDGE_PTS - EDGE_N * delta)[None], H)[0]
    va = cv2.remap(img, a[:, 0:1].copy(), a[:, 1:2].copy(), cv2.INTER_LINEAR).ravel()
    vb = cv2.remap(img, b[:, 0:1].copy(), b[:, 1:2].copy(), cv2.INTER_LINEAR).ravel()
    d = np.clip(va - vb, -40, 40)
    return float(np.sum(d * EDGE_SIGN * polarity))


def refine(img, corners):
    corners = np.float32(corners).copy()
    pol = 1 if edge_score(img, corners, 1) > 0 else -1
    best = edge_score(img, corners, pol)
    for step in (4.0, 2.0, 1.0, 0.5, 0.25):
        improved = True
        while improved:
            improved = False
            for k in range(4):
                for axis in range(2):
                    for sgn in (1, -1):
                        trial = corners.copy()
                        trial[k, axis] += sgn * step
                        s = edge_score(img, trial, pol)
                        if s > best:
                            best, corners, improved = s, trial, True
    return corners, best, pol


def main(names):
    rng = np.random.default_rng(7)
    for name in names:
        bgr = cv2.imread(f"samples/{name}_w.jpg")
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
        for trial in range(3):
            rot = rng.uniform(-45, 45)
            off = rng.uniform(-150, 150, size=2)
            td, td_to_world = fake_rectify(gray, CORNERS[name], rot, off)
            valid = td >= 0
            res = find_grid(td, valid)
            score, theta, p, ox, oy, m = res
            # board corners in rotated frame -> top-down -> world
            minv = cv2.invertAffineTransform(m)
            pts = np.array([[ox, oy], [ox + 8 * p, oy], [ox + 8 * p, oy + 8 * p], [ox, oy + 8 * p]])
            td_pts = (minv[:, :2] @ pts.T).T + minv[:, 2]
            coarse = edge_score(td.astype(np.float32), td_pts, 1)
            td_pts, es, pol = refine(np.where(valid, td, np.nan_to_num(np.nanmean(np.where(valid, td, np.nan)))).astype(np.float32), td_pts)
            p = np.mean([np.linalg.norm(td_pts[(k + 1) % 4] - td_pts[k]) for k in range(4)]) / 8
            w = (td_to_world @ np.c_[td_pts, np.ones(4)].T).T[:, :2]
            centre = w.mean(axis=0)
            side = 8 * p * MM_PER_PX
            print(f"{name} t{trial} edge {abs(coarse):6.0f}->{es:6.0f} score={score:5.0f}/112 side={side:5.1f}mm centre=({centre[0]:+5.1f},{centre[1]:+5.1f})")
            vis = cv2.cvtColor(np.clip(td, 0, 255).astype(np.uint8), cv2.COLOR_GRAY2BGR)
            H = homography_from_corners(td_pts)
            for i in range(9):
                for a, b in [((i, 0), (i, 8)), ((0, i), (8, i))]:
                    q = cv2.perspectiveTransform(np.float32([[a, b]]), H)[0]
                    cv2.line(vis, tuple(map(int, q[0])), tuple(map(int, q[1])), (0, 0, 255), 1)
            cv2.imwrite(f"/tmp/grid_{name}_{trial}.jpg", vis, [cv2.IMWRITE_JPEG_QUALITY, 70])


if __name__ == "__main__":
    main(sys.argv[1:] or list(CORNERS))


def dump(out_dir="/tmp/kibli_td"):
    """Writes fake top-down views for the Swift port's test harness."""
    import os
    os.makedirs(out_dir, exist_ok=True)
    rng = np.random.default_rng(11)
    for name in CORNERS:
        gray = cv2.cvtColor(cv2.imread(f"samples/{name}_w.jpg"), cv2.COLOR_BGR2GRAY).astype(np.float32)
        for trial in range(2):
            td, _ = fake_rectify(gray, CORNERS[name], rng.uniform(-45, 45), rng.uniform(-150, 150, size=2))
            td.astype(np.float32).tofile(f"{out_dir}/{name}_{trial}.f32")
