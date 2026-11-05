import CoreGraphics
import Vision

/// Corners in normalized image coordinates, with the origin at the bottom left.
struct RecordQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

extension RecordQuad {
    /// A square looks the same turned by a quarter, so its corners alone can't say which way is up.
    /// Straightening by the smallest rotation keeps the top of the record toward the top of the phone.
    func turnedToSmallestRotation(aspect: CGFloat) -> RecordQuad {
        var quad = self
        for _ in 0..<4 {
            let across = atan2(quad.topRight.y - quad.topLeft.y, (quad.topRight.x - quad.topLeft.x) * aspect)
            if abs(across) <= .pi / 4 { return quad }
            quad = RecordQuad(topLeft: quad.bottomLeft, topRight: quad.topLeft, bottomRight: quad.topRight, bottomLeft: quad.bottomRight)
        }
        return self
    }
}

enum DetectedRecord: Equatable, Sendable {
    case sleeve(RecordQuad)
    /// A square just around the disc, in normalized image coordinates.
    case disc(CGRect)
}

enum RecordDetector {
    /// The tripod height is fixed, so a sleeve is always about the same size in the frame. Accepting
    /// only that size stops the artwork inside a cover being mistaken for the cover.
    private static let sizeTolerance: CGFloat = 0.15
    private static let maxAnalysisSide = 1000

    static func detect(in image: CGImage, lens: Lens) -> DetectedRecord? {
        // Discs first: their corners are empty, which a dark sleeve's never are.
        if let disc = detectDisc(in: image, lens: lens) { return .disc(disc) }
        return detectSleeve(in: image, lens: lens).map(DetectedRecord.sleeve)
    }

    // MARK: - Sleeves

    private static func detectSleeve(in image: CGImage, lens: Lens) -> RecordQuad? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.8
        request.maximumAspectRatio = 1
        request.minimumSize = 0.3
        request.minimumConfidence = 0.3
        request.quadratureTolerance = 20
        request.maximumObservations = 12
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let short = min(width, height)
        let expected = lens.sleeveShare
        let candidates = (request.results ?? []).compactMap { observation -> (RecordQuad, CGFloat)? in
            func point(_ normalized: CGPoint) -> CGPoint { CGPoint(x: normalized.x * width, y: normalized.y * height) }
            let topLeft = point(observation.topLeft)
            let topRight = point(observation.topRight)
            let bottomLeft = point(observation.bottomLeft)
            let side = (hypot(topRight.x - topLeft.x, topRight.y - topLeft.y) + hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)) / 2 / short
            guard abs(side - expected) <= sizeTolerance else { return nil }
            let quad = RecordQuad(
                topLeft: observation.topLeft,
                topRight: observation.topRight,
                bottomRight: observation.bottomRight,
                bottomLeft: observation.bottomLeft
            )
            return (quad.turnedToSmallestRotation(aspect: width / height), side)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    // MARK: - Discs

    private static func detectDisc(in image: CGImage, lens: Lens) -> CGRect? {
        let scale = min(CGFloat(maxAnalysisSide) / CGFloat(max(image.width, image.height)), 1)
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        var gray = [UInt8](repeating: 0, count: width * height)
        let didDraw = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        // Keep to the middle of the frame, away from the tripod base and anything else on the table.
        let short = min(width, height)
        let searchHalf = Int((lens.guideHalfSide + 0.08) * CGFloat(short))
        let bounds = (
            minX: max(width / 2 - searchHalf, 0), maxX: min(width / 2 + searchHalf, width - 1),
            minY: max(height / 2 - searchHalf, 0), maxY: min(height / 2 + searchHalf, height - 1)
        )
        guard let blob = largestDarkBlob(in: gray, width: width, bounds: bounds) else { return nil }
        guard !blob.touchesBounds else { return nil }

        let blobWidth = blob.maxX - blob.minX + 1
        let blobHeight = blob.maxY - blob.minY + 1
        let aspect = CGFloat(blobWidth) / CGFloat(blobHeight)
        let side = CGFloat(max(blobWidth, blobHeight))
        guard
            aspect > 0.94, aspect < 1.06,
            abs(side / CGFloat(short) - lens.sleeveShare) <= sizeTolerance
        else { return nil }

        guard isRound(blob, in: gray, width: width) else { return nil }

        // The buffer's first row is the top of the image.
        let centerX = CGFloat(blob.minX + blob.maxX + 1) / 2 / CGFloat(width)
        let centerY = 1 - CGFloat(blob.minY + blob.maxY + 1) / 2 / CGFloat(height)
        let squareWidth = side * 1.02 / CGFloat(width)
        let squareHeight = side * 1.02 / CGFloat(height)
        return CGRect(x: centerX - squareWidth / 2, y: centerY - squareHeight / 2, width: squareWidth, height: squareHeight)
    }

