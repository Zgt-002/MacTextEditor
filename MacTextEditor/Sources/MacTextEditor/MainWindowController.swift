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

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
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

    private struct SearchResultItem {
        let headerTitle: String?
        let documentID: UUID?
        let mode: EditorDisplayMode?
        let match: EditorSearchMatch?

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
    private var activeIndex = -1
    private var untitledCounter = 1

    private let searchChunkByteCount = 4 * 1024 * 1024
    private let searchBatchMatchCount = 512

    private let tabStack = NSStackView()
    private let tabScroll = NSScrollView()
    private let contentContainer = NSView()
    private let modeControl = NSSegmentedControl(
        labels: EditorDisplayMode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let encodingPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "准备就绪")
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let scopePopup = NSPopUpButton()
    private let caseCheckbox = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil)
    private let wholeWordCheckbox = NSButton(checkboxWithTitle: "全词", target: nil, action: nil)
    private let regexCheckbox = NSButton(checkboxWithTitle: "正则", target: nil, action: nil)
    private let findStatus = NSTextField(labelWithString: "")
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTextEditor"
        window.minSize = NSSize(width: 820, height: 520)
        window.center()
        super.init(window: window)
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
        let findButton = button("查找替换", #selector(showFindBar))

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

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        configureFindBar()
        configureResults()

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
            contentContainer,
            findBar,
            resultsScroll,
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
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    private func configureFindBar() {
        findField.placeholderString = "查找"
        findField.delegate = self
        findField.cell?.usesSingleLineMode = true
        findField.cell?.isScrollable = true
        findField.cell?.lineBreakMode = .byClipping
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        replaceField.placeholderString = "替换为"
        replaceField.delegate = self
        replaceField.cell?.usesSingleLineMode = true
        replaceField.cell?.isScrollable = true
        replaceField.cell?.lineBreakMode = .byClipping
        replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        scopePopup.addItems(withTitles: ["当前文件", "所有打开文件"])

        let previousButton = button("上一个", #selector(findPrevious))
        let nextButton = button("下一个", #selector(findNext))
        let allButton = button("查找全部", #selector(findAll))
        let replaceButton = button("替换", #selector(replaceCurrent))
        let replaceAllButton = button("全部替换", #selector(replaceAll))

        findStatus.textColor = .secondaryLabelColor
        findStatus.font = .systemFont(ofSize: 11)
        findBar.setViews([
            findField, replaceField, scopePopup,
            caseCheckbox, wholeWordCheckbox, regexCheckbox,
            previousButton, nextButton, allButton, replaceButton, replaceAllButton,
            findStatus
        ], in: .leading)
        findBar.orientation = .horizontal
        findBar.alignment = .centerY
        findBar.spacing = 6
        findBar.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        findBar.isHidden = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === findField || field === replaceField else { return }
        searchTask?.cancel()
        findStatus.stringValue = ""
    }

    private func configureResults() {
        resultsScroll.hasVerticalScroller = true
        resultsScroll.verticalScroller = ArrowCursorScroller(frame: .zero)
        resultsScroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.rowHeight = 20
        resultsTable.intercellSpacing = NSSize(width: 0, height: 0)
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.allowsMultipleSelection = false
        resultsScroll.documentView = resultsTable
        resultsScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        resultsScroll.isHidden = true
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
            field.lineBreakMode = .byTruncatingTail
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
            cell.textField?.stringValue = item.title
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
                } else {
                    document.loadState = .failed(error.localizedDescription)
                    rebuildTabs()
                    if activeDocument?.id == documentID {
                        updateStatus(extra: "Text加载失败：\(error.localizedDescription)")
                    }
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
        documents.remove(at: index)
        activeIndex = min(index, documents.count - 1)
        if documents.isEmpty {
            untitledCounter = 1
            newDocument()
        } else {
            rebuildTabs()
            showActiveDocument()
        }
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
            let becameDirty = !document.isDirty
            document.isDirty = document.isDirty || (editor?.isModified ?? false)
            self.searchTask?.cancel()
            self.searchCaches.removeValue(forKey: document.id)
            if becameDirty, document.isDirty { self.rebuildTabs() }
        }
        editor.onSelectionChanged = { [weak self] in self?.updateStatus() }
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
            document.isDirty = true
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
            document.isDirty = document.isDirty || editor.isModified || document.byteStore.isModified
        } else if document.byteStore.isModified {
            document.isDirty = true
        }
    }

    @objc private func displayModeChanged() {
        guard let document = activeDocument,
              let mode = EditorDisplayMode(rawValue: modeControl.selectedSegment) else { return }
        let oldMode = document.displayMode
        guard mode != oldMode else { return }
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
        searchCaches.removeValue(forKey: document.id)
        document.isDirty = false
        startProgressiveTextLoad(
            document,
            encoding: encoding,
            fallbackToHexOnFailure: false
        )
    }

    @objc func showFindBar() {
        findBar.isHidden = false
        window?.makeFirstResponder(findField)
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
            resultsScroll.isHidden = true
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
                    let match: EditorSearchMatch?
                    let matches: [EditorSearchMatch]
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
                        match = found
                        if let found {
                            revealSearchMatch(found, in: document, at: index, mode: mode)
                            findStatus.stringValue = "已找到，正在统计…"
                            matches = try await collectMatches(
                                in: documentEditor,
                                query: query,
                                options: options
                            )
                        } else {
                            matches = []
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
                        match = found
                        if let found {
                            revealSearchMatch(found, in: document, at: index, mode: mode)
                            findStatus.stringValue = "已找到，正在统计…"
                            matches = try await collectByteMatches(
                                in: document,
                                bytes: bytes,
                                mode: mode
                            )
                            documentEditor.setSearchHighlights(matches.map(\.byteRange))
                        } else {
                            matches = []
                        }
                    }
                    if let match {
                        searchCaches[document.id] = SearchCache(
                            query: query,
                            options: options,
                            mode: mode,
                            matches: matches
                        )
                        if let position = matches.firstIndex(of: match) {
                            findStatus.stringValue = "第\(position + 1)/\(matches.count)项"
                        }
                        return
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
        progress: ((Int) -> Void)? = nil
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
            progress?(matches.count)
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
        progress: ((Int) -> Void)? = nil
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
            matches.append(contentsOf: batch.offsets.map {
                byteSearchMatch(
                    in: document.byteStore,
                    offset: $0,
                    length: bytes.count,
                    mode: mode
                )
            })
            progress?(matches.count)
            if batch.isFinished { return matches }
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

    @objc private func findAll() {
        if scopePopup.indexOfSelectedItem == 0, activeDocument?.isTextLoading == true {
            findStatus.stringValue = "Text加载完成后才能查找全部"
            return
        }
        let query = findField.stringValue
        guard !query.isEmpty else {
            findStatus.stringValue = "请输入查找内容"
            return
        }
        let options = searchOptions
        let indexes = scopePopup.indexOfSelectedItem == 0
            ? [activeIndex]
            : Array(documents.indices)
        searchTask?.cancel()
        searchResultItems.removeAll(keepingCapacity: true)
        resultsTable.reloadData()
        resultsScroll.isHidden = false
        resultQuery = query
        resultOptions = options
        findStatus.stringValue = "正在分块查找…"

        searchTask = Task { [weak self] in
            guard let self else { return }
            var total = 0
            do {
                for index in indexes where documents.indices.contains(index) {
                    try Task.checkCancellation()
                    let document = documents[index]
                    if document.isTextLoading { continue }
                    let mode = document.displayMode
                    if mode == .text, !document.hasDecodedText { continue }
                    let matches: [EditorSearchMatch]
                    if let cached = cachedMatches(
                        for: document,
                        query: query,
                        options: options,
                        mode: mode
                    ) {
                        matches = cached
                    } else if mode == .text {
                        let documentEditor = editor(for: document)
                        documentEditor.clearSearchHighlights()
                        matches = try await collectMatches(
                            in: documentEditor,
                            query: query,
                            options: options
                        ) { count in
                            self.findStatus.stringValue = "正在查找\(document.displayName)：\(count)项"
                        }
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
                            mode: mode
                        ) { count in
                            self.findStatus.stringValue = "正在查找\(document.displayName)：\(count)项"
                        }
                        documentEditor.setSearchHighlights(matches.map(\.byteRange))
                        searchCaches[document.id] = SearchCache(
                            query: query,
                            options: options,
                            mode: mode,
                            matches: matches
                        )
                    }
                    guard !matches.isEmpty else { continue }
                    total += matches.count
                    searchResultItems.append(SearchResultItem(
                        headerTitle: "\(document.displayName)（\(matches.count)项）",
                        documentID: nil,
                        mode: nil,
                        match: nil
                    ))
                    for (offset, match) in matches.enumerated() {
                        searchResultItems.append(SearchResultItem(
                            headerTitle: nil,
                            documentID: document.id,
                            mode: mode,
                            match: match
                        ))
                        if offset.isMultiple(of: searchBatchMatchCount) {
                            resultsTable.reloadData()
                            try Task.checkCancellation()
                            await Task.yield()
                        }
                    }
                    resultsTable.reloadData()
                }
                if searchResultItems.isEmpty {
                    searchResultItems.append(SearchResultItem(
                        headerTitle: "未找到",
                        documentID: nil,
                        mode: nil,
                        match: nil
                    ))
                }
                resultsTable.reloadData()
                findStatus.stringValue = "共\(total)项"
            } catch is CancellationError {
            } catch {
                findStatus.stringValue = error.localizedDescription
            }
        }
    }

    private func jumpToSearchResult(_ item: SearchResultItem) {
        guard let documentID = item.documentID,
              let mode = item.mode,
              let match = item.match,
              let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let document = documents[index]
        revealSearchMatch(match, in: document, at: index, mode: mode)
        let location = mode == .text
            ? "行\(match.lineNumber)"
            : String(format: "偏移0x%016llX", UInt64(match.byteRange.location))
        updateStatus(extra: "查找结果 \(location)")
    }

    @objc private func replaceCurrent() {
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
                   exact[0] == NSRange(location: 0, length: selectedLength) {
                    editor.replaceSelection(with: replaceField.stringValue)
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
               document.byteStore.data(in: selected.location..<NSMaxRange(selected)) == query {
                try document.byteStore.replaceBytes(
                    in: selected.location..<NSMaxRange(selected),
                    with: replacement
                )
                document.isDirty = true
                editor.reloadData()
                searchCaches.removeValue(forKey: document.id)
                startDirectionalFind(direction: 1)
            } else {
                startDirectionalFind(direction: 1)
            }
        } catch {
            findStatus.stringValue = error.localizedDescription
        }
    }

    @objc private func replaceAll() {
        let indexes = scopePopup.indexOfSelectedItem == 0
            ? [activeIndex]
            : Array(documents.indices)
        let queryText = findField.stringValue
        let replacementText = replaceField.stringValue
        let options = searchOptions
        searchTask?.cancel()
        findStatus.stringValue = "正在分块替换…"
        searchTask = Task { [weak self] in
            guard let self else { return }
            var total = 0
            do {
                for index in indexes where documents.indices.contains(index) {
                    try Task.checkCancellation()
                    let document = documents[index]
                    guard !document.isReadOnly,
                          !document.isTextLoading else { continue }
                    if document.displayMode == .text {
                        guard document.hasDecodedText else { continue }
                        let count = try editor(for: document).replaceAll(
                            query: queryText,
                            replacement: replacementText,
                            options: options
                        )
                        total += count
                        if count > 0 { document.isDirty = true }
                    } else {
                        let query = try byteQuery(from: queryText, mode: document.displayMode)
                        let replacement = try byteQuery(from: replacementText, mode: document.displayMode)
                        guard query.count == replacement.count else {
                            throw ByteStoreError.replacementLengthMismatch
                        }
                        let matches = try await collectByteMatches(
                            in: document,
                            bytes: query,
                            mode: document.displayMode
                        ) { count in
                            self.findStatus.stringValue = "正在扫描\(document.displayName)：\(count)项"
                        }
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
                        }
                    }
                    searchCaches.removeValue(forKey: document.id)
                    await Task.yield()
                }
                rebuildTabs()
                showActiveDocument()
                findStatus.stringValue = "已替换\(total)项，尚未保存到磁盘"
            } catch is CancellationError {
            } catch {
                findStatus.stringValue = error.localizedDescription
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
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
