import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

@main
struct CoreTests {
    @MainActor
    static func main() async throws {
        try testChineseUTF8RoundTrip()
        try testIncompleteUTF8Preview()
        try testGB18030RoundTrip()
        try testSearchAndReplaceChineseText()
        try testRegularExpressionCaptureReplacement()
        try testBackgroundUTF8Replacement()
        try testBinaryFileCanBeEditedAndSaved()
        try testByteStoreChunkBoundarySearch()
        try testByteStoreRevision()
        try testSmartHighlightChunkBoundaries()
        try testSmartHighlightBatchPagination()
        try testSmartHighlightBinarySliceAndEOF()
        try await testSmartHighlightCancellation()
        try runSmartHighlightCacheTests()
        try testIncrementalUTF8ChineseBoundary()
        try testBinaryDetectionBeyondPrefix()
        try testLargeFilePolicy()
        print("Core tests passed")
    }

    private static func testChineseUTF8RoundTrip() throws {
        let source = "中文普通文本\n第二行😀"
        let data = try FileCodec.encode(source, using: .utf8)
        guard let decoded = FileCodec.decodeAutomatically(data) else {
            throw TestFailure.failed("UTF-8 auto detection failed")
        }
        try expect(decoded.text == source, "UTF-8 round trip failed")
        try expect(decoded.encoding == .utf8, "UTF-8 encoding detection failed")
        try expect(decoded.lineEnding == .lf, "LF detection failed")
    }

    private static func testGB18030RoundTrip() throws {
        let source = "简体中文测试"
        let data = try FileCodec.encode(source, using: .gb18030)
        let decoded = try FileCodec.decode(data, using: .gb18030)
        try expect(decoded.text == source, "GB18030 round trip failed")
    }

    private static func testIncompleteUTF8Preview() throws {
        var data = Data(repeating: 0x41, count: FileCodec.previewByteCount - 2)
        data.append(contentsOf: [0xE4, 0xB8])
        guard let decoded = FileCodec.decodePreviewAutomatically(data) else {
            throw TestFailure.failed("Incomplete UTF-8 preview was not decoded")
        }
        try expect(decoded.encoding == .utf8, "Incomplete UTF-8 preview encoding failed")
        try expect(decoded.text.utf8.count == FileCodec.previewByteCount - 2, "Incomplete UTF-8 suffix was not trimmed")
    }

    private static func testSearchAndReplaceChineseText() throws {
        let options = SearchOptions(caseSensitive: true, wholeWord: false, regularExpression: false)
        let result = try SearchEngine.replacingAll(
            in: "中文测试，中文查找",
            query: "中文",
            replacement: "文本",
            options: options
        )
        try expect(result.count == 2, "Chinese match count failed")
        try expect(result.text == "文本测试，文本查找", "Chinese replacement failed")
    }

    private static func testRegularExpressionCaptureReplacement() throws {
        let options = SearchOptions(caseSensitive: true, wholeWord: false, regularExpression: true)
        let result = try SearchEngine.replacingAll(
            in: "abc123 def456",
            query: "([a-z]+)([0-9]+)",
            replacement: "$2-$1",
            options: options
        )
        try expect(result.count == 2, "Regular-expression replacement count failed")
        try expect(result.text == "123-abc 456-def", "Regular-expression capture replacement failed")
    }

    private static func testBackgroundUTF8Replacement() throws {
        let exact = try SearchEngine.replacingAllUTF8(
            in: Data("中文-123-中文".utf8),
            query: "中文",
            replacement: "文本",
            options: SearchOptions(caseSensitive: true)
        )
        try expect(exact.count == 2, "Background UTF-8 replacement count failed")
        try expect(String(data: exact.data, encoding: .utf8) == "文本-123-文本", "Background UTF-8 replacement failed")

        let folded = try SearchEngine.replacingAllUTF8(
            in: Data("Alpha alpha".utf8),
            query: "alpha",
            replacement: "x",
            options: SearchOptions()
        )
        try expect(folded.count == 2, "Background case-insensitive replacement count failed")
        try expect(String(data: folded.data, encoding: .utf8) == "x x", "Background case-insensitive replacement failed")
    }

