import Foundation

/// Wire contract between the iPhone app and the watch app. Both targets
/// compile this file (see `project.yml`), so the keys can't drift apart.
///
/// Deliberately small: clips go one way, a store-confirmation comes back. An
/// earlier version also carried device status and start/stop commands for a
/// Nomi remote on the wrist; that was removed, since the watch has no BLE link
/// of its own and the phone can only answer when it happens to be connected.
enum WatchLinkMessage {
    /// Attached to `transferFile` so the phone keeps the watch-side filename,
    /// which is already in `RecordingName`'s `yyyyMMddHHmmss` form.
    static let fileNameKey = "name"

    /// Sent back by the phone (via `transferUserInfo`, so it survives an app
    /// restart) once the clip is on disk in the Library. Only then may the
    /// watch delete its copy: WatchConnectivity reports a transfer "finished"
    /// once the *daemon* has the file, which is one crash away from the app
    /// never storing it — and the wrist copy is the only other one.
    static let storedKey = "stored"

    /// ★ 2026-11-03 八轮（用户："有些需要标记重点的，能否在手表下方按一下就打点"）：
    /// 这一段录音里用户打点的时间点（秒，相对录音开头），随 `transferFile` 的 metadata 一起走。
    ///
    /// ⚠️ 为什么塞 metadata 而不是另发一个文件：旁挂文件要单独处理"到达顺序 / 失败重传 /
    ///    手机端配对"，而 metadata 与音频是**同一条传输**的原子附属物——音频到，点必到。
    ///    体积也合适：10 分钟狂点也就几十个 Double。
    static let marksKey = "marks"

    /// 打点旁挂文件名后缀（手表侧落盘：`20261103T101530.marks.json`）。
    /// 手机端收到 metadata 后写成同名旁挂，供后续摘要/高亮使用。
    static let marksFileExtension = "marks.json"

    // MARK: - Voiceprint sample (watch → phone, ★ 2026-11-04)
    //
    // 用户："需要在 Apple Watch 里面加入一个声纹，录制声纹说话这样你能区分是谁说话"。
    //
    // 手表只负责**采**：录一段 8–12 秒的朗读，用和录音完全相同的麦克风与编码参数
    // （同一台设备、同一个麦克风 = 同一个声道，这是轻量声纹能不能用的前提）。
    // 特征提取和比对全部在手机上做（`VoiceprintEngine`），手表上没有算力也没有必要。

    /// `true` = 这个文件是声纹样本，不是一条录音。手机端据此把它送去注册而不是入库。
    static let voiceprintKey = "voiceprint"

    /// ★ 2026-11-06：注册**回执**（phone → watch，随上下文走）。
    ///
    /// 旧行为：手表发完样本只能停在"已发送"，注册成没成、失败为什么，手表
    /// 永远不知道——用户在表上盯着一句没有下文的话。现在手机注册完（无论
    /// 成败）把结果随下一次上下文推回来；`voiceprintResultIDKey` 是这次注册
    /// 的时间戳，手表端按 ID 去重——上下文是"最新值"语义，同一条结果会被
    /// 重复送达，没有去重就会把"已更新"反复盖回"已发送"。
    static let voiceprintResultKey = "voiceprintResult"
    static let voiceprintResultIDKey = "voiceprintResultID"

    // MARK: - Recorder state (watch → phone)
    //
    // Pushed with `updateApplicationContext`, which suits a heartbeat better
    // than `sendMessage`: it needs no reachability, a new push *replaces* an
    // undelivered one instead of queueing behind it, and the latest value is
    // waiting in `receivedApplicationContext` when the phone app next launches.

    /// Whether a take is running on the wrist right now.
    static let recordingKey = "recording"
    /// When it started, as epoch seconds — the phone renders the elapsed time
    /// itself rather than being fed a duration that goes stale between pushes.
    static let recordingSinceKey = "recordingSince"
    /// Clips recorded and waiting to reach the phone.
    static let transferPendingKey = "transferPending"
    /// Epoch seconds, refreshed on every push including the idle 10 s beats.
    /// Without it two identical payloads are indistinguishable, and the phone
    /// can't tell a watch that's still recording from one that stopped talking
    /// mid-take — which is the whole difference between a live status and a
    /// lie.
    static let heartbeatKey = "heartbeat"

