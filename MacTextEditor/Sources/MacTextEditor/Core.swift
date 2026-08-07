import Foundation
import CoreFoundation

enum EditorDisplayMode: Int, CaseIterable, Sendable {
    case text
    case hexadecimal
    case binary

    var title: String {
        switch self {
        case .text: return "Text"
        case .hexadecimal: return "Hex"
        case .binary: return "Binary"
        }
    }
}

enum EditorTextEncoding: Int, CaseIterable, Sendable {
    case utf8
    case utf8BOM
    case utf16LittleEndian
    case utf16BigEndian
    case gb18030
    case big5

    var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .gb18030: return "GB18030 / GBK"
        case .big5: return "Big5"
        }
    }

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .gb18030:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        case .big5:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0A03)))
        }
    }
}

enum EditorLineEnding: String, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    case none = "-"
}

struct DecodedText: Sendable {
    let text: String
    let encoding: EditorTextEncoding
    let lineEnding: EditorLineEnding
}

enum FileCodecError: LocalizedError {
    case cannotDecode
    case cannotEncode(String)

    var errorDescription: String? {
        switch self {
        case .cannotDecode:
            return "无法识别文本编码，请切换到Hex模式或手动选择编码。"
        case .cannotEncode(let encoding):
            return "当前内容无法使用\(encoding)无损保存，请改用UTF-8。"
        }
    }
}

enum FileCodec {
    static let largeFileThreshold: UInt64 = 32 * 1024 * 1024
    static let previewByteCount = 2 * 1024 * 1024

