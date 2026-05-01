import Foundation

@MainActor
public protocol MetamorphiaMode {
    static var slashKeyword: String { get }
    static func handle(argument: String, viewModel: AICommandViewModel) async
}
