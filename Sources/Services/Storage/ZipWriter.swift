import Foundation

/// 最小的 ZIP 打包器：**只存不压**（store，method 0），零第三方依赖。
///
/// ★ 2026-11-04（用户："把我当前总结、思维导图、待办都进行分享出去打包方式"）：
/// iOS 没有系统级 ZIP 写入 API（`FileManager` 那个 `zipItem` 只在 macOS），
/// 而这里要打的东西是 .md / .txt（几 KB）、.png 和 .m4a（本来就压过）——
/// 再走一次 deflate 收益接近零，还要背上一个几万行的压缩库。
///
/// 所以只实现 ZIP 的"容器"部分：本地头 + 中央目录 + 结尾记录，CRC32 自己算。
/// 产物是标准 zip，macOS 归档工具、Windows 资源管理器、任何解压软件都能直接打开。
struct ZipWriter {

    private struct Entry {
        var name: String
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
        var time: UInt16
        var date: UInt16
    }

    private var body = Data()
    private var entries: [Entry] = []

    /// 统一用 UTF-8 文件名位（bit 11），中文文件名在旧解压软件里也不会乱码。
    private static let utf8Flag: UInt16 = 0x0800

    mutating func add(_ name: String, data: Data, modified: Date = Date()) {
        let (time, date) = Self.dosStamp(modified)
        let crc = Self.crc32(data)
        let offset = UInt32(body.count)
        let nameBytes = Data(name.utf8)

        body.append(contentsOf: Self.le32(0x0403_4b50))       // local file header
        body.append(contentsOf: Self.le16(20))               // version needed
        body.append(contentsOf: Self.le16(Self.utf8Flag))
        body.append(contentsOf: Self.le16(0))                // method: store
        body.append(contentsOf: Self.le16(time))
        body.append(contentsOf: Self.le16(date))
        body.append(contentsOf: Self.le32(crc))
        body.append(contentsOf: Self.le32(UInt32(data.count)))
        body.append(contentsOf: Self.le32(UInt32(data.count)))
        body.append(contentsOf: Self.le16(UInt16(nameBytes.count)))
        body.append(contentsOf: Self.le16(0))                // extra length
        body.append(nameBytes)
        body.append(data)

        entries.append(Entry(name: name, crc: crc, size: UInt32(data.count),
                             offset: offset, time: time, date: date))
    }

    mutating func add(_ name: String, text: String, modified: Date = Date()) {
        add(name, data: Data(text.utf8), modified: modified)
    }

    func finish() -> Data {
        var out = body
        let cdStart = UInt32(out.count)

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            out.append(contentsOf: Self.le32(0x0201_4b50))    // central directory header
            out.append(contentsOf: Self.le16(20))             // version made by
            out.append(contentsOf: Self.le16(20))             // version needed
            out.append(contentsOf: Self.le16(Self.utf8Flag))
            out.append(contentsOf: Self.le16(0))              // method: store
            out.append(contentsOf: Self.le16(entry.time))
            out.append(contentsOf: Self.le16(entry.date))
            out.append(contentsOf: Self.le32(entry.crc))
            out.append(contentsOf: Self.le32(entry.size))
            out.append(contentsOf: Self.le32(entry.size))
            out.append(contentsOf: Self.le16(UInt16(nameBytes.count)))
            out.append(contentsOf: Self.le16(0))              // extra
            out.append(contentsOf: Self.le16(0))              // comment
            out.append(contentsOf: Self.le16(0))              // disk number
            out.append(contentsOf: Self.le16(0))              // internal attrs
            out.append(contentsOf: Self.le32(0))              // external attrs
            out.append(contentsOf: Self.le32(entry.offset))
            out.append(nameBytes)
        }

        let cdSize = UInt32(out.count) - cdStart
        out.append(contentsOf: Self.le32(0x0605_4b50))        // end of central directory
        out.append(contentsOf: Self.le16(0))
        out.append(contentsOf: Self.le16(0))
        out.append(contentsOf: Self.le16(UInt16(entries.count)))
        out.append(contentsOf: Self.le16(UInt16(entries.count)))
        out.append(contentsOf: Self.le32(cdSize))
        out.append(contentsOf: Self.le32(cdStart))
        out.append(contentsOf: Self.le16(0))                  // comment length
        return out
    }

    // MARK: - Little-endian helpers

    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
         UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// ZIP 的时间戳是 MS-DOS 格式：日期从 1980 年起算，秒只有 2 秒精度。
    private static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980) - 1980
        let month = c.month ?? 1
        let day = c.day ?? 1
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = (c.second ?? 0) / 2
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        return (dosTime, dosDate)
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
