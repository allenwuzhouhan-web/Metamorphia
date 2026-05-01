/*
 * Metamorphia
 * T11 — DateResultCard
 *
 * Renders a compact date card below the result bubble when the agent's
 * terminal text matches a date pattern (<300 chars). Read-only; no haptics.
 */

import SwiftUI

struct DateResultCard: View {
    let result: DateResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Date")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }

            Text(result.formattedDate)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(result.relativeDescription)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))

            if let context = result.context, !context.isEmpty {
                Text(context)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
}
