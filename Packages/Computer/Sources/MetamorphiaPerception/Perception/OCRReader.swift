import Foundation
import Vision
import CoreGraphics

/// In-memory OCR via Apple Vision framework.
public enum OCRReader {

    public struct OCRResult: Sendable {
        public let text: String
        /// Bounding box in normalized coordinates (0-1), origin bottom-left (Vision convention).
        public let boundingBox: CGRect
        public let confidence: Float

        public init(text: String, boundingBox: CGRect, confidence: Float) {
            self.text = text
            self.boundingBox = boundingBox
            self.confidence = confidence
        }
    }

    /// Recognize text in a CGImage.
    public static func recognize(image: CGImage, languages: [String] = ["en"]) async throws -> [OCRResult] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let results = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> OCRResult? in
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    return OCRResult(
                        text: topCandidate.string,
                        boundingBox: observation.boundingBox,
                        confidence: topCandidate.confidence
                    )
                }
                continuation.resume(returning: results)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Convert normalized bounding box (origin bottom-left) to screen coordinates (origin top-left).
    public static func toScreenCoordinates(_ box: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let x = box.origin.x * CGFloat(imageWidth)
        let y = (1.0 - box.origin.y - box.height) * CGFloat(imageHeight)
        let w = box.width * CGFloat(imageWidth)
        let h = box.height * CGFloat(imageHeight)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