    @MainActor
    private static func testBinaryFileCanBeEditedAndSaved() throws {
        let temporaryDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".codex-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory.appendingPathComponent("binary-save-test.bin")
        let original = Data([0x00, 0x01, 0xFE, 0xFF, 0x10])
        try original.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let document = try EditorDocument(url: fileURL)
        try expect(!document.hasDecodedText, "Binary file was incorrectly marked as decoded text")
        try document.byteStore.replaceByte(at: 2, with: 0xAA)
        try document.save(to: fileURL)
        let savedData = try Data(contentsOf: fileURL)
        try expect(savedData == Data([0x00, 0x01, 0xAA, 0xFF, 0x10]), "Binary byte edit was not saved")
    }

    private static func testByteStoreChunkBoundarySearch() throws {
        let chunkSize = 4 * 1024 * 1024
        var data = Data(repeating: 0x41, count: chunkSize + 32)
        let query = Data([0xDE, 0xAD, 0xBE, 0xEF])
        data.replaceSubrange((chunkSize - 2)..<(chunkSize + 2), with: query)
        let store = ByteStore(data: data)
        let first = store.search(
            for: query,
            fromPosition: 0,
            direction: 1,
            byteLimit: chunkSize,
            maximumCount: 512
        )
        try expect(first.offsets == [chunkSize - 2], "Byte search missed a chunk-boundary match")
        let remainder = store.search(
            for: query,
            fromPosition: first.nextPosition,
            direction: 1,
            byteLimit: chunkSize,
            maximumCount: 512
        )
        try expect(remainder.offsets.isEmpty && remainder.isFinished, "Byte search duplicated a boundary match")
        let backward = store.search(
            for: query,
            fromPosition: store.count,
            direction: -1,
            byteLimit: chunkSize,
            maximumCount: 1
        )
        try expect(backward.offsets == [chunkSize - 2], "Backward byte search failed")
    }

    private static func testByteStoreRevision() throws {
        let store = ByteStore(data: Data([0x41, 0x42]))
        let initialRevision = store.revision
        try store.replaceByte(at: 0, with: 0x41)
        try expect(store.revision == initialRevision, "No-op byte edit changed the revision")
        try store.replaceByte(at: 0, with: 0x5A)
        try expect(store.revision == initialRevision + 1, "Byte edit did not change the revision")
        try expect(store.materializedData() == Data([0x5A, 0x42]), "Byte materialization lost an edit")
    }

    private static func scanSmartHighlights(_ source: Data, query: Data, chunkSize: Int) throws -> [NSRange] {
        var ranges: [NSRange] = []
        var nextPosition = 0
        var chunkStart = 0
        while chunkStart < source.count {
            let boundary = min(source.count, chunkStart + chunkSize)
            let readEnd = min(source.count, boundary + query.count - 1)
            let data = source.subdata(in: chunkStart..<readEnd)
            var batch: SmartHighlightBatch
            repeat {
                batch = try SmartHighlightMatcher.scan(
                    data: data,
                    baseOffset: chunkStart,
                    searchRange: NSRange(location: chunkStart, length: boundary - chunkStart),
                    query: query,
                    fromPosition: nextPosition,
                    maximumCount: 2
                )
                ranges.append(contentsOf: batch.ranges)
                nextPosition = batch.nextPosition
            } while !batch.isFinished
            chunkStart = boundary
        }
        return ranges
    }

