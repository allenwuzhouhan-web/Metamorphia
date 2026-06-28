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

    private init() {}

    func update(from inputBarState: InputBarState) {
        status = MenuBarTaskStatus(inputBarState: inputBarState)
    }
}

struct MenuBarTaskStatusDot: View {
    @ObservedObject private var store = MenuBarTaskStatusStore.shared

    var body: some View {
        Group {
            if store.status == .inProgress {
                // Only the in-progress state pulses, so the schedule runs solely
                // while a task is active and stops the moment it finishes.
                // Throttle to ~15fps so a long-running task doesn't churn a fresh
                // NSImage/CGContext per display frame (up to 120Hz on ProMotion)
                // just to redraw an 18x18 dot; the pulse stays smooth to the eye.
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
                    dotImage(phase: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // Idle/static states render a single frame with no timer, so the
                // menu-bar item can sleep and App Nap can engage.
                dotImage(phase: 0)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func dotImage(phase: Double) -> some View {
        Image(nsImage: MenuBarTaskStatusImage.make(status: store.status, phase: phase))
            .resizable()
            .interpolation(.high)
            .renderingMode(.original)
            .accessibilityLabel(accessibilityLabel)
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
