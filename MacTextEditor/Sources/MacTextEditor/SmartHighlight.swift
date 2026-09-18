import Foundation

struct SmartHighlightBatch: Sendable {
    let ranges: [NSRange]
    let nextPosition: Int
    let isFinished: Bool
}

enum SmartHighlightMatcher {
    static func scan(
        data: Data,
        baseOffset: Int,
        searchRange: NSRange,
        query: Data,
        fromPosition: Int,
        maximumCount: Int = 512
    ) throws -> SmartHighlightBatch {
        try Task.checkCancellation()
        precondition(maximumCount > 0)
        let boundary = NSMaxRange(searchRange)
        var position = max(searchRange.location, fromPosition)
        guard !query.isEmpty, position < boundary else {
            return SmartHighlightBatch(ranges: [], nextPosition: max(position, boundary), isFinished: true)
        }

        var ranges: [NSRange] = []
        while position < boundary, ranges.count < maximumCount {
            try Task.checkCancellation()
            let start = data.index(data.startIndex, offsetBy: position - baseOffset)
            guard let match = data.range(of: query, in: start..<data.endIndex) else {
                return SmartHighlightBatch(ranges: ranges, nextPosition: max(position, boundary), isFinished: true)
            }
            let matchStart = baseOffset + data.distance(from: data.startIndex, to: match.lowerBound)
            guard matchStart < boundary else {
                return SmartHighlightBatch(ranges: ranges, nextPosition: max(position, boundary), isFinished: true)
            }
            ranges.append(NSRange(location: matchStart, length: query.count))
            // A match may consume the following block's prefix; retain its real end.
            position = matchStart + query.count
        }
        return SmartHighlightBatch(ranges: ranges, nextPosition: position, isFinished: position >= boundary)
    }
}
