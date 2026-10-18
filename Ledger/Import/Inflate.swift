import Foundation

/// 纯 Swift 的 DEFLATE（RFC 1951）解压，用于读取 .xlsx（ZIP）文件，不依赖第三方库或 zlib。
/// 实现参考 zlib 的 puff.c：简单、正确优先，性能足够处理账单文件。
enum Inflate {
    enum InflateError: Error {
        case truncated
        case invalidBlockType
        case invalidStoredLength
        case invalidCode
        case invalidDistance
    }

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for len in lengths { count[len] += 1 }
            // o[len]：长度为 len 的第一个符号在 symbol 中的位置（长度 0 不参与）
            var o = [Int](repeating: 0, count: 16)
            o[1] = 0
            for len in 1..<15 { o[len + 1] = o[len] + count[len] }
            for (sym, len) in lengths.enumerated() where len != 0 {
                symbol[o[len]] = sym
                o[len] += 1
            }
        }
    }

    private struct State {
        let input: [UInt8]
        var pos = 0
        var bitBuf: UInt32 = 0
        var bitCnt = 0
        var out: [UInt8] = []

        init(input: [UInt8]) { self.input = input }

        mutating func bits(_ need: Int) throws -> Int {
            var val = bitBuf
            while bitCnt < need {
                guard pos < input.count else { throw InflateError.truncated }
                val |= UInt32(input[pos]) << UInt32(bitCnt)
                pos += 1
                bitCnt += 8
            }
            bitBuf = need >= 32 ? 0 : val >> UInt32(need)
            bitCnt -= need
            return Int(val & ((UInt32(1) << UInt32(need)) - 1))
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw InflateError.invalidCode
        }
    }

    private static let lbase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lext = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let dbase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                4097, 6145, 8193, 12289, 16385, 24577]
    private static let dext = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static let fixedTables: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0..<144 { lengths[i] = 8 }
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        for i in 280..<288 { lengths[i] = 8 }
        return (Huffman(lengths: lengths), Huffman(lengths: [Int](repeating: 5, count: 30)))
    }()

    /// 解压原始 DEFLATE 数据（无 zlib / gzip 头）
    static func inflate(_ data: Data, expectedSize: Int = 0) throws -> Data {
        var s = State(input: [UInt8](data))
        s.out.reserveCapacity(max(expectedSize, data.count * 3))
        var last = 0
        repeat {
            last = try s.bits(1)
            let type = try s.bits(2)
            switch type {
            case 0: try stored(&s)
            case 1: try codes(&s, fixedTables.0, fixedTables.1)
            case 2: try dynamic(&s)
            default: throw InflateError.invalidBlockType
            }
        } while last == 0
        return Data(s.out)
    }

    private static func stored(_ s: inout State) throws {
        s.bitBuf = 0
        s.bitCnt = 0
        guard s.pos + 4 <= s.input.count else { throw InflateError.truncated }
        let len = Int(s.input[s.pos]) | (Int(s.input[s.pos + 1]) << 8)
        let nlen = Int(s.input[s.pos + 2]) | (Int(s.input[s.pos + 3]) << 8)
        s.pos += 4
        guard len == (~nlen & 0xFFFF) else { throw InflateError.invalidStoredLength }
        guard s.pos + len <= s.input.count else { throw InflateError.truncated }
        s.out.append(contentsOf: s.input[s.pos..<(s.pos + len)])
        s.pos += len
    }

    private static func codes(_ s: inout State, _ lencode: Huffman, _ distcode: Huffman) throws {
        while true {
            var symbol = try s.decode(lencode)
            if symbol < 256 {
                s.out.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw InflateError.invalidCode }
                let len = lbase[symbol] + (try s.bits(lext[symbol]))
                let dsym = try s.decode(distcode)
                guard dsym < 30 else { throw InflateError.invalidDistance }
                let dist = dbase[dsym] + (try s.bits(dext[dsym]))
                guard dist <= s.out.count else { throw InflateError.invalidDistance }
                let start = s.out.count - dist
                for i in 0..<len { s.out.append(s.out[start + i]) }
            }
        }
    }

    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static func dynamic(_ s: inout State) throws {
        let nlen = try s.bits(5) + 257
        let ndist = try s.bits(5) + 1
        let ncode = try s.bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw InflateError.invalidCode }
        var lengths = [Int](repeating: 0, count: 19)
        for i in 0..<ncode { lengths[order[i]] = try s.bits(3) }
        let lencode = Huffman(lengths: lengths)

        var all = [Int](repeating: 0, count: nlen + ndist)
        var index = 0
        while index < nlen + ndist {
            let symbol = try s.decode(lencode)
            if symbol < 16 {
                all[index] = symbol
                index += 1
            } else {
                var len = 0
                var repeatCount: Int
                if symbol == 16 {
                    guard index > 0 else { throw InflateError.invalidCode }
                    len = all[index - 1]
                    repeatCount = 3 + (try s.bits(2))
                } else if symbol == 17 {
                    repeatCount = 3 + (try s.bits(3))
                } else {
                    repeatCount = 11 + (try s.bits(7))
                }
                guard index + repeatCount <= nlen + ndist else { throw InflateError.invalidCode }
                for _ in 0..<repeatCount { all[index] = len; index += 1 }
            }
        }
        guard all[256] != 0 else { throw InflateError.invalidCode }
        try codes(&s, Huffman(lengths: Array(all[0..<nlen])), Huffman(lengths: Array(all[nlen...])))
    }
}

/// 最小 ZIP 读取器（只读中央目录，支持 stored / deflate），用于 .xlsx
struct ZipArchive {
    struct Entry {
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: Error {
        case notZip
        case unsupportedMethod(Int)
        case corrupted
    }

    let bytes: [UInt8]
    let entries: [Entry]

    init(data: Data) throws {
        let b = [UInt8](data)
        bytes = b
        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }

        guard b.count >= 22, b[0] == 0x50, b[1] == 0x4B else { throw ZipError.notZip }
        // 查找中央目录结束记录（从尾部向前）
        var eocd = -1
        var i = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while i >= lowest {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var list: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014B50 else { throw ZipError.corrupted }
            let method = u16(p + 10)
            let csize = u32(p + 20)
            let usize = u32(p + 24)
            let nameLen = u16(p + 28)
            let extraLen = u16(p + 30)
            let commentLen = u16(p + 32)
            let offset = u32(p + 42)
            guard p + 46 + nameLen <= b.count else { throw ZipError.corrupted }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            list.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.lowercased() == name.lowercased() }
    }

    func data(for entry: Entry) throws -> Data {
        let o = entry.localHeaderOffset
        guard o + 30 <= bytes.count else { throw ZipError.corrupted }
        let nameLen = Int(bytes[o + 26]) | (Int(bytes[o + 27]) << 8)
        let extraLen = Int(bytes[o + 28]) | (Int(bytes[o + 29]) << 8)
        let start = o + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= bytes.count else { throw ZipError.corrupted }
        let raw = Data(bytes[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0: return raw
        case 8: return try Inflate.inflate(raw, expectedSize: entry.uncompressedSize)
        default: throw ZipError.unsupportedMethod(entry.method)
        }
    }
}
