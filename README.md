# kibli

arkit chess experiments

## building

```sh
xcodegen generate
xcodebuild -project Kibli.xcodeproj -scheme Kibli -destination 'id=<device udid>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <device udid> build/Build/Products/Debug-iphoneos/Kibli.app
```

## roadmap

- [x] app icon (`tools/make_icon.sh` renders it from `tools/icon.svg`)
- [x] find the table plane, find the board, lock an anchor, draw a grid, squares, and arrows
  - the camera image is projected onto the arkit table plane so the board is a flat grid, then the 8x8 window whose squares alternate light/dark best wins (ignores rims, hands and pieces) and its corners snap to the square edges
  - `tools/grid_proto.py` is the python prototype; `swiftc -O -o /tmp/gridcheck tools/gridcheck/main.swift Kibli/AR/GridFinder.swift Kibli/AR/TopDownImage.swift` runs the swift finder on its dumped test views
- [x] fuse sightings from different viewpoints to solve for the playing surface height above the table, and keep refining after lock
- [x] capture button saves the camera frame + intrinsics + camera and board pose; `tools/pull_captures.sh` copies them into `samples/captures`
- [x] once locked, follow the board by refining the predicted corners (about 4ms) instead of searching again; autofocus and exposure aim at the board
- [x] `tools/replay` runs saved captures through the real pipeline on the mac: `swiftc -O -o /tmp/replay tools/replay/main.swift Kibli/AR/{GridFinder,TopDownImage,BoardEstimator,BoardPose,BoardSearch}.swift && /tmp/replay`
- [x] starting position: the frame around the playing area is smooth along its length while the outer files are busy, which pins the grid when only four ranks of squares show
- [x] move detection: for a guessed position and the current camera, predict which squares should show bare wood (pieces hide the squares behind them), check how bare each looks, and pick the current position or the legal move that fits best. no reference frame, so the phone can move between moves; a two-move search catches up after a missed move. `tools/perft` checks the move generator, `tools/snapshot` replays captures that saved a locked board
- [x] blackbox recorder (menu > record session): logs camera pose, intrinsics, every detection, lock, relock and move read, plus half-size frames at 2 fps. `tools/pull_captures.sh` pulls recordings too; `.venv/bin/python tools/recording.py samples/recordings/<name>` prints a timeline and renders the believed board onto each frame (and an mp4 with ffmpeg)
- [x] locked board follows the real one: after a second of missed refinements it searches the whole view again, and relocks once three fresh sightings agree; sightings older than 8s are dropped because arkit's map drifts
- [~] lidar occupancy: depth points placed on the board in 3d give each square's height. turned off in scoring (`Occupancy.useDepth`): at playing distance the smoothed depth map reads a full starting position as flat. recordings and captures still save depth; `DEPTH=1 tools/movereplay` tries it
- [x] training data: `tools/dataset/build.py` turns ChessReD2K (CC BY-NC-SA, research only) and samryan18 (MIT) into 165k labelled 32x32 square crops in `samples/datasets/squares.npz`; `tools/dataset/train_occupancy.py` trains a baseline occupancy net
- [x] fit check: every position is scored as a fraction of a perfect match (about 0.9 when right), so moves need a good fit, not just a better one; an empty or freshly set-up board resets the game, and no moves are read until the starting position is seen. `SIM=1 tools/movereplay` runs the real detector over a recording
- [x] per-frame snap: once locked, the grid is refined 15 times a second and the drawn board follows what the camera sees, on top of the world-fixed estimate (which still only takes 4 sightings a second). `tools/overlaycheck` measures drawn-vs-actual error per recorded frame
- [x] second opinion while locked: a full search once a second (alternating around the lock and where the phone points) relocks when three agree on a spot that scores clearly better, which catches a lock that's a whole square off. `tools/lockscore <capture>` compares a saved lock against a fresh search
- [x] square-off correction: every tracking update also scores the grid shifted one square each way; a decaying average over ~1.5s moves the lock once a shift is clearly and consistently better (threshold tuned on recordings: wrong lock fixed 7.5s in, correct locks peak at 44 of 60). `tools/spotscore` scores two board positions against a recording
- [x] look-alike moves: when the square a piece left is hidden (black's back ranks seen from white's side), moves like Nf6 and f6 fit identically; the app shows the candidates as buttons instead of guessing. `SIM=1 PICK=Nf6 tools/movereplay` replays a recording picking those
- [x] height fit: tries every surface height from -1 to 12 cm and keeps the one where sightings from different viewpoints agree best (medians, so slid frames don't matter); tracked sightings always feed it and relocks keep history that agrees. a board on its box sits ~6 cm up. `tools/heightreplay <recording>` prints the fitted height over time
- [x] piece colour: black pieces' middles sit far below even the dark squares, white pieces' between dark and light, so occupied squares also vote on colour; this is what separates a capture from a quiet move. `tools/fen d4 e5 ...` prints the FEN for a move list, for `tools/movereplay`
- [ ] upright per-square crops (a billboard standing on each square, facing the camera, in colour) for a piece classifier
- [ ] occupancy net in the app (core ml), fine-tuned on our own board
- [ ] piece classification, so games can start mid-way and missed moves can be recovered
- [ ] engine (stockfish for analysis, maia for human-like moves)

The canonical repo for this is hosted on tangled over at [`https://tangled.org/dunkirk.sh/kibli`](https://tangled.org/dunkirk.sh/kibli)

<p align="center">
    <img src="https://raw.githubusercontent.com/taciturnaxolotl/carriage/main/.github/images/line-break.svg" />
</p>

<p align="center">
    <i><code>&copy; 2026-present <a href="https://dunkirk.sh">Kieran Klukas</a></code></i>
</p>

<p align="center">
    <a href="https://tangled.org/dunkirk.sh/kibli/blob/main/LICENSE.md"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=MIT&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
