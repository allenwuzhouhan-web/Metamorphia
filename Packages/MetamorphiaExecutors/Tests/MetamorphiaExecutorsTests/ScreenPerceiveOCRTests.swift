import XCTest
@testable import MetamorphiaExecutors
import MetamorphiaAgentKit
import MetamorphiaPerception

/// Rank 7 — ScreenPerceiveTool schema coverage for the new `ocr` policy
/// parameter. Schema-shape tests only (no live capture), so they run anywhere.
final class ScreenPerceiveOCRTests: XCTestCase {

    // MARK: - Schema

    func testScreenPerceiveTool_ocrParam_InSchema() {
        let tool = ScreenPerceiveTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["ocr"], "screen_perceive must expose 'ocr' parameter")
        let ocrSchema = props["ocr"] as? [String: Any]
        XCTAssertEqual(ocrSchema?["type"] as? String, "string",
                       "ocr parameter must be string-typed")
        XCTAssertNotNil(ocrSchema?["description"],
                        "ocr parameter must have a description")
    }

    func testScreenPerceiveTool_ocrEnumValues_Match() {
        let tool = ScreenPerceiveTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        let ocrSchema = props["ocr"] as? [String: Any]
        let values = ocrSchema?["enum"] as? [String] ?? []

        XCTAssertEqual(Set(values), Set(["auto", "require", "skip", "async"]),
                       "ocr enum must include all four policy modes")
    }

    // MARK: - Description mentions the new parameter

    func testScreenPerceiveTool_descriptionMentionsOCRPolicy() {
        let tool = ScreenPerceiveTool()
        // Description should hint at the new modes so the LLM picks the right
        // one without consulting the JSON schema.
        XCTAssertTrue(tool.description.lowercased().contains("ocr"),
                      "description must mention OCR policy")
        for mode in ["auto", "require", "skip", "async"] {
            XCTAssertTrue(tool.description.contains(mode),
                          "description must mention '\(mode)' mode")
        }
    }

    // MARK: - Backward compat: force_ocr still present

    func testScreenPerceiveTool_forceOCRStillPresent() {
        let tool = ScreenPerceiveTool()
        let props = (tool.parameters["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["force_ocr"],
                        "force_ocr must remain for backward compat")
    }
}
