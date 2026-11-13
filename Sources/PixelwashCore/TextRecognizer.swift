import CoreGraphics
import Foundation
import Vision

/// A line of recognised text. `box` is normalised (0…1) with the origin at the
/// bottom-left of the page, as Vision reports it.
public struct RecognizedText: Sendable {
    public let string: String
    public let box: CGRect
}

public enum TextRecognizer {
    /// Runs Apple's on-device OCR. Only ever called on validated pixels.
    public static func recognize(_ image: CGImage) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, !best.string.isEmpty else { return nil }
            return RecognizedText(string: best.string, box: observation.boundingBox)
        }
    }
}