    static func decodeAutomatically(_ data: Data) -> DecodedText? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return decoded(text, encoding: .utf8BOM)
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return decoded(text, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return decoded(text, encoding: .utf16BigEndian)
        }
        if let text = String(data: data, encoding: .utf8), !looksBinary(data) {
            return decoded(text, encoding: .utf8)
        }
        if let utf16 = decodeLikelyUTF16(data) {
            return utf16
        }
        guard !looksBinary(data) else { return nil }
        for encoding in [EditorTextEncoding.gb18030, .big5] {
            if let text = String(data: data, encoding: encoding.foundationEncoding) {
                return decoded(text, encoding: encoding)
            }
        }
        return nil
    }

    static func decodePreviewAutomatically(_ data: Data) -> DecodedText? {
        let hasUTF8BOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = hasUTF8BOM ? data.dropFirst(3) : data[...]
        if !looksBinary(data), let text = decodeUTF8Preview(payload) {
            return decoded(text, encoding: hasUTF8BOM ? .utf8BOM : .utf8)
        }
        return decodeAutomatically(data)
    }

    static func decode(_ data: Data, using encoding: EditorTextEncoding) throws -> DecodedText {
        let payload: Data
        switch encoding {
        case .utf8BOM where data.starts(with: [0xEF, 0xBB, 0xBF]):
            payload = data.dropFirst(3)
        case .utf16LittleEndian where data.starts(with: [0xFF, 0xFE]):
            payload = data.dropFirst(2)
        case .utf16BigEndian where data.starts(with: [0xFE, 0xFF]):
            payload = data.dropFirst(2)
        default:
            payload = data
        }
        guard let text = String(data: payload, encoding: encoding.foundationEncoding) else {
            throw FileCodecError.cannotDecode
        }
        return decoded(text, encoding: encoding)
    }

    static func encode(_ text: String, using encoding: EditorTextEncoding) throws -> Data {
        guard var data = text.data(using: encoding.foundationEncoding, allowLossyConversion: false) else {
            throw FileCodecError.cannotEncode(encoding.title)
        }
        switch encoding {
        case .utf8BOM:
            data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
        case .utf16LittleEndian:
            data.insert(contentsOf: [0xFF, 0xFE], at: 0)
        case .utf16BigEndian:
            data.insert(contentsOf: [0xFE, 0xFF], at: 0)
        default:
            break
        }
        return data
    }

    static func readPrefix(of url: URL, count: Int = previewByteCount) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    static func lineNumber(
        at byteOffset: UInt64,
        in url: URL,
        using encoding: EditorTextEncoding
    ) throws -> Int {
        let newline = "\n".data(using: encoding.foundationEncoding) ?? Data([0x0A])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = byteOffset
        var newlineCount = 0
        while remaining > 0 {
            let count = Int(min(remaining, 1024 * 1024))
            let chunk = try handle.read(upToCount: count) ?? Data()
            guard !chunk.isEmpty else { break }
            var searchStart = 0
            while searchStart < chunk.count,
                  let range = chunk.range(
                      of: newline,
                      options: [],
                      in: searchStart..<chunk.count
                  ) {
                newlineCount += 1
                searchStart = range.upperBound
            }
            remaining -= UInt64(chunk.count)
        }
        return newlineCount + 1
    }

    static func decodeWindow(
        _ data: Data,
        using encoding: EditorTextEncoding
    ) throws -> (decoded: DecodedText, data: Data, leadingByteCount: Int) {
        let alignment = encoding == .utf16LittleEndian || encoding == .utf16BigEndian ? 2 : 1
        let trimLimit = min(4, data.count)
        for leading in 0...trimLimit where leading.isMultiple(of: alignment) {
            for trailing in 0...trimLimit where trailing.isMultiple(of: alignment) {
                guard leading + trailing < data.count else { continue }
                let end = data.count - trailing
                let windowData = data.subdata(in: leading..<end)
                if let decoded = try? decode(windowData, using: encoding) {
                    return (decoded, windowData, leading)
                }
            }
        }
        throw FileCodecError.cannotDecode
    }

    private static func decoded(_ text: String, encoding: EditorTextEncoding) -> DecodedText {
        DecodedText(text: text, encoding: encoding, lineEnding: detectLineEnding(text))
    }

    private static func decodeUTF8Preview(_ data: Data.SubSequence) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let bytes = [UInt8](data.suffix(3))
        for length in 1...bytes.count {
            let suffix = Array(bytes.suffix(length))
            let expectedLength: Int
            switch suffix[0] {
            case 0xC2...0xDF: expectedLength = 2
            case 0xE0...0xEF: expectedLength = 3
            case 0xF0...0xF4: expectedLength = 4
            default: continue
            }
            guard expectedLength > length,
                  suffix.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { continue }
            return String(data: data.dropLast(length), encoding: .utf8)
        }
        return nil
    }

    private static func detectLineEnding(_ text: String) -> EditorLineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\n") { return .lf }
        if text.contains("\r") { return .cr }
        return .none
    }

    private static func decodeLikelyUTF16(_ data: Data) -> DecodedText? {
        guard data.count >= 4 else { return nil }
        let sample = data.prefix(min(data.count, 4096))
        var evenZeros = 0
        var oddZeros = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let limit = max(2, sample.count / 16)
        if oddZeros >= limit,
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return decoded(text, encoding: .utf16LittleEndian)
        }
        if evenZeros >= limit,
           let text = String(data: data, encoding: .utf16BigEndian) {
            return decoded(text, encoding: .utf16BigEndian)
        }
        return nil
    }

    private static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sampleSize = min(data.count, 8192)
        let offsets = [
            0,
            max(0, (data.count - sampleSize) / 2),
            max(0, data.count - sampleSize)
        ]
        var controls = 0
        var sampledBytes = 0
        for offset in Set(offsets) {
            let sample = data[offset..<(offset + sampleSize)]
            sampledBytes += sample.count
            for byte in sample {
                if byte == 0 { return true }
                if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
                    controls += 1
                }
            }
        }
        return controls * 20 > sampledBytes
    }
}

struct SearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regularExpression = false
}

enum SearchEngine {
    static func matches(
        in text: String,
        query: String,
        options: SearchOptions
    ) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        if options.regularExpression || options.wholeWord {
            let source = options.regularExpression
                ? query
                : NSRegularExpression.escapedPattern(for: query)
            let pattern = options.wholeWord
                ? "(?<![\\p{L}\\p{N}_])(?:\(source))(?![\\p{L}\\p{N}_])"
                : source
            let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
            let regex = try NSRegularExpression(pattern: pattern, options: regexOptions)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        }

