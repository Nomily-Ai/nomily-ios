import Combine
import Foundation

/// ★ 2026-10-28（饭耳逆向规格 §1.2「每日 token 用量热力图」）：
/// 按天累计大模型消耗，供设置页的贡献图式热力图展示。
///
/// 口径说明（诚实地写在存储里，UI 也照此措辞）：
/// - 三个云厂商（OpenAI/Claude/Gemini）与非流式网关会回 `usage`，但本项目
///   的请求链路有流式/分块/重试多条，**统一取 usage 需要改七处解析**，收益不值；
/// - 因此这里按 **字符数 × 0.62** 估算 token（0.62 = 本仓库已实测的中文
///   tokens/字符 比例，见 `LLMCompletionService.maxCharsPerRequest` 注释），
///   用于"哪天用了多少"的相对趋势，不做账单级精确值。
final class TokenUsageStore: ObservableObject {

    static let shared = TokenUsageStore()

    /// `yyyy-MM-dd` → 估算 token 数。
    @Published private(set) var daily: [String: Int] = [:]
    /// 当天调用次数（用于「这天没有用大模型」之外的明细）。
    @Published private(set) var callsByDay: [String: Int] = [:]

    private let queue = DispatchQueue(label: "com.nomily.app.tokenusage", qos: .utility)

    private init() { load() }

    /// 记一次完成：输入 + 输出字符数 → 估算 token。
    func record(inputChars: Int, outputChars: Int) {
        let tokens = Int(Double(max(0, inputChars + outputChars)) * 0.62)
        guard tokens > 0 else { return }
        let key = Self.dayKey(Date())
        daily[key, default: 0] += tokens
        callsByDay[key, default: 0] += 1
        persist()
    }

    /// 热力图用：最近 `days` 天（含今天）的 (日期, token) 序列，缺天补 0。
    func recent(days: Int) -> [(date: Date, tokens: Int, calls: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = Self.dayKey(date)
            return (date, daily[key] ?? 0, callsByDay[key] ?? 0)
        }
    }

    static func dayKey(_ date: Date) -> String {
        keyFormatter.string(from: date)
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - persistence

    private struct Snapshot: Codable {
        var daily: [String: Int]
        var calls: [String: Int]
    }

    private var url: URL {
        StorageLocations.root.appendingPathComponent("token-usage.json", isDirectory: false)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        daily = snap.daily
        callsByDay = snap.calls
    }

    private func persist() {
        let snap = Snapshot(daily: daily, calls: callsByDay)
        let target = url
        queue.async {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }
}