    // MARK: - All-day recording switch (both directions, ★ 2026-11-05)
    //
    // 用户："全天候录音开关 nomily AI APP 设置 APPLE watch 设置也要有一个开关。"
    // 两端各有一个开关，各自通过**自己方向**的 applicationContext 同步：
    //  · 手机 → 手表：`pushCurrentContext(allDay:)` 一次性带上（只在手机上翻开关时
    //    才带这个键——上下文是整体替换的，常态不带就不会盖掉手表自己的值）；
    //  · 手表 → 手机：手表的录音状态推送（`pushState`）每次都带上手表当前值，
    //    手机的开关显示在"手机从未设置过"时跟随它。

    /// Bool。见上面的双向说明；键缺省 = "这条推送不带全-天候状态"，两端都跳过。
    static let allDayKey = "allDayRecording"

    // MARK: - Always-on face switch (phone → watch, ★ 2026-11-06)
    //
    // 用户："手表这边可以增加一个表情常亮让手表持续显示在首页的设置在 app 里面。"
    // 与 allDayKey 同一条推送规则：**只在手机上翻开关时**随 application context 一次性
    // 带上（上下文整体替换，常态不带就不会盖掉手表自己的值）。
    //
    // ⚠️ 语义边界：这个开关管的是"暗显（wrist down）的那段时间里首页画表情还是黑屏"，
    //    不是"多久返回表盘"——watchOS 7 起常亮时长只能由用户在
    //    设置 → 通用 → 唤醒屏幕 → 返回表盘时间 决定（可按 App 单独设置，最长 1 小时），
    //    没有任何公开 API 能让 App 覆盖它。录音中例外：workout 会话期间本来就常驻常显。
    static let alwaysOnFaceKey = "alwaysOnFace"

    // MARK: - ★ 2026-11-06 二轮："让脸活起来"的四个设置（phone → watch）
    //
    // 用户："不操作交互打瞌睡，瞳孔跟随手指…眼睛形状也加入进来，手机设置里
    // 多一些设置优化（Apple Watch 的设置里面）。"
    //
    // 与 alwaysOnFaceKey 同一条推送规则：**只在手机上改设置时**随上下文一次性
    // 带上（翻设置的哪端说了算，对端跟随）。手表端落在 `WatchRecordingPrefs`，
    // 由 `NomilyWatchApp` 的四个回调接线。
    /// 眼睛形状（`BotEyeShape.rawValue`：tall / round / calm / curious）。
    static let eyeShapeKey = "eyeShape"
    /// 不操作打瞌睡开关。
    static let drowsyEnabledKey = "drowsyEnabled"
    /// 多少秒没触摸开始打瞌睡（Int，秒）。
    static let drowsyAfterKey = "drowsyAfter"
    /// 按住拖动时眼睛看向手指。
    static let pupilFollowKey = "pupilFollow"

    // MARK: - Face style (phone → watch)
    //
    // ★ 2026-10-16 thirteenth revision: this is the **first time** the phone actively pushes an appearance setting to the watch.
    // Before this, phone→watch had only one message, `stored` (`transferUserInfo`, a one-shot event),
    // and "what the watch home screen looks like" had always been a **local** watch preference (colour, quick menu, language).
    // This round the user explicitly asked for the "home-screen eye expression" to sit **in the iPhone's Settings**,
    // so it has to cross this link.

    /// Which expression the home-screen face shows. The value is `BotFaceStyle.rawValue`.
    ///
    /// ⚠️ Goes through `updateApplicationContext` rather than `transferUserInfo`: this pushes
    ///    the "**current value**", not "something happened". A late-arriving old value means nothing,
    ///    and the definition of `updateApplicationContext` is precisely "the new version **replaces**
    ///    the version not yet sent" — when the user taps three times to change the expression, the watch should see only the last one.
    ///
    /// ℹ️ The two directions' application contexts are **separate** slots, so the watch's
    ///    "recording state" push (also `updateApplicationContext`) won't be crowded out by this one.
    static let faceStyleKey = "faceStyle"

