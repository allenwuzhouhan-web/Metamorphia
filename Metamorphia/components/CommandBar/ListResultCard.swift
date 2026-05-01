/*
 * Metamorphia
 * T11 — ListResultCard
 *
 * Renders a compact numbered list card when the agent's reply is ≥3 list
 * items with ≥50% list-line ratio. Scrollable up to 180 pt. Read-only.
 */

import SwiftUI

struct ListResultCard: View {
    let result: ListResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                if let title = result.title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                } else {
                    Text("List")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.items.enumerated()), id: \.element.id) { idx, item in
                        row(index: idx, item: item)
                    }
                }
            }
            .frame(maxHeight: 180)

            Text("\(result.items.count) items")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private func row(index: Int, item: ListItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
