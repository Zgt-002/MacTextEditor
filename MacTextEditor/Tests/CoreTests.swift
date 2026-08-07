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
    static func main() throws {
        try testChineseUTF8RoundTrip()
        try testIncompleteUTF8Preview()
        try testGB18030RoundTrip()
        try testSearchAndReplaceChineseText()
        try testRegularExpressionCaptureReplacement()
        try testBinaryFileCanBeEditedAndSaved()
        try testByteStoreChunkBoundarySearch()
        try testByteStoreRevision()
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