        let source = text as NSString
        let compareOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        var result: [NSRange] = []
        var location = 0
        while location < source.length {
            let range = source.range(
                of: query,
                options: compareOptions,
                range: NSRange(location: location, length: source.length - location)
            )
            if range.location == NSNotFound { break }
            result.append(range)
            location = range.location + max(range.length, 1)
        }
        return result
    }

    static func replacingAll(
        in text: String,
        query: String,
        replacement: String,
        options: SearchOptions
    ) throws -> (text: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        if options.regularExpression {
            let pattern = options.wholeWord
                ? "(?<![\\p{L}\\p{N}_])(?:\(query))(?![\\p{L}\\p{N}_])"
                : query
            let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
            let regex = try NSRegularExpression(pattern: pattern, options: regexOptions)
            let range = NSRange(text.startIndex..., in: text)
            let count = regex.numberOfMatches(in: text, range: range)
            let replaced = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: replacement
            )
            return (replaced, count)
        }
        let ranges = try matches(in: text, query: query, options: options)
        guard !ranges.isEmpty else { return (text, 0) }
        let output = NSMutableString(string: text)
        for range in ranges.reversed() {
            output.replaceCharacters(in: range, with: replacement)
        }
        return (output as String, ranges.count)
    }
}

struct LargeFileSearchResult {
    let totalCount: Int
    let byteOffsets: [UInt64]
    let matches: [LargeFileSearchMatch]
}

struct LargeFileSearchMatch {
    let byteOffset: UInt64
    let lineNumber: Int
    let lineText: String
}

enum LargeFileSearchError: LocalizedError {
    case unsupportedOptions
    case unsupportedCaseFolding
    case cannotEncodeQuery

    var errorDescription: String? {
        switch self {
        case .unsupportedOptions:
            return "大文件全文查找暂不支持正则表达式或全词匹配。"
        case .unsupportedCaseFolding:
            return "大文件全文查找暂不支持非ASCII字符的忽略大小写匹配。"
        case .cannotEncodeQuery:
            return "查找内容无法使用当前文件编码表示。"
        }
    }
}

enum LargeFileSearch {
    static func findAll(
        in url: URL,
        query: String,
        encoding: EditorTextEncoding,
        options: SearchOptions
    ) throws -> LargeFileSearchResult {
        guard !query.isEmpty else {
            return LargeFileSearchResult(totalCount: 0, byteOffsets: [], matches: [])
        }
        guard !options.regularExpression, !options.wholeWord else {
            throw LargeFileSearchError.unsupportedOptions
        }
        if !options.caseSensitive,
           query.unicodeScalars.contains(where: {
               $0.value > 0x7F && String($0).lowercased() != String($0).uppercased()
           }) {
            throw LargeFileSearchError.unsupportedCaseFolding
        }
        guard var needle = query.data(
            using: encoding.foundationEncoding,
            allowLossyConversion: false
        ), !needle.isEmpty else {
            throw LargeFileSearchError.cannotEncodeQuery
        }

        let containsASCIILetter = query.unicodeScalars.contains {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }
        let foldASCII = !options.caseSensitive && containsASCIILetter
        if foldASCII {
            needle = foldingASCII(in: needle)
        }
        let alignment: UInt64 = encoding == .utf16LittleEndian || encoding == .utf16BigEndian ? 2 : 1
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize = 4 * 1024 * 1024
        let overlapSize = max(0, needle.count - 1)
        var carry = Data()
        var bytesRead: UInt64 = 0
        var nextAllowedOffset: UInt64 = 0
        var offsets: [UInt64] = []

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var searchData = carry
            searchData.append(chunk)
            let searchBase = bytesRead - UInt64(carry.count)
            let haystack = foldASCII ? foldingASCII(in: searchData) : searchData
            var searchStart = haystack.startIndex

            while searchStart <= haystack.endIndex - needle.count,
                  let range = haystack.range(
                    of: needle,
                    in: searchStart..<haystack.endIndex
                  ) {
                let absoluteOffset = searchBase + UInt64(range.lowerBound)
                if absoluteOffset >= nextAllowedOffset,
                   absoluteOffset.isMultiple(of: alignment) {
                    offsets.append(absoluteOffset)
                    nextAllowedOffset = absoluteOffset + UInt64(needle.count)
                }
                searchStart = max(range.upperBound, range.lowerBound + 1)
            }

            bytesRead += UInt64(chunk.count)
            carry = Data(searchData.suffix(min(overlapSize, searchData.count)))
        }

