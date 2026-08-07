import Foundation

enum ByteStoreError: LocalizedError {
    case invalidRange
    case replacementLengthMismatch

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "字节范围超出文件大小。"
        case .replacementLengthMismatch:
            return "Hex/Binary模式当前只支持相同字节数的覆盖替换。"
        }
    }
}

struct ByteSearchBatch {
    let offsets: [Int]
    let nextPosition: Int
    let isFinished: Bool
}

struct ByteStoreSnapshot: @unchecked Sendable {
    let baseData: Data
    let changes: [Int: UInt8]
    let revision: Int
    private let changeOffsets: [Int]

    init(baseData: Data, changes: [Int: UInt8], revision: Int) {
        self.baseData = baseData
        self.changes = changes
        self.revision = revision
        changeOffsets = changes.keys.sorted()
    }

    var count: Int { baseData.count }

    func data(in range: Range<Int>) -> Data {
        let lower = max(0, min(count, range.lowerBound))
        let upper = max(lower, min(count, range.upperBound))
        guard !changes.isEmpty else { return Data(baseData[lower..<upper]) }
        var result = Data(baseData[lower..<upper])
        var index = lowerBound(of: lower)
        while index < changeOffsets.count {
            let offset = changeOffsets[index]
            if offset >= upper { break }
            if let byte = changes[offset] {
                result[offset - lower] = byte
            }
            index += 1
        }
        return result
    }

    private func lowerBound(of value: Int) -> Int {
        var lower = 0
        var upper = changeOffsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if changeOffsets[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

final class ByteStore {
    private var baseData: Data
    private var changes: [Int: UInt8] = [:]
    private var sortedChangeOffsets: [Int]?
    private(set) var revision = 0

    init(data: Data) {
        baseData = data
    }

    var count: Int { baseData.count }
    var isModified: Bool { !changes.isEmpty }

    func byte(at offset: Int) -> UInt8? {
        guard baseData.indices.contains(offset) else { return nil }
        return changes[offset] ?? baseData[offset]
    }

    func data(in range: Range<Int>) -> Data {
        let lower = max(0, min(count, range.lowerBound))
        let upper = max(lower, min(count, range.upperBound))
        var result = Data(baseData[lower..<upper])
        let offsets = orderedChangeOffsets()
        var index = lowerBound(of: lower, in: offsets)
        while index < offsets.count {
            let offset = offsets[index]
            if offset >= upper { break }
            if let byte = changes[offset] {
                result[offset - lower] = byte
            }
            index += 1
        }
        return result
    }

    func replaceByte(at offset: Int, with byte: UInt8) throws {
        guard baseData.indices.contains(offset) else { throw ByteStoreError.invalidRange }
        guard (changes[offset] ?? baseData[offset]) != byte else { return }
        if baseData[offset] == byte {
            changes.removeValue(forKey: offset)
        } else {
            changes[offset] = byte
        }
        sortedChangeOffsets = nil
        revision += 1
    }

    func replaceBytes(in range: Range<Int>, with replacement: Data) throws {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw ByteStoreError.invalidRange
        }
        guard range.count == replacement.count else {
            throw ByteStoreError.replacementLengthMismatch
        }
        for (index, byte) in replacement.enumerated() {
            try replaceByte(at: range.lowerBound + index, with: byte)
        }
    }

    func reset(with data: Data) {
        baseData = data
        changes.removeAll(keepingCapacity: false)
        sortedChangeOffsets = nil
        revision += 1
    }

    func materializedData() -> Data {
        if changes.isEmpty { return baseData }
        return data(in: 0..<count)
    }

    func snapshot() -> ByteStoreSnapshot {
        ByteStoreSnapshot(baseData: baseData, changes: changes, revision: revision)
    }

    func search(
        for query: Data,
        fromPosition: Int,
        direction: Int,
        byteLimit: Int,
        maximumCount: Int
    ) -> ByteSearchBatch {
        guard !query.isEmpty else {
            return ByteSearchBatch(offsets: [], nextPosition: 0, isFinished: true)
        }
        let forward = direction >= 0
        let start = max(0, min(count, fromPosition))
        let limit = max(1, byteLimit)
        let matchLimit = max(1, maximumCount)
        let boundary = forward ? min(count, start + limit) : max(0, start - limit)
        let overlap = max(0, query.count - 1)
        let readStart = forward ? start : max(0, boundary - overlap)
        let readEnd = forward ? min(count, boundary + overlap) : start
        let bytes = data(in: readStart..<readEnd)
        var offsets: [Int] = []

        if forward {
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex, offsets.count < matchLimit,
                  let range = bytes.range(of: query, in: cursor..<bytes.endIndex) {
                let absolute = readStart + range.lowerBound
                if boundary < count, absolute >= boundary { break }
                offsets.append(absolute)
                cursor = max(range.upperBound, range.lowerBound + 1)
            }
        } else {
            var upper = bytes.endIndex
            while upper > bytes.startIndex, offsets.count < matchLimit,
                  let range = bytes.range(of: query, options: .backwards, in: bytes.startIndex..<upper) {
                let absolute = readStart + range.lowerBound
                if boundary > 0, absolute + query.count <= boundary { break }
                offsets.append(absolute)
                upper = range.lowerBound
            }
        }

        let reachedLimit = offsets.count >= matchLimit
        let nextPosition: Int
        if reachedLimit, let last = offsets.last {
            nextPosition = forward ? last + query.count : last
        } else {
            nextPosition = boundary
        }
        return ByteSearchBatch(
            offsets: offsets,
            nextPosition: nextPosition,
            isFinished: forward ? nextPosition >= count : nextPosition <= 0
        )
    }

    func write(to target: URL, chunkSize: Int = 4 * 1024 * 1024) throws {
        let fileManager = FileManager.default
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).mte-\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var offset = 0
            while offset < count {
                let end = min(count, offset + chunkSize)
                try handle.write(contentsOf: data(in: offset..<end))
                offset = end
            }
            try handle.synchronize()
            try handle.close()

            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
            baseData = try Data(contentsOf: target, options: [.mappedIfSafe])
            changes.removeAll(keepingCapacity: false)
            sortedChangeOffsets = nil
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func orderedChangeOffsets() -> [Int] {
        if let sortedChangeOffsets { return sortedChangeOffsets }
        let offsets = changes.keys.sorted()
        sortedChangeOffsets = offsets
        return offsets
    }

    private func lowerBound(of value: Int, in values: [Int]) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if values[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