    private static func testSmartHighlightChunkBoundaries() throws {
        let chinese = Data("x中文y中文z".utf8)
        let query = Data("中文".utf8)
        for chunkSize in 1...9 {
            let ranges = try scanSmartHighlights(chinese, query: query, chunkSize: chunkSize)
            try expect(ranges == [NSRange(location: 1, length: 6), NSRange(location: 8, length: 6)],
                       "Smart highlighting missed a Chinese UTF-8 chunk-boundary match")
        }
        for chunkSize in 1...6 {
            let ranges = try scanSmartHighlights(Data("aaaaaaaaaa".utf8), query: Data("aaa".utf8), chunkSize: chunkSize)
            try expect(ranges == [NSRange(location: 0, length: 3), NSRange(location: 3, length: 3), NSRange(location: 6, length: 3)],
                       "Smart highlighting duplicated an overlapping cross-chunk match")
        }
        let short = try scanSmartHighlights(Data("aaaa".utf8), query: Data("aaa".utf8), chunkSize: 2)
        try expect(short == [NSRange(location: 0, length: 3)], "Smart highlighting duplicated the aaa/aaaa boundary match")
    }

    private static func testSmartHighlightBatchPagination() throws {
        let data = Data(repeating: 0x61, count: 1025)
        let range = NSRange(location: 100, length: data.count)
        let first = try SmartHighlightMatcher.scan(data: data, baseOffset: 100, searchRange: range,
                                                  query: Data([0x61]), fromPosition: 100)
        try expect(first.ranges.count == 512 && first.nextPosition == 612 && !first.isFinished,
                   "Smart highlighting did not stop at the first 512-match batch")
        let second = try SmartHighlightMatcher.scan(data: data, baseOffset: 100, searchRange: range,
                                                   query: Data([0x61]), fromPosition: first.nextPosition)
        try expect(second.ranges.count == 512 && second.nextPosition == 1124 && !second.isFinished,
                   "Smart highlighting did not continue the second batch")
        let third = try SmartHighlightMatcher.scan(data: data, baseOffset: 100, searchRange: range,
                                                  query: Data([0x61]), fromPosition: second.nextPosition)
        try expect(third.ranges == [NSRange(location: 1124, length: 1)] && third.nextPosition == 1125 && third.isFinished,
                   "Smart highlighting did not finish the last batch")
    }

    private static func testSmartHighlightBinarySliceAndEOF() throws {
        let original = Data([0xFF, 0xEE, 0x00, 0xAB, 0x00, 0xAB, 0x00])
        let slice = original[2...]
        try expect(slice.startIndex != 0, "Smart highlighting slice test must use a nonzero Data start index")
        let query = Data([0x00, 0xAB])
        let batch = try SmartHighlightMatcher.scan(data: slice, baseOffset: 200,
                                                  searchRange: NSRange(location: 200, length: slice.count),
                                                  query: query, fromPosition: 200)
        try expect(batch.ranges == [NSRange(location: 200, length: 2), NSRange(location: 202, length: 2)]
                   && batch.nextPosition == 205 && batch.isFinished,
                   "Smart highlighting mishandled binary NUL bytes, sliced Data, or the EOF suffix")
        let beyond = try SmartHighlightMatcher.scan(data: Data([0x41, 0x00, 0xAB]), baseOffset: 10,
                                                   searchRange: NSRange(location: 10, length: 1),
                                                   query: query, fromPosition: 10)
        try expect(beyond.ranges.isEmpty && beyond.nextPosition == 11 && beyond.isFinished,
                   "Smart highlighting accepted a match starting outside the owned range")
        let crossed = try SmartHighlightMatcher.scan(data: Data("aaa".utf8), baseOffset: 0,
                                                    searchRange: NSRange(location: 0, length: 1),
                                                    query: Data("aaa".utf8), fromPosition: 0)
        try expect(crossed.nextPosition == 3 && crossed.isFinished,
                   "Smart highlighting truncated a cross-boundary match end")
        let empty = try SmartHighlightMatcher.scan(data: Data(), baseOffset: 5,
                                                  searchRange: NSRange(location: 5, length: 0),
                                                  query: query, fromPosition: 8)
        try expect(empty.ranges.isEmpty && empty.nextPosition == 8 && empty.isFinished,
                   "Smart highlighting moved the next allowed match position backward at EOF")
    }

