import SwiftUI
import UserNotifications

/// Apple Watch 设置菜单（★ 2026-10-30 用户："点击 Nomily 里面设置的 apple watch
/// 手表表情需要放一个菜单而不是直接占满，因为这个相当于手表的设置"）。
///
/// 之前这一页**就是**表盘表情选择器本身：十几行表情铺满整页，而它其实是「手表设置」的
/// 入口——用户进来先该看到"有哪些可以设"，再点进去改。现在这一页是一张菜单：
/// 表盘表情（二级页 `WatchFaceStyleSettingsView`）、AI 怎么称呼你、定时录音、
/// 回顾摘要与待办。
struct WatchFacePickerView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var watch: WatchSyncService

    // ★ 2026-10-30：称呼草稿（从主设置页搬来，逻辑不变）。
    @State private var userNameDraft = ""

    /// 当前表情（菜单行右侧显示，让用户不用点进去就知道现在选的是哪个）。
    private var currentStyle: BotFaceStyle {
        BotFaceStyle.decode(configService.config.watchFaceStyle) ?? .calm
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WatchFaceStyleSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Label(L10n.Face.title, systemImage: "face.smiling")
                        Spacer(minLength: 0)
                        Text(currentStyle.title)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L10n.Face.menuFooter)
            }

            userNameSection

            timedRecordingSection

            recapSection
        }
        // 手表相关的一切都收在这一页，标题就是设备名。
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { userNameDraft = configService.config.userName ?? "" }
    }

    // MARK: - 回顾摘要（★ 2026-10-30）

    /// 用户："回顾摘要要支持在手机设置里面支持设置，在里面可以查看到待办，支持在手表里面
    /// 点击可以同步到手机的待办里面"。
    ///
    /// 开关关掉时不仅停止推送，还会把手机上那份「待发回顾」清空并推一次空列表——
    /// 否则手表上留着旧摘要，用户会以为开关没生效。
    private var recapSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { configService.config.watchRecapEnabled },
                set: { on in
                    configService.config.watchRecapEnabled = on
                    configService.saveNow()
                    watch.setRecapEnabled(on)
                }
            )) {
                Text(L10n.Recap.toggle)
            }
        } header: {
            Text(L10n.Recap.title)
        } footer: {
            Text(L10n.Recap.footer)
        }
    }

    // MARK: - AI 怎么称呼你（★ 2026-10-30 自主设置页搬入）

    /// 称呼。写进 `AppConfig.userName`，`JobRunners.withUserContext` 在每次
    /// 摘要时带给模型（数据全局，只是入口归到 Apple Watch 设置页）。
    /// ★ 2026-10-30（用户："AI 怎么称呼我我新增修改都没办法点击那个保存"）：
    ///   原来 onChange 每敲一个字就写进 config，「保存」的 disabled 条件
    ///   `draft == 已保存值` 恒成立 → 按钮永远点不了。改成：输入只动草稿，
    ///   保存按钮 / 键盘回车才落盘；草稿与已存值不同时按钮可用。
    private var userNameSection: some View {
        Section {
            HStack(spacing: 12) {
                TextField(L10n.Profile.userNamePlaceholder, text: $userNameDraft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(commitUserName)
                Button(L10n.Profile.save) {
                    commitUserName()
                }
                .font(.subheadline.weight(.semibold))
                .disabled(userNameDraft == (configService.config.userName ?? ""))
            }
        } header: {
            Text(L10n.Profile.userName)
        } footer: {
            Text(L10n.Profile.footer)
        }
    }

    private func commitUserName() {
        configService.config.userName = userNameDraft.isEmpty ? nil : userNameDraft
        configService.saveNow()
    }

    // MARK: - 定时录音（★ 2026-10-30 自主设置页搬入）

    /// 到点命令 **手表** 开录/停录（`TimedRecordingScheduler`）。只在装了
    /// 表 App 时能进到本页，正好与"只对手表有效"的语义对齐。
    private var timedRecordingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { configService.config.timedRecordingEnabled },
                set: { on in
                    configService.config.timedRecordingEnabled = on
                    configService.scheduleSave()
                    if on {
                        // 顺手要一次通知权限——手表迟迟没录上时的兜底提醒通道。
                        UNUserNotificationCenter.current().requestAuthorization(
                            options: [.alert, .sound]
                        ) { _, _ in }
                        TimedRecordingScheduler.shared.evaluate()
                    }
                }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.TimedRecording.enable)
                    InfoTip(text: L10n.TimedRecording.enableFooter)
                }
            }

            if configService.config.timedRecordingEnabled {
                DatePicker(
                    L10n.TimedRecording.start,
                    selection: Binding(
                        get: { Self.timeValue(configService.config.timedRecordingStart) },
                        set: { configService.config.timedRecordingStart = Self.timeString($0); configService.scheduleSave() }
                    ),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    L10n.TimedRecording.end,
                    selection: Binding(
                        get: { Self.timeValue(configService.config.timedRecordingEnd) },
                        set: { configService.config.timedRecordingEnd = Self.timeString($0); configService.scheduleSave() }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }

            if let notice = TimedRecordingScheduler.shared.lastNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.TimedRecording.title)
        } footer: {
            Text(L10n.TimedRecording.footer)
        }
    }

    private static func timeValue(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = parts.count == 2 ? parts[0] : 23
        comps.minute = parts.count == 2 ? parts[1] : 30
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func timeString(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 23, comps.minute ?? 30)
    }
}