        let matches = try loadMatchDetails(
            from: url,
            offsets: offsets,
            encoding: encoding
        )
        return LargeFileSearchResult(
            totalCount: offsets.count,
            byteOffsets: offsets,
            matches: matches
        )
    }

    private static func foldingASCII(in data: Data) -> Data {
        Data(data.map { byte in
            (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
        })
    }

    private static func loadMatchDetails(
        from url: URL,
        offsets: [UInt64],
        encoding: EditorTextEncoding
    ) throws -> [LargeFileSearchMatch] {
        guard !offsets.isEmpty else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let newline = "\n".data(using: encoding.foundationEncoding) ?? Data([0x0A])
        var matches: [LargeFileSearchMatch] = []
        matches.reserveCapacity(offsets.count)
        var targetIndex = 0
        var buffer = Data()
        var bufferOffset: UInt64 = 0
        var lineNumber = 1

        func appendMatches(in lineData: Data, lineOffset: UInt64) {
            let lineEnd = lineOffset + UInt64(lineData.count)
            while targetIndex < offsets.count, offsets[targetIndex] < lineEnd {
                let offset = offsets[targetIndex]
                let relativeOffset = Int(offset - lineOffset)
                matches.append(LargeFileSearchMatch(
                    byteOffset: offset,
                    lineNumber: lineNumber,
                    lineText: linePreview(
                        lineData,
                        matchOffset: relativeOffset,
                        encoding: encoding
                    )
                ))
                targetIndex += 1
            }
        }

        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while lineStart < buffer.endIndex,
                  let range = buffer.range(
                      of: newline,
                      in: lineStart..<buffer.endIndex
                  ) {
                let lineData = Data(buffer[lineStart..<range.lowerBound])
                appendMatches(
                    in: lineData,
                    lineOffset: bufferOffset + UInt64(lineStart - buffer.startIndex)
                )
                lineNumber += 1
                lineStart = range.upperBound
            }
            if lineStart > buffer.startIndex {
                bufferOffset += UInt64(lineStart - buffer.startIndex)
                buffer = Data(buffer[lineStart..<buffer.endIndex])
            }
        }
        appendMatches(in: buffer, lineOffset: bufferOffset)
        return matches
    }

    private static func linePreview(
        _ data: Data,
        matchOffset: Int,
        encoding: EditorTextEncoding
    ) -> String {
        let unitByteCount = encoding == .utf16LittleEndian || encoding == .utf16BigEndian ? 2 : 1
        var start = max(0, matchOffset - 120)
        start -= start % unitByteCount
        let end = min(data.count, matchOffset + 512)
        let decoded = decodeLinePreview(
            Data(data[start..<end]),
            encoding: encoding
        )
        let preview = String(decoded.prefix(300))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 {
            return "…\(preview)"
        }
        return preview
    }

    private static func decodeLinePreview(
        _ data: Data,
        encoding: EditorTextEncoding
    ) -> String {
        if let text = String(data: data, encoding: encoding.foundationEncoding) {
            return text
        }
        let trimLimit = min(4, data.count)
        for leading in 0...trimLimit {
            for trailing in 0...trimLimit where leading + trailing < data.count {
                let end = data.count - trailing
                if let text = String(
                    data: data.subdata(in: leading..<end),
                    encoding: encoding.foundationEncoding
                ) {
                    return text
                }
            }
        }
        return ""
    }
}

extension String {
    func leftPadding(toLength: Int, with character: Character) -> String {
        String(repeating: String(character), count: max(0, toLength - count)) + self
    }
}
