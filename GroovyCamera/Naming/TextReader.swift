import Foundation
import Vision

/// Reads the text on a finished photo, on the phone.
enum TextReader {
    static func read(url: URL) -> [TextLine] {
        // Accurate rather than fast: this runs in the background, and stylized covers need it.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard (try? VNImageRequestHandler(url: url).perform([request])) != nil else { return [] }

        return (request.results ?? []).compactMap { observation -> TextLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision's origin is the bottom left.
            return TextLine(text: text, height: observation.boundingBox.height, top: 1 - observation.boundingBox.maxY)
        }
    }
}