/// Which expression the watch home face wears (Settings → Apple Watch → Home Face).
///
/// ★ added in 2026-10-16 revision thirteen (user: "the Nomily AI app's settings need one more
///    is a setting for the watch home screen's eye expressions, bringing the gork bot expressions from the earlier github into
///    the Nomily AI app's settings so their expressions can be used").
///
/// ★ 2026-10-20 extended with three more settings (user: "more expressions, and let the phone
///    set its colour and blink pace, show the square frame, and let the face change on its own"):
///    auto-cycle toggle, blink pace, eye colour, square frame. All four ride the same
///    `updateApplicationContext` as the style (see `WatchSyncService.sendFaceSettings` — that
///    call *replaces* the whole context, so every push must carry all five keys).
///
/// ★ 2026-10-30 二稿（用户："点击设置的 apple watch 手表表情需要放一个菜单而不是
/// 直接占满，因为这个相当于手表的设置"）：本页退回**二级页**——Apple Watch 菜单
/// （`WatchFacePickerView`）才是总入口，表情选择、闪烁节奏、颜色、方框都在这里改。
///
/// ## One row = one expression, and the left is what it **really** looks like
/// The left of each row isn't an icon or text but **a directly drawn pair of eyes** —
/// and it uses **exactly the same** drawing code as on the watch (`BotFacePair`).
///
/// ⚠️ This is the one thing on this page worth being strict about: an expression is something **you can't pin down by name**.
///    "Shy" and "Sad" both take a sentence to explain in Chinese, yet drawn out they're told apart at a glance.
///    More importantly, if the preview and the real hardware each drew their own, the user would pick a smiling eye on the phone
///    and find a droopy one on raising the wrist — so sharing the same code in one file across both sides isn't about saving effort,
///    it's a **correctness** requirement (the reasoning is at the top of `BotFaceStyle`).
///
/// ## Why the previews sit on a dark chip when a colour is picked
/// The watch home face is drawn on the watch's dark screen. In light phone mode the form row is
/// near-white, so a white/pale eye colour would be invisible right where the user is choosing it.
/// When a custom colour is in force the preview therefore gets a small dark chip behind it —
/// the closest a phone row gets to the real surface. No colour picked (`nil`) keeps the plain
/// foreground-colour preview, same as before.
struct WatchFaceStyleSettingsView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var watch: WatchSyncService

    /// The currently selected option. Never stored = `calm` (must match the watch side's default,
    /// otherwise what the phone shows and what the watch draws won't line up).
    private var chosen: BotFaceStyle {
        BotFaceStyle.decode(configService.config.watchFaceStyle) ?? .calm
    }

    /// The eye colour in force. `nil` = "follow watch" (the watch's own Appearance pick).
    /// Only well-formed hex counts — a malformed stored value means "unset", never black.
    private var chosenColorHex: String? {
        Self.validHex(configService.config.watchEyeColor)
    }

    private var chosenBlink: BotBlinkSpeed {
        BotBlinkSpeed(rawValue: configService.config.watchBlinkSpeed ?? "") ?? .normal
    }

    var body: some View {
        Form {
            Section {
                ForEach(BotFaceStyle.allCases) { style in
                    row(style)
                }
            } header: {
                Text(L10n.Face.title)
            } footer: {
                Text(L10n.Face.footer)
            }

            Section {
                Toggle(L10n.Face.autoCycle, isOn: Binding(
                    get: { configService.config.watchFaceAutoCycle ?? true },
                    set: { configService.config.watchFaceAutoCycle = $0; persistAndPush() }
                ))
            } footer: {
                Text(L10n.Face.autoCycleFooter)
            }

            Section {
                Picker(L10n.Face.blinkSpeed, selection: Binding(
                    get: { chosenBlink },
                    set: { configService.config.watchBlinkSpeed = $0.rawValue; persistAndPush() }
                )) {
                    ForEach(BotBlinkSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.Face.blinkSpeed)
            }

            Section {
                colorSwatches
            } header: {
                Text(L10n.Face.eyeColor)
            }

            // ★ 2026-10-30（用户第二次点名，截图指定："是删除这个里面的方框"）：
            //   「方框」开关整行撤掉——眼睛外圈那个圆角方框功能本身下线。
            //   推送侧保持"不显示"（`watchFaceFrame = false`），旧手表端收到
            //   false 不会画框；watchFaceFrame 字段保留只为旧配置解码。
        }
        // ★ 2026-10-30 二稿：本页退回「表盘表情」二级页——Apple Watch 菜单页
        // 才是手表设置的总入口（用户："不要直接占满"）。
        .navigationTitle(L10n.Face.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Expression row

    private func row(_ style: BotFaceStyle) -> some View {
        Button {
            choose(style)
        } label: {
            HStack(spacing: 12) {
                preview(style)

                Text(style.title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if style == chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.appAccent)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(style == chosen ? [.isSelected] : [])
    }

    /// The drawn eyes, on a dark chip when a custom colour makes that necessary (see the header comment).
    ///
    /// ★ 2026-10-20 (second pass): the square frame is drawn here too, through the same
    /// shared `BotFaceFrame` the watch uses. Before this the preview showed bare eyes
    /// while the watch wrapped them in a frame — the user tuned expressions against a
    /// picture that didn't match the device, and the frame itself had no preview at all.
    @ViewBuilder
    private func preview(_ style: BotFaceStyle) -> some View {
        let tint = chosenColorHex.map { Color(botHex: $0) } ?? Color.primary
        let frameOn = configService.config.watchFaceFrame ?? true
        let face = ZStack {
            if frameOn {
                BotFaceFrame(size: Self.previewSize, tint: tint)
            }
            BotFacePair(style: style, size: Self.previewSize, tint: tint)
        }
        if chosenColorHex != nil {
            face
                .frame(width: Self.previewBoxWidth, height: Self.previewBoxWidth, alignment: .center)
                .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            face
                .frame(width: Self.previewBoxWidth, alignment: .center)
        }
    }

    // MARK: - Colour swatches

    /// A fixed, friendly palette. These ride the wire as `RRGGBB` hex (no `#`),
    /// the same shape `WatchFaceStore.applySettings` validates on the watch side.
    private static let palette: [String] = [
        "FFFFFF", // white — the classic on the dark watch screen
        "E41D25", // brand red
        "FF7A45", // orange
        "FFD60A", // yellow
        "34C759", // green
        "00C7BE", // teal
        "0A84FF", // blue
        "5E5CE6", // indigo
        "BF5AF2", // purple
        "FF375F", // pink
    ]

    @ViewBuilder
    private var colorSwatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 10)], spacing: 12) {
            followWatchSwatch
            ForEach(Self.palette, id: \.self) { hex in
                colorSwatch(hex)
            }
        }
        .padding(.vertical, 4)
    }

    /// The "don't override the watch" option: a hollow, dashed circle.
    private var followWatchSwatch: some View {
        Button {
            configService.config.watchEyeColor = nil
            persistAndPush()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.swatchSize, height: Self.swatchSize)
                if chosenColorHex == nil {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Face.followWatch)
        .accessibilityAddTraits(chosenColorHex == nil ? [.isSelected] : [])
    }

    private func colorSwatch(_ hex: String) -> some View {
        let selected = chosenColorHex == hex
        return Button {
            configService.config.watchEyeColor = hex
            persistAndPush()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(botHex: hex))
                    .frame(width: Self.swatchSize, height: Self.swatchSize)
                if selected {
                    // The check rides on an outline so it stays visible on light AND dark swatches.
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                        .frame(width: Self.swatchSize + 8, height: Self.swatchSize + 8)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(white: 0.1).opacity(0.9))
                        .shadow(color: .white.opacity(0.9), radius: 1.2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(hex))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Persist + push

    /// Every change on this page goes through here: write to disk **now** (a tap, not a drag —
    /// and pushing depends on the value being persisted, the watch may not wake for minutes),
    /// then push the **complete** five-key bundle (the context call replaces wholesale).
    private func persistAndPush() {
        configService.saveNow()
        watch.sendFaceSettings(
            style: chosen.rawValue,
            colorHex: chosenColorHex,
            blinkSpeed: chosenBlink.rawValue,
            autoCycle: configService.config.watchFaceAutoCycle ?? true,
            frameVisible: configService.config.watchFaceFrame ?? true
        )
    }

    private func choose(_ style: BotFaceStyle) {
        guard style != chosen else { return }
        configService.config.watchFaceStyle = style.rawValue
        persistAndPush()
    }

    private static func validHex(_ value: String?) -> String? {
        guard let value, isValidFaceHex(value) else { return nil }
        return value
    }

    /// The nominal edge length of the preview face.
    ///
    /// ⚠️ This isn't the size on the watch (there it's 0.76 of the screen width, about 119pt on a 40mm).
    ///    What's taken here is the level that "fits in a phone row yet still shows the shape differences":
    ///    at 40pt the idle eyes are about 9.4 × 15pt, and the arc option's stroke width is about 3pt —
    ///    any smaller and you can't tell `listen` from `scan`.
    private static let previewSize: CGFloat = 40
    /// The width of the preview column. A little wider than the widest option (the eye cluster is about 40pt).
    private static let previewBoxWidth: CGFloat = 52
    /// Diameter of one colour swatch.
    private static let swatchSize: CGFloat = 30
}
