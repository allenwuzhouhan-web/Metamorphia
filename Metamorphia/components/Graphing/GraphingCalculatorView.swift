import SwiftUI

/// A Desmos-lite graphing calculator that plots explicit, parametric, and polar curves on
/// a pannable / zoomable canvas, auto-generates sliders for any free parameter, and can
/// scatter-plot CSV pasted from the clipboard. Self-contained: all state lives in a
/// `@StateObject` view model, with no app singletons.
///
/// Seed it three ways:
///   • `GraphingCalculatorView()`                      — one default `y = x` curve.
///   • `GraphingCalculatorView(initialCurves: [...])`  — your own curves.
///   • `GraphingCalculatorView(latex: "y=\\sin x")`    — from a LaTeX equation (for the
///                                                       command bar's "plot this").
public struct GraphingCalculatorView: View {
    @StateObject private var model: GraphViewModel

    // MARK: - Initializers

    /// Seeds the calculator with an explicit list of curves (default: a single `y = x`).
    public init(initialCurves: [PlotCurve] = []) {
        _model = StateObject(wrappedValue: GraphViewModel(curves: initialCurves))
    }

    /// Seeds the calculator from a simple LaTeX equation via `LatexToPlot`. If the LaTeX
    /// can't be understood it falls back to a default curve rather than showing nothing.
    public init(latex: String) {
        let curves: [PlotCurve]
        if let plot = LatexToPlot.expression(fromLatex: latex) {
            curves = [PlotCurve(kind: plot.kind, expressionA: plot.a, expressionB: plot.b)]
        } else {
            curves = []
        }
        _model = StateObject(wrappedValue: GraphViewModel(curves: curves))
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GraphCanvas(model: model)
                .frame(minHeight: 220)
                .overlay(alignment: .topTrailing) { canvasButtons }

            curveList

            if !model.parameterNames.isEmpty {
                parameterSliders
            }

            if model.hasData {
                dataSeriesList
            }

            footerButtons
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
    }

    // MARK: - Canvas overlay buttons

    private var canvasButtons: some View {
        HStack(spacing: 6) {
            iconButton("arrow.up.left.and.arrow.down.right", help: "Fit to content") {
                withAnimation(.easeOut(duration: 0.25)) { model.fitToContent() }
            }
            iconButton("scope", help: "Reset view") {
                withAnimation(.easeOut(duration: 0.25)) { model.resetViewport() }
            }
        }
        .padding(10)
    }

    // MARK: - Curve rows

    private var curveList: some View {
        VStack(spacing: 8) {
            ForEach($model.curves) { $curve in
                CurveRow(curve: $curve) {
                    model.inputsChanged()
                } onDelete: {
                    withAnimation(.easeInOut(duration: 0.18)) { model.removeCurve(curve.id) }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { model.addCurve() }
            } label: {
                Label("Add curve", systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.65))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Parameter sliders

    private var parameterSliders: some View {
        VStack(spacing: 6) {
            ForEach(model.parameterNames, id: \.self) { name in
                HStack(spacing: 10) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(minWidth: 18, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { model.parameters[name] ?? 1 },
                            set: { model.parameters[name] = $0; model.parameterChanged() }
                        ),
                        in: model.parameterRange
                    )
                    .tint(Color(red: 0.5, green: 0.55, blue: 1.0))

                    Text(String(format: "%.2f", model.parameters[name] ?? 1))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Imported data series

    private var dataSeriesList: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.dataSeries.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(plotHex: GraphViewModel.palette[index % GraphViewModel.palette.count]))
                        .frame(width: 10, height: 10)
                    Text(series.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("\(series.points.count) pts")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { model.removeDataSeries(series.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Footer

    @State private var importNotice: String?

    private var footerButtons: some View {
        HStack(spacing: 10) {
            Button {
                let added = model.importClipboardCSV()
                withAnimation(.easeInOut(duration: 0.2)) {
                    importNotice = added > 0
                        ? "Added \(added) series"
                        : "No numeric data on clipboard"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    withAnimation(.easeInOut(duration: 0.2)) { importNotice = nil }
                }
            } label: {
                Label("Plot clipboard CSV", systemImage: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.65))

            if let notice = importNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .transition(.opacity)
            }
            Spacer()
        }
    }

    // MARK: - Small building blocks

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Curve row

/// One editable curve: expression field(s), kind picker, colour swatch, enable toggle,
/// and a delete button. The second expression field only appears for parametric curves.
private struct CurveRow: View {
    @Binding var curve: PlotCurve
    let onChange: () -> Void
    let onDelete: () -> Void

    private var swatchColor: Binding<Color> {
        Binding(
            get: { Color(plotHex: curve.colorHex) },
            set: { curve.colorHex = $0.plotHexString; onChange() }
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ColorPicker("", selection: swatchColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 24, height: 24)

                Toggle("", isOn: Binding(
                    get: { curve.enabled },
                    set: { curve.enabled = $0; onChange() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.7)
                .frame(width: 36)

                expressionField(prompt: promptA, text: Binding(
                    get: { curve.expressionA },
                    set: { curve.expressionA = $0; onChange() }
                ))

                Picker("", selection: Binding(
                    get: { curve.kind },
                    set: { curve.kind = $0; onChange() }
                )) {
                    Text("y=f(x)").tag(PlotKind.explicit)
                    Text("param").tag(PlotKind.parametric)
                    Text("polar").tag(PlotKind.polar)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 92)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            if curve.kind == .parametric {
                HStack(spacing: 8) {
                    Spacer().frame(width: 24 + 36 + 16)
                    expressionField(prompt: "y(t)", text: Binding(
                        get: { curve.expressionB },
                        set: { curve.expressionB = $0; onChange() }
                    ))
                    Spacer().frame(width: 92 + 8 + 12)
                }
            }
        }
        .opacity(curve.enabled ? 1 : 0.45)
    }

    private var promptA: String {
        switch curve.kind {
        case .explicit: return "f(x)"
        case .parametric: return "x(t)"
        case .polar: return "r(\u{03B8})"
        }
    }

    private func expressionField(prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(parses(text.wrappedValue) ? Color.clear : Color.red.opacity(0.4),
                                  lineWidth: 1)
            )
    }

    /// Whether the field's text parses, used only to tint the border (never crashes).
    private func parses(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || PlotExpression(trimmed) != nil
    }
}
