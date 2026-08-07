import Foundation

struct IncrementalDecodeResult: Sendable {
    let utf8Data: Data
    let remainder: Data
    let containsCRLF: Bool
    let containsLF: Bool
    let containsCR: Bool
    let firstByte: UInt8?
    let lastByte: UInt8?
}

enum IncrementalTextDecoder {
    static func detectEncoding(in data: Data, previewByteCount: Int) -> EditorTextEncoding? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        let preview = Data(data.prefix(previewByteCount))
        return FileCodec.decodePreviewAutomatically(preview)?.encoding
    }

    static func payloadStart(for encoding: EditorTextEncoding, in data: Data) -> Int {
        switch encoding {
        case .utf8BOM where data.starts(with: [0xEF, 0xBB, 0xBF]): return 3
        case .utf16LittleEndian where data.starts(with: [0xFF, 0xFE]): return 2
        case .utf16BigEndian where data.starts(with: [0xFE, 0xFF]): return 2
        default: return 0
        }
    }

    static func decode(
        _ data: Data,
        using encoding: EditorTextEncoding,
        isFinal: Bool
    ) throws -> IncrementalDecodeResult {
        if isFinal {
            guard let text = String(data: data, encoding: encoding.foundationEncoding),
                  let utf8 = text.data(using: .utf8) else {
                throw FileCodecError.cannotDecode
            }
            return result(utf8Data: utf8, remainder: Data())
        }

        let maximumRemainder: Int
        switch encoding {
        case .utf8, .utf8BOM: maximumRemainder = 3
        case .utf16LittleEndian, .utf16BigEndian: maximumRemainder = 3
        case .gb18030: maximumRemainder = 3
        case .big5: maximumRemainder = 1
        }
        for remainderCount in 0...min(maximumRemainder, data.count) {
            let split = data.count - remainderCount
            let prefix = Data(data.prefix(split))
            guard let text = String(data: prefix, encoding: encoding.foundationEncoding),
                  let utf8 = text.data(using: .utf8) else { continue }
            return result(utf8Data: utf8, remainder: Data(data.suffix(remainderCount)))
        }
        throw FileCodecError.cannotDecode
    }

    private static func result(utf8Data: Data, remainder: Data) -> IncrementalDecodeResult {
        var containsCRLF = false
        var containsLF = false
        var containsCR = false
        var previous: UInt8?
        for byte in utf8Data {
            if byte == 0x0A {
                containsLF = true
                if previous == 0x0D { containsCRLF = true }
            } else if byte == 0x0D {
                containsCR = true
            }
            previous = byte
        }
        return IncrementalDecodeResult(
            utf8Data: utf8Data,
            remainder: remainder,
            containsCRLF: containsCRLF,
            containsLF: containsLF,
            containsCR: containsCR,
            firstByte: utf8Data.first,
            lastByte: utf8Data.last
        )
    }
}
