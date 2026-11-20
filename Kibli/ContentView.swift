import ARKit
import RealityKit
import SwiftUI

struct ContentView: View {
    @State private var tracker = BoardTracker()
    @State private var flash = false
    @State private var showsGame = true

    var body: some View {
        ZStack {
            BoardARView(tracker: tracker)
                .ignoresSafeArea()

            Color.white
                .opacity(flash ? 0.3 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if tracker.phase != .locked {
                Reticle(found: tracker.searchHint == .holdSteady)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                StatusBar(tracker: tracker)
                if tracker.phase != .locked {
                    SearchChecklist(tracker: tracker)
                        .transition(.blurReplace)
                }
                if tracker.showsDebug {
                    DebugPanel(tracker: tracker)
                        .transition(.blurReplace)
                }
                Spacer()
                if tracker.phase == .locked, tracker.watchesMoves {
                    GamePanel(tracker: tracker, expanded: $showsGame)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let note = tracker.captureNote {
                    Label(note, systemImage: note.hasPrefix("Save failed") ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.blurReplace)
                }
                Toolbar(tracker: tracker)
            }
            .padding(.horizontal, 12)
            .animation(.smooth, value: tracker.phase)
            .animation(.smooth, value: tracker.showsDebug)
            .animation(.smooth, value: showsGame)
            .animation(.smooth, value: tracker.captureNote)
        }
        .sensoryFeedback(.success, trigger: tracker.lockCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: tracker.moveCount)
        .sensoryFeedback(.impact(weight: .light), trigger: tracker.savedCount)
        .onChange(of: tracker.savedCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.4)) { flash = false }
        }
        .statusBarHidden()
    }
}

// MARK: AR view

private struct BoardARView: UIViewRepresentable {
    let tracker: BoardTracker

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped(_:))
        ))
        tracker.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(tracker: tracker) }

    @MainActor
    final class Coordinator: NSObject {
        let tracker: BoardTracker
        init(tracker: BoardTracker) { self.tracker = tracker }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            tracker.handleTap(at: gesture.location(in: gesture.view))
        }
    }
}

// MARK: Status

private struct StatusBar: View {
    let tracker: BoardTracker

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: tracker.phase != .locked)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .contentTransition(.opacity)

            Spacer(minLength: 0)

            if tracker.isRecording, let started = tracker.recordingStarted {
                RecordingBadge(started: started)
            }
            Accessory(tracker: tracker)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .animation(.smooth, value: title)
    }

    private var symbol: String {
        if tracker.trackingNote != nil { return "exclamationmark.triangle.fill" }
        switch tracker.phase {
        case .findingTable, .findingBoard: return tracker.searchHint.symbol
        case .locked:
            switch tracker.visibility {
            case .seeing: return "checkmark.circle.fill"
            case .glimpsing: return "eye.trianglebadge.exclamationmark"
            case .notSeen: return "eye.slash"
            }
        }
    }

    private var tint: Color {
        if tracker.trackingNote != nil { return .yellow }
        switch tracker.phase {
        case .findingTable: return .secondary
        case .findingBoard: return .orange
        case .locked: return tracker.visibility == .seeing ? .green : .secondary
        }
    }

    private var title: String {
        switch tracker.phase {
        case .findingTable: tracker.searchHint.title
        case .findingBoard(let progress): progress > 0 ? "Hold steady" : tracker.searchHint.title
        case .locked:
            if let square = tracker.selected { "\(square) selected" }
            else {
                switch tracker.visibility {
                case .seeing: "Board locked"
                case .glimpsing: "Board partly hidden"
                case .notSeen(let seconds): seconds > 1 ? "Holding position" : "Board locked"
                }
            }
        }
    }

    private var subtitle: String {
        if let note = tracker.trackingNote { return note }
        switch tracker.phase {
        case .findingTable: return tracker.searchHint.advice
        case .findingBoard(let progress):
            if progress > 0 { return "Found it, locking in a moment" }
            return tracker.searchHint.advice
        case .locked:
            if tracker.selected != nil { return "Tap another square to draw an arrow" }
            if case .notSeen(let seconds) = tracker.visibility, seconds > 1 {
                return "Lost sight \(seconds)s ago, keeping the last spot"
            }
            return "Tap squares to draw arrows"
        }
    }
}

extension BoardTracker.SearchHint {
    var title: String {
        switch self {
        case .mapTable: "Map the table"
        case .aimAtTable: "Aim at the board"
        case .tooFar: "Move closer"
        case .tooFlat: "Look down more"
        case .partlyOutOfView: "Fit the whole board"
        case .unclearSquares: "Looking for squares"
        case .holdSteady: "Hold steady"
        }
    }

    var advice: String {
        switch self {
        case .mapTable: "Move the phone slowly so it can see the table surface"
        case .aimAtTable: "Point the middle of the screen at the board"
        case .tooFar: "Get within about an arm's length of the board"
        case .tooFlat: "Raise the phone so it looks down on the board, not across it"
        case .partlyOutOfView: "All four corners of the squares need to be on screen"
        case .unclearSquares: "Keep the board in the middle; more light and less glare help"
        case .holdSteady: "Found it, locking in a moment"
        }
    }

