import Foundation

struct SmartHighlightCache {
    private struct Entry {
        var range: NSRange
        var matches: [NSRange]
        let maximumMatchLength: Int

        init(range: NSRange, matches: [NSRange]) {
            self.range = range
            self.matches = matches
            maximumMatchLength = matches.reduce(0) { max($0, $1.length) }
        }

        var byteCost: Int { 64 + matches.count * MemoryLayout<NSRange>.stride }

        func clipped(to range: NSRange) -> Entry {
            if range == self.range { return self }
            let first = lowerBound(range.location)
            let last = lowerBound(NSMaxRange(range))
            return Entry(range: range, matches: Array(matches[first..<last]))
        }

        func lowerBound(_ location: Int) -> Int {
            var low = 0
            var high = matches.count
            while low < high {
                let middle = low + (high - low) / 2
                if matches[middle].location < location { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    private let maximumByteCost: Int
    private var entries: [Entry] = []
    private(set) var byteCost = 0

    init(maximumByteCost: Int = 4 * 1024 * 1024) {
        self.maximumByteCost = maximumByteCost
    }

    mutating func insert(scannedRange: NSRange, matches: [NSRange]) {
        guard scannedRange.length > 0 else { return }
        var validMatches = matches.filter {
            $0.length > 0 && $0.location >= scannedRange.location && $0.location < NSMaxRange(scannedRange)
        }
        if zip(validMatches, validMatches.dropFirst()).contains(where: { $0.location >= $1.location }) {
            validMatches.sort {
                $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
            }
            var previous: NSRange?
            validMatches = validMatches.filter { match in
                defer { previous = match }
                return previous != match
            }
        }
        let newEntry = Entry(range: scannedRange, matches: validMatches)
        if entries.last.map({ NSMaxRange($0.range) <= scannedRange.location }) ?? true {
            entries.append(newEntry)
            byteCost += newEntry.byteCost
            return
        }

        var low = 0
        var high = entries.count
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(entries[middle].range) <= scannedRange.location { low = middle + 1 } else { high = middle }
        }
        let first = low
        var last = first
        while last < entries.count && entries[last].range.location < NSMaxRange(scannedRange) { last += 1 }
        var replacements: [Entry] = []
        if first < last && entries[first].range.location < scannedRange.location {
            replacements.append(entries[first].clipped(to: NSRange(
                location: entries[first].range.location,
                length: scannedRange.location - entries[first].range.location
            )))
        }
        replacements.append(newEntry)
        if first < last && NSMaxRange(entries[last - 1].range) > NSMaxRange(scannedRange) {
            replacements.append(entries[last - 1].clipped(to: NSRange(
                location: NSMaxRange(scannedRange),
                length: NSMaxRange(entries[last - 1].range) - NSMaxRange(scannedRange)
            )))
        }
        byteCost -= entries[first..<last].reduce(0) { $0 + $1.byteCost }
        byteCost += replacements.reduce(0) { $0 + $1.byteCost }
        entries.replaceSubrange(first..<last, with: replacements)
    }

    mutating func retain(in retentionRanges: [NSRange], protecting priorityRanges: [NSRange]) {
        let retention = Self.normalized(retentionRanges)
        var retained: [Entry] = []
        var retentionIndex = 0
        for entry in entries {
            while retentionIndex < retention.count && NSMaxRange(retention[retentionIndex]) <= entry.range.location {
                retentionIndex += 1
            }
            var index = retentionIndex
            while index < retention.count && retention[index].location < NSMaxRange(entry.range) {
                let intersection = NSIntersectionRange(entry.range, retention[index])
                if intersection.length > 0 { retained.append(entry.clipped(to: intersection)) }
                index += 1
            }
        }
        entries = retained
        byteCost = entries.reduce(0) { $0 + $1.byteCost }
        guard byteCost > maximumByteCost else { return }

        // Split at viewport boundaries so evicting prefetch data cannot discard current-screen coverage.
        let priority = Self.normalized(priorityRanges)
        var pieces: [Entry] = []
        for entry in entries {
            var cursor = entry.range.location
            for range in priority where range.location < NSMaxRange(entry.range) && NSMaxRange(range) > cursor {
                let start = max(cursor, range.location)
                if start > cursor {
                    pieces.append(entry.clipped(to: NSRange(location: cursor, length: start - cursor)))
                }
                let end = min(NSMaxRange(entry.range), NSMaxRange(range))
                pieces.append(entry.clipped(to: NSRange(location: start, length: end - start)))
                cursor = end
            }
            if cursor < NSMaxRange(entry.range) {
                pieces.append(entry.clipped(to: NSRange(location: cursor, length: NSMaxRange(entry.range) - cursor)))
            }
        }
        byteCost = pieces.reduce(0) { $0 + $1.byteCost }
        let removable = pieces.indices.filter { index in
            !priority.contains { NSIntersectionRange(pieces[index].range, $0).length > 0 }
        }.sorted { left, right in
            let leftDistance = Self.distance(pieces[left].range, from: priority)
            let rightDistance = Self.distance(pieces[right].range, from: priority)
            return leftDistance == rightDistance ? left < right : leftDistance > rightDistance
        }
        var removed = Set<Int>()
        for index in removable where byteCost > maximumByteCost {
            removed.insert(index)
            byteCost -= pieces[index].byteCost
        }
        entries = pieces.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
    }

    func missingRanges(in ranges: [NSRange]) -> [NSRange] {
        var missing: [NSRange] = []
        var entryIndex = 0
        for range in Self.normalized(ranges) {
            var cursor = range.location
            while entryIndex < entries.count && NSMaxRange(entries[entryIndex].range) <= cursor { entryIndex += 1 }
            var index = entryIndex
            while index < entries.count && entries[index].range.location < NSMaxRange(range) {
                let entry = entries[index]
                if entry.range.location > cursor {
                    missing.append(NSRange(location: cursor, length: entry.range.location - cursor))
                }
                cursor = max(cursor, NSMaxRange(entry.range))
                index += 1
            }
            if cursor < NSMaxRange(range) {
                missing.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
            }
        }
        return missing
    }

    func matches(in ranges: [NSRange]) -> [NSRange] {
        let ranges = Self.normalized(ranges)
        guard let first = ranges.first, let last = ranges.last else { return [] }
        var result: [NSRange] = []
        var rangeIndex = 0
        for entry in entries {
            if entry.range.location >= NSMaxRange(last) { break }
            let earliestStart = max(0, first.location - entry.maximumMatchLength + 1)
            if NSMaxRange(entry.range) <= earliestStart { continue }
            let firstMatch = entry.lowerBound(earliestStart)
            let lastMatch = entry.lowerBound(NSMaxRange(last))
            for match in entry.matches[firstMatch..<lastMatch] {
                while rangeIndex < ranges.count && NSMaxRange(ranges[rangeIndex]) <= match.location { rangeIndex += 1 }
                if rangeIndex == ranges.count { return result }
                if NSMaxRange(match) > ranges[rangeIndex].location { result.append(match) }
            }
        }
        return result
    }

    mutating func removeAll() {
        entries.removeAll()
        byteCost = 0
    }

    private static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let previous = result.last, NSMaxRange(previous) >= range.location {
                result[result.count - 1].length = max(NSMaxRange(previous), NSMaxRange(range)) - previous.location
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func distance(_ range: NSRange, from priority: [NSRange]) -> Int {
        priority.map { max(0, max($0.location - NSMaxRange(range), range.location - NSMaxRange($0))) }.min() ?? Int.max
    }
}
