import Foundation
import NaturalLanguage
import Accelerate

/// On-device embedding. Primary: `NLContextualEmbedding` (macOS 14+,
/// multilingual, Neural Engine). Fallback: `NLEmbedding.sentenceEmbedding`
/// (English-only, static). Both are projected/padded to a fixed 768 floats
/// so the Retrace vector column has a single dimension.
public actor Embed {

    public static let canonicalDim = 768

    public static let shared = Embed()

    // Lazy-init models. Some `NLContextualEmbedding` instances require an
    // asset download on first use — we respect `hasAvailableAssets` and
    // defer to the fallback model when the download hasn't landed yet.
    private var contextualEnglish: NLContextualEmbedding?
    private var sentenceEnglish: NLEmbedding?
    private var contextualLoadAttempted = false

    public init() {}

    /// Embed `text` into a 768-dim L2-normalized vector. Returns nil for
    /// trivially short inputs (less than 4 UTF-8 bytes) to avoid polluting
    /// the index with noise.
    public func embed(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= 4 else { return nil }

        if let vec = await contextualVector(for: trimmed) {
            return l2Normalize(project(vec, to: Self.canonicalDim))
        }
        if let vec = await sentenceVector(for: trimmed) {
            return l2Normalize(project(vec, to: Self.canonicalDim))
        }
        return nil
    }

    // MARK: - NLContextualEmbedding

    private func contextualVector(for text: String) async -> [Double]? {
        if !contextualLoadAttempted {
            contextualLoadAttempted = true
            if let model = NLContextualEmbedding(language: .english) {
                if model.hasAvailableAssets {
                    if (try? model.load()) != nil {
                        contextualEnglish = model
                    }
                }
                // Skip silent download trigger — the host app should call
                // `requestAssets()` during onboarding or a Settings action
                // to avoid surprising the user with a network hit.
            }
        }
        guard let model = contextualEnglish else { return nil }
        guard let result = try? model.embeddingResult(for: text, language: .english) else {
            return nil
        }

        // NLContextualEmbeddingResult exposes per-token vectors. Mean-pool
        // for a paragraph embedding.
        var accum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            if accum.isEmpty {
                accum = vec
            } else if accum.count == vec.count {
                for i in 0..<accum.count { accum[i] += vec[i] }
            }
            count += 1
            return true
        }
        guard count > 0, !accum.isEmpty else { return nil }
        let invN = 1.0 / Double(count)
        for i in 0..<accum.count { accum[i] *= invN }
        return accum
    }

    // MARK: - NLEmbedding

    private func sentenceVector(for text: String) async -> [Double]? {
        if sentenceEnglish == nil {
            sentenceEnglish = NLEmbedding.sentenceEmbedding(for: .english)
        }
        guard let model = sentenceEnglish else { return nil }

        // NLEmbedding.sentenceEmbedding is paragraph-scaled — feed up to
        // ~600 tokens per call to stay fast.
        let clipped = String(text.prefix(2400))
        guard let vec = model.vector(for: clipped) else { return nil }
        return vec
    }

    // MARK: - Projection / Normalization

    /// Project or pad `v` to the canonical dimension. If `v.count > dim`, we
    /// mean-pool adjacent pairs until reaching the target (dimensionality
    /// reduction with minimal loss for small ratios). If `v.count < dim`, we
    /// zero-pad at the tail (safe for cosine — zero dims contribute 0 to
    /// the dot product and are stripped by L2 normalization).
    private func project(_ v: [Double], to dim: Int) -> [Float] {
        if v.count == dim {
            return v.map { Float($0) }
        }
        if v.count > dim {
            // Simple stride-pool.
            let stride = Double(v.count) / Double(dim)
            var out = [Float](repeating: 0, count: dim)
            for i in 0..<dim {
                let start = Int(Double(i) * stride)
                let end = min(v.count, Int(Double(i + 1) * stride))
                guard end > start else { continue }
                var sum: Double = 0
                for j in start..<end { sum += v[j] }
                out[i] = Float(sum / Double(end - start))
            }
            return out
        }
        var out = [Float](repeating: 0, count: dim)
        for i in 0..<v.count { out[i] = Float(v[i]) }
        return out
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var result = v
        var norm: Float = 0
        result.withUnsafeBufferPointer { buf in
            vDSP_svesq(buf.baseAddress!, 1, &norm, vDSP_Length(buf.count))
        }
        norm = sqrt(norm)
        guard norm > 1e-8 else { return result }
        var inv = 1.0 / norm
        result.withUnsafeMutableBufferPointer { buf in
            vDSP_vsmul(buf.baseAddress!, 1, &inv, buf.baseAddress!, 1, vDSP_Length(buf.count))
        }
        return result
    }
}