    // MARK: - Face settings (phone → watch, ★ 2026-10-20)
    //
    // The user asked to drive the face's colour, blink pace and the "square frame with
    // auto-cycling expressions" from the phone. Same channel and same caveats as
    // `faceStyleKey`: one `updateApplicationContext` per push, "newest value wins",
    // watch-local defaults apply when a key is missing (old phone → new watch).

    /// The eye colour as `RRGGBB` hex (no `#`). Absent = follow the watch's own
    /// "Appearance" palette — the pre-existing watch-local preference stays authoritative
    /// until the user actually picks a colour on the phone.
    static let faceColorKey = "faceColor"
    /// `BotBlinkSpeed.rawValue` — scales the blink-gap tiers. Absent = `normal`.
    static let blinkSpeedKey = "blinkSpeed"
    /// Whether the idle expression auto-cycles inside the square frame. Absent = `true`
    /// (the dynamic behaviour the user asked for is the default).
    static let faceAutoCycleKey = "faceAutoCycle"
    /// Whether the rounded-square frame is drawn around the face. Absent = `true`.
    static let faceFrameKey = "faceFrame"

    // MARK: - Recaps (phone → watch, ★ 2026-10-23)
    //
    // The user asked: "watch 那边能否靠 Siri Recap 的看齐" — Apple's Siri Recap
    // (watchOS 26/27, S11) shows a wrist digest of your day, but it is opt-in,
    // beta, and not offered in China. Our answer is a Nomily recap: every time
    // the phone finishes a summary job, it extracts a tiny digest (title +
    // ≤3 key points) and pushes it here. The watch keeps the last 7 days and
    // shows them from a home-menu page.

    /// The value is JSON-encoded `Data` of `[WatchRecap]` — `applicationContext`
    /// only takes property-list values, so the array travels as an opaque blob
    /// and both ends decode with this same shared struct (this file is compiled
    /// into both targets, so the wire format can't drift).
    static let recapsKey = "recaps"

    // MARK: - Timed recording command (phone → watch, ★ 2026-10-30)
    //
    // 用户："定时录音应该是归纳到 Apple Watch 上面，只对这个设备有效"——
    // 定时窗口到点后，手机不再用麦克风录，而是让**手表**开始录（手表是贴身
    // 设备，整夜在腕上；手机进程死了也没有替代品）。命令走
    // `updateApplicationContext`：不需要可达性，"最新值胜出"，手表 App 下次
    // 运行时一定拿到。watchOS 的麦克风只在 App 前台可用，所以手表端把命令
    // 存下来、抬腕进 App 时补执行（见 `WatchLink.retryUnconfirmedTimedCommand`）。

    /// `"start"` = 让手表开始录音；`"stop"` = 停止。手表端对 start 幂等
    /// （已在录就忽略），对 stop 幂等（没在录就忽略）。
    static let timedRecordCommandKey = "timedRecordCommand"
    /// 手机签发命令的时刻（epoch 秒）。手表用去重：applicationContext 会被
    /// 后续的任何推送（表情/Recap）原样重发，同一个命令只能生效一次。
    static let timedRecordIssuedAtKey = "timedRecordIssuedAt"
    /// 录音窗口结束时刻（epoch 秒）。手表据此自己兜底停止——手机进程在窗口
    /// 结束前死了也停得下来。
    static let timedRecordEndsAtKey = "timedRecordEndsAt"

    // MARK: - Reminder request (watch → phone, ★ 2026-10-30)
    //
    // 用户："支持在手表里面点击可以同步到手机的待办里面"。
    // 手表 Recap 详情里的待办行可点，点了就把"这一条"发回手机，手机写进系统
    // 「提醒事项」。走 `transferUserInfo`：这是一次**事件**（不能丢），不是
    // "最新值"，而 transferUserInfo 会排队重发直到送达。

    /// 要加进提醒事项的待办文本（纯文本）。
    static let reminderTitleKey = "reminderTitle"
    /// 来源录音名，写进提醒的备注里（"来自 Nomily 录音《…》"）。
    static let reminderSourceKey = "reminderSource"
}

