import Foundation

private func expectHighlightCache(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

func runSmartHighlightCacheTests() throws {
    var cache = SmartHighlightCache()
    for page in 0..<40 {
        cache.insert(scannedRange: NSRange(location: page * 100, length: 100), matches: [
            NSRange(location: page * 100 + 10, length: 3)
        ])
    }
    let retention = NSRange(location: 1_000, length: 2_100)
    let viewport = NSRange(location: 2_000, length: 100)
    cache.retain(in: [retention], protecting: [viewport])
    try expectHighlightCache(cache.matches(in: [retention]).count == 21, "Cache did not retain twenty-one screens")
    try expectHighlightCache(cache.missingRanges(in: [retention]).isEmpty, "Retained screens lost scan coverage")
    try expectHighlightCache(cache.matches(in: [NSRange(location: 1_100, length: 100)]) == [NSRange(location: 1_110, length: 3)], "Returning to a cached screen missed its matches")
    try expectHighlightCache(cache.missingRanges(in: [NSRange(location: 900, length: 100)]) == [NSRange(location: 900, length: 100)], "Far-away screen was not evicted")
    cache.retain(in: [NSRange(location: 1_500, length: 2_100)], protecting: [NSRange(location: 2_500, length: 100)])
    try expectHighlightCache(cache.missingRanges(in: [NSRange(location: 1_500, length: 2_100)]) == [NSRange(location: 3_100, length: 500)], "Viewport movement did not identify only newly visited screens")

    cache.removeAll()
    try expectHighlightCache(cache.byteCost == 0, "Reset did not release the cache budget")
    cache.insert(scannedRange: NSRange(location: 20, length: 20), matches: [])
    cache.insert(scannedRange: NSRange(location: 60, length: 20), matches: [])
    try expectHighlightCache(cache.missingRanges(in: [NSRange(location: 50, length: 50), NSRange(location: 0, length: 60)]) == [
        NSRange(location: 0, length: 20), NSRange(location: 40, length: 20), NSRange(location: 80, length: 20)
    ], "Missing coverage was not merged and sorted correctly")

    cache.removeAll()
    cache.insert(scannedRange: NSRange(location: 0, length: 100), matches: [
        NSRange(location: 10, length: 2), NSRange(location: 30, length: 2), NSRange(location: 90, length: 2)
    ])
    cache.insert(scannedRange: NSRange(location: 20, length: 40), matches: [
        NSRange(location: 50, length: 2), NSRange(location: 40, length: 2), NSRange(location: 40, length: 2)
    ])
    try expectHighlightCache(cache.matches(in: [NSRange(location: 0, length: 100)]) == [
        NSRange(location: 10, length: 2), NSRange(location: 40, length: 2), NSRange(location: 50, length: 2), NSRange(location: 90, length: 2)
    ], "Overlapping insertion did not replace old matching starts without duplicates")
    try expectHighlightCache(cache.missingRanges(in: [NSRange(location: 0, length: 100)]).isEmpty, "Overlapping insertion introduced a coverage gap")
    cache.retain(in: [NSRange(location: 5, length: 10), NSRange(location: 35, length: 20)], protecting: [])
    try expectHighlightCache(cache.matches(in: [NSRange(location: 0, length: 100)]) == [
        NSRange(location: 10, length: 2), NSRange(location: 40, length: 2), NSRange(location: 50, length: 2)
    ], "Retention ranges were not clipped exactly")

    cache.removeAll()
    cache.insert(scannedRange: NSRange(location: 100, length: 20), matches: [NSRange(location: 118, length: 8)])
    cache.retain(in: [NSRange(location: 110, length: 10)], protecting: [])
    try expectHighlightCache(cache.matches(in: [NSRange(location: 122, length: 2)]) == [NSRange(location: 118, length: 8)], "A match extending beyond the coverage boundary was clipped or omitted")
    try expectHighlightCache(cache.missingRanges(in: [NSRange(location: 120, length: 6)]) == [NSRange(location: 120, length: 6)], "Extending matches incorrectly claimed additional start coverage")

    var bounded = SmartHighlightCache(maximumByteCost: 160)
    for page in 0..<5 {
        bounded.insert(scannedRange: NSRange(location: page * 100, length: 100), matches: [NSRange(location: page * 100 + 10, length: 2)])
    }
    bounded.retain(in: [NSRange(location: 0, length: 500)], protecting: [NSRange(location: 200, length: 100)])
    try expectHighlightCache(bounded.byteCost <= 160, "Non-priority cache exceeded its memory budget")
    try expectHighlightCache(bounded.missingRanges(in: [NSRange(location: 200, length: 100)]).isEmpty, "Memory pressure evicted the visible screen")
    try expectHighlightCache(bounded.missingRanges(in: [NSRange(location: 0, length: 100)]) == [NSRange(location: 0, length: 100)], "Memory pressure retained a farther screen instead of a nearer screen")

    var dense = SmartHighlightCache(maximumByteCost: 80)
    dense.insert(scannedRange: NSRange(location: 0, length: 300), matches: (0..<300).map { NSRange(location: $0, length: 1) })
    dense.retain(in: [NSRange(location: 0, length: 300)], protecting: [NSRange(location: 100, length: 100)])
    try expectHighlightCache(dense.matches(in: [NSRange(location: 0, length: 300)]).count == 100, "Dense current-screen results were evicted or outer results were retained")
    try expectHighlightCache(dense.missingRanges(in: [NSRange(location: 100, length: 100)]).isEmpty, "Dense current-screen coverage was not protected")
    try expectHighlightCache(dense.byteCost > 80, "Current-screen completeness should take precedence over the cache budget")
}
