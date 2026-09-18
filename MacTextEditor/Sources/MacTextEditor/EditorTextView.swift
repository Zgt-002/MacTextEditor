import AppKit
@preconcurrency import ScintillaCocoaBridge

struct EditorSearchMatch: Equatable {
    let byteRange: NSRange
    let lineNumber: Int
    let lineText: String
}

struct EditorSearchBatch {
    let matches: [EditorSearchMatch]
    let nextPosition: Int
    let isFinished: Bool
}

@MainActor
final class EditorTextView: NSView, @preconcurrency MTEEditorViewDelegate {
    private let editorView = MTEEditorView()
    private var selectionChangePending = false
    private var viewportChangePending = false
    private(set) var isIncrementallyLoading = false
    private(set) var contentRevision = 0
    var onTextChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onViewportChanged: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    var onEscape: (() -> Bool)?

    var string: String { editorView.stringValue }
    var selectedByteRange: NSRange { editorView.selectedByteRange }
    var selectedString: String { editorView.selectedString }
    var visibleByteRange: NSRange { editorView.visibleByteRange }
    var isModified: Bool { editorView.isModified }
    var canUndo: Bool { editorView.canUndo }
    var documentLength: Int { editorView.documentLength }

    func snapshotUTF8Data() -> Data {
        editorView.utf8Data
    }

    func copyUTF8Bytes(in range: NSRange) -> Data {
        editorView.copyUTF8Bytes(in: range)
    }

    func smartHighlightByteRanges(extraScreens: Int) -> [NSRange] {
        editorView.smartHighlightByteRanges(extraScreens: extraScreens).map(\.rangeValue)
    }

    func setEditable(_ editable: Bool) {
        editorView.isEditable = editable
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.delegate = self
        editorView.fileDropHandler = { [weak self] urls in
            self?.onFilesDropped?(urls)
        }
        editorView.escapeHandler = { [weak self] in self?.onEscape?() ?? false }
        addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorView.topAnchor.constraint(equalTo: topAnchor),
            editorView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(text: String, editable: Bool, largeDocument: Bool) {
        editorView.load(text, editable: editable, largeDocument: largeDocument)
        contentRevision += 1
    }

    func beginIncrementalLoad(
        expectedByteLength: Int,
        editable: Bool,
        largeDocument: Bool
    ) {
        isIncrementallyLoading = true
        editorView.beginIncrementalLoad(
            withUTF8Data: Data(),
            expectedLength: expectedByteLength,
            editable: editable,
            largeDocument: largeDocument
        )
    }

    func beginIncrementalReload(editable: Bool) {
        isIncrementallyLoading = true
        editorView.beginIncrementalReload(editable: editable)
    }

    func beginIncrementalReplacement(editable: Bool) {
        isIncrementallyLoading = true
        editorView.beginIncrementalReplacement(editable: editable)
    }

    func deleteTrailingBytes(maximumLength: Int) -> Int {
        editorView.deleteTrailingBytes(maximumLength: maximumLength)
    }

    func appendUTF8Data(_ data: Data) {
        editorView.appendUTF8Data(data)
    }

    func finishIncrementalLoad() {
        editorView.finishIncrementalLoad()
        isIncrementallyLoading = false
        contentRevision += 1
    }

    func finishIncrementalReplacement() {
        editorView.finishIncrementalReplacement()
        isIncrementallyLoading = false
        contentRevision += 1
    }

    func setSavePoint() {
        editorView.setSavePoint()
    }

    func undo() {
        editorView.undo()
    }

    func searchBatch(
        query: String,
        options: SearchOptions,
        fromPosition: Int,
        direction: Int,
        byteLimit: Int,
        maximumCount: Int
    ) throws -> EditorSearchBatch {
        var searchError: NSError?
        let batch = editorView.searchOccurrences(
            of: query,
            options: scintillaOptions(options),
            fromPosition: fromPosition,
            direction: direction,
            byteLimit: byteLimit,
            maximumCount: maximumCount,
            error: &searchError
        )
        if let searchError { throw searchError }
        return EditorSearchBatch(
            matches: batch.matches.map {
                EditorSearchMatch(
                    byteRange: $0.byteRange,
                    lineNumber: $0.lineNumber,
                    lineText: $0.lineText
                )
            },
            nextPosition: batch.nextPosition,
            isFinished: batch.isFinished
        )
    }

    func clearSearchHighlights() {
        editorView.clearSearchHighlights()
    }

    func setVisibleSmartHighlights(_ ranges: [NSRange]) {
        editorView.setVisibleSmartByteRanges(ranges.map(NSValue.init(range:)))
    }

    func addVisibleSmartHighlights(_ ranges: [NSRange]) {
        editorView.addVisibleSmartByteRanges(ranges.map(NSValue.init(range:)))
    }

    func addFullSmartHighlights(_ ranges: [NSRange]) {
        editorView.addFullSmartByteRanges(ranges.map(NSValue.init(range:)))
    }

    func clearFullSmartHighlights() {
        editorView.clearFullSmartHighlights()
    }

    func clearSmartHighlights() {
        editorView.clearSmartHighlights()
    }

    func addMarkedHighlights(_ ranges: [NSRange]) {
        editorView.addMarkedByteRanges(ranges.map(NSValue.init(range:)))
    }

    func clearMarkedHighlights() {
        editorView.clearMarkedHighlights()
    }

    func replaceSelection(with replacement: String) {
        editorView.replaceSelectedText(with: replacement)
    }

    func replaceAll(
        query: String,
        replacement: String,
        options: SearchOptions
    ) throws -> Int {
        var replaceError: NSError?
        let count = editorView.replaceAllOccurrences(
            of: query,
            with: replacement,
            options: scintillaOptions(options),
            error: &replaceError
        )
        if let replaceError { throw replaceError }
        return count
    }

    func reveal(_ match: EditorSearchMatch) {
        editorView.selectAndRevealByteRange(match.byteRange)
    }

    func lineAndColumn() -> (line: Int, column: Int) {
        (editorView.currentLine, editorView.currentColumn)
    }

    func focus() {
        editorView.focusEditor()
    }

    func editorViewContentDidChange(_ editorView: MTEEditorView) {
        guard !isIncrementallyLoading else { return }
        contentRevision += 1
        onTextChanged?()
    }

    func editorViewSelectionDidChange(_ editorView: MTEEditorView) {
        guard !selectionChangePending else { return }
        selectionChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionChangePending = false
            self.onSelectionChanged?()
        }
    }

    func editorViewViewportDidChange(_ editorView: MTEEditorView) {
        guard !viewportChangePending else { return }
        viewportChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportChangePending = false
            self.onViewportChanged?()
        }
    }

    private func scintillaOptions(_ options: SearchOptions) -> MTEFindOptions {
        var result: MTEFindOptions = []
        if options.caseSensitive { result.insert(.matchCase) }
        if options.wholeWord { result.insert(.wholeWord) }
        if options.regularExpression { result.insert(.regularExpression) }
        return result
    }
}
