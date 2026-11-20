import ARKit
import RealityKit
import SwiftUI

struct ContentView: View {
    @State private var tracker = BoardTracker()
    @State private var flash = false
    @State private var showsGame = true
    @State private var showsInspector = false

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
                    .overlay(alignment: .bottom) {
                        // Floats just under the status bar without pushing
                        // anything else down.
                        if let announcement = tracker.announcement {
                            MoveBanner(san: announcement.san, color: announcement.color)
                                .id(announcement.id)
                                .offset(y: 54)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .zIndex(1)
                if tracker.phase != .locked {
                    SearchChecklist(tracker: tracker)
                        .transition(.blurReplace)
                }
                if tracker.showsDebug {
                    DebugHUD(tracker: tracker) { showsInspector = true }
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
            .animation(.spring(duration: 0.4, bounce: 0.25), value: tracker.announcement?.id)
        }
        .sensoryFeedback(.success, trigger: tracker.lockCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: tracker.moveCount)
        .sensoryFeedback(.impact(weight: .light), trigger: tracker.savedCount)
        .onChange(of: tracker.savedCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.4)) { flash = false }
        }
        .statusBarHidden()
        .sheet(isPresented: $showsInspector) {
            DebugSheet(tracker: tracker)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(.thinMaterial)
        }
    }
}

// MARK: AR view

private struct BoardARView: UIViewRepresentable {
    let tracker: BoardTracker

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        // The overlay is flat unlit geometry; none of RealityKit's camera
        // effects or lighting help it, and each costs GPU time every frame.
        view.renderOptions.formUnion([
            .disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableHDR,
            .disableGroundingShadows, .disableAREnvironmentLighting, .disablePersonOcclusion, .disableFaceMesh,
        ])
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
                    .lineLimit(2, reservesSpace: true)
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
            if tracker.viewTooLow { return "Raise the phone to look down on the board; pieces read better from above" }
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
                        Text(watchTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(watchDetail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
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

            if !tracker.choices.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(tracker.choices.enumerated()), id: \.element.san) { index, choice in
                        Button {
                            tracker.choose(choice.move)
                        } label: {
                            Text(verbatim: "\(choice.san)  \(choice.move.from.description)→\(choice.move.to.description)")
                                .font(.subheadline.monospaced().weight(.semibold))
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color(BoardTracker.choiceColors[index % BoardTracker.choiceColors.count]))
                    }
                }
                .transition(.blurReplace)
            }

            if expanded {
                HStack(alignment: .top, spacing: 12) {
                    BoardDiagram(
                        position: tracker.game.position,
                        lastMove: tracker.game.lastMove,
                        choices: tracker.choices.enumerated().map { i, choice in
                            (choice.move, Color(BoardTracker.choiceColors[i % BoardTracker.choiceColors.count]))
                        }
                    )
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
        case .idle, .findingStart, .boardEmpty: "checkerboard.rectangle"
        case .watching: "eye"
        case .handInView: "hand.raised"
        case .unclear: "questionmark.circle"
        case .choosing: "hand.point.up.left"
        }
    }

    private var watchTint: Color {
        switch tracker.watch {
        case .watching: .green
        case .unclear, .choosing: .orange
        default: .secondary
        }
    }

    private var watchTitle: String {
        if let status = tracker.game.status { return status }
        switch tracker.watch {
        case .idle, .findingStart: return "Set up the pieces"
        case .boardEmpty: return "Board is empty"
        case .watching: return tracker.game.position.sideToMove == .white ? "White to move" : "Black to move"
        case .handInView: return "Waiting for hands to clear"
        case .unclear: return "Couldn't tell what moved"
        case .choosing: return "Which move was it?"
        }
    }

    private var watchDetail: String {
        switch tracker.watch {
        case .idle, .findingStart: "Waiting to see the starting position"
        case .boardEmpty: "Set up the pieces to start a new game"
        case .watching: "Watching for moves"
        case .handInView: "Moves are read once nothing is moving"
        case .unclear: "Undo or fix the position, then try again"
        case .choosing: "Match the coloured arrow on the board, or step to the side to see"
        }
    }
}

