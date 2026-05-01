import SwiftUI

struct AttachmentBadgeView: View {
    let count: Int
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 4) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.75)))
        }
        .buttonStyle(.plain)
        .help("\(count) file\(count == 1 ? "" : "s") attached. Click to clear.")
    }
}
