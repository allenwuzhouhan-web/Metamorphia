import Foundation

/// Manages Metamorphia's spoken-address name and flexible wake-phrase
/// generation. Also stores transcription variants learned during optional
/// calibration (calibration UI is deferred past T5 but the variants store
/// exists so the matcher can grow without migrations).
///
/// Default name is "Metamorphia" — changeable later in Settings. Users say
/// "Hey Metamorphia, …" and we strip the address prefix before submitting
/// the command to the agent.
final class AssistantNameManager {
    static let shared = AssistantNameManager()

    private let nameKey = "metamorphia_assistant_name"
    private let variantsKey = "metamorphia_assistant_name_variants"

    var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "Metamorphia" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    /// Transcription variants learned during calibration — how
    /// `SFSpeechRecognizer` actually hears the user say the name (varies per
    /// accent/voice). Empty in T5; populated if/when the calibration flow
    /// lands.
    var learnedVariants: [String] {
        get { UserDefaults.standard.stringArray(forKey: variantsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: variantsKey) }
    }

    func addLearnedVariant(_ variant: String) {
        let lower = variant
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return }
        var current = learnedVariants
        if !current.contains(lower) {
            current.append(lower)
            learnedVariants = current
        }
    }

    func clearLearnedVariants() {
        learnedVariants = []
    }

    /// Phrases that should be stripped from the head of a command. Longest
    /// first so the most specific prefix wins.
    func addressPrefixes() -> [String] {
        let n = name.lowercased()
        var prefixes = [
            n,
            "hey \(n)",
            "help \(n)",
            "ok \(n)",
            "okay \(n)",
        ]
        for variant in learnedVariants {
            prefixes.append(variant)
            prefixes.append("hey \(variant)")
            prefixes.append("help \(variant)")
        }
        return prefixes.sorted { $0.count > $1.count }
    }

    /// Strip any address prefix from `command`. Non-destructive — returns the
    /// original text if nothing matches.
    func stripNamePrefix(from command: String) -> String {
        let lower = command
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in addressPrefixes() {
            if lower.hasPrefix(prefix) {
                let stripped = command
                    .dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? command : stripped
            }
        }
        return command
    }
}