private struct BoardDiagram: View {
    let position: Position
    let lastMove: Move?
    var choices: [(move: Move, color: Color)] = []

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach((0..<8).reversed(), id: \.self) { rank in
                GridRow {
                    ForEach(0..<8, id: \.self) { file in
                        let square = Square(file: file, rank: rank)!
                        ZStack {
                            Rectangle().fill(color(for: square))
                            if let piece = position[square] {
                                PieceGlyph(piece: piece, size: 16)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            Canvas { context, size in
                let square = size.width / 8
                func point(_ s: Square) -> CGPoint {
                    CGPoint(x: (CGFloat(s.file) + 0.5) * square, y: (7.5 - CGFloat(s.rank)) * square)
                }
                func arrow(_ move: Move, _ color: Color, width: CGFloat) {
                    let a = point(move.from), b = point(move.to)
                    let angle = atan2(b.y - a.y, b.x - a.x)
                    let head = square * 0.38
                    let tip = CGPoint(x: b.x - cos(angle) * square * 0.15, y: b.y - sin(angle) * square * 0.15)
                    let shaftEnd = CGPoint(x: tip.x - cos(angle) * head * 0.8, y: tip.y - sin(angle) * head * 0.8)
                    var shaft = Path()
                    shaft.move(to: a)
                    shaft.addLine(to: shaftEnd)
                    context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    var tri = Path()
                    tri.move(to: tip)
                    tri.addLine(to: CGPoint(x: tip.x - cos(angle - 0.5) * head, y: tip.y - sin(angle - 0.5) * head))
                    tri.addLine(to: CGPoint(x: tip.x - cos(angle + 0.5) * head, y: tip.y - sin(angle + 0.5) * head))
                    tri.closeSubpath()
                    context.fill(tri, with: .color(color))
                }
                if let lastMove, choices.isEmpty { arrow(lastMove, .teal.opacity(0.85), width: square * 0.18) }
                for choice in choices { arrow(choice.move, choice.color.opacity(0.9), width: square * 0.16) }
            }
            .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 8))
        .animation(.smooth(duration: 0.3), value: lastMove)
        .accessibilityLabel("Board diagram")
    }

    private func color(for square: Square) -> Color {
        if let lastMove, choices.isEmpty, square == lastMove.from || square == lastMove.to {
            return square.isLight ? Color(red: 0.62, green: 0.85, blue: 0.82) : Color(red: 0.33, green: 0.62, blue: 0.6)
        }
        return square.isLight ? Color(red: 0.93, green: 0.87, blue: 0.76) : Color(red: 0.62, green: 0.45, blue: 0.33)
    }
}

/// A chess piece drawn with the solid glyph for both sides, filled white or
/// black with a thin contrasting outline so it reads on either square.
private struct PieceGlyph: View {
    let piece: Piece
    let size: CGFloat

    var body: some View {
        let glyph = Text(Piece(color: .black, kind: piece.kind).symbol).font(.system(size: size))
        let outline: Color = piece.color == .white ? .black.opacity(0.75) : .white.opacity(0.35)
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                glyph.foregroundStyle(outline)
                    .offset(x: [0.6, -0.6, 0, 0][i], y: [0, 0, 0.6, -0.6][i])
            }
            glyph.foregroundStyle(piece.color == .white ? Color.white : Color.black)
        }
    }
}

/// Slides in when a move is read: who played it and what it was.
private struct MoveBanner: View {
    let san: String
    let color: PieceColor
    @State private var visible = true

