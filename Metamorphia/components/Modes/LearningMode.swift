import Foundation

public enum LearningMode: MetamorphiaMode {

    public static let slashKeyword = "learning"

    public static func handle(argument: String, viewModel: AICommandViewModel) async {
        let topic = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            viewModel.showModeError("Give a topic, e.g. /learning krebs cycle")
            return
        }
        let systemPrompt = """
        You are Metamorphia Learning Mode. Build a thorough, well-structured \
        explanation of: \(topic). Use markdown headings, numbered sections, \
        LaTeX for any math, code blocks for examples. Aim for ~500-800 words.
        """
        await viewModel.submit(prompt: topic, systemPrompt: systemPrompt)
    }
}