    private static let darkLevel: UInt8 = 110
    /// A disc's edge is the same distance from its center all the way round, while a square's
    /// varies by about 40%. A tilted sleeve can't pass this, even though its box has empty corners.
    private static let roundnessTolerance = 0.05

    /// Walks in from outside the blob along rays from its center to find its outer edge. Going
    /// inward means the label and reflections inside the disc don't matter.
    private static func isRound(_ blob: Blob, in gray: [UInt8], width: Int) -> Bool {
        let centerX = Double(blob.minX + blob.maxX) / 2
        let centerY = Double(blob.minY + blob.maxY) / 2
        let radius = Double(max(blob.maxX - blob.minX, blob.maxY - blob.minY)) / 2
        var distances: [Double] = []
        for step in 0..<72 {
            let angle = Double(step) * .pi / 36
            var distance = radius * 1.5
            while distance > 0 {
                let x = Int(centerX + cos(angle) * distance)
                let y = Int(centerY + sin(angle) * distance)
                // Staying inside the blob's own box skips dark things nearby, like the tripod base.
                if x >= blob.minX, x <= blob.maxX, y >= blob.minY, y <= blob.maxY, gray[y * width + x] < darkLevel {
                    distances.append(distance)
                    break
                }
                distance -= 1
            }
        }
        guard distances.count == 72 else { return false }

        // Highlights on the vinyl can only shorten a ray, so short rays are allowed. Long ones are
        // what give a square away, because its corners reach well past the median.
        let median = distances.sorted()[distances.count / 2]
        let long = distances.filter { $0 > median * (1 + roundnessTolerance) }.count
        let short = distances.filter { $0 < median * 0.85 }.count
        return long <= 3 && short <= 24
    }

    private struct Blob {
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        var count: Int
        var touchesBounds: Bool
    }

    private static func largestDarkBlob(
        in gray: [UInt8],
        width: Int,
        bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)
    ) -> Blob? {
        var visited = [Bool](repeating: false, count: gray.count)
        var best: Blob?
        var stack: [Int] = []

        for startY in bounds.minY...bounds.maxY {
            for startX in bounds.minX...bounds.maxX {
                let start = startY * width + startX
                guard !visited[start], gray[start] < darkLevel else { continue }
                var blob = Blob(minX: startX, maxX: startX, minY: startY, maxY: startY, count: 0, touchesBounds: false)
                visited[start] = true
                stack.append(start)
                while let index = stack.popLast() {
                    let x = index % width
                    let y = index / width
                    blob.count += 1
                    blob.minX = min(blob.minX, x)
                    blob.maxX = max(blob.maxX, x)
                    blob.minY = min(blob.minY, y)
                    blob.maxY = max(blob.maxY, y)
                    if x == bounds.minX || x == bounds.maxX || y == bounds.minY || y == bounds.maxY {
                        blob.touchesBounds = true
                    }
                    for (nextX, nextY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    where nextX >= bounds.minX && nextX <= bounds.maxX && nextY >= bounds.minY && nextY <= bounds.maxY {
                        let next = nextY * width + nextX
                        if !visited[next], gray[next] < darkLevel {
                            visited[next] = true
                            stack.append(next)
                        }
                    }
                }
                if blob.count > (best?.count ?? 0) { best = blob }
            }
        }
        return best
    }
}