    var body: some View {
        Group {
            if visible {
                HStack(spacing: 10) {
                    Circle()
                        .fill(color == .white ? Color.white : Color.black)
                        .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                        .frame(width: 14, height: 14)
                    Text(color == .white ? "White played" : "Black played")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(san)
                        .font(.title3.monospaced().weight(.bold))
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.smooth) { visible = false }
        }
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
                        let isLast = row.number == game.numbered.last?.number
                        let blackLast = isLast && row.black != nil
                        GridRow {
                            Text("\(row.number).").foregroundStyle(.secondary)
                            Text(row.white)
                                .fontWeight(isLast && !blackLast ? .bold : .regular)
                                .foregroundStyle(isLast && !blackLast ? Color.teal : Color.primary)
                            Text(row.black ?? "")
                                .fontWeight(blackLast ? .bold : .regular)
                                .foregroundStyle(blackLast ? Color.teal : Color.primary)
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

/// A small always-on readout while debugging: the top-down search view, the
/// fit of the game being followed, and the closest moves. Tap for the full
/// inspector.
private struct DebugHUD: View {
    let tracker: BoardTracker
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let image = tracker.debugImage {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                    } else {
                        Color.black.opacity(0.3)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Metric(label: "fit", value: tracker.insight.current.map { String(format: "%.2f", $0) } ?? "n/a",
                               tint: fitTint(tracker.insight.current))
                        Metric(label: "grid", value: "\(tracker.lastChecker)", tint: .secondary)
                        Metric(label: "height", value: tracker.surfaceHeight.map { String(format: "%.1fcm", $0 * 100) } ?? "n/a", tint: .secondary)
                    }
                    // Always three rows, so the card never changes height.
                    ForEach(0..<3, id: \.self) { i in
                        if i < tracker.insight.ranked.count {
                            let move = tracker.insight.ranked[i]
                            FitBar(label: move.san, fit: move.fit, current: tracker.insight.current, threshold: tracker.matchFit)
                        } else if i == 0 {
                            SettleBar(progress: tracker.insight.settle)
                        } else {
                            Color.clear.frame(height: 14)
                        }
                    }
                    .frame(height: 14)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private func fitTint(_ fit: Float?) -> Color {
    guard let fit else { return .secondary }
    return fit >= 0.75 ? .green : fit >= 0.55 ? .yellow : .orange
}

private struct Metric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
        }
        .frame(minWidth: 44, alignment: .leading)
    }
}

/// One move's fit, drawn against the current position's fit (thin line) and
/// the bar a move has to clear (tick).
private struct FitBar: View {
    let label: String
    let fit: Float
    let current: Float?
    let threshold: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospaced().weight(.medium))
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(fitTint(fit).gradient)
                        .frame(width: width * CGFloat(min(max(fit, 0), 1)))
                    Rectangle().fill(.white.opacity(0.7)).frame(width: 1.5, height: 10)
                        .offset(x: width * CGFloat(threshold))
                    if let current {
                        Rectangle().fill(.white).frame(width: 2, height: 14)
                            .offset(x: width * CGFloat(min(max(current, 0), 1)) - 1)
                    }
                }
            }
            .frame(height: 8)
            Text(String(format: "%.2f", fit))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

private struct SettleBar: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: progress >= 1 ? "checkmark.circle.fill" : "hand.raised")
                .font(.caption)
                .foregroundStyle(progress >= 1 ? .green : .secondary)
            ProgressView(value: progress)
                .tint(.cyan)
            Text(progress >= 1 ? "still" : "settling")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The full inspector, as a sheet over the camera view.
private struct DebugSheet: View {
    @Bindable var tracker: BoardTracker