    var symbol: String {
        switch self {
        case .mapTable: "rectangle.dashed"
        case .aimAtTable: "scope"
        case .tooFar: "arrow.down.right.and.arrow.up.left"
        case .tooFlat: "arrow.down.to.line"
        case .partlyOutOfView: "arrow.up.left.and.arrow.down.right"
        case .unclearSquares: "viewfinder"
        case .holdSteady: "hand.raised"
        }
    }
}

/// What it takes to lock, with the steps already met ticked off.
private struct SearchChecklist: View {
    let tracker: BoardTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            step("Table mapped", done: tableMapped, active: !tableMapped)
            step("Whole board on screen, seen from above", done: boardSeen, active: tableMapped && !boardSeen)
            step("Hold still for a moment", done: false, active: boardSeen, progress: progress)
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.smooth, value: tableMapped)
        .animation(.smooth, value: boardSeen)
    }

    private var tableMapped: Bool { tracker.phase != .findingTable }
    private var boardSeen: Bool {
        if case .findingBoard(let progress) = tracker.phase, progress > 0 { return true }
        return tracker.searchHint == .holdSteady
    }
    private var progress: Double? {
        if case .findingBoard(let progress) = tracker.phase, progress > 0 { return progress }
        return nil
    }

    private func step(_ text: String, done: Bool, active: Bool, progress: Double? = nil) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if let progress {
                    Gauge(value: progress) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(.green)
                        .scaleEffect(0.42)
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.dotted" : "circle"))
                        .foregroundStyle(done ? .green : (active ? .orange : .secondary))
                        .symbolEffect(.rotate, isActive: active)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 22, height: 22)
            Text(text)
                .foregroundStyle(done || active ? .primary : .secondary)
        }
    }
}

/// Camera-style corner brackets showing where to put the board. They turn
/// green once the squares are found.
private struct Reticle: View {
    let found: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) * 0.72
            let arm = side * 0.14
            Path { path in
                let rect = CGRect(
                    x: (geometry.size.width - side) / 2, y: (geometry.size.height - side) / 2 + 50,
                    width: side, height: side
                )
                for (corner, dx, dy) in [
                    (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                    (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0), (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                ] {
                    path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                }
            }
            .stroke(found ? Color.green : Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .animation(.smooth, value: found)
        }
        .ignoresSafeArea()
    }
}

/// A red dot and elapsed time while the blackbox recorder is running.
private struct RecordingBadge: View {
    let started: Date

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
            Text(started, style: .timer)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
    }
}

/// Calibration ring while the height is still being measured, the height
/// once it's known.
private struct Accessory: View {
    let tracker: BoardTracker

