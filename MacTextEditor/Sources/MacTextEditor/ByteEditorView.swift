import AppKit

@MainActor
final class ByteEditorView: NSView {
    private let scrollView = NSScrollView()
    private let contentView: ByteContentView

    var onBytesChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var isEditable: Bool {
        get { contentView.isEditable }
        set { contentView.isEditable = newValue }
    }

    var mode: EditorDisplayMode {
        didSet {
            guard mode != .text else {
                mode = oldValue
                return
            }
            contentView.mode = mode
            updateDocumentSize()
        }
    }

    var selectedByteRange: NSRange { contentView.selectedByteRange }

    init(store: ByteStore, mode: EditorDisplayMode, editable: Bool) {
        self.mode = mode == .text ? .hexadecimal : mode
        contentView = ByteContentView(store: store, mode: self.mode)
        contentView.isEditable = editable
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller = ArrowCursorScroller(frame: .zero)
        scrollView.horizontalScroller = ArrowCursorScroller(frame: .zero)
        scrollView.documentView = contentView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        contentView.onBytesChanged = { [weak self] in self?.onBytesChanged?() }
        contentView.onSelectionChanged = { [weak self] in self?.onSelectionChanged?() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateDocumentSize()
    }

    func reloadData() {
        contentView.reloadData()
        updateDocumentSize()
    }

    func reveal(byteRange: NSRange) {
        contentView.reveal(byteRange: byteRange)
        updateDocumentSize()
        let row = byteRange.location / contentView.bytesPerRow
        let target = NSRect(
            x: 0,
            y: CGFloat(row) * contentView.lineHeight,
            width: contentView.requiredWidth,
            height: contentView.lineHeight
        )
        contentView.scrollToVisible(target)
        window?.makeFirstResponder(contentView)
    }

    func setSearchHighlights(_ ranges: [NSRange]) {
        contentView.searchHighlights = ranges.sorted { $0.location < $1.location }
    }

    func clearSearchHighlights() {
        contentView.searchHighlights = []
    }

    func focus() {
        window?.makeFirstResponder(contentView)
    }

    private func updateDocumentSize() {
        let viewport = scrollView.contentSize
        contentView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(viewport.width, contentView.requiredWidth),
            height: max(viewport.height, contentView.requiredHeight)
        )
    }
}

@MainActor
private final class ByteContentView: NSView {
    let store: ByteStore
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let lineHeight: CGFloat = 20
    private let horizontalPadding: CGFloat = 8
    private(set) var characterWidth: CGFloat = 8
    private var selectedOffset: Int?
    private var selectedLength = 1
    private var selectedComponent = 0

    var onBytesChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var isEditable = true
    var searchHighlights: [NSRange] = [] {
        didSet { needsDisplay = true }
    }
    var mode: EditorDisplayMode {
        didSet {
            selectedComponent = 0
            needsDisplay = true
        }
    }

    var bytesPerRow: Int { mode == .binary ? 8 : 16 }
    var requiredWidth: CGFloat {
        let characters = mode == .binary
            ? 18 + bytesPerRow * 9 - 1
            : 18 + 16 * 3 + 1 + 16
        return horizontalPadding * 2 + CGFloat(characters) * characterWidth
    }
    var requiredHeight: CGFloat {
        CGFloat(max(1, (store.count + bytesPerRow - 1) / bytesPerRow)) * lineHeight
    }
    var selectedByteRange: NSRange {
        guard let selectedOffset else { return NSRange(location: 0, length: 0) }
        return NSRange(location: selectedOffset, length: selectedLength)
    }

