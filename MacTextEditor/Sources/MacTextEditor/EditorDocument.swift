import AppKit

enum DocumentLoadState: Sendable {
    case loadingPreview
    case streaming
    case ready
    case failed(String)
    case cancelled
}

enum EditorDocumentError: LocalizedError {
    case readOnly
    case textDecodeUnavailable

    var errorDescription: String? {
        switch self {
        case .readOnly:
            return "当前文件处于只读模式，不能保存。"
        case .textDecodeUnavailable:
            return "当前字节内容无法使用所选编码转换为文本。"
        }
    }
}

@MainActor
final class EditorDocument {
    let id = UUID()
    var fileURL: URL?
    var displayName: String
    var text: String
    let byteStore: ByteStore
    var encoding: EditorTextEncoding
    var lineEnding: EditorLineEnding
    var displayMode: EditorDisplayMode
    var isDirty = false
    var isLargeFile = false
    var isReadOnly = false
    var hasDecodedText = true
    var fullFileSize: UInt64 = 0
    var largeViewOffset: UInt64 = 0
    var largeViewStartLine = 1
    var loadState: DocumentLoadState = .ready
    var loadedByteCount: UInt64 = 0
    var loadSessionID: UUID?

    var isTextLoading: Bool {
        switch loadState {
        case .loadingPreview, .streaming: return true
        default: return false
        }
    }

    var rawData: Data {
        get { byteStore.materializedData() }
        set { byteStore.reset(with: newValue) }
    }

    init(untitledNumber: Int) {
        displayName = "新建文件 \(untitledNumber)"
        text = ""
        byteStore = ByteStore(data: Data())
        encoding = .utf8
        lineEnding = .none
        displayMode = .text
    }

    init(url: URL) throws {
        fileURL = url
        displayName = url.lastPathComponent
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isWritableKey])
        fullFileSize = UInt64(values.fileSize ?? 0)
        isLargeFile = fullFileSize > FileCodec.largeFileThreshold
        isReadOnly = !(values.isWritable ?? true)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        byteStore = ByteStore(data: data)

        let decoded = FileCodec.decodeAutomatically(data)
        if let decoded {
            text = decoded.text
            encoding = decoded.encoding
            lineEnding = decoded.lineEnding
            displayMode = .text
            hasDecodedText = true
        } else {
            text = ""
            encoding = .utf8
            lineEnding = .none
            displayMode = .hexadecimal
            hasDecodedText = false
        }
    }

    init(loading url: URL) throws {
        fileURL = url
        displayName = url.lastPathComponent
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isWritableKey])
        fullFileSize = UInt64(values.fileSize ?? 0)
        isLargeFile = fullFileSize > FileCodec.largeFileThreshold
        isReadOnly = !(values.isWritable ?? true)
        text = ""
        byteStore = ByteStore(data: Data())
        encoding = .utf8
        lineEnding = .none
        displayMode = .text
        hasDecodedText = false
        loadState = .loadingPreview
        loadSessionID = UUID()
    }

    var tabTitle: String {
        if isDirty { return "\(displayName) ●" }
        if isTextLoading { return "\(displayName) ◌" }
        return displayName
    }

    var currentData: Data {
        if displayMode == .text, hasDecodedText {
            return (try? FileCodec.encode(text, using: encoding)) ?? storedFileData
        }
        return storedFileData
    }

    func synchronizeBytesFromText() throws {
        guard hasDecodedText else { throw EditorDocumentError.textDecodeUnavailable }
        byteStore.reset(with: try FileCodec.encode(text, using: encoding))
        fullFileSize = UInt64(byteStore.count)
    }

    func synchronizeTextFromBytes() throws {
        let decoded = try FileCodec.decode(storedFileData, using: encoding)
        text = decoded.text
        lineEnding = decoded.lineEnding
        hasDecodedText = true
    }

    func reopen(using newEncoding: EditorTextEncoding) throws {
        let data = storedFileData
        let decoded = try FileCodec.decode(data, using: newEncoding)
        text = decoded.text
        encoding = decoded.encoding
        lineEnding = decoded.lineEnding
        displayMode = .text
        hasDecodedText = true
        isDirty = false
    }

    func discardFileBackedContentCache() {
        guard fileURL != nil, hasDecodedText, !isDirty else { return }
        text = ""
    }

    func loadLargeFileWindow(
        containing byteOffset: UInt64,
        lineNumber: Int,
        query: String,
        lookBehindBytes: Int = FileCodec.previewByteCount / 4
    ) throws -> NSRange {
        guard isLargeFile, let fileURL else { return NSRange(location: 0, length: 0) }
        let newline = "\n".data(using: encoding.foundationEncoding) ?? Data([0x0A])
        let alignment: UInt64 = newline.count == 2 ? 2 : 1
        let lookBehind = UInt64(max(0, lookBehindBytes))
        var windowOffset = byteOffset > lookBehind ? byteOffset - lookBehind : 0
        windowOffset -= windowOffset % alignment

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        if windowOffset > 0 {
            try handle.seek(toOffset: windowOffset)
            let prefix = try handle.read(upToCount: Int(min(lookBehind, byteOffset - windowOffset))) ?? Data()
            if let range = prefix.range(of: newline) {
                windowOffset += UInt64(range.upperBound)
            }
        }
        try handle.seek(toOffset: windowOffset)
        let windowData = try handle.read(upToCount: FileCodec.previewByteCount) ?? Data()
        let decodedWindow = try FileCodec.decodeWindow(windowData, using: encoding)
        windowOffset += UInt64(decodedWindow.leadingByteCount)
        text = decodedWindow.decoded.text
        lineEnding = decodedWindow.decoded.lineEnding
        largeViewOffset = windowOffset

        let relativeOffset = Int(byteOffset - windowOffset)
        let prefixData = Data(decodedWindow.data.prefix(relativeOffset))
        let prefixText: String
        if let decoded = try? FileCodec.decode(prefixData, using: encoding) {
            prefixText = decoded.text
        } else {
            prefixText = try FileCodec.decodeWindow(prefixData, using: encoding).decoded.text
        }
        let precedingLines = prefixText.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        largeViewStartLine = max(1, lineNumber - precedingLines)
        return NSRange(location: prefixText.utf16.count, length: query.utf16.count)
    }

    func save(to destination: URL? = nil) throws {
        guard !isReadOnly else { throw EditorDocumentError.readOnly }
        let target = destination ?? fileURL
        guard let target else { return }
        if displayMode == .text {
            try synchronizeBytesFromText()
        }
        try byteStore.write(to: target)
        fileURL = target
        displayName = target.lastPathComponent
        fullFileSize = UInt64(byteStore.count)
        isDirty = false
    }

    private var storedFileData: Data {
        byteStore.materializedData()
    }
}
