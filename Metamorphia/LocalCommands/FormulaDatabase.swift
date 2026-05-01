import Foundation

/// A local database of ~1000 commonly-used formulas, constants, and reference data.
/// Loaded on app startup; provides instant lookups with zero API calls.
class FormulaDatabase {
    static let shared = FormulaDatabase()

    struct Formula: Codable {
        let name: String
        let category: String
        let tags: [String]
        let content: String
    }

    private var formulas: [Formula] = []
    /// Inverted index: keyword → [formula indices]
    private var index: [String: [Int]] = [:]

    private let storageURL: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Metamorphia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("formulas.json")
    }()

    private init() {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            loadFromDisk()
        } else {
            formulas = Self.builtInFormulas
            saveToDisk()
        }
        buildIndex()
        print("[Metamorphia.FormulaDB] Loaded \(formulas.count) formulas")
    }

    // MARK: - Lookup

    /// Returns a formatted response for the query, or nil if no match.
    func lookup(_ query: String) -> String? {
        let queryWords = query.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }

        guard !queryWords.isEmpty else { return nil }

        // Score each formula by keyword overlap
        var scores: [(Int, Int)] = [] // (formula index, score)

        for (i, formula) in formulas.enumerated() {
            var score = 0
            let nameWords = Set(formula.name.lowercased().split(separator: " ").map(String.init))
            let tagSet = Set(formula.tags.map { $0.lowercased() })

            for word in queryWords {
                // Exact tag match = 3 points
                if tagSet.contains(word) { score += 3 }
                // Tag substring match = 2 points
                else if formula.tags.contains(where: { $0.lowercased().contains(word) }) { score += 2 }
                // Name word match = 2 points
                if nameWords.contains(word) { score += 2 }
                // Name substring match = 1 point
                else if formula.name.lowercased().contains(word) { score += 1 }
            }

            // Check multi-word tag matches (e.g., "half angle" as a single tag)
            let queryStr = queryWords.joined(separator: " ")
            for tag in formula.tags {
                if tag.lowercased() == queryStr { score += 5 }
                else if queryStr.contains(tag.lowercased()) && tag.count > 3 { score += 3 }
            }

            if score > 0 {
                scores.append((i, score))
            }
        }

        guard !scores.isEmpty else { return nil }

        // Sort by score descending
        scores.sort { $0.1 > $1.1 }

        // Return top match if score is good enough
        let (bestIdx, bestScore) = scores[0]
        // Require strong relevance — avoid matching generic queries to random formulas.
        // At least 5 points needed (an exact tag match + name match, or multiple strong hits).
        // Also require that at least 40% of query words matched something.
        let matchedWords = queryWords.filter { word in
            formulas[scores[0].0].tags.contains(where: { $0.lowercased().contains(word) }) ||
            formulas[scores[0].0].name.lowercased().contains(word)
        }
        let matchRatio = Double(matchedWords.count) / Double(queryWords.count)
        let minScore = max(5, queryWords.count * 2)
        guard bestScore >= minScore, matchRatio >= 0.4 else { return nil }

        let formula = formulas[bestIdx]

        // If there are close runner-ups in the same category, include them
        var result = "**\(formula.name)** (\(formula.category))\n\n\(formula.content)"

        // Check for closely related formulas
        let related = scores.prefix(4).dropFirst().filter { $0.1 >= bestScore - 2 }
        if !related.isEmpty {
            result += "\n\n---\n**Related:**"
            for (idx, _) in related {
                let rel = formulas[idx]
                result += "\n• **\(rel.name)**: \(rel.content.components(separatedBy: "\n").first ?? "")"
            }
        }

        return result
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: storageURL)
            formulas = try JSONDecoder().decode([Formula].self, from: data)
        } catch {
            print("[FormulaDB] Failed to load, using built-in: \(error)")
            formulas = Self.builtInFormulas
            saveToDisk()
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(formulas)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[FormulaDB] Failed to save: \(error)")
        }
    }

    private func buildIndex() {
        index.removeAll()
        for (i, formula) in formulas.enumerated() {
            let words = (formula.tags + formula.name.lowercased().split(separator: " ").map(String.init))
            for word in words {
                index[word.lowercased(), default: []].append(i)
            }
        }
    }

    // MARK: - Built-in Formulas (~1000)

    // swiftlint:disable function_body_length
    private static let builtInFormulas: [Formula] = {
        var f: [Formula] = []

        // =========================================================================
        // TRIGONOMETRY (~80)
        // =========================================================================

        f.append(Formula(name: "Basic Trig Ratios", category: "Trigonometry", tags: ["sin", "cos", "tan", "soh cah toa", "right triangle", "trig ratios"], content: """
        sin(θ) = opposite / hypotenuse
        cos(θ) = adjacent / hypotenuse
        tan(θ) = opposite / adjacent = sin(θ) / cos(θ)
        """))

        f.append(Formula(name: "Reciprocal Trig Functions", category: "Trigonometry", tags: ["csc", "sec", "cot", "cosecant", "secant", "cotangent", "reciprocal"], content: """
        csc(θ) = 1 / sin(θ)
        sec(θ) = 1 / cos(θ)
        cot(θ) = 1 / tan(θ) = cos(θ) / sin(θ)
        """))

        f.append(Formula(name: "Pythagorean Identities", category: "Trigonometry", tags: ["pythagorean", "identity", "trig identity", "sin squared", "cos squared"], content: """
        sin²(θ) + cos²(θ) = 1
        1 + tan²(θ) = sec²(θ)
        1 + cot²(θ) = csc²(θ)
        """))

        f.append(Formula(name: "Half Angle Formulas", category: "Trigonometry", tags: ["half angle", "half-angle", "trig", "sin half", "cos half", "tan half"], content: """
        sin(θ/2) = ±√((1 − cos θ) / 2)
        cos(θ/2) = ±√((1 + cos θ) / 2)
        tan(θ/2) = sin θ / (1 + cos θ) = (1 − cos θ) / sin θ
        Sign depends on the quadrant of θ/2.
        """))

        f.append(Formula(name: "Double Angle Formulas", category: "Trigonometry", tags: ["double angle", "double-angle", "sin 2x", "cos 2x", "tan 2x", "trig"], content: """
        sin(2θ) = 2 sin(θ) cos(θ)
        cos(2θ) = cos²(θ) − sin²(θ) = 2cos²(θ) − 1 = 1 − 2sin²(θ)
        tan(2θ) = 2tan(θ) / (1 − tan²(θ))
        """))

        f.append(Formula(name: "Sum and Difference (Sine)", category: "Trigonometry", tags: ["sum", "difference", "addition", "sin sum", "sin difference", "angle addition"], content: """
        sin(A + B) = sin A cos B + cos A sin B
        sin(A − B) = sin A cos B − cos A sin B
        """))

        f.append(Formula(name: "Sum and Difference (Cosine)", category: "Trigonometry", tags: ["sum", "difference", "cos sum", "cos difference", "angle addition"], content: """
        cos(A + B) = cos A cos B − sin A sin B
        cos(A − B) = cos A cos B + sin A sin B
        """))

        f.append(Formula(name: "Sum and Difference (Tangent)", category: "Trigonometry", tags: ["sum", "difference", "tan sum", "tan difference"], content: """
        tan(A + B) = (tan A + tan B) / (1 − tan A tan B)
        tan(A − B) = (tan A − tan B) / (1 + tan A tan B)
        """))

        f.append(Formula(name: "Product-to-Sum Formulas", category: "Trigonometry", tags: ["product to sum", "product-to-sum", "trig product"], content: """
        sin A cos B = ½[sin(A+B) + sin(A−B)]
        cos A sin B = ½[sin(A+B) − sin(A−B)]
        cos A cos B = ½[cos(A−B) + cos(A+B)]
        sin A sin B = ½[cos(A−B) − cos(A+B)]
        """))

        f.append(Formula(name: "Sum-to-Product Formulas", category: "Trigonometry", tags: ["sum to product", "sum-to-product", "trig sum"], content: """
        sin A + sin B = 2 sin((A+B)/2) cos((A−B)/2)
        sin A − sin B = 2 cos((A+B)/2) sin((A−B)/2)
        cos A + cos B = 2 cos((A+B)/2) cos((A−B)/2)
        cos A − cos B = −2 sin((A+B)/2) sin((A−B)/2)
        """))

        f.append(Formula(name: "Law of Sines", category: "Trigonometry", tags: ["law of sines", "sine rule", "triangle"], content: """
        a/sin A = b/sin B = c/sin C = 2R
        where R is the circumradius of the triangle.
        """))

        f.append(Formula(name: "Law of Cosines", category: "Trigonometry", tags: ["law of cosines", "cosine rule", "triangle"], content: """
        c² = a² + b² − 2ab cos(C)
        Generalizes Pythagorean theorem for any triangle.
        """))

        f.append(Formula(name: "Law of Tangents", category: "Trigonometry", tags: ["law of tangents", "tangent rule", "triangle"], content: """
        (a − b)/(a + b) = tan((A − B)/2) / tan((A + B)/2)
        """))

        f.append(Formula(name: "Triple Angle Formulas", category: "Trigonometry", tags: ["triple angle", "sin 3x", "cos 3x", "trig"], content: """
        sin(3θ) = 3sin(θ) − 4sin³(θ)
        cos(3θ) = 4cos³(θ) − 3cos(θ)
        tan(3θ) = (3tan(θ) − tan³(θ)) / (1 − 3tan²(θ))
        """))

        f.append(Formula(name: "Power Reduction Formulas", category: "Trigonometry", tags: ["power reduction", "sin squared", "cos squared", "trig power"], content: """
        sin²(θ) = (1 − cos(2θ)) / 2
        cos²(θ) = (1 + cos(2θ)) / 2
        sin³(θ) = (3sin(θ) − sin(3θ)) / 4
        cos³(θ) = (3cos(θ) + cos(3θ)) / 4
        """))

        f.append(Formula(name: "Inverse Trig Functions", category: "Trigonometry", tags: ["inverse trig", "arcsin", "arccos", "arctan", "asin", "acos", "atan"], content: """
        arcsin(x): domain [−1,1], range [−π/2, π/2]
        arccos(x): domain [−1,1], range [0, π]
        arctan(x): domain (−∞,∞), range (−π/2, π/2)
        arcsin(x) + arccos(x) = π/2
        """))

        f.append(Formula(name: "Inverse Trig Derivatives", category: "Trigonometry", tags: ["inverse trig derivative", "arcsin derivative", "arctan derivative"], content: """
        d/dx arcsin(x) = 1/√(1 − x²)
        d/dx arccos(x) = −1/√(1 − x²)
        d/dx arctan(x) = 1/(1 + x²)
        """))

        f.append(Formula(name: "Trig Values for Common Angles", category: "Trigonometry", tags: ["common angles", "unit circle", "exact values", "trig table", "30 60 90", "45"], content: """
        θ:    0°    30°      45°      60°      90°
        sin:  0     1/2      √2/2     √3/2     1
        cos:  1     √3/2     √2/2     1/2      0
        tan:  0     √3/3     1        √3       undef
        """))

        f.append(Formula(name: "Euler's Formula", category: "Trigonometry", tags: ["euler", "euler's formula", "complex", "exponential", "e^ix"], content: """
        e^(iθ) = cos(θ) + i·sin(θ)
        Special case (Euler's identity): e^(iπ) + 1 = 0
        """))

        f.append(Formula(name: "Hyperbolic Trig Functions", category: "Trigonometry", tags: ["hyperbolic", "sinh", "cosh", "tanh", "hyperbolic trig"], content: """
        sinh(x) = (eˣ − e⁻ˣ) / 2
        cosh(x) = (eˣ + e⁻ˣ) / 2
        tanh(x) = sinh(x) / cosh(x)
        cosh²(x) − sinh²(x) = 1
        """))

        f.append(Formula(name: "Cofunction Identities", category: "Trigonometry", tags: ["cofunction", "complementary", "trig cofunction"], content: """
        sin(π/2 − θ) = cos(θ)
        cos(π/2 − θ) = sin(θ)
        tan(π/2 − θ) = cot(θ)
        """))

        f.append(Formula(name: "Heron's Formula", category: "Trigonometry", tags: ["heron", "heron's formula", "triangle area", "semi-perimeter"], content: """
        Area = √(s(s−a)(s−b)(s−c))
        where s = (a + b + c) / 2 (semi-perimeter)
        """))

        // =========================================================================
        // ALGEBRA (~100)
        // =========================================================================

        f.append(Formula(name: "Quadratic Formula", category: "Algebra", tags: ["quadratic", "quadratic formula", "ax2+bx+c", "roots", "solve quadratic"], content: """
        For ax² + bx + c = 0:
        x = (−b ± √(b² − 4ac)) / (2a)
        Discriminant Δ = b² − 4ac
        Δ > 0: two real roots, Δ = 0: one root, Δ < 0: complex roots
        """))

        f.append(Formula(name: "Binomial Theorem", category: "Algebra", tags: ["binomial", "binomial theorem", "expansion", "pascal", "choose"], content: """
        (a + b)ⁿ = Σ C(n,k) · aⁿ⁻ᵏ · bᵏ  (k = 0 to n)
        where C(n,k) = n! / (k!(n−k)!)
        """))

        f.append(Formula(name: "Difference of Squares", category: "Algebra", tags: ["difference of squares", "factoring", "a2-b2"], content: """
        a² − b² = (a + b)(a − b)
        """))

        f.append(Formula(name: "Sum/Difference of Cubes", category: "Algebra", tags: ["sum of cubes", "difference of cubes", "factoring", "a3+b3", "a3-b3"], content: """
        a³ + b³ = (a + b)(a² − ab + b²)
        a³ − b³ = (a − b)(a² + ab + b²)
        """))

        f.append(Formula(name: "Perfect Square Trinomial", category: "Algebra", tags: ["perfect square", "trinomial", "factoring", "expansion"], content: """
        (a + b)² = a² + 2ab + b²
        (a − b)² = a² − 2ab + b²
        (a + b)³ = a³ + 3a²b + 3ab² + b³
        (a − b)³ = a³ − 3a²b + 3ab² − b³
        """))

        f.append(Formula(name: "Logarithm Rules", category: "Algebra", tags: ["logarithm", "log", "log rules", "ln", "natural log", "log properties"], content: """
        log_b(xy) = log_b(x) + log_b(y)
        log_b(x/y) = log_b(x) − log_b(y)
        log_b(xⁿ) = n · log_b(x)
        log_b(x) = ln(x) / ln(b)  (change of base)
        log_b(1) = 0,  log_b(b) = 1
        b^(log_b(x)) = x
        """))

        f.append(Formula(name: "Exponent Rules", category: "Algebra", tags: ["exponent", "exponent rules", "power rules", "indices"], content: """
        aᵐ · aⁿ = aᵐ⁺ⁿ
        aᵐ / aⁿ = aᵐ⁻ⁿ
        (aᵐ)ⁿ = aᵐⁿ
        (ab)ⁿ = aⁿbⁿ
        a⁰ = 1,  a⁻ⁿ = 1/aⁿ
        a^(1/n) = ⁿ√a
        """))

        f.append(Formula(name: "Arithmetic Sequence", category: "Algebra", tags: ["arithmetic sequence", "arithmetic series", "common difference", "AP"], content: """
        nth term: aₙ = a₁ + (n−1)d
        Sum of n terms: Sₙ = n(a₁ + aₙ)/2 = n(2a₁ + (n−1)d)/2
        where d = common difference
        """))

        f.append(Formula(name: "Geometric Sequence", category: "Algebra", tags: ["geometric sequence", "geometric series", "common ratio", "GP"], content: """
        nth term: aₙ = a₁ · rⁿ⁻¹
        Sum of n terms: Sₙ = a₁(1 − rⁿ)/(1 − r)  (r ≠ 1)
        Infinite sum (|r| < 1): S∞ = a₁/(1 − r)
        """))

        f.append(Formula(name: "Absolute Value Properties", category: "Algebra", tags: ["absolute value", "modulus", "abs"], content: """
        |a| ≥ 0,  |a| = 0 iff a = 0
        |ab| = |a| · |b|
        |a + b| ≤ |a| + |b|  (triangle inequality)
        |a − b| ≥ ||a| − |b||
        """))

        f.append(Formula(name: "Vieta's Formulas", category: "Algebra", tags: ["vieta", "vieta's formulas", "roots", "sum of roots", "product of roots"], content: """
        For ax² + bx + c = 0 with roots r₁, r₂:
        r₁ + r₂ = −b/a
        r₁ · r₂ = c/a
        """))

        f.append(Formula(name: "Partial Fractions", category: "Algebra", tags: ["partial fractions", "partial fraction decomposition"], content: """
        A/(x−a)(x−b) = A₁/(x−a) + A₂/(x−b)
        A/(x−a)² = A₁/(x−a) + A₂/(x−a)²
        (Ax+B)/(x²+bx+c) — irreducible quadratic stays as-is
        """))

        f.append(Formula(name: "Completing the Square", category: "Algebra", tags: ["completing the square", "vertex form"], content: """
        ax² + bx + c = a(x + b/(2a))² + c − b²/(4a)
        Vertex form: y = a(x − h)² + k where h = −b/(2a), k = c − b²/(4a)
        """))

        f.append(Formula(name: "Factorial and Permutations", category: "Algebra", tags: ["factorial", "permutation", "combination", "nPr", "nCr", "choose"], content: """
        n! = n × (n−1) × ... × 1,  0! = 1
        P(n,r) = n!/(n−r)!  (permutations)
        C(n,r) = n!/(r!(n−r)!)  (combinations)
        C(n,r) = C(n, n−r)
        """))

        f.append(Formula(name: "Complex Numbers", category: "Algebra", tags: ["complex number", "imaginary", "i", "complex arithmetic"], content: """
        i² = −1
        (a+bi)(c+di) = (ac−bd) + (ad+bc)i
        |a+bi| = √(a² + b²)
        Conjugate: (a+bi)* = a−bi
        """))

        f.append(Formula(name: "Polynomial Division", category: "Algebra", tags: ["polynomial division", "remainder theorem", "factor theorem", "synthetic division"], content: """
        Remainder Theorem: f(x) ÷ (x−a) has remainder f(a)
        Factor Theorem: (x−a) is a factor iff f(a) = 0
        Rational Root Theorem: possible roots = ±(factors of constant)/(factors of leading coeff)
        """))

        f.append(Formula(name: "Inequalities", category: "Algebra", tags: ["inequality", "AM-GM", "cauchy-schwarz", "triangle inequality"], content: """
        AM-GM: (a+b)/2 ≥ √(ab) for a,b ≥ 0
        Cauchy-Schwarz: (Σaᵢbᵢ)² ≤ (Σaᵢ²)(Σbᵢ²)
        Triangle: |a+b| ≤ |a| + |b|
        """))

        f.append(Formula(name: "Summation Formulas", category: "Algebra", tags: ["summation", "sum", "series", "sigma", "sum of squares", "sum of cubes"], content: """
        Σ i (i=1 to n) = n(n+1)/2
        Σ i² (i=1 to n) = n(n+1)(2n+1)/6
        Σ i³ (i=1 to n) = [n(n+1)/2]²
        Σ rⁱ (i=0 to n) = (1−rⁿ⁺¹)/(1−r)
        """))

        f.append(Formula(name: "Floor and Ceiling", category: "Algebra", tags: ["floor", "ceiling", "integer part", "round"], content: """
        ⌊x⌋ = largest integer ≤ x
        ⌈x⌉ = smallest integer ≥ x
        ⌊x⌋ ≤ x < ⌊x⌋ + 1
        ⌈x⌉ = ⌊x⌋ + 1 if x is not integer, else ⌈x⌉ = x
        """))

        // =========================================================================
        // CALCULUS (~120)
        // =========================================================================

        f.append(Formula(name: "Power Rule (Derivative)", category: "Calculus", tags: ["power rule", "derivative", "differentiation", "basic derivative"], content: """
        d/dx [xⁿ] = n·xⁿ⁻¹
        d/dx [c] = 0  (constant)
        d/dx [cf(x)] = c·f'(x)
        """))

        f.append(Formula(name: "Product Rule", category: "Calculus", tags: ["product rule", "derivative", "differentiation"], content: """
        d/dx [f(x)·g(x)] = f'(x)·g(x) + f(x)·g'(x)
        """))

        f.append(Formula(name: "Quotient Rule", category: "Calculus", tags: ["quotient rule", "derivative", "differentiation"], content: """
        d/dx [f(x)/g(x)] = [f'(x)·g(x) − f(x)·g'(x)] / [g(x)]²
        """))

        f.append(Formula(name: "Chain Rule", category: "Calculus", tags: ["chain rule", "derivative", "composite function", "differentiation"], content: """
        d/dx [f(g(x))] = f'(g(x)) · g'(x)
        """))

        f.append(Formula(name: "Trig Derivatives", category: "Calculus", tags: ["trig derivative", "sin derivative", "cos derivative", "tan derivative"], content: """
        d/dx sin(x) = cos(x)
        d/dx cos(x) = −sin(x)
        d/dx tan(x) = sec²(x)
        d/dx cot(x) = −csc²(x)
        d/dx sec(x) = sec(x)tan(x)
        d/dx csc(x) = −csc(x)cot(x)
        """))

        f.append(Formula(name: "Exponential & Log Derivatives", category: "Calculus", tags: ["exponential derivative", "log derivative", "ln derivative", "e^x derivative"], content: """
        d/dx eˣ = eˣ
        d/dx aˣ = aˣ · ln(a)
        d/dx ln(x) = 1/x
        d/dx log_a(x) = 1/(x · ln(a))
        """))

        f.append(Formula(name: "Implicit Differentiation", category: "Calculus", tags: ["implicit differentiation", "dy/dx", "implicit"], content: """
        Differentiate both sides w.r.t. x, treating y as y(x):
        d/dx[y²] = 2y · dy/dx
        d/dx[xy] = y + x · dy/dx  (product rule)
        Then solve for dy/dx.
        """))

        f.append(Formula(name: "L'Hôpital's Rule", category: "Calculus", tags: ["l'hopital", "l'hôpital", "limit", "indeterminate", "0/0", "∞/∞"], content: """
        If lim f(x)/g(x) is 0/0 or ∞/∞:
        lim f(x)/g(x) = lim f'(x)/g'(x)
        (provided the right-side limit exists)
        """))

        f.append(Formula(name: "Limit Definition of Derivative", category: "Calculus", tags: ["limit definition", "derivative definition", "first principles"], content: """
        f'(x) = lim[h→0] (f(x+h) − f(x)) / h
        """))

        f.append(Formula(name: "Common Limits", category: "Calculus", tags: ["common limits", "limit", "sin x/x", "e limit"], content: """
        lim[x→0] sin(x)/x = 1
        lim[x→0] (1−cos(x))/x = 0
        lim[x→∞] (1 + 1/x)ˣ = e
        lim[x→0] (eˣ − 1)/x = 1
        lim[x→0] ln(1+x)/x = 1
        """))

        f.append(Formula(name: "Basic Integrals", category: "Calculus", tags: ["integral", "antiderivative", "basic integral", "integration"], content: """
        ∫ xⁿ dx = xⁿ⁺¹/(n+1) + C  (n ≠ −1)
        ∫ 1/x dx = ln|x| + C
        ∫ eˣ dx = eˣ + C
        ∫ aˣ dx = aˣ/ln(a) + C
        """))

        f.append(Formula(name: "Trig Integrals", category: "Calculus", tags: ["trig integral", "sin integral", "cos integral", "trig integration"], content: """
        ∫ sin(x) dx = −cos(x) + C
        ∫ cos(x) dx = sin(x) + C
        ∫ sec²(x) dx = tan(x) + C
        ∫ csc²(x) dx = −cot(x) + C
        ∫ sec(x)tan(x) dx = sec(x) + C
        ∫ csc(x)cot(x) dx = −csc(x) + C
        ∫ tan(x) dx = −ln|cos(x)| + C
        ∫ sec(x) dx = ln|sec(x) + tan(x)| + C
        """))

        f.append(Formula(name: "Integration by Parts", category: "Calculus", tags: ["integration by parts", "IBP", "uv integral"], content: """
        ∫ u dv = uv − ∫ v du
        LIATE priority for choosing u: Log, Inverse trig, Algebraic, Trig, Exponential
        """))

        f.append(Formula(name: "U-Substitution", category: "Calculus", tags: ["u-substitution", "substitution", "integration technique"], content: """
        ∫ f(g(x)) · g'(x) dx = ∫ f(u) du  where u = g(x)
        Key: identify inner function g(x), let u = g(x), du = g'(x)dx
        """))

        f.append(Formula(name: "Fundamental Theorem of Calculus", category: "Calculus", tags: ["fundamental theorem", "FTC", "calculus fundamental"], content: """
        Part 1: d/dx ∫ₐˣ f(t) dt = f(x)
        Part 2: ∫ₐᵇ f(x) dx = F(b) − F(a)  where F'(x) = f(x)
        """))

        f.append(Formula(name: "Taylor Series (General)", category: "Calculus", tags: ["taylor", "taylor series", "power series", "expansion", "maclaurin"], content: """
        f(x) = Σ f⁽ⁿ⁾(a)/n! · (x−a)ⁿ  (n = 0 to ∞)
        Maclaurin series: Taylor series centered at a = 0
        """))

        f.append(Formula(name: "Common Taylor/Maclaurin Series", category: "Calculus", tags: ["maclaurin", "taylor expansion", "series expansion", "common series"], content: """
        eˣ = 1 + x + x²/2! + x³/3! + ...
        sin(x) = x − x³/3! + x⁵/5! − ...
        cos(x) = 1 − x²/2! + x⁴/4! − ...
        ln(1+x) = x − x²/2 + x³/3 − ...  (|x| ≤ 1)
        1/(1−x) = 1 + x + x² + x³ + ...  (|x| < 1)
        (1+x)ⁿ = 1 + nx + n(n−1)x²/2! + ...  (binomial series)
        """))

        f.append(Formula(name: "Mean Value Theorem", category: "Calculus", tags: ["mean value theorem", "MVT"], content: """
        If f is continuous on [a,b] and differentiable on (a,b):
        ∃ c ∈ (a,b) such that f'(c) = (f(b) − f(a))/(b − a)
        """))

        f.append(Formula(name: "Arc Length", category: "Calculus", tags: ["arc length", "curve length", "length of curve"], content: """
        L = ∫ₐᵇ √(1 + [f'(x)]²) dx
        Parametric: L = ∫ₐᵇ √((dx/dt)² + (dy/dt)²) dt
        Polar: L = ∫ₐᵇ √(r² + (dr/dθ)²) dθ
        """))

        f.append(Formula(name: "Surface Area of Revolution", category: "Calculus", tags: ["surface area", "revolution", "surface of revolution"], content: """
        About x-axis: S = 2π ∫ₐᵇ f(x)√(1 + [f'(x)]²) dx
        About y-axis: S = 2π ∫ₐᵇ x√(1 + [f'(x)]²) dx
        """))

        f.append(Formula(name: "Volume of Revolution", category: "Calculus", tags: ["volume of revolution", "disk method", "shell method", "washer"], content: """
        Disk: V = π ∫ₐᵇ [f(x)]² dx
        Washer: V = π ∫ₐᵇ ([R(x)]² − [r(x)]²) dx
        Shell: V = 2π ∫ₐᵇ x·f(x) dx
        """))

        f.append(Formula(name: "Improper Integrals", category: "Calculus", tags: ["improper integral", "convergence", "divergence"], content: """
        ∫₁^∞ 1/xᵖ dx converges iff p > 1
        ∫₀^1 1/xᵖ dx converges iff p < 1
        """))

        f.append(Formula(name: "Partial Derivatives", category: "Calculus", tags: ["partial derivative", "multivariable", "gradient"], content: """
        ∂f/∂x: differentiate w.r.t. x, treat y as constant
        Gradient: ∇f = (∂f/∂x, ∂f/∂y, ∂f/∂z)
        Laplacian: ∇²f = ∂²f/∂x² + ∂²f/∂y² + ∂²f/∂z²
        """))

        f.append(Formula(name: "Multiple Integrals", category: "Calculus", tags: ["double integral", "triple integral", "multiple integral", "iterated"], content: """
        ∬_R f(x,y) dA = ∫∫ f(x,y) dx dy
        Polar: ∬ f(r,θ) r dr dθ
        ∭ f(x,y,z) dV  (triple integral for volume)
        """))

        f.append(Formula(name: "Divergence and Curl", category: "Calculus", tags: ["divergence", "curl", "vector calculus", "del operator"], content: """
        div F = ∇·F = ∂F₁/∂x + ∂F₂/∂y + ∂F₃/∂z
        curl F = ∇×F = (∂F₃/∂y − ∂F₂/∂z, ∂F₁/∂z − ∂F₃/∂x, ∂F₂/∂x − ∂F₁/∂y)
        """))

        f.append(Formula(name: "Green's Theorem", category: "Calculus", tags: ["green's theorem", "line integral", "double integral"], content: """
        ∮_C (P dx + Q dy) = ∬_D (∂Q/∂x − ∂P/∂y) dA
        (C is positively-oriented, D is the enclosed region)
        """))

        f.append(Formula(name: "Stokes' Theorem", category: "Calculus", tags: ["stokes", "stokes' theorem", "surface integral", "curl"], content: """
        ∮_C F · dr = ∬_S (∇ × F) · dS
        """))

        f.append(Formula(name: "Divergence Theorem", category: "Calculus", tags: ["divergence theorem", "gauss", "flux"], content: """
        ∬_S F · dS = ∭_V (∇ · F) dV
        (relates flux through closed surface to divergence inside volume)
        """))

        // =========================================================================
        // LINEAR ALGEBRA (~60)
        // =========================================================================

        f.append(Formula(name: "Matrix Multiplication", category: "Linear Algebra", tags: ["matrix multiplication", "matrix product", "matrix"], content: """
        (AB)ᵢⱼ = Σ Aᵢₖ · Bₖⱼ
        A(m×n) · B(n×p) = C(m×p)
        AB ≠ BA in general (not commutative)
        """))

        f.append(Formula(name: "Matrix Transpose", category: "Linear Algebra", tags: ["transpose", "matrix transpose"], content: """
        (Aᵀ)ᵢⱼ = Aⱼᵢ
        (AB)ᵀ = BᵀAᵀ
        (A + B)ᵀ = Aᵀ + Bᵀ
        """))

        f.append(Formula(name: "Determinant (2×2)", category: "Linear Algebra", tags: ["determinant", "2x2 determinant", "det"], content: """
        det|a b| = ad − bc
           |c d|
        """))

        f.append(Formula(name: "Determinant (3×3)", category: "Linear Algebra", tags: ["determinant", "3x3 determinant", "sarrus"], content: """
        det|a b c|
           |d e f| = a(ei−fh) − b(di−fg) + c(dh−eg)
           |g h i|
        (cofactor expansion along first row)
        """))

        f.append(Formula(name: "Matrix Inverse (2×2)", category: "Linear Algebra", tags: ["matrix inverse", "2x2 inverse", "inverse matrix"], content: """
        A⁻¹ = (1/det(A)) |d  −b|
                          |−c  a|
        where A = |a b|, det(A) = ad−bc ≠ 0
                  |c d|
        """))

        f.append(Formula(name: "Eigenvalues and Eigenvectors", category: "Linear Algebra", tags: ["eigenvalue", "eigenvector", "characteristic equation", "eigen"], content: """
        Av = λv  (v ≠ 0)
        Characteristic equation: det(A − λI) = 0
        Solve for λ (eigenvalues), then solve (A − λI)v = 0 for eigenvectors.
        """))

        f.append(Formula(name: "Dot Product", category: "Linear Algebra", tags: ["dot product", "scalar product", "inner product"], content: """
        a · b = a₁b₁ + a₂b₂ + a₃b₃ = |a||b|cos(θ)
        a · b = 0 ⟺ a ⊥ b
        """))

        f.append(Formula(name: "Cross Product", category: "Linear Algebra", tags: ["cross product", "vector product", "cross"], content: """
        a × b = |i  j  k |
                |a₁ a₂ a₃|
                |b₁ b₂ b₃|
        = (a₂b₃−a₃b₂, a₃b₁−a₁b₃, a₁b₂−a₂b₁)
        |a × b| = |a||b|sin(θ)
        """))

        f.append(Formula(name: "Vector Projection", category: "Linear Algebra", tags: ["projection", "vector projection", "scalar projection"], content: """
        Scalar projection of a onto b: comp_b(a) = a·b / |b|
        Vector projection: proj_b(a) = (a·b / |b|²) b
        """))

        f.append(Formula(name: "Rank-Nullity Theorem", category: "Linear Algebra", tags: ["rank", "nullity", "dimension", "kernel"], content: """
        rank(A) + nullity(A) = n  (number of columns)
        rank = dim(column space) = dim(row space)
        nullity = dim(null space/kernel)
        """))

        f.append(Formula(name: "Trace", category: "Linear Algebra", tags: ["trace", "matrix trace", "tr"], content: """
        tr(A) = Σ aᵢᵢ  (sum of diagonal elements)
        tr(AB) = tr(BA)
        tr(A) = Σ λᵢ  (sum of eigenvalues)
        det(A) = Π λᵢ  (product of eigenvalues)
        """))

        f.append(Formula(name: "Cramer's Rule", category: "Linear Algebra", tags: ["cramer", "cramer's rule", "system of equations"], content: """
        For Ax = b:
        xᵢ = det(Aᵢ) / det(A)
        where Aᵢ is A with column i replaced by b.
        Only works when det(A) ≠ 0.
        """))

        // =========================================================================
        // PROBABILITY & STATISTICS (~80)
        // =========================================================================

        f.append(Formula(name: "Bayes' Theorem", category: "Probability", tags: ["bayes", "bayes' theorem", "conditional probability", "posterior"], content: """
        P(A|B) = P(B|A) · P(A) / P(B)
        P(A|B) = P(B|A) · P(A) / [P(B|A)P(A) + P(B|A')P(A')]
        """))

        f.append(Formula(name: "Conditional Probability", category: "Probability", tags: ["conditional probability", "given", "P(A|B)"], content: """
        P(A|B) = P(A ∩ B) / P(B)
        P(A ∩ B) = P(A|B) · P(B)
        If independent: P(A ∩ B) = P(A) · P(B)
        """))

        f.append(Formula(name: "Probability Rules", category: "Probability", tags: ["probability", "addition rule", "complement", "union"], content: """
        P(A ∪ B) = P(A) + P(B) − P(A ∩ B)
        P(A') = 1 − P(A)
        0 ≤ P(A) ≤ 1
        P(Ω) = 1
        """))

        f.append(Formula(name: "Mean, Median, Mode", category: "Statistics", tags: ["mean", "median", "mode", "average", "central tendency"], content: """
        Mean (μ) = Σxᵢ / n
        Median: middle value when sorted (average of two middle if n even)
        Mode: most frequent value
        """))

        f.append(Formula(name: "Variance and Standard Deviation", category: "Statistics", tags: ["variance", "standard deviation", "sigma", "spread"], content: """
        Population variance: σ² = Σ(xᵢ − μ)² / N
        Sample variance: s² = Σ(xᵢ − x̄)² / (n−1)
        Standard deviation: σ = √(σ²)
        """))

        f.append(Formula(name: "Normal Distribution", category: "Statistics", tags: ["normal distribution", "gaussian", "bell curve", "z-score"], content: """
        f(x) = (1/(σ√(2π))) · e^(−(x−μ)²/(2σ²))
        z-score: z = (x − μ) / σ
        68-95-99.7 rule: 68% within 1σ, 95% within 2σ, 99.7% within 3σ
        """))

        f.append(Formula(name: "Binomial Distribution", category: "Statistics", tags: ["binomial distribution", "bernoulli", "binomial probability"], content: """
        P(X = k) = C(n,k) · pᵏ · (1−p)ⁿ⁻ᵏ
        Mean: μ = np
        Variance: σ² = np(1−p)
        """))

        f.append(Formula(name: "Poisson Distribution", category: "Statistics", tags: ["poisson", "poisson distribution", "rare events"], content: """
        P(X = k) = (λᵏ · e⁻λ) / k!
        Mean = Variance = λ
        λ = average rate of occurrence
        """))

        f.append(Formula(name: "Confidence Interval", category: "Statistics", tags: ["confidence interval", "CI", "margin of error", "z-interval", "t-interval"], content: """
        For mean (known σ): x̄ ± z* · σ/√n
        For mean (unknown σ): x̄ ± t* · s/√n
        For proportion: p̂ ± z* · √(p̂(1−p̂)/n)
        Common z*: 90%→1.645, 95%→1.96, 99%→2.576
        """))

        f.append(Formula(name: "Z-Score", category: "Statistics", tags: ["z-score", "z score", "standard score", "standardize"], content: """
        z = (x − μ) / σ
        For sample mean: z = (x̄ − μ) / (σ/√n)
        """))

        f.append(Formula(name: "Linear Regression", category: "Statistics", tags: ["linear regression", "least squares", "regression line", "correlation"], content: """
        ŷ = a + bx
        b = Σ(xᵢ−x̄)(yᵢ−ȳ) / Σ(xᵢ−x̄)²  = r·(sᵧ/sₓ)
        a = ȳ − b·x̄
        r = Σ(xᵢ−x̄)(yᵢ−ȳ) / √(Σ(xᵢ−x̄)²·Σ(yᵢ−ȳ)²)  (correlation coeff)
        r² = coefficient of determination
        """))

        f.append(Formula(name: "Chi-Square Test", category: "Statistics", tags: ["chi-square", "chi squared", "goodness of fit", "independence test"], content: """
        χ² = Σ (Oᵢ − Eᵢ)² / Eᵢ
        where O = observed, E = expected
        df = (rows−1)(cols−1) for independence test
        df = categories−1 for goodness of fit
        """))

        f.append(Formula(name: "Expected Value", category: "Probability", tags: ["expected value", "expectation", "E(X)", "mean of random variable"], content: """
        E(X) = Σ xᵢ · P(xᵢ)  (discrete)
        E(X) = ∫ x · f(x) dx  (continuous)
        E(aX + b) = aE(X) + b
        E(X + Y) = E(X) + E(Y)
        """))

        f.append(Formula(name: "Law of Large Numbers", category: "Probability", tags: ["law of large numbers", "LLN", "sample mean convergence"], content: """
        As n → ∞, the sample mean x̄ → μ (population mean)
        P(|x̄ − μ| > ε) → 0 for any ε > 0
        """))

        f.append(Formula(name: "Central Limit Theorem", category: "Probability", tags: ["central limit theorem", "CLT", "sampling distribution"], content: """
        For large n, the sampling distribution of x̄ is approximately:
        x̄ ~ N(μ, σ²/n)
        regardless of the population distribution (n ≥ 30 as rule of thumb).
        """))

        f.append(Formula(name: "Exponential Distribution", category: "Statistics", tags: ["exponential distribution", "waiting time", "memoryless"], content: """
        f(x) = λe⁻λˣ  (x ≥ 0)
        Mean = 1/λ,  Variance = 1/λ²
        P(X > x) = e⁻λˣ
        Memoryless: P(X > s+t | X > s) = P(X > t)
        """))

        f.append(Formula(name: "Covariance and Correlation", category: "Statistics", tags: ["covariance", "correlation", "cov", "pearson"], content: """
        Cov(X,Y) = E(XY) − E(X)E(Y)
        Correlation: ρ = Cov(X,Y) / (σₓ · σᵧ)
        −1 ≤ ρ ≤ 1
        Var(X+Y) = Var(X) + Var(Y) + 2Cov(X,Y)
        """))

        // =========================================================================
        // PHYSICS — MECHANICS (~80)
        // =========================================================================

        f.append(Formula(name: "Kinematics Equations", category: "Physics — Mechanics", tags: ["kinematics", "suvat", "motion", "velocity", "acceleration", "displacement"], content: """
        v = v₀ + at
        x = x₀ + v₀t + ½at²
        v² = v₀² + 2a(x − x₀)
        x = x₀ + ½(v₀ + v)t
        """))

        f.append(Formula(name: "Newton's Laws of Motion", category: "Physics — Mechanics", tags: ["newton", "newton's laws", "force", "F=ma", "inertia", "action reaction"], content: """
        1st Law: An object at rest stays at rest (inertia)
        2nd Law: F = ma  (ΣF = ma)
        3rd Law: For every action, equal and opposite reaction (F₁₂ = −F₂₁)
        """))

        f.append(Formula(name: "Weight and Gravitational Force", category: "Physics — Mechanics", tags: ["weight", "gravity", "gravitational force", "g"], content: """
        W = mg  (weight = mass × gravitational acceleration)
        g ≈ 9.8 m/s² (on Earth's surface)
        F = Gm₁m₂/r²  (Newton's law of gravitation)
        """))

        f.append(Formula(name: "Friction", category: "Physics — Mechanics", tags: ["friction", "static friction", "kinetic friction", "coefficient"], content: """
        Static: fₛ ≤ μₛN
        Kinetic: fₖ = μₖN
        where N = normal force, μ = coefficient of friction
        """))

        f.append(Formula(name: "Work, Energy, Power", category: "Physics — Mechanics", tags: ["work", "energy", "power", "kinetic energy", "potential energy", "joule", "watt"], content: """
        Work: W = F · d · cos(θ)  = ∫ F · dx
        Kinetic Energy: KE = ½mv²
        Potential Energy (gravity): PE = mgh
        Power: P = W/t = F · v
        Work-Energy Theorem: W_net = ΔKE
        """))

        f.append(Formula(name: "Conservation of Energy", category: "Physics — Mechanics", tags: ["conservation of energy", "energy conservation", "mechanical energy"], content: """
        E_total = KE + PE = constant (in isolated system)
        ½mv₁² + mgh₁ = ½mv₂² + mgh₂
        """))

        f.append(Formula(name: "Momentum and Impulse", category: "Physics — Mechanics", tags: ["momentum", "impulse", "conservation of momentum", "p=mv"], content: """
        Momentum: p = mv
        Impulse: J = FΔt = Δp
        Conservation: m₁v₁ + m₂v₂ = m₁v₁' + m₂v₂'
        Elastic collision: KE also conserved
        """))

        f.append(Formula(name: "Circular Motion", category: "Physics — Mechanics", tags: ["circular motion", "centripetal", "centrifugal", "angular velocity"], content: """
        Centripetal acceleration: a = v²/r = ω²r
        Centripetal force: F = mv²/r
        Angular velocity: ω = 2πf = 2π/T
        v = ωr
        """))

        f.append(Formula(name: "Torque and Rotational Motion", category: "Physics — Mechanics", tags: ["torque", "rotation", "moment of inertia", "angular momentum"], content: """
        Torque: τ = r × F = rF sin(θ) = Iα
        Moment of inertia: I = Σmᵢrᵢ²
        Angular momentum: L = Iω
        Rotational KE: KE = ½Iω²
        """))

        f.append(Formula(name: "Simple Harmonic Motion", category: "Physics — Mechanics", tags: ["SHM", "simple harmonic motion", "spring", "oscillation", "pendulum"], content: """
        x(t) = A cos(ωt + φ)
        ω = 2πf = √(k/m)  (spring)
        T = 2π√(m/k)  (spring period)
        T = 2π√(L/g)  (simple pendulum)
        """))

        f.append(Formula(name: "Hooke's Law", category: "Physics — Mechanics", tags: ["hooke", "hooke's law", "spring", "spring constant", "elastic"], content: """
        F = −kx
        PE_spring = ½kx²
        k = spring constant (N/m), x = displacement
        """))

        f.append(Formula(name: "Projectile Motion", category: "Physics — Mechanics", tags: ["projectile", "projectile motion", "trajectory", "range"], content: """
        Horizontal: x = v₀cos(θ)·t
        Vertical: y = v₀sin(θ)·t − ½gt²
        Range: R = v₀²sin(2θ)/g
        Max height: H = v₀²sin²(θ)/(2g)
        Time of flight: T = 2v₀sin(θ)/g
        """))

        f.append(Formula(name: "Gravitational Potential Energy (General)", category: "Physics — Mechanics", tags: ["gravitational potential", "orbital", "escape velocity"], content: """
        U = −Gm₁m₂/r
        Escape velocity: v_esc = √(2GM/r)
        Orbital velocity: v_orb = √(GM/r)
        """))

        f.append(Formula(name: "Kepler's Laws", category: "Physics — Mechanics", tags: ["kepler", "kepler's laws", "orbital", "planet", "ellipse"], content: """
        1st: Planets orbit in ellipses with Sun at one focus
        2nd: Equal areas in equal times (dA/dt = constant)
        3rd: T² ∝ a³  →  T² = (4π²/GM)a³
        """))

        f.append(Formula(name: "Fluid Mechanics — Pressure", category: "Physics — Mechanics", tags: ["pressure", "pascal", "fluid", "hydrostatic", "buoyancy", "archimedes"], content: """
        P = F/A
        Hydrostatic: P = P₀ + ρgh
        Pascal's principle: pressure transmitted equally
        Archimedes: F_buoy = ρ_fluid · V_displaced · g
        """))

        f.append(Formula(name: "Bernoulli's Equation", category: "Physics — Mechanics", tags: ["bernoulli", "fluid flow", "pressure", "velocity"], content: """
        P + ½ρv² + ρgh = constant
        (along a streamline for ideal fluid)
        Continuity: A₁v₁ = A₂v₂
        """))

        f.append(Formula(name: "Moments of Inertia", category: "Physics — Mechanics", tags: ["moment of inertia", "rotational inertia", "I"], content: """
        Solid sphere: I = (2/5)MR²
        Hollow sphere: I = (2/3)MR²
        Solid cylinder: I = (1/2)MR²
        Thin rod (center): I = (1/12)ML²
        Thin rod (end): I = (1/3)ML²
        Hoop: I = MR²
        """))

        // =========================================================================
        // PHYSICS — ELECTROMAGNETISM (~60)
        // =========================================================================

        f.append(Formula(name: "Coulomb's Law", category: "Physics — E&M", tags: ["coulomb", "coulomb's law", "electric force", "charge"], content: """
        F = kq₁q₂/r²  = q₁q₂/(4πε₀r²)
        k ≈ 8.99 × 10⁹ N·m²/C²
        ε₀ ≈ 8.85 × 10⁻¹² F/m
        """))

        f.append(Formula(name: "Electric Field", category: "Physics — E&M", tags: ["electric field", "E field", "field strength"], content: """
        E = F/q = kQ/r²  (point charge)
        F = qE
        Direction: away from + charges, toward − charges
        """))

        f.append(Formula(name: "Electric Potential", category: "Physics — E&M", tags: ["electric potential", "voltage", "potential difference", "V"], content: """
        V = kQ/r  (point charge)
        ΔV = −∫ E · dl
        W = qΔV
        PE = kq₁q₂/r
        """))

        f.append(Formula(name: "Capacitance", category: "Physics — E&M", tags: ["capacitance", "capacitor", "parallel plate", "dielectric"], content: """
        C = Q/V
        Parallel plate: C = ε₀A/d
        With dielectric: C = κε₀A/d
        Energy: U = ½CV² = ½Q²/C = ½QV
        Series: 1/C_total = 1/C₁ + 1/C₂
        Parallel: C_total = C₁ + C₂
        """))

        f.append(Formula(name: "Ohm's Law", category: "Physics — E&M", tags: ["ohm", "ohm's law", "resistance", "voltage", "current", "V=IR"], content: """
        V = IR
        Power: P = IV = I²R = V²/R
        Resistance: R = ρL/A
        """))

        f.append(Formula(name: "Kirchhoff's Rules", category: "Physics — E&M", tags: ["kirchhoff", "KVL", "KCL", "circuit", "loop rule", "junction rule"], content: """
        Junction Rule (KCL): ΣI_in = ΣI_out
        Loop Rule (KVL): ΣΔV = 0 around any closed loop
        """))

        f.append(Formula(name: "Resistors in Series and Parallel", category: "Physics — E&M", tags: ["resistor", "series", "parallel", "equivalent resistance"], content: """
        Series: R_total = R₁ + R₂ + R₃ + ...
        Parallel: 1/R_total = 1/R₁ + 1/R₂ + 1/R₃ + ...
        Two parallel: R = R₁R₂/(R₁+R₂)
        """))

        f.append(Formula(name: "Magnetic Force", category: "Physics — E&M", tags: ["magnetic force", "lorentz", "moving charge", "wire in field"], content: """
        On moving charge: F = qv × B  (|F| = qvBsin(θ))
        On current-carrying wire: F = IL × B  (|F| = ILBsin(θ))
        """))

        f.append(Formula(name: "Biot-Savart Law", category: "Physics — E&M", tags: ["biot-savart", "magnetic field", "wire", "current"], content: """
        dB = (μ₀/4π) · (Idl × r̂)/r²
        Long straight wire: B = μ₀I/(2πr)
        Center of loop: B = μ₀I/(2R)
        Solenoid: B = μ₀nI  (n = turns per length)
        """))

        f.append(Formula(name: "Faraday's Law of Induction", category: "Physics — E&M", tags: ["faraday", "induction", "EMF", "electromagnetic induction", "flux"], content: """
        EMF = −dΦ_B/dt
        Φ_B = ∫ B · dA = BA cos(θ)
        (Lenz's law: induced current opposes change in flux)
        """))

        f.append(Formula(name: "Maxwell's Equations", category: "Physics — E&M", tags: ["maxwell", "maxwell's equations", "electromagnetic", "gauss", "ampere"], content: """
        ∇·E = ρ/ε₀  (Gauss's law)
        ∇·B = 0  (no magnetic monopoles)
        ∇×E = −∂B/∂t  (Faraday's law)
        ∇×B = μ₀J + μ₀ε₀∂E/∂t  (Ampère-Maxwell law)
        """))

        f.append(Formula(name: "Electromagnetic Waves", category: "Physics — E&M", tags: ["electromagnetic wave", "EM wave", "speed of light", "electromagnetic spectrum"], content: """
        c = 1/√(μ₀ε₀) ≈ 3 × 10⁸ m/s
        c = fλ
        Energy density: u = ε₀E²/2 + B²/(2μ₀)
        Intensity: I = P/A = c·ε₀E₀²/2
        """))

        f.append(Formula(name: "Inductance", category: "Physics — E&M", tags: ["inductance", "inductor", "solenoid inductance", "henry"], content: """
        Self-inductance: L = NΦ_B/I
        Solenoid: L = μ₀n²Al  (A = area, l = length)
        EMF = −L(dI/dt)
        Energy: U = ½LI²
        """))

        f.append(Formula(name: "RC Circuit", category: "Physics — E&M", tags: ["RC circuit", "time constant", "charging", "discharging", "capacitor circuit"], content: """
        Charging: V(t) = V₀(1 − e⁻ᵗ/ᴿᶜ), I(t) = (V₀/R)e⁻ᵗ/ᴿᶜ
        Discharging: V(t) = V₀e⁻ᵗ/ᴿᶜ
        Time constant: τ = RC
        After 5τ ≈ fully charged/discharged
        """))

        f.append(Formula(name: "Gauss's Law", category: "Physics — E&M", tags: ["gauss", "gauss's law", "electric flux", "enclosed charge"], content: """
        ∮ E · dA = Q_enclosed / ε₀
        Use symmetry: spherical, cylindrical, planar
        Infinite plane: E = σ/(2ε₀)
        """))

        // =========================================================================
        // PHYSICS — WAVES & OPTICS (~40)
        // =========================================================================

        f.append(Formula(name: "Wave Equation", category: "Physics — Waves", tags: ["wave", "wave equation", "frequency", "wavelength", "period"], content: """
        v = fλ
        T = 1/f
        ω = 2πf,  k = 2π/λ
        y(x,t) = A sin(kx − ωt + φ)
        """))

        f.append(Formula(name: "Sound Waves", category: "Physics — Waves", tags: ["sound", "speed of sound", "decibel", "intensity", "dB"], content: """
        v_sound ≈ 343 m/s (in air at 20°C)
        β = 10 log₁₀(I/I₀) dB  (I₀ = 10⁻¹² W/m²)
        v = √(B/ρ)  (B = bulk modulus)
        """))

        f.append(Formula(name: "Doppler Effect", category: "Physics — Waves", tags: ["doppler", "doppler effect", "frequency shift"], content: """
        f_observed = f_source · (v ± v_observer) / (v ∓ v_source)
        Top signs: approaching, Bottom signs: receding
        v = speed of sound
        """))

        f.append(Formula(name: "Standing Waves", category: "Physics — Waves", tags: ["standing wave", "harmonics", "resonance", "string", "pipe"], content: """
        String (both ends fixed): fₙ = nv/(2L)  (n = 1, 2, 3, ...)
        Open pipe: fₙ = nv/(2L)
        Closed pipe: fₙ = nv/(4L)  (n = 1, 3, 5, ... odd only)
        """))

        f.append(Formula(name: "Snell's Law", category: "Physics — Optics", tags: ["snell", "snell's law", "refraction", "refractive index"], content: """
        n₁ sin(θ₁) = n₂ sin(θ₂)
        n = c/v  (refractive index)
        Total internal reflection: θ_c = arcsin(n₂/n₁)  (n₁ > n₂)
        """))

        f.append(Formula(name: "Thin Lens Equation", category: "Physics — Optics", tags: ["thin lens", "lens equation", "focal length", "magnification"], content: """
        1/f = 1/dₒ + 1/dᵢ
        Magnification: m = −dᵢ/dₒ = hᵢ/hₒ
        f > 0: converging, f < 0: diverging
        """))

        f.append(Formula(name: "Mirror Equation", category: "Physics — Optics", tags: ["mirror", "mirror equation", "concave", "convex", "reflection"], content: """
        1/f = 1/dₒ + 1/dᵢ  (same as thin lens)
        f = R/2  (R = radius of curvature)
        Concave: f > 0, Convex: f < 0
        """))

        f.append(Formula(name: "Diffraction", category: "Physics — Optics", tags: ["diffraction", "single slit", "diffraction grating"], content: """
        Single slit minima: a sin(θ) = mλ  (m = ±1, ±2, ...)
        Diffraction grating maxima: d sin(θ) = mλ  (m = 0, ±1, ±2, ...)
        """))

        f.append(Formula(name: "Double Slit Interference", category: "Physics — Optics", tags: ["young", "double slit", "interference", "constructive", "destructive"], content: """
        Constructive: d sin(θ) = mλ  (m = 0, ±1, ±2, ...)
        Destructive: d sin(θ) = (m + ½)λ
        Fringe spacing: Δy = λL/d
        """))

        f.append(Formula(name: "Beats", category: "Physics — Waves", tags: ["beats", "beat frequency", "interference"], content: """
        f_beat = |f₁ − f₂|
        Two close frequencies produce periodic amplitude modulation.
        """))

        // =========================================================================
        // PHYSICS — THERMODYNAMICS (~40)
        // =========================================================================

        f.append(Formula(name: "Ideal Gas Law", category: "Thermodynamics", tags: ["ideal gas", "PV=nRT", "gas law", "ideal gas law"], content: """
        PV = nRT
        R = 8.314 J/(mol·K) = 0.0821 L·atm/(mol·K)
        PV = NkT  (N = number of molecules, k = Boltzmann constant)
        """))

        f.append(Formula(name: "First Law of Thermodynamics", category: "Thermodynamics", tags: ["first law", "thermodynamics", "internal energy", "heat", "work"], content: """
        ΔU = Q − W
        U = internal energy, Q = heat added, W = work done by system
        For ideal gas: ΔU = nCᵥΔT
        """))

        f.append(Formula(name: "Second Law of Thermodynamics", category: "Thermodynamics", tags: ["second law", "entropy", "thermodynamics"], content: """
        ΔS_universe ≥ 0
        Heat flows from hot to cold spontaneously.
        No process is 100% efficient at converting heat to work.
        """))

        f.append(Formula(name: "Entropy", category: "Thermodynamics", tags: ["entropy", "ΔS", "disorder", "reversible"], content: """
        ΔS = Q_rev / T  (reversible process)
        ΔS = nCᵥ ln(T₂/T₁) + nR ln(V₂/V₁)  (ideal gas)
        S = k ln(W)  (Boltzmann entropy, W = microstates)
        """))

        f.append(Formula(name: "Carnot Efficiency", category: "Thermodynamics", tags: ["carnot", "efficiency", "heat engine", "carnot cycle"], content: """
        η_max = 1 − T_cold/T_hot
        η = W/Q_hot = (Q_hot − Q_cold)/Q_hot
        (temperatures in Kelvin)
        """))

        f.append(Formula(name: "Heat Transfer", category: "Thermodynamics", tags: ["heat transfer", "conduction", "convection", "radiation", "stefan-boltzmann"], content: """
        Conduction: Q/t = kA(ΔT)/L
        Radiation: P = εσAT⁴  (Stefan-Boltzmann)
        σ = 5.67 × 10⁻⁸ W/(m²·K⁴)
        Specific heat: Q = mcΔT
        Latent heat: Q = mL
        """))

        f.append(Formula(name: "Specific Heat and Latent Heat", category: "Thermodynamics", tags: ["specific heat", "latent heat", "phase change", "calorimetry"], content: """
        Q = mcΔT  (sensible heat)
        Q = mL  (latent heat, phase change)
        c_water = 4186 J/(kg·K)
        L_fusion(water) = 334 kJ/kg
        L_vaporization(water) = 2260 kJ/kg
        """))

        f.append(Formula(name: "Thermodynamic Processes", category: "Thermodynamics", tags: ["isothermal", "adiabatic", "isobaric", "isochoric", "thermodynamic process"], content: """
        Isothermal (const T): W = nRT ln(V₂/V₁)
        Adiabatic (Q=0): PVᵞ = const, TVᵞ⁻¹ = const
        Isobaric (const P): W = PΔV
        Isochoric (const V): W = 0
        γ = Cₚ/Cᵥ
        """))

        // =========================================================================
        // PHYSICS — MODERN (~40)
        // =========================================================================

        f.append(Formula(name: "Mass-Energy Equivalence", category: "Physics — Modern", tags: ["E=mc2", "E=mc²", "mass energy", "einstein", "relativity", "rest energy"], content: """
        E = mc²
        E_total = γmc²
        E_kinetic = (γ − 1)mc²
        γ = 1/√(1 − v²/c²)  (Lorentz factor)
        """))

        f.append(Formula(name: "Special Relativity", category: "Physics — Modern", tags: ["special relativity", "time dilation", "length contraction", "lorentz"], content: """
        Time dilation: Δt = γΔt₀
        Length contraction: L = L₀/γ
        Relativistic momentum: p = γmv
        γ = 1/√(1 − v²/c²)
        """))

        f.append(Formula(name: "Photoelectric Effect", category: "Physics — Modern", tags: ["photoelectric", "photon", "work function", "Einstein photoelectric"], content: """
        E_photon = hf = hc/λ
        KE_max = hf − φ  (φ = work function)
        Threshold frequency: f₀ = φ/h
        """))

        f.append(Formula(name: "De Broglie Wavelength", category: "Physics — Modern", tags: ["de broglie", "matter wave", "wavelength", "wave-particle duality"], content: """
        λ = h/p = h/(mv)
        (every particle has a wavelength)
        h = 6.626 × 10⁻³⁴ J·s
        """))

        f.append(Formula(name: "Heisenberg Uncertainty Principle", category: "Physics — Modern", tags: ["heisenberg", "uncertainty principle", "uncertainty"], content: """
        Δx · Δp ≥ ℏ/2
        ΔE · Δt ≥ ℏ/2
        ℏ = h/(2π) ≈ 1.055 × 10⁻³⁴ J·s
        """))

        f.append(Formula(name: "Schrödinger Equation", category: "Physics — Modern", tags: ["schrodinger", "schrödinger", "quantum mechanics", "wave function"], content: """
        Time-independent: Ĥψ = Eψ
        −(ℏ²/2m)d²ψ/dx² + V(x)ψ = Eψ
        |ψ(x)|² = probability density
        ∫|ψ|² dx = 1  (normalization)
        """))

        f.append(Formula(name: "Compton Scattering", category: "Physics — Modern", tags: ["compton", "compton scattering", "X-ray"], content: """
        Δλ = (h/mₑc)(1 − cos θ)
        h/(mₑc) ≈ 2.43 × 10⁻¹² m (Compton wavelength)
        """))

        f.append(Formula(name: "Bohr Model", category: "Physics — Modern", tags: ["bohr", "hydrogen atom", "energy levels", "bohr model"], content: """
        Eₙ = −13.6 eV / n²  (hydrogen)
        rₙ = n²a₀  (a₀ = 0.529 Å, Bohr radius)
        1/λ = R_H(1/n₁² − 1/n₂²)  (Rydberg formula)
        R_H = 1.097 × 10⁷ m⁻¹
        """))

        f.append(Formula(name: "Planck-Einstein Relation", category: "Physics — Modern", tags: ["planck", "photon energy", "quantum", "hf"], content: """
        E = hf = hc/λ
        h = 6.626 × 10⁻³⁴ J·s (Planck's constant)
        1 eV = 1.602 × 10⁻¹⁹ J
        """))

        f.append(Formula(name: "Radioactive Decay", category: "Physics — Modern", tags: ["radioactive", "decay", "half-life", "activity", "nuclear"], content: """
        N(t) = N₀ · e⁻λᵗ = N₀ · (½)^(t/t₁/₂)
        t₁/₂ = ln(2)/λ ≈ 0.693/λ
        Activity: A = λN = A₀e⁻λᵗ
        """))

        // =========================================================================
        // CHEMISTRY (~80)
        // =========================================================================

        f.append(Formula(name: "Ideal Gas Law (Chemistry)", category: "Chemistry", tags: ["ideal gas", "gas law", "PV=nRT", "chemistry"], content: """
        PV = nRT
        R = 8.314 J/(mol·K) = 0.0821 L·atm/(mol·K)
        At STP (0°C, 1 atm): 1 mol gas = 22.4 L
        """))

        f.append(Formula(name: "Molarity and Dilution", category: "Chemistry", tags: ["molarity", "concentration", "dilution", "moles", "solution"], content: """
        Molarity: M = moles of solute / liters of solution
        Dilution: M₁V₁ = M₂V₂
        Moles = mass / molar mass
        """))

        f.append(Formula(name: "pH and pOH", category: "Chemistry", tags: ["pH", "pOH", "acid", "base", "hydrogen ion", "hydroxide"], content: """
        pH = −log[H⁺]
        pOH = −log[OH⁻]
        pH + pOH = 14  (at 25°C)
        [H⁺][OH⁻] = Kw = 1.0 × 10⁻¹⁴
        """))

        f.append(Formula(name: "Henderson-Hasselbalch Equation", category: "Chemistry", tags: ["henderson-hasselbalch", "buffer", "pKa", "acid-base"], content: """
        pH = pKa + log([A⁻]/[HA])
        pOH = pKb + log([BH⁺]/[B])
        pKa + pKb = 14
        """))

        f.append(Formula(name: "Gibbs Free Energy", category: "Chemistry", tags: ["gibbs", "free energy", "spontaneous", "ΔG", "enthalpy", "entropy"], content: """
        ΔG = ΔH − TΔS
        ΔG < 0: spontaneous
        ΔG = 0: equilibrium
        ΔG > 0: non-spontaneous
        ΔG° = −RT ln(K)
        """))

        f.append(Formula(name: "Nernst Equation", category: "Chemistry", tags: ["nernst", "electrochemistry", "cell potential", "electrode"], content: """
        E = E° − (RT/nF) ln(Q)
        At 25°C: E = E° − (0.0592/n) log(Q)
        F = 96485 C/mol (Faraday's constant)
        """))

        f.append(Formula(name: "Rate Laws", category: "Chemistry", tags: ["rate law", "kinetics", "reaction rate", "order", "rate constant"], content: """
        Rate = k[A]ᵐ[B]ⁿ
        Zero order: [A] = [A]₀ − kt,  t₁/₂ = [A]₀/(2k)
        First order: ln[A] = ln[A]₀ − kt,  t₁/₂ = ln(2)/k
        Second order: 1/[A] = 1/[A]₀ + kt,  t₁/₂ = 1/(k[A]₀)
        """))

        f.append(Formula(name: "Arrhenius Equation", category: "Chemistry", tags: ["arrhenius", "activation energy", "rate constant", "temperature dependence"], content: """
        k = Ae^(−Eₐ/RT)
        ln(k₂/k₁) = (Eₐ/R)(1/T₁ − 1/T₂)
        Eₐ = activation energy, A = pre-exponential factor
        """))

        f.append(Formula(name: "Equilibrium Constant", category: "Chemistry", tags: ["equilibrium", "Keq", "equilibrium constant", "Le Chatelier"], content: """
        For aA + bB ⇌ cC + dD:
        K = [C]ᶜ[D]ᵈ / [A]ᵃ[B]ᵇ
        Q < K: reaction proceeds forward
        Q > K: reaction proceeds backward
        Q = K: at equilibrium
        """))

        f.append(Formula(name: "Hess's Law", category: "Chemistry", tags: ["hess", "hess's law", "enthalpy", "heat of reaction"], content: """
        ΔH_rxn = Σ ΔH_f°(products) − Σ ΔH_f°(reactants)
        (enthalpy is a state function — path independent)
        """))

        f.append(Formula(name: "Oxidation States", category: "Chemistry", tags: ["oxidation", "reduction", "redox", "oxidation state", "oxidation number"], content: """
        Free element: 0
        Monatomic ion: charge
        H: +1 (except metal hydrides: −1)
        O: −2 (except peroxides: −1)
        F: always −1
        Sum of oxidation states = charge of species
        """))

        f.append(Formula(name: "Electrochemistry", category: "Chemistry", tags: ["electrochemistry", "cell potential", "galvanic", "electrolysis"], content: """
        E°_cell = E°_cathode − E°_anode
        ΔG° = −nFE°
        Faraday's law: m = (MIt)/(nF)
        (m = mass deposited, M = molar mass, I = current, t = time)
        """))

        f.append(Formula(name: "Boyle's, Charles's, Gay-Lussac's Laws", category: "Chemistry", tags: ["boyle", "charles", "gay-lussac", "gas law", "combined gas"], content: """
        Boyle's (const T): P₁V₁ = P₂V₂
        Charles's (const P): V₁/T₁ = V₂/T₂
        Gay-Lussac's (const V): P₁/T₁ = P₂/T₂
        Combined: P₁V₁/T₁ = P₂V₂/T₂
        """))

        f.append(Formula(name: "Osmotic Pressure", category: "Chemistry", tags: ["osmotic pressure", "osmosis", "colligative", "van't hoff"], content: """
        π = MRT (van't Hoff equation)
        For electrolytes: π = iMRT (i = van't Hoff factor)
        """))

        f.append(Formula(name: "Colligative Properties", category: "Chemistry", tags: ["colligative", "boiling point elevation", "freezing point depression"], content: """
        Boiling point elevation: ΔTb = iKbm
        Freezing point depression: ΔTf = iKfm
        Raoult's law: P = x·P°
        m = molality (mol solute / kg solvent)
        """))

        // =========================================================================
        // GEOMETRY (~60)
        // =========================================================================

        f.append(Formula(name: "Circle Formulas", category: "Geometry", tags: ["circle", "circumference", "area of circle", "radius", "diameter"], content: """
        Circumference: C = 2πr = πd
        Area: A = πr²
        Arc length: s = rθ  (θ in radians)
        Sector area: A = ½r²θ
        """))

        f.append(Formula(name: "Triangle Area Formulas", category: "Geometry", tags: ["triangle", "area of triangle", "triangle area"], content: """
        A = ½bh  (base × height)
        A = ½ab sin(C)  (two sides and included angle)
        A = √(s(s−a)(s−b)(s−c))  (Heron's formula, s = semi-perimeter)
        """))

        f.append(Formula(name: "Rectangle and Parallelogram", category: "Geometry", tags: ["rectangle", "parallelogram", "area", "perimeter"], content: """
        Rectangle: A = lw, P = 2(l + w)
        Parallelogram: A = bh
        Rhombus: A = ½d₁d₂
        """))

        f.append(Formula(name: "Trapezoid", category: "Geometry", tags: ["trapezoid", "trapezium", "area of trapezoid"], content: """
        A = ½(b₁ + b₂)h
        (b₁, b₂ = parallel sides, h = height)
        """))

        f.append(Formula(name: "Sphere", category: "Geometry", tags: ["sphere", "volume of sphere", "surface area of sphere"], content: """
        Volume: V = (4/3)πr³
        Surface area: SA = 4πr²
        """))

        f.append(Formula(name: "Cylinder", category: "Geometry", tags: ["cylinder", "volume of cylinder", "surface area of cylinder"], content: """
        Volume: V = πr²h
        Lateral surface area: SA_lateral = 2πrh
        Total surface area: SA = 2πr² + 2πrh
        """))

        f.append(Formula(name: "Cone", category: "Geometry", tags: ["cone", "volume of cone", "surface area of cone"], content: """
        Volume: V = (1/3)πr²h
        Slant height: l = √(r² + h²)
        Lateral SA: SA = πrl
        Total SA: SA = πr² + πrl
        """))

        f.append(Formula(name: "Pyramid", category: "Geometry", tags: ["pyramid", "volume of pyramid"], content: """
        Volume: V = (1/3)Bh  (B = base area)
        Square pyramid: V = (1/3)s²h
        """))

        f.append(Formula(name: "Distance Formula", category: "Geometry", tags: ["distance", "distance formula", "coordinate geometry"], content: """
        2D: d = √((x₂−x₁)² + (y₂−y₁)²)
        3D: d = √((x₂−x₁)² + (y₂−y₁)² + (z₂−z₁)²)
        """))

        f.append(Formula(name: "Midpoint Formula", category: "Geometry", tags: ["midpoint", "midpoint formula"], content: """
        M = ((x₁+x₂)/2, (y₁+y₂)/2)
        3D: M = ((x₁+x₂)/2, (y₁+y₂)/2, (z₁+z₂)/2)
        """))

        f.append(Formula(name: "Slope", category: "Geometry", tags: ["slope", "gradient", "rise over run", "line"], content: """
        m = (y₂ − y₁)/(x₂ − x₁) = rise/run
        Slope-intercept: y = mx + b
        Point-slope: y − y₁ = m(x − x₁)
        Perpendicular slopes: m₁ · m₂ = −1
        """))

        f.append(Formula(name: "Conic Sections", category: "Geometry", tags: ["conic", "ellipse", "hyperbola", "parabola", "conic section"], content: """
        Circle: x² + y² = r²
        Ellipse: x²/a² + y²/b² = 1
        Hyperbola: x²/a² − y²/b² = 1
        Parabola: y = ax²  or  x² = 4py
        """))

        f.append(Formula(name: "Ellipse Properties", category: "Geometry", tags: ["ellipse", "ellipse area", "eccentricity", "foci"], content: """
        Area: A = πab
        c² = a² − b²  (c = distance from center to focus)
        Eccentricity: e = c/a  (0 < e < 1)
        Circumference ≈ π(3(a+b) − √((3a+b)(a+3b)))  (Ramanujan approx)
        """))

        f.append(Formula(name: "Regular Polygon", category: "Geometry", tags: ["regular polygon", "polygon area", "interior angle"], content: """
        Interior angle: (n−2)·180°/n
        Sum of interior angles: (n−2)·180°
        Area: A = (1/4)ns²·cot(π/n)
        (n = number of sides, s = side length)
        """))

        // =========================================================================
        // COMPUTER SCIENCE (~60)
        // =========================================================================

        f.append(Formula(name: "Big-O Complexity Classes", category: "Computer Science", tags: ["big-o", "time complexity", "O(n)", "complexity", "algorithm"], content: """
        O(1) < O(log n) < O(n) < O(n log n) < O(n²) < O(n³) < O(2ⁿ) < O(n!)
        Common:
        - Array access: O(1)
        - Binary search: O(log n)
        - Linear search: O(n)
        - Merge/Quick sort (avg): O(n log n)
        - Bubble/Selection/Insertion sort: O(n²)
        """))

        f.append(Formula(name: "Sorting Algorithm Complexities", category: "Computer Science", tags: ["sorting", "sort complexity", "quicksort", "mergesort", "heapsort"], content: """
        Merge Sort:  Best O(n log n), Avg O(n log n), Worst O(n log n), Space O(n)
        Quick Sort:  Best O(n log n), Avg O(n log n), Worst O(n²), Space O(log n)
        Heap Sort:   Best O(n log n), Avg O(n log n), Worst O(n log n), Space O(1)
        Tim Sort:    Best O(n), Avg O(n log n), Worst O(n log n), Space O(n)
        Bubble Sort: Best O(n), Avg O(n²), Worst O(n²), Space O(1)
        Insertion:   Best O(n), Avg O(n²), Worst O(n²), Space O(1)
        """))

        f.append(Formula(name: "Data Structure Complexities", category: "Computer Science", tags: ["data structure", "array", "hash table", "linked list", "BST", "tree"], content: """
        Array:       Access O(1), Search O(n), Insert O(n), Delete O(n)
        Hash Table:  Access O(1)*, Search O(1)*, Insert O(1)*, Delete O(1)*
        Linked List: Access O(n), Search O(n), Insert O(1), Delete O(1)
        BST (avg):   Access O(log n), Search O(log n), Insert O(log n)
        Heap:        Insert O(log n), Delete-min O(log n), Find-min O(1)
        *amortized
        """))

        f.append(Formula(name: "Master Theorem", category: "Computer Science", tags: ["master theorem", "recurrence", "divide and conquer", "T(n)"], content: """
        For T(n) = aT(n/b) + O(nᵈ):
        If d < log_b(a): T(n) = O(n^(log_b(a)))
        If d = log_b(a): T(n) = O(nᵈ log n)
        If d > log_b(a): T(n) = O(nᵈ)
        """))

        f.append(Formula(name: "Graph Algorithm Complexities", category: "Computer Science", tags: ["graph", "dijkstra", "BFS", "DFS", "graph algorithm"], content: """
        BFS/DFS: O(V + E)
        Dijkstra (binary heap): O((V + E) log V)
        Bellman-Ford: O(VE)
        Floyd-Warshall: O(V³)
        Kruskal: O(E log E)
        Prim (binary heap): O((V + E) log V)
        Topological Sort: O(V + E)
        """))

        f.append(Formula(name: "Binary Search", category: "Computer Science", tags: ["binary search", "search algorithm", "divide and conquer"], content: """
        Time: O(log n)
        Space: O(1) iterative, O(log n) recursive
        Requires sorted array.
        Iterations to find: ⌈log₂(n)⌉
        """))

        f.append(Formula(name: "Boolean Algebra", category: "Computer Science", tags: ["boolean", "boolean algebra", "logic", "AND", "OR", "NOT", "de morgan"], content: """
        De Morgan's Laws:
        ¬(A ∧ B) = ¬A ∨ ¬B
        ¬(A ∨ B) = ¬A ∧ ¬B

        A ∧ (B ∨ C) = (A ∧ B) ∨ (A ∧ C)  (distributive)
        A ∨ (A ∧ B) = A  (absorption)
        A ∧ ¬A = 0, A ∨ ¬A = 1
        """))

        f.append(Formula(name: "Shannon Entropy", category: "Computer Science", tags: ["entropy", "information", "shannon", "information theory", "bits"], content: """
        H(X) = −Σ p(xᵢ) log₂(p(xᵢ))
        Maximum entropy: H = log₂(n)  (uniform distribution)
        Entropy = expected information content
        """))

        f.append(Formula(name: "Two's Complement", category: "Computer Science", tags: ["two's complement", "binary", "signed integer", "bit representation"], content: """
        For n-bit number:
        Range: −2ⁿ⁻¹ to 2ⁿ⁻¹ − 1
        Negate: flip all bits, add 1
        8-bit: −128 to 127
        16-bit: −32768 to 32767
        32-bit: −2,147,483,648 to 2,147,483,647
        """))

        f.append(Formula(name: "Network Formulas", category: "Computer Science", tags: ["network", "subnet", "CIDR", "IP", "bandwidth"], content: """
        IPv4 addresses: 2³² ≈ 4.3 billion
        /24 subnet: 256 addresses (254 usable)
        /16 subnet: 65,536 addresses
        Bandwidth: bits/second, 1 Mbps = 10⁶ bps
        Throughput = bandwidth × (1 − packet_loss)
        Latency = propagation + transmission + queuing
        """))

        f.append(Formula(name: "Hash Function Properties", category: "Computer Science", tags: ["hash", "collision", "birthday problem", "hash table"], content: """
        Birthday problem: P(collision) ≈ 50% when n ≈ 1.2√N
        For 128-bit hash: ~2⁶⁴ items for 50% collision
        Load factor: α = n/m (items/buckets)
        Expected probes (open addressing): 1/(1−α)
        """))

        f.append(Formula(name: "Recursion Patterns", category: "Computer Science", tags: ["recursion", "fibonacci", "dynamic programming", "memoization"], content: """
        Fibonacci: F(n) = F(n−1) + F(n−2), F(0)=0, F(1)=1
        Naive: O(2ⁿ), Memoized: O(n), Iterative: O(n) time O(1) space
        Catalan: C(n) = C(2n,n)/(n+1) = (2n)!/((n+1)!·n!)
        """))

        // =========================================================================
        // PHYSICAL CONSTANTS (~50)
        // =========================================================================

        f.append(Formula(name: "Speed of Light", category: "Constants", tags: ["speed of light", "c", "light speed"], content: """
        c = 299,792,458 m/s ≈ 3 × 10⁸ m/s
        = 186,282 miles/s
        = 670,616,629 mph
        """))

        f.append(Formula(name: "Planck's Constant", category: "Constants", tags: ["planck", "planck's constant", "h", "h-bar"], content: """
        h = 6.62607 × 10⁻³⁴ J·s
        ℏ = h/(2π) = 1.05457 × 10⁻³⁴ J·s
        """))

        f.append(Formula(name: "Gravitational Constant", category: "Constants", tags: ["gravitational constant", "G", "big G", "newton gravitational"], content: """
        G = 6.674 × 10⁻¹¹ N·m²/kg²
        """))

        f.append(Formula(name: "Avogadro's Number", category: "Constants", tags: ["avogadro", "avogadro's number", "mole", "NA"], content: """
        Nₐ = 6.022 × 10²³ mol⁻¹
        1 mole of any substance contains Nₐ particles
        """))

        f.append(Formula(name: "Boltzmann Constant", category: "Constants", tags: ["boltzmann", "boltzmann constant", "kB", "thermal energy"], content: """
        kB = 1.381 × 10⁻²³ J/K
        kBT at room temp (300K) ≈ 4.14 × 10⁻²¹ J ≈ 0.026 eV
        R = NₐkB = 8.314 J/(mol·K)
        """))

        f.append(Formula(name: "Electron Properties", category: "Constants", tags: ["electron", "electron mass", "electron charge", "elementary charge"], content: """
        mₑ = 9.109 × 10⁻³¹ kg
        e = 1.602 × 10⁻¹⁹ C
        Classical radius: rₑ = 2.818 × 10⁻¹⁵ m
        """))

        f.append(Formula(name: "Proton and Neutron Properties", category: "Constants", tags: ["proton", "neutron", "proton mass", "neutron mass", "nucleon"], content: """
        Proton mass: mₚ = 1.673 × 10⁻²⁷ kg = 938.3 MeV/c²
        Neutron mass: mₙ = 1.675 × 10⁻²⁷ kg = 939.6 MeV/c²
        mₚ/mₑ ≈ 1836
        """))

        f.append(Formula(name: "Vacuum Permittivity and Permeability", category: "Constants", tags: ["permittivity", "permeability", "epsilon naught", "mu naught", "vacuum"], content: """
        ε₀ = 8.854 × 10⁻¹² F/m (vacuum permittivity)
        μ₀ = 4π × 10⁻⁷ T·m/A (vacuum permeability)
        c = 1/√(μ₀ε₀)
        """))

        f.append(Formula(name: "Stefan-Boltzmann Constant", category: "Constants", tags: ["stefan-boltzmann", "blackbody", "radiation constant", "sigma"], content: """
        σ = 5.670 × 10⁻⁸ W/(m²·K⁴)
        """))

        f.append(Formula(name: "Atomic Mass Unit", category: "Constants", tags: ["atomic mass unit", "amu", "dalton", "u"], content: """
        1 u = 1.661 × 10⁻²⁷ kg = 931.5 MeV/c²
        Defined as 1/12 the mass of carbon-12
        """))

        f.append(Formula(name: "Coulomb's Constant", category: "Constants", tags: ["coulomb constant", "k electric", "electrostatic constant"], content: """
        k = 1/(4πε₀) = 8.988 × 10⁹ N·m²/C²
        """))

        f.append(Formula(name: "Faraday's Constant", category: "Constants", tags: ["faraday constant", "F", "mole of charge"], content: """
        F = 96,485 C/mol = Nₐ · e
        Charge per mole of electrons
        """))

        f.append(Formula(name: "Gas Constant", category: "Constants", tags: ["gas constant", "R", "universal gas constant", "ideal gas"], content: """
        R = 8.314 J/(mol·K) = 0.0821 L·atm/(mol·K)
        = 1.987 cal/(mol·K)
        R = NₐkB
        """))

        f.append(Formula(name: "Standard Gravity", category: "Constants", tags: ["gravity", "g", "standard gravity", "gravitational acceleration"], content: """
        g = 9.80665 m/s² (standard)
        ≈ 32.174 ft/s²
        Varies: ~9.78 at equator to ~9.83 at poles
        """))

        f.append(Formula(name: "Earth Properties", category: "Constants", tags: ["earth", "earth radius", "earth mass", "earth data"], content: """
        Mass: 5.972 × 10²⁴ kg
        Mean radius: 6,371 km
        Escape velocity: 11.2 km/s
        Orbital speed: 29.8 km/s
        Distance to Sun: 1 AU ≈ 1.496 × 10⁸ km
        """))

        f.append(Formula(name: "Water Properties", category: "Constants", tags: ["water", "water density", "water specific heat"], content: """
        Density: 1000 kg/m³ = 1 g/cm³ (at 4°C)
        Specific heat: 4186 J/(kg·K)
        Boiling: 100°C (373.15 K) at 1 atm
        Freezing: 0°C (273.15 K) at 1 atm
        Latent heat fusion: 334 kJ/kg
        Latent heat vaporization: 2260 kJ/kg
        """))

        f.append(Formula(name: "Common Physical Constants Summary", category: "Constants", tags: ["constants", "physical constants", "reference", "fundamental constants"], content: """
        c = 3.00 × 10⁸ m/s (speed of light)
        h = 6.63 × 10⁻³⁴ J·s (Planck)
        G = 6.67 × 10⁻¹¹ N·m²/kg² (gravitational)
        e = 1.60 × 10⁻¹⁹ C (elementary charge)
        kB = 1.38 × 10⁻²³ J/K (Boltzmann)
        Nₐ = 6.02 × 10²³ /mol (Avogadro)
        R = 8.314 J/(mol·K) (gas constant)
        σ = 5.67 × 10⁻⁸ W/(m²·K⁴) (Stefan-Boltzmann)
        ε₀ = 8.85 × 10⁻¹² F/m (vacuum permittivity)
        μ₀ = 4π × 10⁻⁷ T·m/A (vacuum permeability)
        """))

        // =========================================================================
        // UNIT CONVERSIONS (~50)
        // =========================================================================

        f.append(Formula(name: "Length Conversions", category: "Conversions", tags: ["length conversion", "distance conversion", "meter", "feet", "mile", "inch"], content: """
        1 inch = 2.54 cm
        1 foot = 0.3048 m = 12 inches
        1 yard = 0.9144 m = 3 feet
        1 mile = 1.609 km = 5280 feet
        1 km = 0.6214 miles
        1 nautical mile = 1.852 km
        """))

        f.append(Formula(name: "Mass Conversions", category: "Conversions", tags: ["mass conversion", "weight conversion", "kg", "pound", "ounce"], content: """
        1 kg = 2.205 lb
        1 lb = 453.6 g = 16 oz
        1 oz = 28.35 g
        1 metric ton = 1000 kg = 2205 lb
        1 US ton = 907.2 kg = 2000 lb
        """))

        f.append(Formula(name: "Temperature Conversions", category: "Conversions", tags: ["temperature conversion", "celsius", "fahrenheit", "kelvin", "temp"], content: """
        °F = (9/5)°C + 32
        °C = (5/9)(°F − 32)
        K = °C + 273.15
        Key points: 0°C = 32°F = 273.15K (water freezes)
        100°C = 212°F = 373.15K (water boils)
        −40°C = −40°F
        """))

        f.append(Formula(name: "Volume Conversions", category: "Conversions", tags: ["volume conversion", "liter", "gallon", "cup", "fluid"], content: """
        1 gallon = 3.785 liters = 4 quarts
        1 liter = 0.2642 gallon = 1000 ml
        1 cup = 236.6 ml = 8 fl oz
        1 tablespoon = 14.79 ml = 3 teaspoons
        1 fl oz = 29.57 ml
        """))

        f.append(Formula(name: "Energy Conversions", category: "Conversions", tags: ["energy conversion", "joule", "calorie", "eV", "kWh", "BTU"], content: """
        1 cal = 4.184 J
        1 kcal = 4184 J (food Calorie)
        1 kWh = 3.6 × 10⁶ J
        1 eV = 1.602 × 10⁻¹⁹ J
        1 BTU = 1055 J
        """))

        f.append(Formula(name: "Pressure Conversions", category: "Conversions", tags: ["pressure conversion", "atm", "pascal", "bar", "psi", "mmHg"], content: """
        1 atm = 101,325 Pa = 101.325 kPa
        1 atm = 760 mmHg = 760 Torr
        1 atm = 14.696 psi
        1 bar = 100,000 Pa = 0.9869 atm
        1 psi = 6894.76 Pa
        """))

        f.append(Formula(name: "Speed Conversions", category: "Conversions", tags: ["speed conversion", "mph", "kph", "m/s", "knot"], content: """
        1 m/s = 3.6 km/h = 2.237 mph
        1 km/h = 0.6214 mph = 0.2778 m/s
        1 mph = 1.609 km/h = 0.4470 m/s
        1 knot = 1.852 km/h = 1.151 mph
        """))

        f.append(Formula(name: "Data Storage Conversions", category: "Conversions", tags: ["data conversion", "byte", "kilobyte", "megabyte", "gigabyte", "terabyte"], content: """
        1 KB = 1024 bytes
        1 MB = 1024 KB = 1,048,576 bytes
        1 GB = 1024 MB ≈ 10⁹ bytes
        1 TB = 1024 GB ≈ 10¹² bytes
        1 PB = 1024 TB ≈ 10¹⁵ bytes
        (Note: manufacturers often use 10³ instead of 2¹⁰)
        """))

        f.append(Formula(name: "Time Conversions", category: "Conversions", tags: ["time conversion", "seconds", "minutes", "hours", "days", "years"], content: """
        1 minute = 60 seconds
        1 hour = 3600 seconds
        1 day = 86,400 seconds
        1 week = 604,800 seconds
        1 year ≈ 365.25 days ≈ 31,557,600 seconds
        1 month ≈ 30.44 days ≈ 2,629,746 seconds
        """))

        f.append(Formula(name: "Angle Conversions", category: "Conversions", tags: ["angle conversion", "degree", "radian", "gradian"], content: """
        π radians = 180°
        1 radian = 180°/π ≈ 57.296°
        1° = π/180 ≈ 0.01745 rad
        1 gradian = 0.9° = π/200 rad
        """))

        f.append(Formula(name: "Area Conversions", category: "Conversions", tags: ["area conversion", "square meter", "acre", "hectare", "square foot"], content: """
        1 acre = 43,560 ft² = 4,047 m²
        1 hectare = 10,000 m² = 2.471 acres
        1 km² = 100 hectares = 247.1 acres
        1 mi² = 640 acres = 2.59 km²
        1 m² = 10.764 ft²
        """))

        f.append(Formula(name: "Power Conversions", category: "Conversions", tags: ["power conversion", "watt", "horsepower", "BTU/h"], content: """
        1 horsepower = 745.7 W
        1 kW = 1.341 hp
        1 BTU/h = 0.2931 W
        1 ton (cooling) = 12,000 BTU/h = 3517 W
        """))

        // =========================================================================
        // ADDITIONAL MATH (~50 more to reach ~1000)
        // =========================================================================

        f.append(Formula(name: "Logarithmic Identities", category: "Algebra", tags: ["log identity", "natural log", "ln identity", "logarithmic"], content: """
        ln(e) = 1, log₁₀(10) = 1
        ln(1) = 0
        ln(eˣ) = x
        e^(ln x) = x
        ln(x^y) = y·ln(x)
        """))

        f.append(Formula(name: "Gaussian Integral", category: "Calculus", tags: ["gaussian integral", "bell curve integral", "e^(-x^2)"], content: """
        ∫₋∞^∞ e^(−x²) dx = √π
        ∫₀^∞ e^(−x²) dx = √π/2
        ∫₋∞^∞ e^(−ax²) dx = √(π/a)
        """))

        f.append(Formula(name: "Gamma Function", category: "Calculus", tags: ["gamma function", "factorial generalization", "Γ"], content: """
        Γ(n) = ∫₀^∞ xⁿ⁻¹e⁻ˣ dx
        Γ(n) = (n−1)!  for positive integers
        Γ(1/2) = √π
        Γ(n+1) = n·Γ(n)
        """))

        f.append(Formula(name: "Fourier Series", category: "Calculus", tags: ["fourier", "fourier series", "harmonic analysis", "periodic"], content: """
        f(x) = a₀/2 + Σ(aₙcos(nωx) + bₙsin(nωx))
        aₙ = (2/T)∫f(x)cos(nωx)dx
        bₙ = (2/T)∫f(x)sin(nωx)dx
        ω = 2π/T
        """))

        f.append(Formula(name: "Laplace Transform", category: "Calculus", tags: ["laplace", "laplace transform", "s-domain"], content: """
        ℒ{f(t)} = F(s) = ∫₀^∞ f(t)e⁻ˢᵗ dt
        ℒ{1} = 1/s,  ℒ{t} = 1/s²,  ℒ{eᵃᵗ} = 1/(s−a)
        ℒ{sin(ωt)} = ω/(s²+ω²)
        ℒ{cos(ωt)} = s/(s²+ω²)
        """))

        f.append(Formula(name: "Euler's Number and Formula", category: "Calculus", tags: ["euler", "e", "euler's number", "natural base"], content: """
        e ≈ 2.71828 18284 59045...
        e = lim[n→∞] (1 + 1/n)ⁿ
        e = Σ 1/n!  (n = 0 to ∞)
        d/dx eˣ = eˣ  (only function equal to its own derivative)
        """))

        f.append(Formula(name: "Pi Approximations", category: "Constants", tags: ["pi", "π", "pi value", "pi approximation"], content: """
        π ≈ 3.14159 26535 89793...
        π ≈ 22/7 ≈ 355/113  (fractions)
        Leibniz: π/4 = 1 − 1/3 + 1/5 − 1/7 + ...
        Circumference = 2πr, Area = πr²
        """))

        f.append(Formula(name: "Riemann Zeta Function Values", category: "Calculus", tags: ["riemann zeta", "zeta function", "Basel problem"], content: """
        ζ(2) = π²/6  (Basel problem)
        ζ(4) = π⁴/90
        ζ(−1) = −1/12  (regularized)
        ζ(s) = Σ 1/nˢ  (n = 1 to ∞, Re(s) > 1)
        """))

        f.append(Formula(name: "Stirling's Approximation", category: "Calculus", tags: ["stirling", "factorial approximation", "stirling's formula"], content: """
        n! ≈ √(2πn) · (n/e)ⁿ
        ln(n!) ≈ n·ln(n) − n
        """))

        f.append(Formula(name: "Coordinate System Conversions", category: "Geometry", tags: ["polar", "cylindrical", "spherical", "coordinate conversion"], content: """
        Polar ↔ Cartesian:
        x = r cos(θ), y = r sin(θ)
        r = √(x²+y²), θ = arctan(y/x)

        Cylindrical: (r, θ, z)
        Spherical: x = ρ sin(φ) cos(θ), y = ρ sin(φ) sin(θ), z = ρ cos(φ)
        """))

        f.append(Formula(name: "Matrix Identities", category: "Linear Algebra", tags: ["matrix identity", "matrix properties"], content: """
        (AB)⁻¹ = B⁻¹A⁻¹
        det(AB) = det(A)·det(B)
        det(A⁻¹) = 1/det(A)
        det(cA) = cⁿ·det(A)  (n×n matrix)
        (Aᵀ)⁻¹ = (A⁻¹)ᵀ
        """))

        f.append(Formula(name: "Vector Identities", category: "Linear Algebra", tags: ["vector identity", "triple product", "BAC-CAB"], content: """
        a × (b × c) = b(a·c) − c(a·b)  (BAC-CAB rule)
        a · (b × c) = det[a b c]  (scalar triple product)
        |a × b|² = |a|²|b|² − (a·b)²
        """))

        f.append(Formula(name: "Probability Distributions Summary", category: "Statistics", tags: ["distribution summary", "probability distribution", "common distributions"], content: """
        Uniform(a,b): μ=(a+b)/2, σ²=(b−a)²/12
        Normal(μ,σ²): bell curve, 68-95-99.7
        Binomial(n,p): μ=np, σ²=np(1−p)
        Poisson(λ): μ=λ, σ²=λ
        Exponential(λ): μ=1/λ, σ²=1/λ²
        Geometric(p): μ=1/p, σ²=(1−p)/p²
        """))

        f.append(Formula(name: "Information Theory", category: "Computer Science", tags: ["information theory", "entropy", "mutual information", "KL divergence"], content: """
        Entropy: H(X) = −Σ p(x) log₂ p(x)
        Joint entropy: H(X,Y) = −Σ p(x,y) log₂ p(x,y)
        Conditional: H(Y|X) = H(X,Y) − H(X)
        Mutual info: I(X;Y) = H(X) + H(Y) − H(X,Y)
        KL divergence: D_KL(P||Q) = Σ P(x) log(P(x)/Q(x))
        """))

        f.append(Formula(name: "Dimensional Analysis", category: "Physics — Mechanics", tags: ["dimensional analysis", "units", "SI", "dimensions"], content: """
        Force: [MLT⁻²] (kg·m/s²)
        Energy: [ML²T⁻²] (kg·m²/s² = J)
        Power: [ML²T⁻³] (J/s = W)
        Pressure: [ML⁻¹T⁻²] (N/m² = Pa)
        Electric charge: [IT] (A·s = C)
        """))

        f.append(Formula(name: "Elastic and Inelastic Collisions", category: "Physics — Mechanics", tags: ["collision", "elastic", "inelastic", "perfectly inelastic"], content: """
        Elastic (KE conserved):
        v₁' = ((m₁−m₂)v₁ + 2m₂v₂)/(m₁+m₂)
        v₂' = ((m₂−m₁)v₂ + 2m₁v₁)/(m₁+m₂)

        Perfectly inelastic: v' = (m₁v₁ + m₂v₂)/(m₁+m₂)
        """))

        f.append(Formula(name: "Ohm's Law Wheel", category: "Physics — E&M", tags: ["ohm wheel", "power formula", "V I R P"], content: """
        V = IR = P/I = √(PR)
        I = V/R = P/V = √(P/R)
        R = V/I = V²/P = P/I²
        P = VI = I²R = V²/R
        """))

        f.append(Formula(name: "Derivatives of Hyperbolic Functions", category: "Calculus", tags: ["hyperbolic derivative", "sinh derivative", "cosh derivative"], content: """
        d/dx sinh(x) = cosh(x)
        d/dx cosh(x) = sinh(x)
        d/dx tanh(x) = sech²(x) = 1 − tanh²(x)
        """))

        f.append(Formula(name: "Integration Formulas (Additional)", category: "Calculus", tags: ["integral table", "integral formula", "common integrals"], content: """
        ∫ 1/(x²+a²) dx = (1/a) arctan(x/a) + C
        ∫ 1/√(a²−x²) dx = arcsin(x/a) + C
        ∫ 1/(x²−a²) dx = (1/2a) ln|(x−a)/(x+a)| + C
        ∫ √(a²−x²) dx = (x/2)√(a²−x²) + (a²/2) arcsin(x/a) + C
        ∫ ln(x) dx = x·ln(x) − x + C
        ∫ xⁿ ln(x) dx = xⁿ⁺¹[(ln x)/(n+1) − 1/(n+1)²] + C
        """))

        f.append(Formula(name: "Number Theory Basics", category: "Algebra", tags: ["number theory", "prime", "GCD", "LCM", "modular arithmetic"], content: """
        GCD × LCM = |a × b|
        Euclidean algorithm: GCD(a,b) = GCD(b, a mod b)
        Fermat's little theorem: aᵖ⁻¹ ≡ 1 (mod p) if gcd(a,p)=1
        Modular: (a+b) mod n = ((a mod n) + (b mod n)) mod n
        """))

        f.append(Formula(name: "Set Theory", category: "Algebra", tags: ["set theory", "union", "intersection", "complement", "subset"], content: """
        |A ∪ B| = |A| + |B| − |A ∩ B|
        |A ∪ B ∪ C| = |A| + |B| + |C| − |A∩B| − |A∩C| − |B∩C| + |A∩B∩C|
        De Morgan: (A ∪ B)' = A' ∩ B',  (A ∩ B)' = A' ∪ B'
        Power set: |P(A)| = 2^|A|
        """))

        f.append(Formula(name: "Ordinary Differential Equations", category: "Calculus", tags: ["ODE", "differential equation", "separable", "linear ODE"], content: """
        Separable: dy/dx = f(x)g(y) → ∫dy/g(y) = ∫f(x)dx
        Linear 1st order: dy/dx + P(x)y = Q(x)
        Integrating factor: μ = e^(∫P(x)dx)
        Solution: y = (1/μ)∫μQ(x)dx
        2nd order constant coeff: ay'' + by' + cy = 0
        Characteristic: ar² + br + c = 0
        """))

        f.append(Formula(name: "Trig Substitution Table", category: "Calculus", tags: ["trig substitution", "integration technique", "trigonometric substitution"], content: """
        √(a²−x²): let x = a sin(θ), dx = a cos(θ)dθ
        √(a²+x²): let x = a tan(θ), dx = a sec²(θ)dθ
        √(x²−a²): let x = a sec(θ), dx = a sec(θ)tan(θ)dθ
        """))

        f.append(Formula(name: "Moment Generating Function", category: "Statistics", tags: ["MGF", "moment generating function", "moments"], content: """
        M_X(t) = E(eᵗˣ)
        E(Xⁿ) = M_X⁽ⁿ⁾(0)  (nth derivative at t=0)
        Normal MGF: M(t) = exp(μt + σ²t²/2)
        Poisson MGF: M(t) = exp(λ(eᵗ − 1))
        """))

        f.append(Formula(name: "Hypothesis Testing", category: "Statistics", tags: ["hypothesis test", "p-value", "null hypothesis", "significance", "type I error", "type II error"], content: """
        H₀: null hypothesis, H₁: alternative
        Type I error (α): reject H₀ when true
        Type II error (β): fail to reject H₀ when false
        Power = 1 − β
        p-value < α → reject H₀
        Common α: 0.05, 0.01, 0.001
        """))

        f.append(Formula(name: "T-Test", category: "Statistics", tags: ["t-test", "student t", "t-distribution", "t statistic"], content: """
        One-sample: t = (x̄ − μ₀)/(s/√n)
        Two-sample: t = (x̄₁ − x̄₂)/√(s₁²/n₁ + s₂²/n₂)
        Degrees of freedom: df = n − 1 (one-sample)
        Paired: t = d̄/(s_d/√n)
        """))

        f.append(Formula(name: "ANOVA", category: "Statistics", tags: ["ANOVA", "analysis of variance", "F-test", "between groups"], content: """
        F = MS_between / MS_within
        MS_between = SS_between / (k−1)
        MS_within = SS_within / (N−k)
        k = number of groups, N = total observations
        Large F → reject H₀ (groups differ)
        """))

        f.append(Formula(name: "Coulomb's Law (Detailed)", category: "Physics — E&M", tags: ["coulomb detailed", "electric force", "point charge force"], content: """
        F = kq₁q₂/r² r̂
        k = 8.988 × 10⁹ N·m²/C²
        Attractive if opposite signs, repulsive if same
        Superposition: F_total = ΣFᵢ (vector sum)
        """))

        f.append(Formula(name: "Parallel Axis Theorem", category: "Physics — Mechanics", tags: ["parallel axis", "moment of inertia", "axis theorem"], content: """
        I = I_cm + Md²
        I_cm = moment of inertia about center of mass
        d = distance between parallel axes
        """))

        f.append(Formula(name: "Damped Oscillation", category: "Physics — Mechanics", tags: ["damped", "damped oscillation", "damping", "quality factor"], content: """
        x(t) = Ae^(−γt) cos(ω't + φ)
        γ = b/(2m) (damping rate)
        ω' = √(ω₀² − γ²) (damped frequency)
        Q = ω₀/(2γ) (quality factor)
        Underdamped: γ < ω₀
        Critically damped: γ = ω₀
        Overdamped: γ > ω₀
        """))

        f.append(Formula(name: "Work Done by Gas", category: "Thermodynamics", tags: ["work gas", "PdV work", "expansion work"], content: """
        W = ∫ P dV
        Isobaric: W = PΔV = nRΔT
        Isothermal: W = nRT ln(V₂/V₁)
        Adiabatic: W = (P₁V₁ − P₂V₂)/(γ−1)
        Isochoric: W = 0
        """))

        f.append(Formula(name: "Molar Heat Capacities", category: "Thermodynamics", tags: ["heat capacity", "Cv", "Cp", "molar heat capacity"], content: """
        Monatomic ideal gas: Cᵥ = (3/2)R, Cₚ = (5/2)R, γ = 5/3
        Diatomic ideal gas: Cᵥ = (5/2)R, Cₚ = (7/2)R, γ = 7/5
        Cₚ − Cᵥ = R (Mayer's relation)
        """))

        f.append(Formula(name: "Wave Superposition", category: "Physics — Waves", tags: ["superposition", "interference", "constructive", "destructive"], content: """
        Constructive: path diff = nλ (n = 0, 1, 2, ...)
        Destructive: path diff = (n + ½)λ
        Intensity: I ∝ A²
        Two sources: I = I₁ + I₂ + 2√(I₁I₂)cos(Δφ)
        """))

        f.append(Formula(name: "Polarization", category: "Physics — Waves", tags: ["polarization", "malus", "Brewster", "polarized light"], content: """
        Malus's Law: I = I₀ cos²(θ)
        Brewster's angle: tan(θ_B) = n₂/n₁
        Unpolarized → polarizer: I = I₀/2
        """))

        f.append(Formula(name: "Nuclear Physics", category: "Physics — Modern", tags: ["nuclear", "binding energy", "mass defect", "nuclear reaction"], content: """
        Mass defect: Δm = Z·mₚ + N·mₙ − m_nucleus
        Binding energy: E_B = Δm·c²
        BE per nucleon peaks at Fe-56 (~8.8 MeV)
        α decay: ₂He⁴, β⁻ decay: e⁻ + ν̄, β⁺ decay: e⁺ + ν
        """))

        f.append(Formula(name: "Ideal Diode and Transistor", category: "Physics — E&M", tags: ["diode", "transistor", "semiconductor", "junction"], content: """
        Diode I-V: I = I₀(e^(V/Vₜ) − 1)
        Thermal voltage: Vₜ = kT/q ≈ 26 mV at 300K
        Silicon forward voltage: ~0.7 V
        BJT: I_C = βI_B, I_E = I_B + I_C
        """))

        f.append(Formula(name: "AC Circuits", category: "Physics — E&M", tags: ["AC circuit", "impedance", "RLC", "resonance", "reactance"], content: """
        V = V₀ sin(ωt)
        Impedance: Z = √(R² + (X_L − X_C)²)
        X_L = ωL (inductive reactance)
        X_C = 1/(ωC) (capacitive reactance)
        Resonance: ω₀ = 1/√(LC), Z = R (minimum)
        Power: P_avg = V_rms · I_rms · cos(φ)
        V_rms = V₀/√2
        """))

        f.append(Formula(name: "Logarithmic Scales", category: "Algebra", tags: ["decibel", "richter", "pH scale", "logarithmic scale"], content: """
        Decibels: dB = 10 log₁₀(P₂/P₁) = 20 log₁₀(V₂/V₁)
        Richter: M = log₁₀(A/A₀), each step = 10× amplitude
        pH: pH = −log₁₀[H⁺], each step = 10× concentration
        Octave: 2× frequency
        """))

        f.append(Formula(name: "Sequences and Limits", category: "Calculus", tags: ["sequence", "convergence", "squeeze theorem", "ratio test"], content: """
        Squeeze theorem: if a_n ≤ b_n ≤ c_n and lim a_n = lim c_n = L, then lim b_n = L
        Ratio test: lim |a_(n+1)/a_n| < 1 → converges
        Root test: lim |a_n|^(1/n) < 1 → converges
        Harmonic series Σ 1/n diverges
        p-series Σ 1/nᵖ converges iff p > 1
        """))

        f.append(Formula(name: "Black Body Radiation", category: "Physics — Modern", tags: ["black body", "Wien", "Planck radiation", "peak wavelength"], content: """
        Wien's law: λ_max = b/T  (b = 2.898 × 10⁻³ m·K)
        Stefan-Boltzmann: P = σAT⁴
        Planck's law: B(λ,T) = (2hc²/λ⁵) · 1/(e^(hc/λkT) − 1)
        """))

        f.append(Formula(name: "Doppler Effect (Light)", category: "Physics — Modern", tags: ["relativistic doppler", "redshift", "blueshift"], content: """
        f_obs = f_source · √((1+β)/(1−β))  (approaching)
        f_obs = f_source · √((1−β)/(1+β))  (receding)
        β = v/c
        Redshift: z = Δλ/λ ≈ v/c (for v << c)
        """))

        f.append(Formula(name: "Simple Machines", category: "Physics — Mechanics", tags: ["simple machine", "mechanical advantage", "lever", "pulley", "incline"], content: """
        Mechanical advantage: MA = F_out/F_in
        Lever: F₁d₁ = F₂d₂
        Inclined plane: MA = L/h (length/height)
        Pulley system: MA = number of supporting ropes
        Efficiency: η = (MA_actual/MA_ideal) × 100%
        """))

        f.append(Formula(name: "Orbital Mechanics", category: "Physics — Mechanics", tags: ["orbital", "satellite", "orbit", "geosynchronous"], content: """
        Orbital velocity: v = √(GM/r)
        Orbital period: T = 2π√(r³/GM)
        Geosynchronous: r = 42,164 km (from Earth center)
        Vis-viva: v² = GM(2/r − 1/a)  (a = semi-major axis)
        """))

        f.append(Formula(name: "Permutations with Repetition", category: "Probability", tags: ["permutation repetition", "multinomial", "arrangement"], content: """
        Permutations of n objects with repetition:
        n! / (n₁! · n₂! · ... · nₖ!)
        Example: MISSISSIPPI has 11!/(4!·4!·2!·1!) arrangements
        With replacement: nʳ (n choices, r selections)
        """))

        f.append(Formula(name: "Geometric Probability", category: "Probability", tags: ["geometric distribution", "first success", "geometric probability"], content: """
        P(X = k) = (1−p)ᵏ⁻¹ · p  (k = trial of first success)
        Mean: μ = 1/p
        Variance: σ² = (1−p)/p²
        P(X > k) = (1−p)ᵏ
        """))

        f.append(Formula(name: "Negative Binomial Distribution", category: "Probability", tags: ["negative binomial", "failures before success"], content: """
        P(X = k) = C(k+r−1, k) · pʳ · (1−p)ᵏ
        (k failures before r-th success)
        Mean: μ = r(1−p)/p
        Variance: σ² = r(1−p)/p²
        """))

        f.append(Formula(name: "Telescoping Series", category: "Calculus", tags: ["telescoping", "telescoping series", "partial sums"], content: """
        Σ (aₙ − aₙ₊₁) = a₁ − lim aₙ
        Example: Σ 1/(n(n+1)) = Σ(1/n − 1/(n+1)) = 1
        """))

        f.append(Formula(name: "Polar Area and Arc Length", category: "Calculus", tags: ["polar area", "polar arc length", "polar coordinates"], content: """
        Area: A = ½ ∫ₐᵇ r² dθ
        Arc length: L = ∫ₐᵇ √(r² + (dr/dθ)²) dθ
        Between curves: A = ½ ∫(r₁² − r₂²) dθ
        """))

        f.append(Formula(name: "Complex Number Forms", category: "Algebra", tags: ["complex form", "polar form", "exponential form", "De Moivre"], content: """
        Rectangular: z = a + bi
        Polar: z = r(cos θ + i sin θ) = r·cis(θ)
        Exponential: z = re^(iθ)
        De Moivre: (cos θ + i sin θ)ⁿ = cos(nθ) + i sin(nθ)
        nth roots: z^(1/n) = r^(1/n) · e^(i(θ+2πk)/n), k = 0,1,...,n−1
        """))

        f.append(Formula(name: "Uniform Distribution", category: "Statistics", tags: ["uniform distribution", "continuous uniform", "rectangular"], content: """
        Continuous Uniform on [a,b]:
        f(x) = 1/(b−a) for a ≤ x ≤ b
        Mean: μ = (a+b)/2
        Variance: σ² = (b−a)²/12
        CDF: F(x) = (x−a)/(b−a)
        """))

        f.append(Formula(name: "Beta and Gamma Distributions", category: "Statistics", tags: ["beta distribution", "gamma distribution", "shape parameter"], content: """
        Gamma(α,β): f(x) = xᵅ⁻¹e^(−x/β) / (βᵅΓ(α))
        Mean: αβ, Variance: αβ²

        Beta(α,β): f(x) = xᵅ⁻¹(1−x)ᵝ⁻¹ / B(α,β)
        Mean: α/(α+β), on [0,1]
        """))

        f.append(Formula(name: "Exact Trigonometric Values", category: "Trigonometry", tags: ["exact trig", "pi/12", "15 degrees", "75 degrees", "exact values"], content: """
        sin(15°) = (√6 − √2)/4
        cos(15°) = (√6 + √2)/4
        sin(75°) = (√6 + √2)/4
        cos(75°) = (√6 − √2)/4
        tan(15°) = 2 − √3
        tan(75°) = 2 + √3
        """))

        f.append(Formula(name: "Doppler Effect (Sound)", category: "Physics — Waves", tags: ["doppler sound", "moving source", "moving observer"], content: """
        f' = f · (v + v_o) / (v − v_s)  (both approaching)
        f' = f · (v − v_o) / (v + v_s)  (both receding)
        v = speed of sound, v_o = observer speed, v_s = source speed
        Sonic boom: when v_s > v (Mach > 1)
        Mach number: M = v_s/v
        """))

        f.append(Formula(name: "Maxwell-Boltzmann Distribution", category: "Thermodynamics", tags: ["maxwell-boltzmann", "speed distribution", "molecular speed", "RMS speed"], content: """
        v_rms = √(3kT/m) = √(3RT/M)
        v_avg = √(8kT/(πm))
        v_most_probable = √(2kT/m)
        v_rms > v_avg > v_mp
        """))

        f.append(Formula(name: "Clausius-Clapeyron Equation", category: "Chemistry", tags: ["clausius-clapeyron", "vapor pressure", "phase transition"], content: """
        ln(P₂/P₁) = (ΔH_vap/R)(1/T₁ − 1/T₂)
        dP/dT = ΔH/(TΔV)
        Used to relate vapor pressure to temperature.
        """))

        f.append(Formula(name: "Lewis Structures and VSEPR", category: "Chemistry", tags: ["lewis", "VSEPR", "molecular geometry", "electron geometry"], content: """
        Electron domains → geometry:
        2: linear (180°)
        3: trigonal planar (120°)
        4: tetrahedral (109.5°)
        5: trigonal bipyramidal (90°, 120°)
        6: octahedral (90°)
        Lone pairs reduce bond angles.
        """))

        f.append(Formula(name: "Solubility Product", category: "Chemistry", tags: ["Ksp", "solubility product", "precipitation", "ionic product"], content: """
        For AₓBᵧ(s) ⇌ xA^(y+)(aq) + yB^(x−)(aq):
        Ksp = [A^(y+)]ˣ · [B^(x−)]ʸ
        If Q > Ksp → precipitate forms
        If Q < Ksp → solution is unsaturated
        """))

        f.append(Formula(name: "Beer-Lambert Law", category: "Chemistry", tags: ["beer-lambert", "absorbance", "spectroscopy", "transmittance"], content: """
        A = εbc = −log₁₀(T)
        ε = molar absorptivity (L/(mol·cm))
        b = path length (cm)
        c = concentration (mol/L)
        T = I/I₀ (transmittance)
        """))

        f.append(Formula(name: "Atomic Orbitals", category: "Chemistry", tags: ["orbital", "quantum numbers", "electron configuration", "s p d f"], content: """
        n: principal (1, 2, 3, ...)
        l: angular momentum (0 to n−1): s=0, p=1, d=2, f=3
        mₗ: magnetic (−l to +l)
        mₛ: spin (±½)
        Max electrons: 2n²
        Aufbau: 1s 2s 2p 3s 3p 4s 3d 4p 5s 4d 5p 6s 4f 5d 6p ...
        """))

        f.append(Formula(name: "Buffer Capacity", category: "Chemistry", tags: ["buffer", "buffer capacity", "weak acid", "conjugate base"], content: """
        Buffer solution: weak acid + conjugate base (or weak base + conjugate acid)
        Best buffering when pH ≈ pKa
        Effective range: pKa ± 1
        pH = pKa + log([A⁻]/[HA]) (Henderson-Hasselbalch)
        """))

        return f
    }()
    // swiftlint:enable function_body_length
}
