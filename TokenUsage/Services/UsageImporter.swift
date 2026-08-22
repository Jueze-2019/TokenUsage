import Compression
import Foundation

enum UsageImportError: LocalizedError {
    case unreadableFile
    case invalidZip
    case missingAmountCSV
    case noRecords

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "文件无法读取"
        case .invalidZip: return "不是有效的 ZIP 文件"
        case .missingAmountCSV: return "压缩包中未找到 amount-*.csv"
        case .noRecords: return "未解析到任何用量记录"
        }
    }
}

/// 解析 DeepSeek 平台的用量导出 ZIP（含 amount-*.csv / cost-*.csv）。
/// amount CSV 列：user_id,start_time_iso,end_time_iso,model,api_key_name,api_key,type,price,amount
/// type ∈ input_cache_hit_tokens / input_cache_miss_tokens / output_tokens / request_count
enum UsageImporter {
    /// 导入结果：按 天×模型×Key 聚合的记录 + 文件的精确覆盖截止时间（CSV 中最大行时间戳）。
    /// coverageEnd 用于划分「导入为准 / 实时推算」的边界，避免导入覆盖今天时丢失导入后产生的消耗。
    struct ImportResult {
        let records: [UsageRecord]
        let coverageEnd: Date
    }

    static func importZIP(at url: URL) throws -> ImportResult {
        let entries = try ZipArchive.extract(from: url)
        guard let amountEntry = entries.first(where: {
            $0.name.hasPrefix("amount") && $0.name.hasSuffix(".csv")
        }) else {
            throw UsageImportError.missingAmountCSV
        }
        guard var text = String(data: amountEntry.data, encoding: .utf8) else {
            throw UsageImportError.unreadableFile
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() } // 去 BOM
        // 导出时刻 ≈ ZIP 文件修改时间（拿不到则用当前时间）：
        // 最后一天的数据桶是导出那一刻的部分数据，end_time_iso 标的是整天结束，
        // 覆盖边界取 min(最大 end_time_iso, 导出时刻)，避免与实时记录重复计数或留空档
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return try parseAmountCSV(text, exportedAt: fileDate ?? Date())
    }

    private static func parseAmountCSV(_ text: String, exportedAt: Date) throws -> ImportResult {
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw UsageImportError.noRecords }
        lines.removeFirst() // 表头

        let formatter = ISO8601DateFormatter()
        var byDay: [String: UsageRecord] = [:] // key = day|model|apiKeyName
        var maxEnd = Date.distantPast

        for line in lines {
            let cols = parseCSVLine(line)
            guard cols.count >= 9,
                  let timestamp = formatter.date(from: cols[1]) else { continue }
            let model = cols[3]
            let keyName = cols[4].isEmpty ? "未命名 Key" : cols[4]
            let type = cols[6]
            let amount = Int64(cols[8]) ?? 0
            // price 列为单 token 价格（元），request_count 行为空；price × amount = 真实消费
            let cost = (Double(cols[7]) ?? 0) * Double(amount)
            let day = Calendar.current.startOfDay(for: timestamp)
            if let end = formatter.date(from: cols[2]) { maxEnd = max(maxEnd, end) }
            let id = "\(day.timeIntervalSince1970)|\(model)|\(keyName)"

            var record = byDay[id] ?? UsageRecord(
                day: day, model: model, apiKeyName: keyName,
                inputCacheHit: 0, inputCacheMiss: 0, output: 0, requests: 0
            )
            // 掩码 API Key（sk-abc***xyz）：本地 Key 与平台 Key 名的精确归属依据
            if !cols[5].isEmpty { record.apiKeyMask = cols[5] }
            record.cost += cost
            switch type {
            case "input_cache_hit_tokens": record.inputCacheHit += amount
            case "input_cache_miss_tokens": record.inputCacheMiss += amount
            case "output_tokens": record.output += amount
            case "request_count": record.requests += amount
            default: break
            }
            byDay[id] = record
        }

        let records = byDay.values.sorted { $0.day < $1.day }
        if records.isEmpty { throw UsageImportError.noRecords }
        // 覆盖边界：最后一天桶的 end_time_iso 是整天结束（可能在未来），
        // 实际数据只到导出时刻；取 min 既不与实时记录重复计数，也不留空档
        let coverageEnd = maxEnd == .distantPast ? exportedAt : min(maxEnd, exportedAt)
        return ImportResult(records: records, coverageEnd: coverageEnd)
    }

    /// 引号感知的 CSV 行切分
    private static func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }
}

/// 极简 ZIP 解压（支持 stored / deflate，覆盖 DeepSeek 导出包）。
private struct ZipArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    static func extract(from url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url)
        guard data.count > 22 else { throw UsageImportError.invalidZip }

        func u16(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }

        // 从尾部扫描 End of Central Directory（PK\x05\x06）
        var eocd = -1
        let scanFloor = max(0, data.count - 65_557)
        var i = data.count - 22
        while i >= scanFloor {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw UsageImportError.invalidZip }

        let entryCount = u16(eocd + 10)
        var offset = u32(eocd + 16)
        var entries: [Entry] = []

        for _ in 0..<entryCount {
            // Central directory entry（PK\x01\x02）
            guard data[offset] == 0x50, data[offset + 1] == 0x4B,
                  data[offset + 2] == 0x01, data[offset + 3] == 0x02 else {
                throw UsageImportError.invalidZip
            }
            let method = u16(offset + 10)
            let compressedSize = u32(offset + 20)
            let uncompressedSize = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let localOffset = u32(offset + 42)
            let name = String(
                data: data.subdata(in: offset + 46 ..< offset + 46 + nameLength),
                encoding: .utf8
            ) ?? ""

            // Local file header（PK\x03\x04）
            guard data[localOffset] == 0x50, data[localOffset + 1] == 0x4B,
                  data[localOffset + 2] == 0x03, data[localOffset + 3] == 0x04 else {
                throw UsageImportError.invalidZip
            }
            let localNameLength = u16(localOffset + 26)
            let localExtraLength = u16(localOffset + 28)
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            let compressed = data.subdata(in: dataStart ..< dataStart + compressedSize)

            let payload: Data
            switch method {
            case 0: // stored
                payload = compressed
            case 8: // deflate
                payload = try inflate(compressed, expectedSize: uncompressedSize)
            default:
                throw UsageImportError.invalidZip
            }
            entries.append(Entry(name: name, data: payload))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { buffer.deallocate() }
        let written = data.withUnsafeBytes { src -> Int in
            guard let base = src.baseAddress else { return 0 }
            return compression_decode_buffer(
                buffer, expectedSize,
                base.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { throw UsageImportError.invalidZip }
        return Data(bytes: buffer, count: written)
    }
}