    init(store: ByteStore, mode: EditorDisplayMode) {
        self.store = store
        self.mode = mode
        super.init(frame: .zero)
        characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reloadData() {
        if let selectedOffset, selectedOffset >= store.count {
            self.selectedOffset = store.count > 0 ? store.count - 1 : nil
        }
        needsDisplay = true
    }

    func reveal(byteRange: NSRange) {
        selectedOffset = store.count > 0 ? min(store.count - 1, byteRange.location) : nil
        selectedLength = max(1, min(byteRange.length, store.count - byteRange.location))
        selectedComponent = 0
        needsDisplay = true
        onSelectionChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard store.count > 0 else { return }

        let firstRow = max(0, Int(floor(dirtyRect.minY / lineHeight)))
        let lastRow = min(
            (store.count + bytesPerRow - 1) / bytesPerRow - 1,
            Int(ceil(dirtyRect.maxY / lineHeight))
        )
        guard firstRow <= lastRow else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        for row in firstRow...lastRow {
            let offset = row * bytesPerRow
            let end = min(store.count, offset + bytesPerRow)
            let bytes = store.data(in: offset..<end)
            let origin = NSPoint(x: horizontalPadding, y: CGFloat(row) * lineHeight + 2)
            drawHighlights(rowOffset: offset, byteCount: bytes.count, y: CGFloat(row) * lineHeight)
            (formattedLine(offset: offset, bytes: bytes) as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard store.count > 0 else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = max(0, Int(point.y / lineHeight))
        let character = Int((point.x - horizontalPadding) / characterWidth)
        let addressCharacters = 18
        var byteInRow: Int?
        var component = 0

        if mode == .hexadecimal {
            let relative = character - addressCharacters
            if relative >= 0, relative < 16 * 3 {
                let cellCharacter = relative % 3
                if cellCharacter < 2 {
                    byteInRow = relative / 3
                    component = cellCharacter
                }
            } else {
                let asciiStart = addressCharacters + 16 * 3 + 1
                if character >= asciiStart, character < asciiStart + 16 {
                    byteInRow = character - asciiStart
                }
            }
        } else {
            let relative = character - addressCharacters
            if relative >= 0, relative < bytesPerRow * 9 {
                let cellCharacter = relative % 9
                if cellCharacter < 8 {
                    byteInRow = relative / 9
                    component = cellCharacter
                }
            }
        }

        guard let byteInRow else { return }
        let offset = row * bytesPerRow + byteInRow
        guard offset < store.count else { return }
        selectedOffset = offset
        selectedLength = 1
        selectedComponent = component
        needsDisplay = true
        onSelectionChanged?()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123: moveSelection(delta: -1)
        case 124: moveSelection(delta: 1)
        case 125: moveSelection(delta: bytesPerRow)
        case 126: moveSelection(delta: -bytesPerRow)
        default:
            guard isEditable else {
                NSSound.beep()
                return
            }
            guard let character = event.charactersIgnoringModifiers?.uppercased().first else {
                super.keyDown(with: event)
                return
            }
            if mode == .hexadecimal, let value = character.hexDigitValue {
                editHexNibble(UInt8(value))
            } else if mode == .binary, character == "0" || character == "1" {
                editBinaryBit(character == "1")
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @objc func copy(_ sender: Any?) {
        let range = selectedByteRange
        guard range.length > 0, range.location < store.count else {
            NSSound.beep()
            return
        }
        let end = min(store.count, NSMaxRange(range))
        let bytes = store.data(in: range.location..<end)
        let value: String
        if mode == .hexadecimal {
            value = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        } else {
            value = bytes.map {
                String($0, radix: 2).leftPadding(toLength: 8, with: "0")
            }.joined(separator: " ")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard isEditable,
              let offset = selectedOffset,
              let value = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }

        var replacement = Data()
        if mode == .hexadecimal {
            let normalized = value
                .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
                .filter { !$0.isWhitespace && $0 != "," && $0 != "_" }
            guard !normalized.isEmpty,
                  normalized.count.isMultiple(of: 2),
                  normalized.allSatisfy(\.isHexDigit) else {
                NSSound.beep()
                return
            }
            var index = normalized.startIndex
            while index < normalized.endIndex {
                let end = normalized.index(index, offsetBy: 2)
                guard let byte = UInt8(normalized[index..<end], radix: 16) else {
                    NSSound.beep()
                    return
                }
                replacement.append(byte)
                index = end
            }
        } else {
            let normalized = value.filter { !$0.isWhitespace && $0 != "_" }
            guard !normalized.isEmpty,
                  normalized.count.isMultiple(of: 8),
                  normalized.allSatisfy({ $0 == "0" || $0 == "1" }) else {
                NSSound.beep()
                return
            }
            var index = normalized.startIndex
            while index < normalized.endIndex {
                let end = normalized.index(index, offsetBy: 8)
                guard let byte = UInt8(normalized[index..<end], radix: 2) else {
                    NSSound.beep()
                    return
                }
                replacement.append(byte)
                index = end
            }
        }
        replaceBytes(replacement, at: offset)
    }

    private func editHexNibble(_ nibble: UInt8) {
        guard let offset = selectedOffset, let oldByte = store.byte(at: offset) else { return }
        let newByte = selectedComponent == 0
            ? (oldByte & 0x0F) | (nibble << 4)
            : (oldByte & 0xF0) | nibble
        apply(byte: newByte, oldByte: oldByte, at: offset)
        if selectedComponent == 0 {
            selectedComponent = 1
        } else {
            selectedComponent = 0
            moveSelection(delta: 1)
        }
    }

    private func editBinaryBit(_ enabled: Bool) {
        guard let offset = selectedOffset, let oldByte = store.byte(at: offset) else { return }
        let mask = UInt8(1 << (7 - selectedComponent))
        let newByte = enabled ? oldByte | mask : oldByte & ~mask
        apply(byte: newByte, oldByte: oldByte, at: offset)
        if selectedComponent == 7 {
            selectedComponent = 0
            moveSelection(delta: 1)
        } else {
            selectedComponent += 1
        }
    }

    private func apply(byte: UInt8, oldByte: UInt8, at offset: Int) {
        guard byte != oldByte else {
            needsDisplay = true
            return
        }
        do {
            try store.replaceByte(at: offset, with: byte)
            undoManager?.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    guard let current = target.store.byte(at: offset) else { return }
                    target.apply(byte: oldByte, oldByte: current, at: offset)
                }
            }
            needsDisplay = true
            onBytesChanged?()
        } catch {
            NSSound.beep()
        }
    }

    private func replaceBytes(_ bytes: Data, at offset: Int) {
        guard !bytes.isEmpty, offset >= 0, offset + bytes.count <= store.count else {
            NSSound.beep()
            return
        }
        let range = offset..<(offset + bytes.count)
        let oldBytes = store.data(in: range)
        guard oldBytes != bytes else { return }
        do {
            try store.replaceBytes(in: range, with: bytes)
            undoManager?.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    target.replaceBytes(oldBytes, at: offset)
                }
            }
            selectedOffset = offset
            selectedLength = bytes.count
            selectedComponent = 0
            needsDisplay = true
            onBytesChanged?()
            onSelectionChanged?()
        } catch {
            NSSound.beep()
        }
    }

    private func moveSelection(delta: Int) {
        guard store.count > 0 else { return }
        let current = selectedOffset ?? 0
        selectedOffset = max(0, min(store.count - 1, current + delta))
        selectedLength = 1
        needsDisplay = true
        onSelectionChanged?()
        if let selectedOffset {
            let row = selectedOffset / bytesPerRow
            scrollToVisible(NSRect(x: 0, y: CGFloat(row) * lineHeight, width: 1, height: lineHeight))
        }
    }

    private func drawHighlights(rowOffset: Int, byteCount: Int, y: CGFloat) {
        for index in 0..<byteCount {
            let offset = rowOffset + index
            let color: NSColor?
            if let selectedOffset,
               offset >= selectedOffset,
               offset < selectedOffset + selectedLength {
                color = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.75)
            } else if isSearchHighlighted(offset) {
                color = NSColor.systemYellow.withAlphaComponent(0.55)
            } else {
                color = nil
            }
            guard let color else { continue }
            color.setFill()
            let addressWidth = CGFloat(18) * characterWidth
            if mode == .hexadecimal {
                NSRect(
                    x: horizontalPadding + addressWidth + CGFloat(index * 3) * characterWidth,
                    y: y + 1,
                    width: characterWidth * 2,
                    height: lineHeight - 2
                ).fill()
                NSRect(
                    x: horizontalPadding + CGFloat(18 + 16 * 3 + 1 + index) * characterWidth,
                    y: y + 1,
                    width: characterWidth,
                    height: lineHeight - 2
                ).fill()
            } else {
                NSRect(
                    x: horizontalPadding + addressWidth + CGFloat(index * 9) * characterWidth,
                    y: y + 1,
                    width: characterWidth * 8,
                    height: lineHeight - 2
                ).fill()
            }
        }
    }

    private func isSearchHighlighted(_ offset: Int) -> Bool {
        var lower = 0
        var upper = searchHighlights.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if searchHighlights[middle].location <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return false }
        let range = searchHighlights[lower - 1]
        return offset < NSMaxRange(range)
    }

    private func formattedLine(offset: Int, bytes: Data) -> String {
        let address = String(format: "%016llX  ", UInt64(offset))
        if mode == .binary {
            let bits = bytes.map { String($0, radix: 2).leftPadding(toLength: 8, with: "0") }
                .joined(separator: " ")
            return address + bits
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let padded = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
        let ascii = bytes.map { byte -> Character in
            (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        }
        return address + padded + "  " + String(ascii)
    }
}
