import ARKit
import RealityKit
import SwiftUI

struct ContentView: View {
    @State private var tracker = BoardTracker()
    @State private var flash = false

    var body: some View {
        ZStack {
            BoardARView(tracker: tracker)
                .ignoresSafeArea()

            Color.white
                .opacity(flash ? 0.35 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                StatusCard(tracker: tracker)
                if tracker.showsDebug {
                    DebugPanel(tracker: tracker)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if let note = tracker.captureNote {
                    Toast(text: note)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ActionBar(tracker: tracker)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.snappy, value: tracker.phase)
            .animation(.snappy, value: tracker.showsDebug)
            .animation(.snappy, value: tracker.captureNote)
        }
        .sensoryFeedback(.success, trigger: tracker.lockCount)
        .sensoryFeedback(.impact(weight: .light), trigger: tracker.savedCount)
        .onChange(of: tracker.savedCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.4)) { flash = false }
        }
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

private struct StatusCard: View {
    let tracker: BoardTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StepIndicator(phase: tracker.phase)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .contentTransition(.opacity)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if case .findingBoard(let progress) = tracker.phase {
                ProgressView(value: progress)
                    .tint(.orange)
                    .animation(.snappy, value: progress)
            }

            HStack(spacing: 6) {
                CameraChip(note: tracker.trackingNote)
                if showsBoardChips {
                    BoardChip(tracker: tracker)
                    HeightChip(tracker: tracker)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 22))
    }

    private var showsBoardChips: Bool {
        switch tracker.phase {
        case .findingBoard, .locked: true
        default: false
        }
    }

    private var title: String {
        switch tracker.phase {
        case .findingTable: "Find the table"
        case .findingBoard(let progress): progress > 0 ? "Board found, hold steady" : "Find the board"
        case .tappingCorners(let remaining): remaining == 2 ? "Tap the a1 corner" : "Now tap the h8 corner"
        case .locked:
            if let square = tracker.selected { "\(square) selected" } else { "Board locked" }
        }
    }

    private var detail: String {
        switch tracker.phase {
        case .findingTable:
            return "Sweep the phone slowly across the table."
        case .findingBoard(let progress):
            if progress > 0 { return "Locking once it has stayed put for a moment." }
            if tracker.visibility == .glimpsing { return "Almost, fit the whole board in view." }
            return "Point at the board with all 64 squares in frame."
        case .tappingCorners:
            return "Outer corners of the playing squares, not the rim."
        case .locked:
            if tracker.selected != nil { return "Tap another square to draw an arrow, or the same one to cancel." }
            if !tracker.isManualLock, tracker.calibration < 1 {
                return "Walk around the board a little to sharpen the fit. Tap squares to draw."
            }
            return "Tap a square, then another, to draw an arrow."
        }
    }
}

/// Three dots for table, board, locked, with the current one pulsing.
private struct StepIndicator: View {
    let phase: BoardTracker.Phase

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: isSearching)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 42, height: 42)
    }

    private var isSearching: Bool {
        switch phase {
        case .findingTable, .findingBoard, .tappingCorners: true
        case .locked: false
        }
    }

    private var symbol: String {
        switch phase {
        case .findingTable: "rectangle.dashed"
        case .findingBoard: "viewfinder"
        case .tappingCorners: "hand.tap"
        case .locked: "checkmark.seal.fill"
        }
    }

    private var color: Color {
        switch phase {
        case .findingTable: .gray
        case .findingBoard, .tappingCorners: .orange
        case .locked: .cyan
        }
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.16), in: .capsule)
    }
}

private struct CameraChip: View {
    let note: String?

    var body: some View {
        if let note {
            Chip(symbol: "exclamationmark.triangle.fill", text: note, color: .yellow)
        } else {
            Chip(symbol: "camera.fill", text: "Tracking", color: .green)
        }
    }
}

private struct BoardChip: View {
    let tracker: BoardTracker

    var body: some View {
        if tracker.isManualLock {
            Chip(symbol: "hand.tap.fill", text: "Manual", color: .secondary)
        } else {
            switch tracker.visibility {
            case .seeing:
                Chip(symbol: "eye.fill", text: tracker.phase == .locked ? "Syncing" : "Seeing", color: .green)
            case .glimpsing:
                Chip(symbol: "eye.trianglebadge.exclamationmark", text: "Partial", color: .yellow)
            case .notSeen(let seconds):
                Chip(
                    symbol: "eye.slash",
                    text: tracker.phase == .locked && seconds > 0 ? "Held \(seconds)s" : "No board",
                    color: tracker.phase == .locked ? .secondary : .orange
                )
            }
        }
    }
}

private struct HeightChip: View {
    let tracker: BoardTracker

    var body: some View {
        if !tracker.isManualLock, let height = tracker.surfaceHeight {
            let done = tracker.calibration >= 1
            Chip(
                symbol: done ? "ruler.fill" : "arrow.triangle.2.circlepath",
                text: done
                    ? String(format: "%.1f cm", height * 100)
                    : "Calibrating \(Int(tracker.calibration * 100))%",
                color: done ? .cyan : .secondary
            )
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
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    Color.black.opacity(0.4)
                        .overlay(ProgressView())
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(.rect(cornerRadius: 12))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("checker", "\(tracker.lastChecker)/112")
                row("sightings", "\(tracker.sightings)")
                row("surface", tracker.surfaceHeight.map { String(format: "+%.1f cm", $0 * 100) } ?? "n/a")
                row("parallax", String(format: "%.3f", tracker.parallax))
                row("captures", "\(tracker.captureCount)")
            }
            .font(.caption.monospacedDigit())
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

// MARK: Actions

private struct Toast: View {
    let text: String

    var body: some View {
        Label(text, systemImage: text.hasPrefix("Save failed") ? "xmark.octagon.fill" : "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .capsule)
    }
}

private struct ActionBar: View {
    @Bindable var tracker: BoardTracker

    var body: some View {
        HStack(spacing: 4) {
            if tracker.phase == .locked {
                action("Rotate", "rotate.right") { tracker.quarterTurns = (tracker.quarterTurns + 1) % 4 }
                action("Clear", "eraser") { tracker.clearDrawings() }
            } else {
                action("Manual", "hand.tap") { tracker.beginCornerTaps() }
            }

            CaptureButton(count: tracker.captureCount) { tracker.capture() }
                .padding(.horizontal, 8)

            action(tracker.phase == .locked ? "Relock" : "Restart", "arrow.counterclockwise") { tracker.reset() }
            Menu {
                Toggle(isOn: $tracker.showsDebug) {
                    Label("Debug view", systemImage: "ladybug")
                }
                Button {
                    tracker.beginCornerTaps()
                } label: {
                    Label("Place by tapping corners", systemImage: "hand.tap")
                }
                Button(role: .destructive) {
                    tracker.start()
                } label: {
                    Label("Restart AR session", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
            } label: {
                ActionLabel(title: "More", symbol: "ellipsis.circle")
            }
            .tint(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: .capsule)
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            ActionLabel(title: title, symbol: symbol)
        }
        .buttonStyle(.plain)
    }
}

private struct ActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(height: 22)
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.primary)
        .frame(width: 58, height: 48)
        .contentShape(.rect)
    }
}

private struct CaptureButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                Circle()
                    .fill(.white)
                    .padding(6)
            }
            .frame(width: 60, height: 60)
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.cyan, in: .capsule)
                        .offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture frame, \(count) saved")
    }
}