    var body: some View {
        NavigationStack {
            List {
                Section {
                    movesSection
                } header: {
                    Text("Moves")
                } footer: {
                    Text("Fit is how well a position explains the board, as a share of a perfect match. The white line is the position being followed; the tick is the \(String(format: "%.2f", tracker.matchFit)) a move must reach.")
                }

                Section("What the camera sees") {
                    HStack(alignment: .top, spacing: 12) {
                        SquareMap(title: "Expected", caption: "from the game") { square in
                            .init(fill: tracker.insight.expectedBare?[square.index] == false ? .orange.opacity(0.55) : .clear,
                                  piece: tracker.game.position[square])
                        }
                        SquareMap(title: "Covered", caption: "camera, hands purple") { square in
                            let hand = Double(tracker.insight.hands?[square.index] ?? 0)
                            return .init(fill: hand > 0.15 ? .purple.opacity(min(hand * 2, 0.9))
                                         : .orange.opacity(Double(1 - (tracker.insight.bareness?[square.index] ?? 1))), piece: nil)
                        }
                        SquareMap(title: "Colour", caption: "white / black") { square in
                            let value = Double(tracker.insight.colors?[square.index] ?? 0)
                            let occupied = tracker.game.position[square] != nil
                            return .init(fill: occupied ? (value >= 0 ? Color.white.opacity(value) : Color.black.opacity(-value)) : .clear,
                                         piece: nil)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }

                Section("Board") {
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if let image = tracker.debugImage {
                                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                        .frame(width: 130, height: 130)
                        .clipShape(.rect(cornerRadius: 12))
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            row("grid", "\(tracker.lastChecker)/112")
                            row("height", tracker.surfaceHeight.map { String(format: "%.1f cm", $0 * 100) } ?? "n/a")
                            row("calibrated", "\(Int(tracker.calibration * 100))%")
                            row("view angle", tracker.viewAngle.map { String(format: "%.0f°", $0) } ?? "n/a")
                            row("sightings", "\(tracker.sightings)")
                            row("relocks", "\(tracker.relockCount)")
                            row("shifts", "\(tracker.shiftCount)")
                            row("misses", "\(tracker.misses)")
                        }
                        .font(.caption.monospacedDigit())
                    }
                }

                Section("Session") {
                    LabeledContent("Orientation", value: "\(tracker.quarterTurns) quarter turns")
                    LabeledContent("Captures saved", value: "\(tracker.captureCount)")
                    Button(tracker.isRecording ? "Stop recording" : "Record session",
                           systemImage: tracker.isRecording ? "stop.circle" : "record.circle") { tracker.toggleRecording() }
                    Button("Save capture", systemImage: "camera") { tracker.capture() }
                    Button("Flip board", systemImage: "arrow.up.arrow.down") { tracker.flip() }
                }
            }
            .navigationTitle("Inspector")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var movesSection: some View {
        HStack {
            Label(stateText, systemImage: stateSymbol)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(String(format: "motion %.1f", tracker.insight.motion))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        SettleBar(progress: tracker.insight.settle)
        if let current = tracker.insight.current {
            FitBar(label: "now", fit: current, current: nil, threshold: tracker.matchFit)
        }
        ForEach(Array(tracker.insight.ranked.enumerated()), id: \.offset) { _, move in
            FitBar(label: move.san, fit: move.fit, current: tracker.insight.current, threshold: tracker.matchFit)
        }
    }

    private var stateText: String {
        switch tracker.watch {
        case .idle: "Board not locked"
        case .findingStart: "Waiting for the starting position"
        case .boardEmpty: "Board empty"
        case .watching: "Watching"
        case .handInView: "Something moving"
        case .unclear: "No position fits"
        case .choosing: "Asking which move"
        }
    }

    private var stateSymbol: String {
        switch tracker.watch {
        case .watching: "eye"
        case .handInView: "hand.raised"
        case .unclear: "questionmark.circle"
        case .choosing: "hand.point.up.left"
        default: "checkerboard.rectangle"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// A tiny 8x8 board with a fill per square, for comparing what the game
/// predicts with what the camera reads.
private struct SquareMap: View {
    struct Cell { var fill: Color; var piece: Piece? }
    let title: String
    let caption: String
    let cell: (Square) -> Cell

    var body: some View {
        VStack(spacing: 4) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach((0..<8).reversed(), id: \.self) { rank in
                    GridRow {
                        ForEach(0..<8, id: \.self) { file in
                            let square = Square(file: file, rank: rank)!
                            let content = cell(square)
                            ZStack {
                                Rectangle().fill(square.isLight ? Color(white: 0.55) : Color(white: 0.35))
                                Rectangle().fill(content.fill)
                                if let piece = content.piece {
                                    Text(piece.symbol).font(.system(size: 8))
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 4))
            Text(title).font(.caption2.weight(.semibold))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

extension Square {
    var index: Int { rank * 8 + file }
}

// MARK: Toolbar

private struct Toolbar: View {
    @Bindable var tracker: BoardTracker
    @State private var confirmingStartOver = false

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
                    Section {
                        Button("Start over", systemImage: "arrow.counterclockwise.circle", role: .destructive) {
                            confirmingStartOver = true
                        }
                    }
                    Section("Game") {
                        Button("New game", systemImage: "plus.circle") { tracker.newGame() }
                        Button("Flip board", systemImage: "arrow.up.arrow.down") { tracker.flip() }
                        Toggle("Watch for moves", systemImage: "eye", isOn: $tracker.watchesMoves)
                    }
                    Section("Board") {
                        Button("Find board again", systemImage: "viewfinder") { tracker.reset() }
                        Button("Clear arrows", systemImage: "eraser") { tracker.clearDrawings() }
                    }
                    Section("Tuning") {
                        Button(
                            tracker.isRecording ? "Stop recording" : "Record session",
                            systemImage: tracker.isRecording ? "stop.circle" : "record.circle"
                        ) { tracker.toggleRecording() }
                        Toggle("Debug overlay", systemImage: "ladybug", isOn: $tracker.showsDebug)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
                .confirmationDialog("Start over?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
                    Button("Start over", role: .destructive) { tracker.startOver() }
                } message: {
                    Text("Clears the game and the board lock, and remaps the table. Recordings and captures are kept.")
                }
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