    private static func testSmartHighlightCancellation() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SmartHighlightMatcher.scan(data: Data("abc".utf8), baseOffset: 0,
                                                  searchRange: NSRange(location: 0, length: 3),
                                                  query: Data("a".utf8), fromPosition: 0)
        }
        do {
            _ = try await task.value
            throw TestFailure.failed("Cancelled smart highlighting continued scanning")
        } catch is CancellationError {
        }
    }

    private static func testIncrementalUTF8ChineseBoundary() throws {
        let source = Data("前缀中文后缀".utf8)
        let split = source.firstRange(of: Data("中".utf8))!.lowerBound + 1
        let first = try IncrementalTextDecoder.decode(
            Data(source[..<split]),
            using: .utf8,
            isFinal: false
        )
        var finalSource = first.remainder
        finalSource.append(source[split...])
        let second = try IncrementalTextDecoder.decode(
            finalSource,
            using: .utf8,
            isFinal: true
        )
        var decoded = first.utf8Data
        decoded.append(second.utf8Data)
        try expect(String(data: decoded, encoding: .utf8) == "前缀中文后缀", "Incremental UTF-8 decoding broke a Chinese character")
    }

    private static func testBinaryDetectionBeyondPrefix() throws {
        var data = Data(repeating: 0x41, count: 32 * 1024)
        data[data.count - 1] = 0
        try expect(FileCodec.decodeAutomatically(data) == nil, "Binary suffix was not detected")
    }

    @MainActor
    private static func testLargeFilePolicy() throws {
        let fileSize: UInt64 = 40 * 1024 * 1024
        try expect(fileSize > FileCodec.largeFileThreshold, "40 MB must use large-file mode")

        let temporaryDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".codex-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory.appendingPathComponent("large-file-test.bin")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let handle = try FileHandle(forWritingTo: fileURL)
        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<40 {
            try handle.write(contentsOf: chunk)
        }
        let expectedOffset: UInt64 = 20 * 1024 * 1024
        try handle.seek(toOffset: expectedOffset - 1)
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.seek(toOffset: expectedOffset)
        try handle.write(contentsOf: Data("全文目标".utf8))
        let boundaryOffset: UInt64 = 4 * 1024 * 1024 - 2
        try handle.seek(toOffset: boundaryOffset)
        try handle.write(contentsOf: Data("AbCdE".utf8))
        try handle.close()

        let document = try EditorDocument(url: fileURL)
        try expect(document.isLargeFile, "40 MB document did not enter large-file mode")
        try expect(document.fullFileSize == fileSize, "Large-file size detection failed")
        try expect(document.rawData.count == Int(fileSize), "Large file was not loaded completely")
        try expect(!document.isReadOnly, "Writable large file was incorrectly marked read-only")
        document.displayMode = .hexadecimal
        try expect(document.currentData.count == Int(fileSize), "Large-file mode data was truncated")

        let search = try LargeFileSearch.findAll(
            in: fileURL,
            query: "全文目标",
            encoding: .utf8,
            options: SearchOptions()
        )
        try expect(search.totalCount == 1, "Large-file full search count failed")
        try expect(search.byteOffsets == [expectedOffset], "Large-file full search offset failed")
        try expect(search.matches.count == 1, "Large-file match details failed")
        try expect(search.matches[0].lineNumber == 2, "Large-file line number failed")
        try expect(search.matches[0].lineText.contains("全文目标"), "Large-file line preview failed")
        let jumpedLine = try FileCodec.lineNumber(
            at: expectedOffset,
            in: fileURL,
            using: .utf8
        )
        try expect(jumpedLine == 2, "Large-file scrollbar line number failed")

        let boundarySearch = try LargeFileSearch.findAll(
            in: fileURL,
            query: "abcde",
            encoding: .utf8,
            options: SearchOptions()
        )
        try expect(boundarySearch.totalCount == 1, "Chunk-boundary search count failed")
        try expect(boundarySearch.byteOffsets == [boundaryOffset], "Chunk-boundary search offset failed")
    }
}
