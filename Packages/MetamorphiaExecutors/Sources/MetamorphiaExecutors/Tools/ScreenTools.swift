import Foundation
import MetamorphiaAgentKit

/// Capture the screen to a file using the bundled `screencapture` CLI. Returns
/// the path to the written image — the agent can then pass that path to a
/// vision-capable model or share it.
public struct CaptureScreenTool: ToolDefinition {
    public let name = "capture_screen"
    public let description = "Take a screenshot. Mode: 'full' (all displays), 'window' (user picks a window interactively), 'selection' (user drags a rectangle), 'region' (non-interactive, requires x/y/width/height). Returns the saved file path."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "mode": JSONSchema.enumString(description: "Capture mode.", values: ["full", "window", "selection", "region"]),
            "path": JSONSchema.string(description: "Output path (supports ~). Default: ~/Desktop/metamorphia-capture-<timestamp>.png"),
            "format": JSONSchema.enumString(description: "Image format (default png).", values: ["png", "jpg", "pdf", "tiff"]),
            "display": JSONSchema.integer(description: "For full-screen mode: which display (1-indexed). Omit for all.", minimum: 1, maximum: 8),
            "x": JSONSchema.integer(description: "region mode: left edge (pixels).", minimum: 0),
            "y": JSONSchema.integer(description: "region mode: top edge (pixels).", minimum: 0),
            "width": JSONSchema.integer(description: "region mode: width (pixels).", minimum: 1),
            "height": JSONSchema.integer(description: "region mode: height (pixels).", minimum: 1),
            "no_shadow": JSONSchema.boolean(description: "window mode: drop the window shadow (tighter crop)."),
        ], required: ["mode"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let mode = try requiredString("mode", from: args)
        let format = optionalString("format", from: args) ?? "png"

        let defaultPath: String = {
            let ts = Int(Date().timeIntervalSince1970)
            let desktop = (("~/Desktop" as NSString).expandingTildeInPath as NSString)
            return desktop.appendingPathComponent("metamorphia-capture-\(ts).\(format)")
        }()
        let rawPath = optionalString("path", from: args) ?? defaultPath
        let outPath = (rawPath as NSString).expandingTildeInPath

        var argv: [String] = ["-x", "-t", format]
        switch mode {
        case "full":
            if let d = optionalInt("display", from: args) {
                argv.append(contentsOf: ["-D", String(d)])
            }
        case "window":
            argv.append("-w")
            if optionalBool("no_shadow", from: args) == true { argv.append("-o") }
        case "selection":
            argv.append("-s")
        case "region":
            guard
                let x = optionalInt("x", from: args),
                let y = optionalInt("y", from: args),
                let w = optionalInt("width", from: args),
                let h = optionalInt("height", from: args)
            else {
                return "Error: region mode requires x, y, width, height."
            }
            argv.append(contentsOf: ["-R", "\(x),\(y),\(w),\(h)"])
        default:
            return "Error: unknown mode '\(mode)'."
        }
        argv.append(outPath)

        let result = try await AsyncShellRunner.run(
            executable: "/usr/sbin/screencapture",
            arguments: argv,
            timeout: 60
        )
        if result.exitCode != 0 || !FileManager.default.fileExists(atPath: outPath) {
            let err = result.stderr.isEmpty ? result.stdout : result.stderr
            return "Error: screencapture failed (exit \(result.exitCode)). \(err)"
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outPath),
           let size = attrs[.size] as? Int {
            return "Saved \(ByteCountFormatter().string(fromByteCount: Int64(size))) → \(outPath)"
        }
        return "Saved → \(outPath)"
    }
}