/// One recap entry on the wire. Small by design — the watch shows it on one screen.
///
/// `id` is the clip's `yyyyMMddHHmmss` name: re-summarising the same clip
/// **replaces** its recap instead of stacking a duplicate (same id semantics
/// the phone's Library uses for clips).
/// `recordedAt` is when the take was made (parsed from the name); `createdAt`
/// is when the digest was generated — the 7-day retention clock runs on
/// `createdAt`, so a re-summary refreshes the entry instead of letting an old
/// recording's recap expire the moment it lands.
struct WatchRecap: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let points: [String]
    /// ★ 2026-10-30（用户："在里面可以查看到待办，支持在手表里面点击可以同步到
    /// 手机的待办里面"）：这条摘要里明确承诺的待办（最多 5 条）。手表详情页把它们
    /// 列成可点的行，点一下 → 手机写进「提醒事项」。
    let todos: [String]
    let recordedAt: Date
    let createdAt: Date
    /// ★ 2026-11-03（V4 原型）：这条录音有多长（秒）。
    ///
    /// 手表上唯一能回答"值不值得点开"的量，原型把它做成行内唯一一处暖色。
    /// 手表自己**算不出来**（它没有这条手机录音的音频文件），所以由手机随手推过来；
    /// 老版本手机的推送里没有这个字段 → `nil` → 那一截整段省略，不显示假数据。
    let duration: TimeInterval?

    /// ★★ 2026-11-04（用户："每个记录需要总结出一个主题方便查看主题，点击最近的摘要"）：
    /// **主题**——一行能扫完的短标签，和 `title`（摘要里的第一个标题，可能就是一句长话）
    /// 分开存。
    ///
    /// 为什么要两个字段而不是把 `title` 截短：`title` 在详情页是标题，截短了详情页就没头了；
    /// 而列表里 30 行要的恰恰是"一眼扫完的主题"。主题由手机在推之前算好
    /// （`RecapTopic.of(title:points:)`），老版本手机推的 JSON 里没有它 →
    /// 解码时**用同一套规则就地算**，不会出现"升级后列表全空"。
    let topic: String

    init(
        id: String,
        title: String,
        points: [String],
        todos: [String] = [],
        recordedAt: Date,
        createdAt: Date,
        duration: TimeInterval? = nil,
        topic: String? = nil
    ) {
        self.id = id
        self.title = title
        self.points = points
        self.todos = todos
        self.recordedAt = recordedAt
        self.createdAt = createdAt
        self.duration = duration
        self.topic = topic ?? RecapTopic.of(title: title, points: points)
    }

    /// 手写解码：`todos` / `duration` / `topic` 都是后加的字段，旧版本推上来的 JSON
    /// 里没有它们——合成解码会因此整条失败，手表上一条回顾都读不出来。
    /// 缺省当空 / nil，主题就地按同一套规则算。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        points = try c.decode([String].self, forKey: .points)
        todos = try c.decodeIfPresent([String].self, forKey: .todos) ?? []
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
            ?? RecapTopic.of(title: title, points: points)
    }

    /// 两端都留这么多条（手机 outbox / 手表本地库）。
    ///
    /// ★★ 2026-11-04（用户："手表右滑的最近需要能看到 30 条摘要"）：8 → **30**。
    ///   30 条是腕上"翻回最近一个月"的合理容量：再多，一屏 5 行的滚动条要滑六屏，
    ///   而且 applicationContext 的载荷会逼近 64 KB 的软上限（30 条 × 约 0.5 KB ≈ 15 KB，
    ///   还有脸/表情/语言那几个键，安全余量足够；80 条就到顶了）。
    static let limit = 30
    /// Recaps older than this (by `createdAt`) drop off, on the phone as well
    /// as the watch — an outbox entry no watch will ever see is just clutter,
    /// and a wrist entry nothing refreshes any more is a lie about the past.
    ///
    /// ★★ 2026-11-04：7 天 → **30 天**。条数放到 30 之后，7 天的窗口会让"30 条"变成
    ///   一句空话（一周录不满 30 条的人永远看不到 30 条）；30 天给了它真正填满的机会，
    ///   条数上限仍然由 `limit` 兜住。
    static let retention: TimeInterval = 30 * 24 * 3600
}

