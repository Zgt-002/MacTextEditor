import AppKit
import UniformTypeIdentifiers

private enum ByteQueryError: LocalizedError {
    case invalidHex
    case invalidBinary

    var errorDescription: String? {
        switch self {
        case .invalidHex:
            return "Hex内容必须由成对的0-9、A-F字节组成，例如 DE AD BE EF。"
        case .invalidBinary:
            return "Binary内容必须由完整的8位字节组成，例如 11011110 10101101。"
        }
    }
}

private final class FileDropView: NSView {
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]
        return objects?.map { $0 as URL }.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        } ?? []
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate, NSSplitViewDelegate {
    private struct OpenedFile: @unchecked Sendable {
        let data: Data
        let encoding: EditorTextEncoding?
    }

    private struct SearchCache {
        let query: String
        let options: SearchOptions
        let mode: EditorDisplayMode
        let matches: [EditorSearchMatch]
    }

    private struct SearchResultSource {
        let documentID: UUID
        let fileURL: URL?
        let fileSize: UInt64
        let modificationDate: Date?
    }

    private struct SearchResultItem {
        let headerTitle: String?
        let documentID: UUID?
        let mode: EditorDisplayMode?
        let match: EditorSearchMatch?
        let source: SearchResultSource?

        init(
            headerTitle: String?,
            documentID: UUID?,
            mode: EditorDisplayMode?,
            match: EditorSearchMatch?,
            source: SearchResultSource? = nil
        ) {
            self.headerTitle = headerTitle
            self.documentID = documentID
            self.mode = mode
            self.match = match
            self.source = source
        }

        var title: String {
            if let match {
                if mode != .text {
                    return String(format: "偏移0x%016llX：%@", UInt64(match.byteRange.location), match.lineText)
                }
                return "行\(match.lineNumber)：\(match.lineText)"
            }
            return headerTitle ?? ""
        }
    }

    private struct PendingSearchResultJump {
        let documentID: UUID
        let source: SearchResultSource
        let mode: EditorDisplayMode
        let match: EditorSearchMatch
    }

    private enum ReplacementUndoAction {
        case text(documentID: UUID)
        case bytes(documentID: UUID, ranges: [NSRange], original: Data)

        var documentID: UUID {
            switch self {
            case .text(let documentID), .bytes(let documentID, _, _):
                return documentID
            }
        }
    }

    private var documents: [EditorDocument] = []
    private var editors: [UUID: EditorTextView] = [:]
    private var byteEditors: [UUID: ByteEditorView] = [:]
    private var documentLoadTasks: [UUID: Task<Void, Never>] = [:]
    private var textEditorRevisions: [UUID: Int] = [:]
    private var searchCaches: [UUID: SearchCache] = [:]
    private var searchResultItems: [SearchResultItem] = []
    private var resultQuery = ""
    private var resultOptions = SearchOptions()
    private var searchTask: Task<Void, Never>?
    private var findAllRequestID: UUID?
    private var pendingSearchResultJump: PendingSearchResultJump?
    private var replacementUndoActions: [ReplacementUndoAction] = []
    private var isFindingAll = false
    private var isReplacingAll = false
    private var isUndoingReplacement = false
    private var activeIndex = -1
    private var untitledCounter = 1

    private let searchChunkByteCount = 4 * 1024 * 1024
    private let searchBatchMatchCount = 512
    private let maximumFindPrefillByteCount = 4 * 1024

    private let tabStack = NSStackView()
    private let tabScroll = NSScrollView()
    private let contentContainer = NSView()
    private let editorResultsSplit = NSSplitView()
    private let modeControl = NSSegmentedControl(
        labels: EditorDisplayMode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let encodingPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "准备就绪")
    private let findPanel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 250),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "查找"
        panel.minSize = NSSize(width: 560, height: 250)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }()
    private let findTabView = NSTabView()
    private let findPanelBody = NSStackView()
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let replaceLabel = NSTextField(labelWithString: "替换为：")
    private let replaceRow = NSStackView()
    private let previousButton = NSButton(title: "上一个", target: nil, action: nil)
    private let nextButton = NSButton(title: "下一个", target: nil, action: nil)
    private let findAllButton = NSButton(title: "查找全部", target: nil, action: nil)
    private let replaceButton = NSButton(title: "替换", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "全部替换", target: nil, action: nil)
    private let undoReplaceButton = NSButton(title: "撤销替换", target: nil, action: nil)
    private let markAllButton = NSButton(title: "标记全部", target: nil, action: nil)
    private let clearMarksButton = NSButton(title: "清除标记", target: nil, action: nil)
    private let scopePopup = NSPopUpButton()
    private let caseCheckbox = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil)
    private let wholeWordCheckbox = NSButton(checkboxWithTitle: "全词", target: nil, action: nil)
    private let regexCheckbox = NSButton(checkboxWithTitle: "正则", target: nil, action: nil)
    private let findStatus = NSTextField(labelWithString: "")
    private let findSpinner = NSProgressIndicator()
    private let findProgress = NSProgressIndicator()
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()
    private let resultsContainer = NSView()
    private var resultsPaneHeight: CGFloat = 200

    init() {
        let contentView = FileDropView(frame: .zero)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.title = "MacTextEditor"
        window.minSize = NSSize(width: 820, height: 520)
        window.center()
        super.init(window: window)
        contentView.onFilesDropped = { [weak self] urls in
            self?.open(urls: urls)
        }
        window.delegate = self
        buildInterface()
        newDocument()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var activeDocument: EditorDocument? {
        documents.indices.contains(activeIndex) ? documents[activeIndex] : nil
    }

    private func buildInterface() {
        guard let window, let content = window.contentView else { return }

        let newButton = button("新建", #selector(newDocument))
        let openButton = button("打开…", #selector(openDocuments))
        let saveButton = button("保存", #selector(saveDocument))
        let saveAllButton = button("全部保存", #selector(saveAllDocuments))
        let findButton = button("查找替换", #selector(showFindPanel))

        modeControl.target = self
        modeControl.action = #selector(displayModeChanged)
        modeControl.selectedSegment = 0

        encodingPopup.addItems(withTitles: EditorTextEncoding.allCases.map(\.title))
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged)

        let toolbar = NSStackView(views: [
            newButton, openButton, saveButton, saveAllButton, findButton,
            flexibleSpace(), modeControl, encodingPopup
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.distribution = .fill
        tabStack.spacing = 4
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.horizontalScroller = ArrowCursorScroller(frame: .zero)
        tabScroll.autohidesScrollers = true
        tabScroll.documentView = tabStack
        tabScroll.heightAnchor.constraint(equalToConstant: 38).isActive = true
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor),
            tabStack.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.contentView.widthAnchor)
        ])

        configureFindPanel()
        configureResults()

        editorResultsSplit.isVertical = false
        editorResultsSplit.dividerStyle = .thin
        editorResultsSplit.delegate = self
        editorResultsSplit.addSubview(contentContainer)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [flexibleSpace(), statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.distribution = .fill
        statusRow.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 5, right: 10)
        statusRow.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let root = NSStackView(views: [
            toolbar,
            separator(),
            tabScroll,
            separator(),
            editorResultsSplit,
            separator(),
            statusRow
        ])
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func configureFindPanel() {
        findField.placeholderString = "查找"
        findField.delegate = self
        findField.cell?.usesSingleLineMode = true
        findField.cell?.isScrollable = true
        findField.cell?.lineBreakMode = .byClipping
        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceField.placeholderString = "替换为"
        replaceField.delegate = self
        replaceField.cell?.usesSingleLineMode = true
        replaceField.cell?.isScrollable = true
        replaceField.cell?.lineBreakMode = .byClipping
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scopePopup.addItems(withTitles: ["当前文件", "所有打开文件"])

        previousButton.target = self
        previousButton.action = #selector(findPrevious)
        nextButton.target = self
        nextButton.action = #selector(findNext)
        findAllButton.target = self
        findAllButton.action = #selector(findAll)
        replaceButton.target = self
        replaceButton.action = #selector(replaceCurrent)
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)
        undoReplaceButton.target = self
        undoReplaceButton.action = #selector(undoLastReplacement)
        undoReplaceButton.isEnabled = false
        markAllButton.target = self
        markAllButton.action = #selector(markAll)
        clearMarksButton.target = self
        clearMarksButton.action = #selector(clearMarks)
        let closeButton = button("关闭", #selector(closeFindPanel))
        closeButton.keyEquivalent = "\u{1b}"

        let findLabel = NSTextField(labelWithString: "查找内容：")
        findLabel.alignment = .right
        findLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let findRow = NSStackView(views: [findLabel, findField])
        findRow.orientation = .horizontal
        findRow.alignment = .centerY
        findRow.spacing = 8

        replaceLabel.alignment = .right
        replaceLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        replaceRow.setViews([replaceLabel, replaceField, undoReplaceButton], in: .leading)
        replaceRow.orientation = .horizontal
        replaceRow.alignment = .centerY
        replaceRow.spacing = 8

        let optionControls = NSStackView(views: [
            caseCheckbox, wholeWordCheckbox, regexCheckbox, flexibleSpace()
        ])
        optionControls.orientation = .horizontal
        optionControls.alignment = .centerY
        optionControls.spacing = 14
        let optionsIndent = NSView()
        optionsIndent.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let optionsRow = NSStackView(views: [optionsIndent, optionControls])
        optionsRow.orientation = .horizontal
        optionsRow.alignment = .centerY
        optionsRow.spacing = 8

        let scopeLabel = NSTextField(labelWithString: "查找范围：")
        scopeLabel.alignment = .right
        scopeLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let scopeRow = NSStackView(views: [
            scopeLabel, scopePopup, flexibleSpace(),
            previousButton, nextButton, findAllButton,
            replaceButton, replaceAllButton,
            markAllButton, clearMarksButton
        ])
        scopeRow.orientation = .horizontal
        scopeRow.alignment = .centerY
        scopeRow.spacing = 8

        findStatus.textColor = .secondaryLabelColor
        findStatus.font = .systemFont(ofSize: 11)
        findStatus.lineBreakMode = .byTruncatingTail
        findStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        findSpinner.style = .spinning
        findSpinner.controlSize = .small
        findSpinner.isDisplayedWhenStopped = false
        findSpinner.isHidden = true
        findSpinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        findSpinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
        findProgress.style = .bar
        findProgress.controlSize = .small
        findProgress.isIndeterminate = false
        findProgress.minValue = 0
        findProgress.maxValue = 1
        findProgress.isHidden = true
        findProgress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let bottomRow = NSStackView(views: [findSpinner, findStatus, flexibleSpace(), closeButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        findPanelBody.setViews([
            findRow, replaceRow, optionsRow, scopeRow,
            findProgress, separator(), bottomRow
        ], in: .leading)
        findPanelBody.orientation = .vertical
        findPanelBody.alignment = .width
        findPanelBody.spacing = 10
        findPanelBody.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)

        let findItem = NSTabViewItem(identifier: "find")
        findItem.label = "查找"
        findItem.view = NSView()
        let replaceItem = NSTabViewItem(identifier: "replace")
        replaceItem.label = "替换"
        replaceItem.view = NSView()
        let markItem = NSTabViewItem(identifier: "mark")
        markItem.label = "标记"
        markItem.view = NSView()
        findTabView.addTabViewItem(findItem)
        findTabView.addTabViewItem(replaceItem)
        findTabView.addTabViewItem(markItem)
        findTabView.selectTabViewItem(findItem)
        findTabView.delegate = self
        attachFindPanelBody(to: findItem.view!)
        updateFindPanelMode()

        guard let content = findPanel.contentView else { return }
        findPanel.delegate = self
        findTabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(findTabView)
        NSLayoutConstraint.activate([
            findTabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            findTabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            findTabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            findTabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        if let window {
            let frame = window.frame
            findPanel.setFrameOrigin(NSPoint(
                x: frame.midX - findPanel.frame.width / 2,
                y: frame.maxY - findPanel.frame.height - 70
            ))
        }
    }

    private func attachFindPanelBody(to container: NSView) {
        findPanelBody.removeFromSuperview()
        findPanelBody.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(findPanelBody)
        NSLayoutConstraint.activate([
            findPanelBody.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findPanelBody.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findPanelBody.topAnchor.constraint(equalTo: container.topAnchor),
            findPanelBody.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func updateFindPanelMode() {
        let selectedIndex = findTabView.indexOfTabViewItem(findTabView.selectedTabViewItem!)
        let isReplaceMode = selectedIndex == 1
        let isMarkMode = selectedIndex == 2
        replaceLabel.alphaValue = isReplaceMode ? 1 : 0
        replaceField.alphaValue = isReplaceMode ? 1 : 0
        replaceField.isEnabled = isReplaceMode && !isFindingAll && !isUndoingReplacement
        previousButton.isHidden = isMarkMode
        nextButton.isHidden = isMarkMode
        findAllButton.isHidden = isMarkMode
        replaceButton.isHidden = !isReplaceMode
        replaceAllButton.isHidden = !isReplaceMode
        undoReplaceButton.isHidden = !isReplaceMode
        markAllButton.isHidden = !isMarkMode
        clearMarksButton.isHidden = !isMarkMode
        findPanel.title = isReplaceMode ? "替换" : isMarkMode ? "标记" : "查找"
    }

    private func setFindAllRunning(_ running: Bool) {
        isFindingAll = running
        let controlsEnabled = !running && !isUndoingReplacement
        findField.isEnabled = controlsEnabled
        scopePopup.isEnabled = controlsEnabled
        caseCheckbox.isEnabled = controlsEnabled
        wholeWordCheckbox.isEnabled = controlsEnabled
        regexCheckbox.isEnabled = controlsEnabled
        previousButton.isEnabled = controlsEnabled
        nextButton.isEnabled = controlsEnabled
        findAllButton.isEnabled = controlsEnabled
        replaceButton.isEnabled = !running && !isReplacingAll && !isUndoingReplacement
        replaceAllButton.isEnabled = !running && !isReplacingAll && !isUndoingReplacement
        updateUndoReplaceButton()
        markAllButton.isEnabled = controlsEnabled
        clearMarksButton.isEnabled = controlsEnabled
        findProgress.isHidden = !running
        findSpinner.isHidden = !running
        if running {
            findProgress.doubleValue = 0
            findSpinner.startAnimation(nil)
        } else {
            findSpinner.stopAnimation(nil)
        }
    }

    private func updateUndoReplaceButton() {
        undoReplaceButton.isEnabled = !replacementUndoActions.isEmpty
            && !isFindingAll
            && !isReplacingAll
            && !isUndoingReplacement
    }

    private func invalidateReplacementUndo(for documentID: UUID) {
        guard replacementUndoActions.contains(where: { $0.documentID == documentID }) else {
            return
        }
        replacementUndoActions.removeAll(keepingCapacity: false)
        updateUndoReplaceButton()
    }

    private func updateFindProgress(
        documentName: String,
        scannedBytes: Int,
        totalBytes: Int,
        matchCount: Int,
        action: String = "查找"
    ) {
        let progress = totalBytes > 0
            ? min(1, Double(scannedBytes) / Double(totalBytes))
            : 1
        let scannedSize = ByteCountFormatter.string(
            fromByteCount: Int64(scannedBytes),
            countStyle: .file
        )
        let totalSize = ByteCountFormatter.string(
            fromByteCount: Int64(totalBytes),
            countStyle: .file
        )
        findProgress.doubleValue = progress
        findStatus.textColor = .secondaryLabelColor
        let countLabel = action == "标记" ? "已标记" : "已找到"
        findStatus.stringValue = "正在\(action) \(Int(progress * 100))% · \(countLabel)\(matchCount)项 · \(scannedSize)/\(totalSize) · \(documentName)"
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard tabView === findTabView, let container = tabViewItem?.view else { return }
        attachFindPanelBody(to: container)
        updateFindPanelMode()
        findPanel.makeFirstResponder(findField)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === findField || field === replaceField else { return }
        searchTask?.cancel()
        findStatus.textColor = .secondaryLabelColor
        findStatus.stringValue = ""
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === findField || control === replaceField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            findNext()
            return true
        }
        return false
    }

    private func configureResults() {
        let titleLabel = NSTextField(labelWithString: "查找结果")
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        let closeButton = NSButton(
            title: "×",
            target: self,
            action: #selector(closeSearchResults)
        )
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 16)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "关闭搜索结果"
        closeButton.setAccessibilityLabel("关闭搜索结果")
        closeButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [titleLabel, flexibleSpace(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        header.heightAnchor.constraint(equalToConstant: 26).isActive = true

        resultsScroll.hasVerticalScroller = true
        resultsScroll.verticalScroller = ArrowCursorScroller(frame: .zero)
        resultsScroll.hasHorizontalScroller = true
        resultsScroll.horizontalScroller = ArrowCursorScroller(frame: .zero)
        resultsScroll.autohidesScrollers = true
        resultsScroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.width = 2_600
        column.minWidth = 600
        column.maxWidth = 10_000
        column.resizingMask = .userResizingMask
        resultsTable.addTableColumn(column)
        resultsTable.columnAutoresizingStyle = .noColumnAutoresizing
        resultsTable.headerView = nil
        resultsTable.rowHeight = 18
        resultsTable.intercellSpacing = NSSize(width: 0, height: 0)
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.allowsMultipleSelection = false
        resultsScroll.documentView = resultsTable

        let stack = NSStackView(views: [header, resultsScroll])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        resultsContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: resultsContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor)
        ])
        resultsContainer.isHidden = true
    }

    private func setResultsVisible(_ visible: Bool) {
        if visible {
            guard resultsContainer.superview == nil else { return }
            resultsContainer.isHidden = false
            editorResultsSplit.addSubview(resultsContainer)
            editorResultsSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            editorResultsSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
            editorResultsSplit.adjustSubviews()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.resultsContainer.superview != nil else { return }
                let availableHeight = max(
                    60,
                    self.editorResultsSplit.bounds.height
                        - 260
                        - self.editorResultsSplit.dividerThickness
                )
                let height = min(max(self.resultsPaneHeight, 60), availableHeight)
                self.editorResultsSplit.setPosition(
                    self.editorResultsSplit.bounds.height
                        - height
                        - self.editorResultsSplit.dividerThickness,
                    ofDividerAt: 0
                )
            }
        } else {
            guard resultsContainer.superview != nil else { return }
            resultsPaneHeight = max(resultsContainer.frame.height, 60)
            resultsContainer.removeFromSuperview()
            resultsContainer.isHidden = true
            editorResultsSplit.adjustSubviews()
        }
    }

    @objc private func closeSearchResults() {
        setResultsVisible(false)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === editorResultsSplit else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, 260)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === editorResultsSplit else { return proposedMaximumPosition }
        return min(
            proposedMaximumPosition,
            splitView.bounds.height - 60 - splitView.dividerThickness
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        searchResultItems.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("resultCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byClipping
            field.maximumNumberOfLines = 1
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let item = searchResultItems[row]
        if item.documentID == nil {
            cell.textField?.font = .boldSystemFont(ofSize: 11)
            if let source = item.source,
               documentIndex(for: source) == nil {
                cell.textField?.stringValue = "\(item.title) · 已关闭"
            } else {
                cell.textField?.stringValue = item.title
            }
        } else {
            cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.attributedStringValue = highlightedResultText(item.title)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = resultsTable.selectedRow
        guard searchResultItems.indices.contains(row),
              searchResultItems[row].documentID != nil else { return }
        jumpToSearchResult(searchResultItems[row])
    }

    private func highlightedResultText(_ text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        guard !resultQuery.isEmpty,
              let matches = try? SearchEngine.matches(
                  in: text,
                  query: resultQuery,
                  options: resultOptions
              ) else { return attributed }
        for range in matches {
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.55),
                range: range
            )
        }
        return attributed
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc func newDocument() {
        let document = EditorDocument(untitledNumber: untitledCounter)
        untitledCounter += 1
        documents.append(document)
        activeIndex = documents.count - 1
        rebuildTabs()
        showActiveDocument()
    }

    @objc func openDocuments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls)
        }
    }

    func open(urls: [URL]) {
        syncActiveDocument()
        for url in urls {
            if let existing = documents.firstIndex(where: { $0.fileURL == url }) {
                activeIndex = existing
                continue
            }
            do {
                let document = try EditorDocument(loading: url)
                documents.append(document)
                activeIndex = documents.count - 1
                rebuildTabs()
                showActiveDocument()
                startOpening(document)
            } catch {
                presentError(error, title: "无法打开\(url.lastPathComponent)")
            }
        }
        rebuildTabs()
        showActiveDocument()
        resultsTable.reloadData()
    }

    private func startOpening(_ document: EditorDocument) {
        guard let url = document.fileURL,
              let sessionID = document.loadSessionID else { return }
        let documentID = document.id
        documentLoadTasks[documentID]?.cancel()
        documentLoadTasks[documentID] = Task { [weak self, weak document] in
            guard let self, let document else { return }
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let encoding = IncrementalTextDecoder.detectEncoding(
                        in: data,
                        previewByteCount: FileCodec.previewByteCount
                    )
                    return OpenedFile(data: data, encoding: encoding)
                }.value
                try Task.checkCancellation()
                guard document.loadSessionID == sessionID else { return }

                document.byteStore.reset(with: opened.data)
                document.loadedByteCount = 0
                if let pending = pendingSearchResultJump,
                   pending.documentID == documentID,
                   pending.mode != .text {
                    if let encoding = opened.encoding {
                        document.encoding = encoding
                    }
                    document.displayMode = pending.mode
                    document.hasDecodedText = false
                    document.loadedByteCount = document.fullFileSize
                    document.loadState = .ready
                    document.loadSessionID = nil
                    documentLoadTasks.removeValue(forKey: documentID)
                    rebuildTabs()
                    if activeDocument?.id == documentID { showActiveDocument() }
                    finishPendingSearchResultJump(for: document)
                    return
                }
                if let encoding = opened.encoding {
                    document.encoding = encoding
                    documentLoadTasks.removeValue(forKey: documentID)
                    startProgressiveTextLoad(
                        document,
                        encoding: encoding,
                        fallbackToHexOnFailure: true
                    )
                } else {
                    document.displayMode = .hexadecimal
                    document.hasDecodedText = false
                    document.loadedByteCount = document.fullFileSize
                    document.loadState = .ready
                    document.loadSessionID = nil
                    documentLoadTasks.removeValue(forKey: documentID)
                    rebuildTabs()
                    if activeDocument?.id == documentID { showActiveDocument() }
                    finishPendingSearchResultJump(for: document)
                }
            } catch is CancellationError {
            } catch {
                guard document.loadSessionID == sessionID else { return }
                document.loadState = .failed(error.localizedDescription)
                documentLoadTasks.removeValue(forKey: documentID)
                rebuildTabs()
                if activeDocument?.id == documentID {
                    updateStatus(extra: "打开失败：\(error.localizedDescription)")
                }
                failPendingSearchResultJump(
                    for: documentID,
                    message: "无法重新打开搜索结果：\(error.localizedDescription)"
                )
            }
        }
    }

    private func startProgressiveTextLoad(
        _ document: EditorDocument,
        encoding: EditorTextEncoding,
        fallbackToHexOnFailure: Bool
    ) {
        let documentID = document.id
        documentLoadTasks[documentID]?.cancel()
        let snapshot = document.byteStore.snapshot()
        let sessionID = UUID()
        let existingEditor = editors[documentID]
        document.loadSessionID = sessionID
        document.loadState = .loadingPreview
        document.loadedByteCount = 0
        document.displayMode = .text
        document.encoding = encoding
        document.hasDecodedText = true
        document.text = ""
        existingEditor?.beginIncrementalReload(editable: !document.isReadOnly)
        textEditorRevisions.removeValue(forKey: documentID)
        rebuildTabs()
        if activeDocument?.id == documentID { showActiveDocument() }
        let documentEditor = editor(for: document)
        let isReloadingExistingEditor = existingEditor != nil

        documentLoadTasks[documentID] = Task { [weak self, weak document, weak documentEditor] in
            guard let self, let document, let documentEditor else { return }
            do {
                if isReloadingExistingEditor {
                    while documentEditor.documentLength > 0 {
                        try Task.checkCancellation()
                        guard document.loadSessionID == sessionID else {
                            throw CancellationError()
                        }
                        _ = documentEditor.deleteTrailingBytes(maximumLength: 4 * 1024 * 1024)
                        if activeDocument?.id == documentID {
                            updateStatus(extra: "正在准备编码转换")
                        }
                        await Task.yield()
                    }
                }

                let header = snapshot.data(in: 0..<min(snapshot.count, 4))
                var offset = IncrementalTextDecoder.payloadStart(for: encoding, in: header)
                var remainder = Data()
                var isFirstChunk = true
                var containsCRLF = false
                var containsLF = false
                var containsCR = false
                var previousLastByte: UInt8?

                while offset < snapshot.count {
                    try Task.checkCancellation()
                    let byteCount = isFirstChunk
                        ? FileCodec.previewByteCount
                        : 4 * 1024 * 1024
                    let end = min(snapshot.count, offset + byteCount)
                    let range = offset..<end
                    let carry = remainder
                    let isFinal = end == snapshot.count
                    let result = try await Task.detached(priority: .userInitiated) {
                        var source = carry
                        source.append(snapshot.data(in: range))
                        return try IncrementalTextDecoder.decode(
                            source,
                            using: encoding,
                            isFinal: isFinal
                        )
                    }.value
                    try Task.checkCancellation()
                    guard document.loadSessionID == sessionID,
                          document.byteStore.revision == snapshot.revision else {
                        throw CancellationError()
                    }

                    if previousLastByte == 0x0D, result.firstByte == 0x0A {
                        containsCRLF = true
                    }
                    containsCRLF = containsCRLF || result.containsCRLF
                    containsLF = containsLF || result.containsLF
                    containsCR = containsCR || result.containsCR
                    if let lastByte = result.lastByte { previousLastByte = lastByte }
                    documentEditor.appendUTF8Data(result.utf8Data)
                    remainder = result.remainder
                    offset = end
                    document.loadedByteCount = UInt64(end)
                    document.loadState = offset < snapshot.count ? .streaming : .loadingPreview
                    finishPendingSearchResultJump(for: document)
                    if isFirstChunk {
                        isFirstChunk = false
                        rebuildTabs()
                    }
                    if activeDocument?.id == documentID { updateStatus() }
                    await Task.yield()
                }

                documentEditor.finishIncrementalLoad()
                document.lineEnding = containsCRLF ? .crlf : containsLF ? .lf : containsCR ? .cr : .none
                document.loadedByteCount = document.fullFileSize
                document.loadState = .ready
                document.loadSessionID = nil
                textEditorRevisions[documentID] = snapshot.revision
                documentLoadTasks.removeValue(forKey: documentID)
                rebuildTabs()
                finishPendingSearchResultJump(for: document)
                if activeDocument?.id == documentID { updateStatus(extra: "加载完成") }
            } catch is CancellationError {
            } catch {
                guard document.loadSessionID == sessionID else { return }
                documentLoadTasks.removeValue(forKey: documentID)
                if fallbackToHexOnFailure {
                    document.loadState = .ready
                    document.loadSessionID = nil
                    document.displayMode = .hexadecimal
                    document.hasDecodedText = false
                    editors.removeValue(forKey: documentID)?.removeFromSuperview()
                    rebuildTabs()
                    if activeDocument?.id == documentID {
                        showActiveDocument()
                        updateStatus(extra: "文本解码失败，已切换Hex")
                    }
                    finishPendingSearchResultJump(for: document)
                } else {
                    document.loadState = .failed(error.localizedDescription)
                    rebuildTabs()
                    if activeDocument?.id == documentID {
                        updateStatus(extra: "Text加载失败：\(error.localizedDescription)")
                    }
                    failPendingSearchResultJump(
                        for: documentID,
                        message: "无法定位搜索结果：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    @objc func saveDocument() {
        guard let document = activeDocument else { return }
        syncActiveDocument()
        _ = save(document)
    }

    @objc func saveAllDocuments() {
        syncActiveDocument()
        var saved = 0
        for document in documents where document.isDirty && !document.isReadOnly {
            if save(document) { saved += 1 }
        }
        rebuildTabs()
        updateStatus(extra: "已保存\(saved)个文件")
    }

    private func save(_ document: EditorDocument) -> Bool {
        guard !document.isTextLoading else {
            updateStatus(extra: "Text加载完成后才能保存")
            return false
        }
        var target = document.fileURL
        if target == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.displayName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK else { return false }
            target = panel.url
        }
        do {
            if document.displayMode == .text, let editor = editors[document.id] {
                document.text = editor.string
            }
            try document.save(to: target)
            editors[document.id]?.setSavePoint()
            byteEditors[document.id]?.reloadData()
            document.discardFileBackedContentCache()
            rebuildTabs()
            updateStatus(extra: "已保存")
            return true
        } catch {
            presentError(error, title: "保存失败")
            return false
        }
    }

    @objc func closeActiveDocument() {
        guard documents.indices.contains(activeIndex) else { return }
        closeDocument(at: activeIndex)
    }

    @objc private func selectTab(_ sender: NSButton) {
        syncActiveDocument()
        activeIndex = sender.tag
        rebuildTabs()
        showActiveDocument()
    }

    @objc private func closeTab(_ sender: NSButton) {
        closeDocument(at: sender.tag)
    }

    private func closeDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        syncActiveDocument()
        let document = documents[index]
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "保存对\(document.displayName)的修改吗？"
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "不保存")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn, !save(document) { return }
            if response == .alertSecondButtonReturn { return }
        }
        editors.removeValue(forKey: document.id)?.removeFromSuperview()
        byteEditors.removeValue(forKey: document.id)?.removeFromSuperview()
        documentLoadTasks.removeValue(forKey: document.id)?.cancel()
        textEditorRevisions.removeValue(forKey: document.id)
        searchCaches.removeValue(forKey: document.id)
        invalidateReplacementUndo(for: document.id)
        if pendingSearchResultJump?.documentID == document.id {
            pendingSearchResultJump = nil
        }
        documents.remove(at: index)
        activeIndex = min(index, documents.count - 1)
        if documents.isEmpty {
            untitledCounter = 1
            newDocument()
        } else {
            rebuildTabs()
            showActiveDocument()
        }
        resultsTable.deselectAll(nil)
        resultsTable.reloadData()
    }

    private func rebuildTabs() {
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, document) in documents.enumerated() {
            let select = NSButton(title: document.tabTitle, target: self, action: #selector(selectTab))
            select.tag = index
            select.isBordered = false
            let close = NSButton(title: "×", target: self, action: #selector(closeTab))
            close.tag = index
            close.isBordered = false
            close.contentTintColor = .secondaryLabelColor
            let group = NSStackView(views: [select, close])
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 4
            group.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
            group.setContentHuggingPriority(.required, for: .horizontal)
            group.setContentCompressionResistancePriority(.required, for: .horizontal)

            let tab = NSView()
            tab.translatesAutoresizingMaskIntoConstraints = false
            tab.wantsLayer = true
            tab.layer?.cornerRadius = 7
            tab.layer?.backgroundColor = (index == activeIndex
                ? NSColor.controlAccentColor.withAlphaComponent(0.20)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.10)).cgColor
            tab.layer?.borderWidth = 1
            tab.layer?.borderColor = (index == activeIndex
                ? NSColor.controlAccentColor.withAlphaComponent(0.65)
                : NSColor.separatorColor).cgColor
            group.translatesAutoresizingMaskIntoConstraints = false
            tab.addSubview(group)
            NSLayoutConstraint.activate([
                group.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
                group.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
                group.topAnchor.constraint(equalTo: tab.topAnchor),
                group.bottomAnchor.constraint(equalTo: tab.bottomAnchor)
            ])
            tab.setContentHuggingPriority(.required, for: .horizontal)
            tab.setContentCompressionResistancePriority(.required, for: .horizontal)
            tabStack.addArrangedSubview(tab)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabStack.addArrangedSubview(spacer)
    }

    private func showActiveDocument() {
        guard let document = activeDocument else { return }
        modeControl.selectedSegment = document.displayMode.rawValue
        encodingPopup.selectItem(at: document.encoding.rawValue)
        encodingPopup.isEnabled = true
        let textMode = document.displayMode == .text
        caseCheckbox.isEnabled = textMode
        wholeWordCheckbox.isEnabled = textMode
        regexCheckbox.isEnabled = textMode

        let view: NSView
        switch document.displayMode {
        case .text:
            view = editor(for: document)
        case .hexadecimal, .binary:
            let byteEditor = byteEditor(for: document)
            byteEditor.mode = document.displayMode
            view = byteEditor
        }
        for subview in contentContainer.subviews {
            if subview is EditorTextView || subview is ByteEditorView {
                subview.isHidden = subview !== view
            } else {
                subview.removeFromSuperview()
            }
        }
        if view.superview == nil {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        }
        view.isHidden = false
        updateStatus()
    }

    private func editor(for document: EditorDocument) -> EditorTextView {
        if let existing = editors[document.id] { return existing }
        let editor = EditorTextView()
        if document.isTextLoading {
            editor.beginIncrementalLoad(
                expectedByteLength: Int(min(UInt64(Int.max), document.fullFileSize)),
                editable: !document.isReadOnly,
                largeDocument: document.isLargeFile
            )
        } else {
            editor.load(
                text: document.text,
                editable: !document.isReadOnly && document.hasDecodedText,
                largeDocument: document.isLargeFile
            )
            textEditorRevisions[document.id] = document.byteStore.revision
        }
        editor.onTextChanged = { [weak self, weak document, weak editor] in
            guard let self, let document else { return }
            if !self.isUndoingReplacement {
                self.invalidateReplacementUndo(for: document.id)
            }
            let wasDirty = document.isDirty
            document.isDirty = (editor?.isModified ?? false) || document.byteStore.isModified
            self.searchTask?.cancel()
            self.searchCaches.removeValue(forKey: document.id)
            if wasDirty != document.isDirty { self.rebuildTabs() }
        }
        editor.onSelectionChanged = { [weak self] in self?.updateStatus() }
        editor.onFilesDropped = { [weak self] urls in self?.open(urls: urls) }
        editors[document.id] = editor
        document.discardFileBackedContentCache()
        return editor
    }

    private func byteEditor(for document: EditorDocument) -> ByteEditorView {
        if let existing = byteEditors[document.id] { return existing }
        let editor = ByteEditorView(
            store: document.byteStore,
            mode: document.displayMode,
            editable: !document.isReadOnly
        )
        editor.onBytesChanged = { [weak self, weak document] in
            guard let self, let document else { return }
            if !self.isUndoingReplacement {
                self.invalidateReplacementUndo(for: document.id)
            }
            document.isDirty = document.byteStore.isModified
                || (self.editors[document.id]?.isModified ?? false)
            self.searchTask?.cancel()
            self.searchCaches.removeValue(forKey: document.id)
            self.rebuildTabs()
            self.updateStatus()
        }
        editor.onSelectionChanged = { [weak self] in self?.updateStatus() }
        byteEditors[document.id] = editor
        return editor
    }

    private func syncActiveDocument() {
        guard let document = activeDocument else { return }
        guard !document.isTextLoading else { return }
        if let editor = editors[document.id] {
            document.isDirty = editor.isModified || document.byteStore.isModified
        } else {
            document.isDirty = document.byteStore.isModified
        }
    }

    @objc private func displayModeChanged() {
        guard let document = activeDocument,
              let mode = EditorDisplayMode(rawValue: modeControl.selectedSegment) else { return }
        let oldMode = document.displayMode
        guard mode != oldMode else { return }
        invalidateReplacementUndo(for: document.id)
        do {
            if oldMode == .text, mode != .text, let editor = editors[document.id] {
                if document.isTextLoading {
                    guard document.byteStore.count > 0 || document.fullFileSize == 0 else {
                        modeControl.selectedSegment = oldMode.rawValue
                        updateStatus(extra: "正在读取文件首块")
                        return
                    }
                    documentLoadTasks.removeValue(forKey: document.id)?.cancel()
                    document.loadSessionID = nil
                    document.loadState = .ready
                    editors.removeValue(forKey: document.id)?.removeFromSuperview()
                    textEditorRevisions.removeValue(forKey: document.id)
                } else if editor.isModified {
                    document.text = editor.string
                    document.isDirty = true
                    try document.synchronizeBytesFromText()
                    textEditorRevisions[document.id] = document.byteStore.revision
                    byteEditors[document.id]?.reloadData()
                }
            } else if oldMode != .text, mode == .text {
                if let revision = textEditorRevisions[document.id],
                   revision == document.byteStore.revision,
                   editors[document.id] != nil {
                    document.displayMode = .text
                    showActiveDocument()
                    return
                }
                startProgressiveTextLoad(
                    document,
                    encoding: document.encoding,
                    fallbackToHexOnFailure: false
                )
                return
            }
            document.displayMode = mode
            if mode != .text, case .failed = document.loadState {
                document.loadState = .ready
                document.loadSessionID = nil
                document.loadedByteCount = document.fullFileSize
            }
            showActiveDocument()
        } catch {
            modeControl.selectedSegment = oldMode.rawValue
            presentError(error, title: "无法切换到\(mode.title)模式")
        }
    }

    @objc private func encodingChanged() {
        guard let document = activeDocument,
              let encoding = EditorTextEncoding(rawValue: encodingPopup.indexOfSelectedItem) else { return }
        if document.displayMode != .text {
            document.encoding = encoding
            updateStatus()
            return
        }
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "文件有未保存修改"
            alert.informativeText = "重新选择编码会丢弃未保存修改。"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn {
                encodingPopup.selectItem(at: document.encoding.rawValue)
                return
            }
        }
        invalidateReplacementUndo(for: document.id)
        searchCaches.removeValue(forKey: document.id)
        document.isDirty = false
        startProgressiveTextLoad(
            document,
            encoding: encoding,
            fallbackToHexOnFailure: false
        )
    }

    @objc func showFindPanel() {
        presentFindPanel(tabIndex: 0)
    }

    @objc func showReplacePanel() {
        presentFindPanel(tabIndex: 1)
    }

    private func presentFindPanel(tabIndex: Int) {
        if let document = activeDocument, !document.isTextLoading {
            if document.displayMode == .text, let documentEditor = editors[document.id] {
                let selectedRange = documentEditor.selectedByteRange
                if selectedRange.length > 0 {
                    if selectedRange.length <= maximumFindPrefillByteCount {
                        findField.stringValue = documentEditor.selectedString
                    } else {
                        findStatus.stringValue = "选中内容过大，已保留原查找内容"
                    }
                }
            } else if let documentEditor = byteEditors[document.id] {
                let selectedRange = documentEditor.selectedByteRange
                if selectedRange.length > 0 {
                    if selectedRange.length <= maximumFindPrefillByteCount {
                        let upperBound = min(document.byteStore.count, NSMaxRange(selectedRange))
                        let selectedBytes = document.byteStore.data(
                            in: selectedRange.location..<upperBound
                        )
                        if document.displayMode == .hexadecimal {
                            findField.stringValue = selectedBytes
                                .map { String(format: "%02X", $0) }
                                .joined(separator: " ")
                        } else {
                            findField.stringValue = selectedBytes
                                .map { String($0, radix: 2).leftPadding(toLength: 8, with: "0") }
                                .joined(separator: " ")
                        }
                    } else {
                        findStatus.stringValue = "选中内容过大，已保留原查找内容"
                    }
                }
            }
        }
        findTabView.selectTabViewItem(at: tabIndex)
        updateFindPanelMode()
        findPanel.alphaValue = 1
        if let window, findPanel.parent == nil {
            window.addChildWindow(findPanel, ordered: .above)
        }
        findPanel.makeKeyAndOrderFront(nil)
        findPanel.makeFirstResponder(findField)
    }

    @objc private func closeFindPanel() {
        guard shouldCloseFindPanel() else { return }
        findPanel.orderOut(nil)
    }

    private func shouldCloseFindPanel() -> Bool {
        if isReplacingAll {
            let alert = NSAlert()
            alert.messageText = "全部替换正在进行"
            alert.informativeText = "停止后，当前文件会在安全处理完成后停止，已经完成的替换不会自动撤销。"
            alert.addButton(withTitle: "继续替换")
            alert.addButton(withTitle: "停止替换并关闭")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        if isFindingAll {
            for index in searchResultItems.indices {
                guard let title = searchResultItems[index].headerTitle,
                      title.contains("（正在查找") else { continue }
                searchResultItems[index] = SearchResultItem(
                    headerTitle: title.replacingOccurrences(of: "（正在查找", with: "（已取消"),
                    documentID: nil,
                    mode: nil,
                    match: nil,
                    source: searchResultItems[index].source
                )
            }
            resultsTable.reloadData()
        }
        searchTask?.cancel()
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    private var searchOptions: SearchOptions {
        SearchOptions(
            caseSensitive: caseCheckbox.state == .on,
            wholeWord: wholeWordCheckbox.state == .on,
            regularExpression: regexCheckbox.state == .on
        )
    }

    @objc private func findNext() { startDirectionalFind(direction: 1) }
    @objc private func findPrevious() { startDirectionalFind(direction: -1) }

    private func cachedMatches(
        for document: EditorDocument,
        query: String,
        options: SearchOptions,
        mode: EditorDisplayMode
    ) -> [EditorSearchMatch]? {
        if let cache = searchCaches[document.id],
           cache.query == query,
           cache.options == options,
           cache.mode == mode {
            return cache.matches
        }
        return nil
    }

    private func startDirectionalFind(direction: Int) {
        guard !isReplacingAll, !isFindingAll else { return }
        findStatus.textColor = .secondaryLabelColor
        if scopePopup.indexOfSelectedItem == 0, activeDocument?.isTextLoading == true {
            findStatus.stringValue = "Text加载完成后才能查找"
            return
        }
        let query = findField.stringValue
        guard !query.isEmpty else {
            findStatus.stringValue = "请输入查找内容"
            return
        }
        let options = searchOptions
        if resultQuery != query || resultOptions != options {
            searchResultItems.removeAll(keepingCapacity: true)
            resultsTable.reloadData()
            setResultsVisible(false)
        }
        let indexes: [Int]
        if scopePopup.indexOfSelectedItem == 0 {
            indexes = [activeIndex]
        } else {
            let count = documents.count
            indexes = (0..<count).map { (activeIndex + direction * $0 + count * 2) % count }
        }

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                for index in indexes where documents.indices.contains(index) {
                    try Task.checkCancellation()
                    let document = documents[index]
                    if document.isTextLoading { continue }
                    let mode = document.displayMode
                    let documentLength: Int
                    let selected: NSRange
                    if mode == .text {
                        guard document.hasDecodedText else { continue }
                        let documentEditor = editor(for: document)
                        documentLength = documentEditor.documentLength
                        selected = index == activeIndex
                            ? documentEditor.selectedByteRange
                            : NSRange(location: direction > 0 ? 0 : documentLength, length: 0)
                    } else {
                        let documentEditor = byteEditor(for: document)
                        documentLength = document.byteStore.count
                        selected = index == activeIndex
                            ? documentEditor.selectedByteRange
                            : NSRange(location: direction > 0 ? 0 : documentLength, length: 0)
                    }

                    if let matches = cachedMatches(
                        for: document,
                        query: query,
                        options: options,
                        mode: mode
                    ),
                       let match = directionalMatch(
                           in: matches,
                           selected: selected,
                           direction: direction
                       ) {
                        revealSearchMatch(match, in: document, at: index, mode: mode)
                        let position = matches.firstIndex(of: match)! + 1
                        findStatus.stringValue = "第\(position)/\(matches.count)项"
                        return
                    }

                    let initialPosition = direction > 0 ? NSMaxRange(selected) : selected.location
                    if mode == .text {
                        let documentEditor = editor(for: document)
                        documentEditor.clearSearchHighlights()
                        var found = try await firstMatch(
                            in: documentEditor,
                            query: query,
                            options: options,
                            fromPosition: initialPosition,
                            direction: direction
                        )
                        if found == nil {
                            found = try await firstMatch(
                                in: documentEditor,
                                query: query,
                                options: options,
                                fromPosition: direction > 0 ? 0 : documentLength,
                                direction: direction
                            )
                        }
                        if let found {
                            revealSearchMatch(found, in: document, at: index, mode: mode)
                            findStatus.stringValue = "已找到"
                            return
                        }
                    } else {
                        let bytes = try byteQuery(from: query, mode: mode)
                        let documentEditor = byteEditor(for: document)
                        documentEditor.clearSearchHighlights()
                        var found = try await firstByteMatch(
                            in: document,
                            bytes: bytes,
                            mode: mode,
                            fromPosition: initialPosition,
                            direction: direction
                        )
                        if found == nil {
                            found = try await firstByteMatch(
                                in: document,
                                bytes: bytes,
                                mode: mode,
                                fromPosition: direction > 0 ? 0 : documentLength,
                                direction: direction
                            )
                        }
                        if let found {
                            revealSearchMatch(found, in: document, at: index, mode: mode)
                            findStatus.stringValue = "已找到"
                            return
                        }
                    }
                }
                findStatus.stringValue = "未找到"
            } catch is CancellationError {
            } catch {
                findStatus.stringValue = error.localizedDescription
            }
        }
    }

    private func directionalMatch(
        in matches: [EditorSearchMatch],
        selected: NSRange,
        direction: Int
    ) -> EditorSearchMatch? {
        guard !matches.isEmpty else { return nil }
        if direction > 0 {
            return matches.first(where: { $0.byteRange.location >= NSMaxRange(selected) }) ?? matches[0]
        }
        return matches.last(where: { NSMaxRange($0.byteRange) <= selected.location }) ?? matches[matches.count - 1]
    }

    private func revealSearchMatch(
        _ match: EditorSearchMatch,
        in document: EditorDocument,
        at index: Int,
        mode: EditorDisplayMode
    ) {
        activeIndex = index
        document.displayMode = mode
        rebuildTabs()
        showActiveDocument()
        if mode == .text {
            editor(for: document).reveal(match)
        } else {
            byteEditor(for: document).reveal(byteRange: match.byteRange)
        }
    }

    private func firstMatch(
        in editor: EditorTextView,
        query: String,
        options: SearchOptions,
        fromPosition: Int,
        direction: Int
    ) async throws -> EditorSearchMatch? {
        var position = fromPosition
        while true {
            try Task.checkCancellation()
            let batch = try editor.searchBatch(
                query: query,
                options: options,
                fromPosition: position,
                direction: direction,
                byteLimit: searchChunkByteCount,
                maximumCount: 1
            )
            if let match = batch.matches.first { return match }
            if batch.isFinished { return nil }
            position = batch.nextPosition
            await Task.yield()
        }
    }

    private func collectMatches(
        in editor: EditorTextView,
        query: String,
        options: SearchOptions,
        progress: ((Int, Int) -> Void)? = nil,
        resultBatch: (([EditorSearchMatch], Bool) -> Void)? = nil
    ) async throws -> [EditorSearchMatch] {
        var matches: [EditorSearchMatch] = []
        var position = 0
        while true {
            try Task.checkCancellation()
            let batch = try editor.searchBatch(
                query: query,
                options: options,
                fromPosition: position,
                direction: 1,
                byteLimit: searchChunkByteCount,
                maximumCount: searchBatchMatchCount
            )
            matches.append(contentsOf: batch.matches)
            resultBatch?(batch.matches, batch.isFinished)
            progress?(
                matches.count,
                batch.isFinished ? editor.documentLength : batch.nextPosition
            )
            if batch.isFinished { return matches }
            position = batch.nextPosition
            await Task.yield()
        }
    }

    private func byteQuery(from value: String, mode: EditorDisplayMode) throws -> Data {
        if mode == .hexadecimal {
            let normalized = value
                .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
                .filter { !$0.isWhitespace && $0 != "," && $0 != "_" }
            guard !normalized.isEmpty,
                  normalized.count.isMultiple(of: 2),
                  normalized.allSatisfy(\.isHexDigit) else {
                throw ByteQueryError.invalidHex
            }
            var bytes = Data()
            var index = normalized.startIndex
            while index < normalized.endIndex {
                let end = normalized.index(index, offsetBy: 2)
                guard let byte = UInt8(normalized[index..<end], radix: 16) else {
                    throw ByteQueryError.invalidHex
                }
                bytes.append(byte)
                index = end
            }
            return bytes
        }
        let normalized = value.filter { !$0.isWhitespace && $0 != "_" }
        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 8),
              normalized.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            throw ByteQueryError.invalidBinary
        }
        var bytes = Data()
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let end = normalized.index(index, offsetBy: 8)
            guard let byte = UInt8(normalized[index..<end], radix: 2) else {
                throw ByteQueryError.invalidBinary
            }
            bytes.append(byte)
            index = end
        }
        return bytes
    }

    private func firstByteMatch(
        in document: EditorDocument,
        bytes: Data,
        mode: EditorDisplayMode,
        fromPosition: Int,
        direction: Int
    ) async throws -> EditorSearchMatch? {
        var position = fromPosition
        while true {
            try Task.checkCancellation()
            let batch = document.byteStore.search(
                for: bytes,
                fromPosition: position,
                direction: direction,
                byteLimit: searchChunkByteCount,
                maximumCount: 1
            )
            if let offset = batch.offsets.first {
                return byteSearchMatch(
                    in: document.byteStore,
                    offset: offset,
                    length: bytes.count,
                    mode: mode
                )
            }
            if batch.isFinished { return nil }
            position = batch.nextPosition
            await Task.yield()
        }
    }

    private func collectByteMatches(
        in document: EditorDocument,
        bytes: Data,
        mode: EditorDisplayMode,
        progress: ((Int, Int) -> Void)? = nil,
        resultBatch: (([EditorSearchMatch], Bool) -> Void)? = nil
    ) async throws -> [EditorSearchMatch] {
        var matches: [EditorSearchMatch] = []
        var position = 0
        while true {
            try Task.checkCancellation()
            let batch = document.byteStore.search(
                for: bytes,
                fromPosition: position,
                direction: 1,
                byteLimit: searchChunkByteCount,
                maximumCount: searchBatchMatchCount
            )
            let batchMatches = batch.offsets.map {
                byteSearchMatch(
                    in: document.byteStore,
                    offset: $0,
                    length: bytes.count,
                    mode: mode
                )
            }
            matches.append(contentsOf: batchMatches)
            resultBatch?(batchMatches, batch.isFinished)
            progress?(
                matches.count,
                batch.isFinished ? document.byteStore.count : batch.nextPosition
            )
            if batch.isFinished { return matches }
            position = batch.nextPosition
            await Task.yield()
        }
    }

    private func markMatches(
        in editor: EditorTextView,
        query: String,
        options: SearchOptions,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        var count = 0
        var position = 0
        editor.clearSearchHighlights()
        defer { editor.clearSearchHighlights() }
        while true {
            try Task.checkCancellation()
            let batch = try editor.searchBatch(
                query: query,
                options: options,
                fromPosition: position,
                direction: 1,
                byteLimit: searchChunkByteCount,
                maximumCount: searchBatchMatchCount
            )
            editor.addMarkedHighlights(batch.matches.map(\.byteRange))
            count += batch.matches.count
            progress?(
                count,
                batch.isFinished ? editor.documentLength : batch.nextPosition
            )
            if batch.isFinished { return count }
            position = batch.nextPosition
            await Task.yield()
        }
    }

    private func markByteMatches(
        in document: EditorDocument,
        bytes: Data,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let documentEditor = byteEditor(for: document)
        var count = 0
        var position = 0
        while true {
            try Task.checkCancellation()
            let batch = document.byteStore.search(
                for: bytes,
                fromPosition: position,
                direction: 1,
                byteLimit: searchChunkByteCount,
                maximumCount: searchBatchMatchCount
            )
            documentEditor.addMarkedHighlights(batch.offsets.map {
                NSRange(location: $0, length: bytes.count)
            })
            count += batch.offsets.count
            progress?(
                count,
                batch.isFinished ? document.byteStore.count : batch.nextPosition
            )
            if batch.isFinished { return count }
            position = batch.nextPosition
            await Task.yield()
        }
    }

    private func byteSearchMatch(
        in store: ByteStore,
        offset: Int,
        length: Int,
        mode: EditorDisplayMode
    ) -> EditorSearchMatch {
        let bytesPerRow = mode == .binary ? 8 : 16
        let rowOffset = offset / bytesPerRow * bytesPerRow
        let rowData = store.data(in: rowOffset..<min(store.count, rowOffset + bytesPerRow))
        let lineText: String
        if mode == .binary {
            lineText = rowData.map {
                String($0, radix: 2).leftPadding(toLength: 8, with: "0")
            }.joined(separator: " ")
        } else {
            lineText = rowData.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        return EditorSearchMatch(
            byteRange: NSRange(location: offset, length: length),
            lineNumber: rowOffset / bytesPerRow + 1,
            lineText: lineText
        )
    }

    @objc private func markAll() {
        guard !isReplacingAll, !isFindingAll else { return }
        if scopePopup.indexOfSelectedItem == 0, activeDocument?.isTextLoading == true {
            findStatus.textColor = .systemOrange
            findStatus.stringValue = "Text加载完成后才能标记"
            return
        }
        let query = findField.stringValue
        guard !query.isEmpty else {
            findStatus.textColor = .systemOrange
            findStatus.stringValue = "请输入查找内容"
            return
        }
        let options = searchOptions
        let indexes = scopePopup.indexOfSelectedItem == 0
            ? [activeIndex]
            : Array(documents.indices)
        var documentLengths: [UUID: Int] = [:]
        for index in indexes where documents.indices.contains(index) {
            let document = documents[index]
            guard !document.isTextLoading,
                  document.displayMode != .text || document.hasDecodedText else { continue }
            documentLengths[document.id] = document.displayMode == .text
                ? editor(for: document).documentLength
                : document.byteStore.count
        }
        let totalBytes = documentLengths.values.reduce(0, +)
        searchTask?.cancel()
        setResultsVisible(false)
        let requestID = UUID()
        findAllRequestID = requestID
        setFindAllRunning(true)
        findStatus.textColor = .secondaryLabelColor
        findStatus.stringValue = "正在准备标记…"

        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if findAllRequestID == requestID {
                    findAllRequestID = nil
                    setFindAllRunning(false)
                }
            }
            var total = 0
            var completedBytes = 0
            do {
                for index in indexes where documents.indices.contains(index) {
                    try Task.checkCancellation()
                    let document = documents[index]
                    if document.isTextLoading { continue }
                    let mode = document.displayMode
                    if mode == .text, !document.hasDecodedText { continue }
                    let documentLength = documentLengths[document.id] ?? 0
                    let completedBeforeDocument = completedBytes
                    let marksBeforeDocument = total
                    var lastProgressUpdate = 0.0
                    let reportProgress: (Int, Int) -> Void = { count, scannedBytes in
                        let now = ProcessInfo.processInfo.systemUptime
                        guard now - lastProgressUpdate >= 0.1 || scannedBytes >= documentLength else {
                            return
                        }
                        lastProgressUpdate = now
                        self.updateFindProgress(
                            documentName: document.displayName,
                            scannedBytes: completedBeforeDocument + scannedBytes,
                            totalBytes: totalBytes,
                            matchCount: marksBeforeDocument + count,
                            action: "标记"
                        )
                    }
                    let count: Int
                    if mode == .text {
                        count = try await markMatches(
                            in: editor(for: document),
                            query: query,
                            options: options,
                            progress: reportProgress
                        )
                    } else {
                        count = try await markByteMatches(
                            in: document,
                            bytes: byteQuery(from: query, mode: mode),
                            progress: reportProgress
                        )
                    }
                    total += count
                    completedBytes += documentLength
                    updateFindProgress(
                        documentName: document.displayName,
                        scannedBytes: completedBytes,
                        totalBytes: totalBytes,
                        matchCount: total,
                        action: "标记"
                    )
                }
                if total == 0 {
                    findStatus.textColor = .systemOrange
                    findStatus.stringValue = "未找到匹配内容"
                } else {
                    findStatus.textColor = .secondaryLabelColor
                    findStatus.stringValue = "标记完成 · 共\(total)项"
                }
            } catch is CancellationError {
                if findAllRequestID == requestID {
                    findStatus.textColor = .secondaryLabelColor
                    findStatus.stringValue = "已取消标记"
                }
            } catch {
                if findAllRequestID == requestID {
                    findStatus.textColor = .systemRed
                    findStatus.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func clearMarks() {
        guard !isReplacingAll, !isFindingAll else { return }
        let indexes = scopePopup.indexOfSelectedItem == 0
            ? [activeIndex]
            : Array(documents.indices)
        for index in indexes where documents.indices.contains(index) {
            let documentID = documents[index].id
            editors[documentID]?.clearMarkedHighlights()
            byteEditors[documentID]?.clearMarkedHighlights()
        }
        findStatus.textColor = .secondaryLabelColor
        findStatus.stringValue = "已清除标记"
    }

    @objc private func findAll() {
        guard !isReplacingAll, !isFindingAll else { return }
        if scopePopup.indexOfSelectedItem == 0, activeDocument?.isTextLoading == true {
            findStatus.textColor = .systemOrange
            findStatus.stringValue = "Text加载完成后才能查找全部"
            return
        }
        let query = findField.stringValue
        guard !query.isEmpty else {
            findStatus.textColor = .systemOrange
            findStatus.stringValue = "请输入查找内容"
            return
        }
        let options = searchOptions
        let indexes = scopePopup.indexOfSelectedItem == 0
            ? [activeIndex]
            : Array(documents.indices)
        var documentLengths: [UUID: Int] = [:]
        for index in indexes where documents.indices.contains(index) {
            let document = documents[index]
            guard !document.isTextLoading,
                  document.displayMode != .text || document.hasDecodedText else { continue }
            documentLengths[document.id] = document.displayMode == .text
                ? editor(for: document).documentLength
                : document.byteStore.count
        }
        let totalBytes = documentLengths.values.reduce(0, +)
        searchTask?.cancel()
        searchResultItems.removeAll(keepingCapacity: true)
        resultsTable.reloadData()
        setResultsVisible(true)
        resultQuery = query
        resultOptions = options
        let requestID = UUID()
        findAllRequestID = requestID
        setFindAllRunning(true)
        findStatus.textColor = .secondaryLabelColor
        findStatus.stringValue = "正在准备查找…"

        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if findAllRequestID == requestID {
                    findAllRequestID = nil
                    setFindAllRunning(false)
                }
            }
            var total = 0
            var completedBytes = 0
            do {
                for index in indexes where documents.indices.contains(index) {
                    try Task.checkCancellation()
                    let document = documents[index]
                    if document.isTextLoading { continue }
                    let mode = document.displayMode
                    if mode == .text, !document.hasDecodedText { continue }
                    let sourceValues: URLResourceValues?
                    if let fileURL = document.fileURL {
                        sourceValues = try? fileURL.resourceValues(
                            forKeys: [.fileSizeKey, .contentModificationDateKey]
                        )
                    } else {
                        sourceValues = nil
                    }
                    let resultSource = SearchResultSource(
                        documentID: document.id,
                        fileURL: document.fileURL,
                        fileSize: sourceValues?.fileSize.map { UInt64(max(0, $0)) }
                            ?? document.fullFileSize,
                        modificationDate: sourceValues?.contentModificationDate
                    )
                    let documentLength = documentLengths[document.id] ?? 0
                    let completedBeforeDocument = completedBytes
                    let matchesBeforeDocument = total
                    var lastProgressUpdate = 0.0
                    var lastResultsUpdate = 0.0
                    var headerRow: Int?
                    var displayedMatchCount = 0
                    let reportProgress: (Int, Int) -> Void = { count, scannedBytes in
                        let now = ProcessInfo.processInfo.systemUptime
                        guard now - lastProgressUpdate >= 0.1 || scannedBytes >= documentLength else {
                            return
                        }
                        lastProgressUpdate = now
                        self.updateFindProgress(
                            documentName: document.displayName,
                            scannedBytes: completedBeforeDocument + scannedBytes,
                            totalBytes: totalBytes,
                            matchCount: matchesBeforeDocument + count
                        )
                    }
                    let appendResultBatch: ([EditorSearchMatch], Bool) -> Void = { batch, isFinished in
                        guard self.findAllRequestID == requestID else { return }
                        if !batch.isEmpty {
                            if headerRow == nil {
                                headerRow = self.searchResultItems.count
                                self.searchResultItems.append(SearchResultItem(
                                    headerTitle: "\(document.displayName)（正在查找）",
                                    documentID: nil,
                                    mode: nil,
                                    match: nil,
                                    source: resultSource
                                ))
                            }
                            self.searchResultItems.append(contentsOf: batch.map {
                                SearchResultItem(
                                    headerTitle: nil,
                                    documentID: document.id,
                                    mode: mode,
                                    match: $0,
                                    source: resultSource
                                )
                            })
                            displayedMatchCount += batch.count
                        }
                        guard let headerRow else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        guard isFinished || now - lastResultsUpdate >= 0.1 else { return }
                        lastResultsUpdate = now
                        self.searchResultItems[headerRow] = SearchResultItem(
                            headerTitle: isFinished
                                ? "\(document.displayName)（\(displayedMatchCount)项）"
                                : "\(document.displayName)（正在查找 · 已找到\(displayedMatchCount)项）",
                            documentID: nil,
                            mode: nil,
                            match: nil,
                            source: resultSource
                        )
                        self.resultsTable.noteNumberOfRowsChanged()
                        self.resultsTable.reloadData(
                            forRowIndexes: IndexSet(integer: headerRow),
                            columnIndexes: IndexSet(integer: 0)
                        )
                    }
                    let matches: [EditorSearchMatch]
                    if let cached = cachedMatches(
                        for: document,
                        query: query,
                        options: options,
                        mode: mode
                    ) {
                        matches = cached
                        var offset = 0
                        repeat {
                            let end = min(offset + searchBatchMatchCount, matches.count)
                            let batch = offset < end ? Array(matches[offset..<end]) : []
                            appendResultBatch(batch, end == matches.count)
                            offset = end
                            if offset < matches.count {
                                try Task.checkCancellation()
                                await Task.yield()
                            }
                        } while offset < matches.count
                    } else if mode == .text {
                        let documentEditor = editor(for: document)
                        documentEditor.clearSearchHighlights()
                        matches = try await collectMatches(
                            in: documentEditor,
                            query: query,
                            options: options,
                            progress: reportProgress,
                            resultBatch: appendResultBatch
                        )
                        searchCaches[document.id] = SearchCache(
                            query: query,
                            options: options,
                            mode: mode,
                            matches: matches
                        )
                    } else {
                        let bytes = try byteQuery(from: query, mode: mode)
                        let documentEditor = byteEditor(for: document)
                        documentEditor.clearSearchHighlights()
                        matches = try await collectByteMatches(
                            in: document,
                            bytes: bytes,
                            mode: mode,
                            progress: reportProgress,
                            resultBatch: appendResultBatch
                        )
                        documentEditor.setSearchHighlights(matches.map(\.byteRange))
                        searchCaches[document.id] = SearchCache(
                            query: query,
                            options: options,
                            mode: mode,
                            matches: matches
                        )
                    }
                    total += matches.count
                    completedBytes += documentLength
                    updateFindProgress(
                        documentName: document.displayName,
                        scannedBytes: completedBytes,
                        totalBytes: totalBytes,
                        matchCount: total
                    )
                }
                if searchResultItems.isEmpty {
                    searchResultItems.append(SearchResultItem(
                        headerTitle: "未找到",
                        documentID: nil,
                        mode: nil,
                        match: nil
                    ))
                    resultsTable.noteNumberOfRowsChanged()
                }
                if total == 0 {
                    findStatus.textColor = .systemOrange
                    findStatus.stringValue = "未找到匹配内容"
                } else {
                    findStatus.textColor = .secondaryLabelColor
                    findStatus.stringValue = "查找完成 · 共\(total)项"
                }
            } catch is CancellationError {
                if findAllRequestID == requestID {
                    findStatus.textColor = .secondaryLabelColor
                    findStatus.stringValue = "已取消查找"
                }
            } catch {
                if findAllRequestID == requestID {
                    findStatus.textColor = .systemRed
                    findStatus.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func documentIndex(for source: SearchResultSource) -> Int? {
        if let index = documents.firstIndex(where: { $0.id == source.documentID }) {
            return index
        }
        guard let fileURL = source.fileURL else { return nil }
        let standardizedURL = fileURL.standardizedFileURL
        return documents.firstIndex {
            $0.fileURL?.standardizedFileURL == standardizedURL
        }
    }

    private func isSearchResultSourceCurrent(_ source: SearchResultSource) -> Bool {
        guard let fileURL = source.fileURL,
              let values = try? fileURL.resourceValues(
                  forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              let fileSize = values.fileSize,
              UInt64(max(0, fileSize)) == source.fileSize else { return false }
        guard let modificationDate = source.modificationDate else { return true }
        return values.contentModificationDate == modificationDate
    }

    private func showSearchResult(
        _ match: EditorSearchMatch,
        in document: EditorDocument,
        at index: Int,
        mode: EditorDisplayMode
    ) {
        revealSearchMatch(match, in: document, at: index, mode: mode)
        let location = mode == .text
            ? "行\(match.lineNumber)"
            : String(format: "偏移0x%016llX", UInt64(match.byteRange.location))
        updateStatus(extra: "查找结果 \(location)")
    }

    private func finishPendingSearchResultJump(for document: EditorDocument) {
        guard let pending = pendingSearchResultJump,
              pending.documentID == document.id else { return }

        let end = NSMaxRange(pending.match.byteRange)
        if pending.mode == .text {
            guard document.hasDecodedText else {
                if !document.isTextLoading {
                    pendingSearchResultJump = nil
                    updateStatus(extra: "文件无法以Text模式打开，原搜索结果已失效")
                }
                return
            }
            guard editor(for: document).documentLength >= end else {
                if !document.isTextLoading {
                    pendingSearchResultJump = nil
                    updateStatus(extra: "原搜索位置已超出文件范围，请重新查找")
                }
                return
            }
        } else {
            guard document.byteStore.count >= end else {
                pendingSearchResultJump = nil
                updateStatus(extra: "原搜索位置已超出文件范围，请重新查找")
                return
            }
        }

        pendingSearchResultJump = nil
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        showSearchResult(pending.match, in: document, at: index, mode: pending.mode)
        resultsTable.reloadData()
    }

    private func failPendingSearchResultJump(for documentID: UUID, message: String) {
        guard pendingSearchResultJump?.documentID == documentID else { return }
        pendingSearchResultJump = nil
        updateStatus(extra: message)
    }

    private func jumpToSearchResult(_ item: SearchResultItem) {
        guard let mode = item.mode,
              let match = item.match else { return }
        if let documentID = item.documentID,
           let index = documents.firstIndex(where: { $0.id == documentID }) {
            showSearchResult(match, in: documents[index], at: index, mode: mode)
            return
        }
        guard let source = item.source,
              let fileURL = source.fileURL else {
            updateStatus(extra: "未保存文件关闭后无法重新打开")
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            updateStatus(extra: "搜索结果对应的文件已不存在")
            return
        }
        guard isSearchResultSourceCurrent(source) else {
            updateStatus(extra: "文件内容已变化，原搜索结果已失效，请重新查找")
            return
        }

        if documentIndex(for: source) == nil {
            open(urls: [fileURL])
        }
        guard let index = documentIndex(for: source) else {
            updateStatus(extra: "无法重新打开搜索结果对应的文件")
            return
        }

        let document = documents[index]
        pendingSearchResultJump = PendingSearchResultJump(
            documentID: document.id,
            source: source,
            mode: mode,
            match: match
        )
        activeIndex = index
        rebuildTabs()
        showActiveDocument()
        resultsTable.reloadData()
        if mode != .text,
           document.isTextLoading,
           document.byteStore.count > 0 {
            documentLoadTasks.removeValue(forKey: document.id)?.cancel()
            document.loadSessionID = nil
            document.loadState = .ready
            document.loadedByteCount = document.fullFileSize
            document.displayMode = mode
            document.hasDecodedText = false
            editors.removeValue(forKey: document.id)?.removeFromSuperview()
            textEditorRevisions.removeValue(forKey: document.id)
            finishPendingSearchResultJump(for: document)
            return
        }
        if mode == .text,
           !document.hasDecodedText,
           !document.isTextLoading {
            startProgressiveTextLoad(
                document,
                encoding: document.encoding,
                fallbackToHexOnFailure: false
            )
            updateStatus(extra: "正在重新打开并定位搜索结果")
            return
        }
        if document.isTextLoading {
            updateStatus(extra: "正在重新打开并定位搜索结果")
        } else {
            finishPendingSearchResultJump(for: document)
        }
    }

    @objc private func replaceCurrent() {
        guard !isReplacingAll, !isFindingAll, !isUndoingReplacement else { return }
        findStatus.textColor = .secondaryLabelColor
        guard let document = activeDocument,
              !document.isReadOnly,
              !document.isTextLoading else { return }
        do {
            if document.displayMode == .text {
                guard document.hasDecodedText else { return }
                let editor = editor(for: document)
                let selectedText = editor.selectedString
                let exact = try SearchEngine.matches(
                    in: selectedText,
                    query: findField.stringValue,
                    options: searchOptions
                )
                let selectedLength = (selectedText as NSString).length
                if exact.count == 1,
                   exact[0] == NSRange(location: 0, length: selectedLength),
                   selectedText != replaceField.stringValue {
                    editor.replaceSelection(with: replaceField.stringValue)
                    replacementUndoActions = [.text(documentID: document.id)]
                    updateUndoReplaceButton()
                }
                startDirectionalFind(direction: 1)
                return
            }

            let query = try byteQuery(from: findField.stringValue, mode: document.displayMode)
            let replacement = try byteQuery(from: replaceField.stringValue, mode: document.displayMode)
            guard query.count == replacement.count else {
                throw ByteStoreError.replacementLengthMismatch
            }
            let editor = byteEditor(for: document)
            let selected = editor.selectedByteRange
            if selected.length == query.count,
               document.byteStore.data(in: selected.location..<NSMaxRange(selected)) == query,
               query != replacement {
                try document.byteStore.replaceBytes(
                    in: selected.location..<NSMaxRange(selected),
                    with: replacement
                )
                document.isDirty = true
                editor.reloadData()
                searchCaches.removeValue(forKey: document.id)
                replacementUndoActions = [.bytes(
                    documentID: document.id,
                    ranges: [selected],
                    original: query
                )]
                updateUndoReplaceButton()
                startDirectionalFind(direction: 1)
            } else {
                startDirectionalFind(direction: 1)
            }
        } catch {
            findStatus.stringValue = error.localizedDescription
        }
    }

    @objc private func replaceAll() {
        guard !isReplacingAll, !isFindingAll, !isUndoingReplacement else { return }
        findStatus.textColor = .secondaryLabelColor
        let indexes = scopePopup.indexOfSelectedItem == 0
            ? [activeIndex]
            : Array(documents.indices)
        let queryText = findField.stringValue
        guard !queryText.isEmpty else {
            findStatus.stringValue = "请输入查找内容"
            return
        }
        let replacementText = replaceField.stringValue
        let options = searchOptions
        searchTask?.cancel()
        isReplacingAll = true
        replaceButton.isEnabled = false
        replaceAllButton.isEnabled = false
        updateUndoReplaceButton()
        findStatus.stringValue = "正在准备后台替换…"
        searchTask = Task { [weak self] in
            guard let self else { return }
            var undoActions: [ReplacementUndoAction] = []
            defer {
                isReplacingAll = false
                replaceButton.isEnabled = true
                replaceAllButton.isEnabled = true
                if !undoActions.isEmpty {
                    replacementUndoActions = undoActions
                }
                updateUndoReplaceButton()
            }
            var total = 0
            do {
                for index in indexes where documents.indices.contains(index) {
                    try Task.checkCancellation()
                    let document = documents[index]
                    guard !document.isReadOnly,
                          !document.isTextLoading else { continue }
                    if document.displayMode == .text {
                        guard document.hasDecodedText else { continue }
                        let documentEditor = editor(for: document)
                        documentEditor.setEditable(false)
                        var reloadStarted = false
                        defer {
                            if !reloadStarted {
                                documentEditor.setEditable(!document.isReadOnly)
                            }
                        }
                        findStatus.stringValue = "正在准备\(document.displayName)的数据…"
                        await Task.yield()
                        let encoding = document.encoding
                        let source: Data
                        if encoding == .utf8,
                           !documentEditor.isModified,
                           textEditorRevisions[document.id] == document.byteStore.revision {
                            source = document.byteStore.materializedData()
                        } else {
                            source = documentEditor.snapshotUTF8Data()
                        }
                        let worker = Task.detached(priority: .userInitiated) {
                            try SearchEngine.replacingAllUTF8(
                                in: source,
                                query: queryText,
                                replacement: replacementText,
                                options: options
                            )
                        }
                        let result = try await withTaskCancellationHandler {
                            try await worker.value
                        } onCancel: {
                            worker.cancel()
                        }
                        try Task.checkCancellation()
                        guard result.count > 0 else { continue }

                        reloadStarted = true
                        documentEditor.beginIncrementalReplacement(editable: !document.isReadOnly)
                        while documentEditor.documentLength > 0 {
                            _ = documentEditor.deleteTrailingBytes(maximumLength: 4 * 1024 * 1024)
                            findStatus.stringValue = "正在应用\(document.displayName)：已清理旧内容"
                            await Task.yield()
                        }
                        var offset = 0
                        while offset < result.data.count {
                            let end = min(result.data.count, offset + 4 * 1024 * 1024)
                            documentEditor.appendUTF8Data(Data(result.data[offset..<end]))
                            offset = end
                            let percent = result.data.isEmpty ? 100 : offset * 100 / result.data.count
                            findStatus.stringValue = "正在应用\(document.displayName)：\(percent)%"
                            await Task.yield()
                        }
                        documentEditor.finishIncrementalReplacement()
                        total += result.count
                        document.isDirty = true
                        textEditorRevisions.removeValue(forKey: document.id)
                        undoActions.append(.text(documentID: document.id))
                    } else {
                        let query = try byteQuery(from: queryText, mode: document.displayMode)
                        let replacement = try byteQuery(from: replacementText, mode: document.displayMode)
                        guard query.count == replacement.count else {
                            throw ByteStoreError.replacementLengthMismatch
                        }
                        let matches = try await collectByteMatches(
                            in: document,
                            bytes: query,
                            mode: document.displayMode,
                            progress: { count, _ in
                                self.findStatus.stringValue = "正在扫描\(document.displayName)：\(count)项"
                            }
                        )
                        for (offset, match) in matches.enumerated() {
                            try document.byteStore.replaceBytes(
                                in: match.byteRange.location..<NSMaxRange(match.byteRange),
                                with: replacement
                            )
                            if offset.isMultiple(of: searchBatchMatchCount) {
                                await Task.yield()
                            }
                        }
                        total += matches.count
                        if !matches.isEmpty {
                            document.isDirty = true
                            byteEditor(for: document).reloadData()
                            byteEditor(for: document).clearSearchHighlights()
                            undoActions.append(.bytes(
                                documentID: document.id,
                                ranges: matches.map(\.byteRange),
                                original: query
                            ))
                        }
                    }
                    searchCaches.removeValue(forKey: document.id)
                    try Task.checkCancellation()
                    await Task.yield()
                }
                rebuildTabs()
                showActiveDocument()
                findStatus.stringValue = "已替换\(total)项，尚未保存到磁盘"
            } catch is CancellationError {
                rebuildTabs()
                showActiveDocument()
                findStatus.stringValue = "已取消替换"
            } catch {
                findStatus.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func undoLastReplacement() {
        guard !isReplacingAll,
              !isFindingAll,
              !isUndoingReplacement,
              !replacementUndoActions.isEmpty else { return }

        let actions = replacementUndoActions
        for action in actions {
            guard let document = documents.first(where: { $0.id == action.documentID }) else {
                replacementUndoActions.removeAll(keepingCapacity: false)
                updateUndoReplaceButton()
                findStatus.stringValue = "无法撤销：相关文件已关闭"
                return
            }
            switch action {
            case .text:
                guard editors[document.id]?.canUndo == true else {
                    replacementUndoActions.removeAll(keepingCapacity: false)
                    updateUndoReplaceButton()
                    findStatus.stringValue = "无法撤销：文档撤销记录已失效"
                    return
                }
            case .bytes(_, let ranges, _):
                guard ranges.allSatisfy({
                    $0.location >= 0 && NSMaxRange($0) <= document.byteStore.count
                }) else {
                    replacementUndoActions.removeAll(keepingCapacity: false)
                    updateUndoReplaceButton()
                    findStatus.stringValue = "无法撤销：字节位置已失效"
                    return
                }
            }
        }

        replacementUndoActions.removeAll(keepingCapacity: false)
        searchTask?.cancel()
        isUndoingReplacement = true
        replaceField.isEnabled = false
        setFindAllRunning(false)
        findStatus.textColor = .secondaryLabelColor
        findStatus.stringValue = "正在撤销上次替换…"

        Task { [weak self] in
            guard let self else { return }
            defer {
                isUndoingReplacement = false
                setFindAllRunning(false)
                updateFindPanelMode()
                rebuildTabs()
                showActiveDocument()
            }
            do {
                for action in actions.reversed() {
                    guard let document = documents.first(where: { $0.id == action.documentID }) else {
                        continue
                    }
                    switch action {
                    case .text:
                        let documentEditor = editor(for: document)
                        documentEditor.undo()
                        document.isDirty = documentEditor.isModified
                            || document.byteStore.isModified
                        textEditorRevisions.removeValue(forKey: document.id)
                    case .bytes(_, let ranges, let original):
                        for (index, range) in ranges.reversed().enumerated() {
                            try document.byteStore.replaceBytes(
                                in: range.location..<NSMaxRange(range),
                                with: original
                            )
                            if index.isMultiple(of: searchBatchMatchCount) {
                                await Task.yield()
                            }
                        }
                        document.isDirty = document.byteStore.isModified
                            || (editors[document.id]?.isModified ?? false)
                        byteEditors[document.id]?.reloadData()
                        byteEditors[document.id]?.clearSearchHighlights()
                    }
                    searchCaches.removeValue(forKey: document.id)
                }
                findStatus.stringValue = "已撤销上次替换，尚未保存到磁盘"
            } catch {
                findStatus.textColor = .systemRed
                findStatus.stringValue = "撤销替换失败：\(error.localizedDescription)"
            }
        }
    }

    private func updateStatus(extra: String? = nil) {
        guard let document = activeDocument else { return }
        let size = ByteCountFormatter.string(fromByteCount: Int64(document.fullFileSize), countStyle: .file)
        var position = ""
        if let editor = editors[document.id], document.displayMode == .text {
            let location = editor.lineAndColumn()
            position = "行\(location.line)，列\(location.column) | "
        } else if let editor = byteEditors[document.id], document.displayMode != .text {
            position = String(format: "偏移0x%016llX | ", UInt64(editor.selectedByteRange.location))
        }
        let mode = document.isLargeFile
            ? "\(document.displayMode.title)（大文件）"
            : document.displayMode.title
        let loading: String
        switch document.loadState {
        case .loadingPreview:
            loading = " | 正在加载首屏"
        case .streaming:
            let percent = document.fullFileSize > 0
                ? Int(document.loadedByteCount * 100 / document.fullFileSize)
                : 100
            let loaded = ByteCountFormatter.string(
                fromByteCount: Int64(document.loadedByteCount),
                countStyle: .file
            )
            loading = " | 正在加载\(loaded)/\(size)（\(percent)%）"
        case .failed(let message):
            loading = " | 加载失败：\(message)"
        default:
            loading = ""
        }
        statusLabel.stringValue = "\(position)\(document.encoding.title) | \(document.lineEnding.rawValue) | \(size) | \(mode)\(loading)\(extra.map { " | \($0)" } ?? "")"
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === findPanel else { return }
        findPanel.alphaValue = 1
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === findPanel else { return }
        findPanel.alphaValue = 0.94
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        findPanel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === findPanel {
            guard shouldCloseFindPanel() else { return false }
            findPanel.orderOut(nil)
            return false
        }
        syncActiveDocument()
        let dirty = documents.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "还有\(dirty.count)个文件未保存"
        alert.addButton(withTitle: "全部保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存并退出")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            saveAllDocuments()
            return documents.allSatisfy { !$0.isDirty }
        }
        return response == .alertThirdButtonReturn
    }
}
