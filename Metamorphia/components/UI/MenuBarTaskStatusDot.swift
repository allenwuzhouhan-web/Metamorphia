import AppKit
import Combine
import SwiftUI

@MainActor
enum MenuBarTaskStatus: Equatable {
    case inProgress
    case succeeded
    case failed

    init(inputBarState: InputBarState) {
        switch inputBarState {
        case .processing, .planning, .executing, .streaming:
            self = .inProgress
        case .error:
            self = .failed
        case .ready, .result, .voiceListening, .researchChoice, .browserChoice,
             .thoughtRecall, .newsBriefing, .coworkingSuggestion, .healthCard:
            self = .succeeded
        }
    }
}

@MainActor
final class MenuBarTaskStatusStore: ObservableObject {
    static let shared = MenuBarTaskStatusStore()

    @Published private(set) var status: MenuBarTaskStatus = .succeeded
    /// Mirrors AICommandViewModel.lastResultSummary so ContentView can subscribe
    /// without holding a direct reference to the view model.
    @Published private(set) var lastResultSummary: String?

    private init() {}

    func update(from inputBarState: InputBarState) {
        status = MenuBarTaskStatus(inputBarState: inputBarState)
    }

    func updateResultSummary(_ summary: String?) {
        lastResultSummary = summary
    }
}

struct MenuBarTaskStatusDot: View {
    @ObservedObject private var store = MenuBarTaskStatusStore.shared
    @State private var pulsePhase: Double = 0
    private let pulseTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(nsImage: MenuBarTaskStatusImage.make(status: store.status, phase: pulsePhase))
            .resizable()
            .interpolation(.high)
            .renderingMode(.original)
            .accessibilityLabel(accessibilityLabel)
        .frame(width: 18, height: 18)
            .onReceive(pulseTimer) { date in
                pulsePhase = date.timeIntervalSinceReferenceDate
            }
    }

    private var accessibilityLabel: String {
        switch store.status {
        case .inProgress:
            return "Metamorphia task in progress"
        case .succeeded:
            return "Metamorphia task finished"
        case .failed:
            return "Metamorphia task failed"
        }
    }
}

private enum MenuBarTaskStatusImage {
    static func make(status: MenuBarTaskStatus, phase: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let color = nsColor(for: status)
        let progress = (sin(phase * 2.0 * .pi) + 1.0) / 2.0
        let pulseDiameter = 10.0 + (5.0 * progress)
        let pulseAlpha = 0.28 * (1.0 - progress)
        let pulseRect = centeredRect(size: pulseDiameter, canvas: size)

        color.withAlphaComponent(pulseAlpha).setFill()
        NSBezierPath(ovalIn: pulseRect).fill()

        let dotRect = centeredRect(size: 7.0, canvas: size)
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func nsColor(for status: MenuBarTaskStatus) -> NSColor {
        switch status {
        case .inProgress:
            return .systemYellow
        case .succeeded:
            return .systemGreen
        case .failed:
            return .systemRed
        }
    }

    private static func centeredRect(size: Double, canvas: NSSize) -> NSRect {
        NSRect(
            x: (canvas.width - size) / 2.0,
            y: (canvas.height - size) / 2.0,
            width: size,
            height: size
        )
    }
}