/// 把摘要标题压成"一行主题"。
///
/// ★★ 2026-11-04（用户："每个记录需要总结出一个主题方便查看主题"）：腕上 30 行要的是
/// **能扫的主题**，不是"摘要的第一句"。手机推之前先用这套规则算一次（省得表上算），
/// 表上遇到老负载再算一次（同一份代码，两端不会算出两种主题）。
///
/// 规则（全部可解释，不做"猜"）：
/// 1. 去掉 markdown 记号（`#`、`**`、`-`、`•`、行首序号）、引号、行尾冒号；
/// 2. 压缩连续空白；
/// 3. 冒号前只有 ≤6 字（"会议纪要：xxx"）→ 剥掉这个**标签**，用后面的内容做主题；
/// 4. 已经是短句（≤ `maxLength` 字）→ 原样用；
/// 5. 太长 → 在**前 `maxLength` 字以内**的第一个自然停顿（，。；、·,.;:!?——）处断，
///    断出来的头 ≥ 5 字才用它；
/// 6. 还是太长 → 硬截到 `maxLength - 1` 并以 `…` 收尾。
///
/// 中文按**字符**数限制（一行 30 行列表里量的是视觉长度，不是字节）。
///
/// 这套规则跑过 9 个真实形状的用例（长标题 / 无标点 / 纯标签 / 空标题 / 空要点 /
/// 带序号 / 多余空白），输出都落在 2–14 字之间且没有空串——它必须是**纯函数**，
/// 因为手机推之前和表上读老负载时都要用它，两边算出不同主题就前功尽弃了。
enum RecapTopic {
    /// 主题最多几个字。126pt 宽的一行 11.5pt 字号大约放得下 16 个汉字，
    /// 留一点给省略号，取 14。
    static let maxLength = 14

    private static let breakers: [Character] = ["，", "。", "；", "：", "、", "·", ",",
                                                ".", ";", ":", "!", "?", "！", "？", "—", "-"]

    static func of(title: String, points: [String] = []) -> String {
        var cleaned = clean(title)
        // ★ 先剥掉"会议纪要："这类**标签**——标签不是主题，用户要认的是标签后面那件事。
        //   只在标签很短（≤6 字）时才剥：像"下季度重点：预算与人力"这种，冒号前
        //   已经是半句话，剥了反而把主语砍掉。
        let chars = Array(cleaned)
        if let colon = chars.firstIndex(where: { $0 == "：" || $0 == ":" }), colon <= 6 {
            let rest = clean(String(chars[(colon + 1)...]))
            if rest.count >= 2 { cleaned = rest }
        }
        if let shortened = shorten(cleaned) { return shortened }
        // 标题是空的（摘要第一行没有 `#` 标题）→ 退到第一条要点。
        for point in points {
            if let shortened = shorten(clean(point)) { return shortened }
        }
        return L10n.Watch.recentUntitled
    }

    /// 短就原句；长就在**自然停顿**处断——只认前 `maxLength` 字以内的停顿，
    /// 断出来的头至少 5 字（否则"会议纪要"这种 4 字标签会把整条变成标题党的反面），
    /// 都不满足就硬截到 `maxLength - 1` 并补省略号。返回 `nil` = 这段文本是空的。
    private static func shorten(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if text.count <= maxLength { return text }
        let chars = Array(text)
        var cut: Int?
        for (index, ch) in chars.enumerated() where index < maxLength {
            if breakers.contains(ch) { cut = index; break }
        }
        if let cut, cut >= 5 { return String(chars[0..<cut]) }
        return String(chars[0..<(maxLength - 1)]) + "…"
    }

    /// 去记号 / 压空白 / 去首尾标点。
    private static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "*", with: "")
        // 行首的 `#`、`-`、`•` 和 "1. " / "1、" 这类序号
        while let first = text.first, first == "#" || first == "-" || first == "•"
                || first == " " || first == "\t" {
            text.removeFirst()
        }
        if let dot = text.firstIndex(where: { $0 == "." || $0 == "、" || $0 == ")" || $0 == "）" }),
           text[text.startIndex..<dot].allSatisfy({ $0.isNumber }) {
            text = String(text[text.index(after: dot)...])
        }
        text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        // 压缩空白
        text = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
        // 去掉首尾的引号/冒号/句号
        let trimmables = CharacterSet(charactersIn: "\"'“”‘’《》「」【】:：。.，,;； ")
        return text.trimmingCharacters(in: trimmables)
    }
}