    var body: some View {
        if case .findingBoard(let progress) = tracker.phase, progress > 0 {
            Gauge(value: progress) { EmptyView() }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(.orange)
                .scaleEffect(0.6)
                .frame(width: 34, height: 34)
        } else if tracker.phase == .locked {
            if tracker.calibration < 1 {
                VStack(spacing: 2) {
                    Gauge(value: tracker.calibration) {
                        Image(systemName: "figure.walk")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(.cyan)
                    .scaleEffect(0.6)
                    .frame(width: 34, height: 34)
                    Text("Walk around")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Walk around the board to calibrate, \(Int(tracker.calibration * 100)) percent")
            } else if let height = tracker.surfaceHeight {
                Label(String(format: "%.1f cm", height * 100), systemImage: "ruler")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: Game

private struct GamePanel: View {
    let tracker: BoardTracker
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: watchSymbol)
                        .foregroundStyle(watchTint)
                        .symbolEffect(.pulse, isActive: tracker.watch == .watching)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(watchTitle).font(.subheadline.weight(.semibold))
                        Text(watchDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let last = tracker.game.records.last {
                        Text(last.san)
                            .font(.subheadline.monospaced().weight(.semibold))
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(alignment: .top, spacing: 12) {
                    BoardDiagram(position: tracker.game.position, lastMove: tracker.game.lastMove)
                        .frame(width: 152, height: 152)
                    MoveList(game: tracker.game)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .animation(.smooth, value: tracker.game.records.count)
    }

    private var watchSymbol: String {
        switch tracker.watch {
        case .idle, .findingStart: "checkerboard.rectangle"
        case .watching: "eye"
        case .handInView: "hand.raised"
        case .unclear: "questionmark.circle"
        }
    }

    private var watchTint: Color {
        switch tracker.watch {
        case .watching: .green
        case .unclear: .orange
        default: .secondary
        }
    }

    private var watchTitle: String {
        if let status = tracker.game.status { return status }
        switch tracker.watch {
        case .idle, .findingStart: return "Set up the pieces"
        case .watching: return tracker.game.position.sideToMove == .white ? "White to move" : "Black to move"
        case .handInView: return "Waiting for hands to clear"
        case .unclear: return "Couldn't tell what moved"
        }
    }

    private var watchDetail: String {
        switch tracker.watch {
        case .idle, .findingStart: "Hold still over the starting position"
        case .watching: "Watching for moves"
        case .handInView: "Moves are read once nothing is moving"
        case .unclear: "Undo or fix the position, then try again"
        }
    }
}

private struct BoardDiagram: View {
    let position: Position
    let lastMove: Move?

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach((0..<8).reversed(), id: \.self) { rank in
                GridRow {
                    ForEach(0..<8, id: \.self) { file in
                        let square = Square(file: file, rank: rank)!
                        ZStack {
                            Rectangle().fill(color(for: square))
                            if let piece = position[square] {
                                Text(piece.symbol)
                                    .font(.system(size: 16))
                                    .foregroundStyle(piece.color == .white ? .white : .black)
                                    .shadow(color: piece.color == .white ? .black.opacity(0.6) : .white.opacity(0.4), radius: 0.5)
                            }
                        }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel("Board diagram")
    }

    private func color(for square: Square) -> Color {
        if let lastMove, square == lastMove.from || square == lastMove.to {
            return Color.teal.opacity(square.isLight ? 0.55 : 0.75)
        }
        return square.isLight ? Color(white: 0.86) : Color(red: 0.55, green: 0.42, blue: 0.32)
    }
}

private struct MoveList: View {
    let game: Game

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if game.records.isEmpty {
                    Text("No moves yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(game.numbered, id: \.number) { row in
                        GridRow {
                            Text("\(row.number).").foregroundStyle(.secondary)
                            Text(row.white)
                            Text(row.black ?? "")
                        }
                        .id(row.number)
                    }
                }
                .font(.footnote.monospaced())
            }
            .frame(height: 152)
            .onChange(of: game.records.count) {
                if let last = game.numbered.last { withAnimation { proxy.scrollTo(last.number, anchor: .bottom) } }
            }
        }
    }
}

// MARK: Debug

private struct DebugPanel: View {
    let tracker: BoardTracker

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let image = tracker.debugImage {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                } else {
                    Color.black.opacity(0.3).overlay(ProgressView())
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(.rect(cornerRadius: 12))

            VStack(spacing: 6) {
                if let changes = tracker.lastChanges {
                    ChangeMap(changes: changes.map { 1 - $0 }, tint: .orange)
                        .frame(width: 64, height: 64)
                }
                if let depth = tracker.lastDepthOccupancy {
                    ChangeMap(changes: depth.map { $0 ?? 0 }, tint: .cyan)
                        .frame(width: 64, height: 64)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                row("checker", "\(tracker.lastChecker)/112")
                row("sightings", "\(tracker.sightings)")
                row("surface", tracker.surfaceHeight.map { String(format: "+%.1f cm", $0 * 100) } ?? "n/a")
                row("calibrated", "\(Int(tracker.calibration * 100))%")
                row("turns", "\(tracker.quarterTurns)")
                row("lidar", tracker.hasDepth ? "on" : "none")
                row("fit", tracker.fit.map { String(format: "%.1f", $0) } ?? "n/a")
                row("captures", "\(tracker.captureCount)")
            }
            .font(.caption2.monospacedDigit())
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// A per-square 0 to 1 map, brightest where the value is highest: how
/// covered squares looked in the camera (orange) or by LiDAR (cyan).
private struct ChangeMap: View {
    let changes: [Float]
    var tint: Color = .orange

    var body: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach((0..<8).reversed(), id: \.self) { rank in
                GridRow {
                    ForEach(0..<8, id: \.self) { file in
                        Rectangle().fill(tint.opacity(Double(changes[rank * 8 + file])))
                            .background(Color.black.opacity(0.3))
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 6))
    }
}

// MARK: Toolbar

private struct Toolbar: View {
    @Bindable var tracker: BoardTracker

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                Button("Undo move", systemImage: "arrow.uturn.backward") { tracker.undoMove() }
                    .disabled(tracker.game.records.isEmpty)

                Button {
                    tracker.capture()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.white.opacity(0.9))
                .foregroundStyle(.black)
                .accessibilityLabel("Capture frame")
                .accessibilityValue("\(tracker.captureCount) saved")

                Menu {
                    Section("Game") {
                        Button("New game", systemImage: "plus.circle") { tracker.newGame() }
                        Button("Flip board", systemImage: "arrow.up.arrow.down") { tracker.flip() }
                        Toggle("Watch for moves", systemImage: "eye", isOn: $tracker.watchesMoves)
                    }
                    Section("Board") {
                        Button("Relock board", systemImage: "arrow.counterclockwise") { tracker.reset() }
                        Button("Clear arrows", systemImage: "eraser") { tracker.clearDrawings() }
                    }
                    Section("Tuning") {
                        Button(
                            tracker.isRecording ? "Stop recording" : "Record session",
                            systemImage: tracker.isRecording ? "stop.circle" : "record.circle"
                        ) { tracker.toggleRecording() }
                        Toggle("Debug overlay", systemImage: "ladybug", isOn: $tracker.showsDebug)
                        Button("Restart AR session", systemImage: "arrow.clockwise", role: .destructive) { tracker.start() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .padding(.bottom, 4)
    }
}
