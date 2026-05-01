import Foundation

/// A tool that an LLM agent can invoke.
///
/// This is the shared protocol that binds MetamorphiaAgentKit (which schedules
/// and registers tools), MetamorphiaExecutors (which implements most tools),
/// and MetamorphiaPerception / ComputerLib (which vends perception-backed
/// tools via a native bridge). The protocol is intentionally minimal so it can
/// live in its own package with zero dependencies — avoiding the circular graph
/// that would form if it stayed inside MetamorphiaAgentKit.
///
/// Higher-level helpers such as `toAPISchema()`, `parseArguments()`, and
/// `requiredString(_:from:)` live in a protocol extension inside
/// MetamorphiaAgentKit, where `AnyCodable` and `MetamorphiaError` naturally
/// reside. Consumers that import only this package still have a usable
/// protocol to conform to; they simply throw `Error` directly.
public protocol ToolDefinition: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for parameters, as a dictionary of `Any`.
    var parameters: [String: Any] { get }

    func execute(arguments: String) async throws -> String
}
