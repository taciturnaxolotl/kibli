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
