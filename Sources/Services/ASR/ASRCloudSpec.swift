import Foundation

/// Cloud ASR vendors beyond Azure, as data rather than six more hand-written
/// settings sections.
///
/// 2026-10-22 request:
/// > "把 ASR 服务器里面增加谷歌、AWS、Deepgram、AssemblyAI、Gladia、IBM Watson
/// >  Speech to Text 这些，然后按照他们的给他们加入 logo 配置好入口测试延迟性，
/// >  跟对应模型选择"
///
/// The lesson from the LLM page applies here: six bespoke Forms would be six
/// slightly different behaviours for the same job (credentials → verify → model).
/// So each vendor is a **row of data**: which fields it needs, what its models are
/// called, and one brand logo. One sheet drives all six.
///
/// ⚠️ Scope note, deliberately explicit: these entries make the vendor
/// *configurable and provable* — credentials are validated against the real API
/// and the round trip is measured. **Wired into the transcription engine** so
/// far: Azure, and (2026-10-22) Aliyun file transcription. The rest are not yet
/// routed through `TranscriptionService`; wiring a vendor means writing its
/// audio upload + result parsing, which is a separate change per vendor.
struct ASRCloudSpec: Identifiable, Equatable {

    /// One credential field. `region` is stored in the config, everything else in
    /// the Keychain (see `SecretStore`'s keyed accessors).
    struct Field: Identifiable, Equatable {
        enum Kind: Equatable {
            /// API key / access key id — secret, Keychain.
            case secret
            /// Region, account id, host suffix — not secret, config.json.
            case plain
        }
        let id: String
        let kind: Kind
        /// English fallback; the UI prefers `asr.cloud.field.<id>` from L10n.
        let label: String
        let placeholder: String
        /// Keys that must be present before the probe can run.
        var required: Bool = true

        /// ★ 2026-11-05：凭据字段的标签/占位符翻译。上一版只有标签走了
        /// `L10n.ASRCloud.field`，而且键是**全局** `asr.cloud.field.<id>`——
        /// 但 `apiKey` 这类 id 六家共用，一家翻译会串味，所以干脆没建 en 键，
        /// 中文标签（"项目 Appkey"）就原样漏进了英文界面。改成按厂商命名空间：
        /// `asr.cloud.<vendor>.fields.<id>.label|.placeholder`，en 只需要给
        /// 原值是中文的那几条建键，其余回落（回落值本来就是英文）。
        func localizedLabel(vendor: String) -> String {
            NSLocalizedString("asr.cloud.\(vendor).fields.\(id).label", value: label, comment: "Credential field label")
        }
        func localizedPlaceholder(vendor: String) -> String {
            NSLocalizedString("asr.cloud.\(vendor).fields.\(id).placeholder", value: placeholder, comment: "Credential field placeholder")
        }
    }

    let id: String
    let name: String
    /// Asset-catalog name of the vendor's own logo (template, so it tints).
    let brandAsset: String
    /// One line under the name: what the vendor is good at.
    let tagline: String
    let fields: [Field]
    /// Pre-filled address. Empty = the address is derived (Watson builds it from
    /// the region).
    let defaultEndpoint: String
    let endpointEditable: Bool
    /// Shown before anything is fetched; the probe can replace `watson`/`deepgram`
    /// with the account's real list.
    let models: [String]
    /// Where the credential comes from.
    let console: String
    /// ★ 2026-11-02（用户："该有对应配置页面点击跳转而不是要用户手动输入网址"）：
    /// 控制台/创建 Key 页面的**可点链接**——`console` 里的文字路径告诉用户去哪，
    /// 这个字段是真正的那扇门。nil = 没有稳定入口页。
    let consoleURL: URL?
    /// Vendor-specific caveat.
    let note: String?

    // ★ 2026-10-29（饭耳规格 §1.1 价格/推荐元数据）：选型卡片的数据。
    // 价格是公开刊例的粗略换算（"约"字辈），厂商随时调价——只是**选型参考**，
    // 不是账单口径；没有把握的留 nil，UI 不显示。
    let pricePerHour: String?
    /// 厂商侧是否支持分说话人（说话人分离）。
    let supportsDiarization: Bool
    /// 选型建议短句："推荐 · 中文首选" / "偏贵" 等。nil = 中立。
    let recommendation: String?

    /// ★ 2026-11-06（饭耳 1.0 移植 P0-2）：**准确率口径**——厂商公布的中文
    /// CER / 英文 WER，形如「中文 CER 2.25% · 英文 WER 4.72%」。
    ///
    /// 为什么单独一个字段而不是塞进 `pricePerHour`：价格和精度是两个不同的问题
    /// （"便不便宜"与"准不准"），混在一行里用户没法比较。有数据的厂商才显示，
    /// 没有把握的一律 nil——**不编数字**，这条比"卡片看起来整齐"重要。
    var cerHint: String? = nil

    /// 价格 + 能力一行小字（"约 0.3 元/小时 · 分说话人"）。空 = 没有可靠数据。
    /// ★ 2026-11-05：价格走 `localizedPrice`——上一版直接用原始中文（"约 $0.3/小时"
    /// 里的"约"就是这么漏进英文界面的），`localizedPrice` 键缺失时回落原值，行为不变。
    var metaLine: String? {
        var parts: [String] = []
        if let localizedPrice { parts.append(localizedPrice) }
        if supportsDiarization { parts.append(L10n.ASRCloud.diarization) }
        // ★ 2026-11-06（P0-2）：精度跟在价格后面——"约 0.1 元/小时 · 分说话人 ·
        // 中文 CER 2.25%"正是饭耳卡片那一行的排法。
        if let localizedCerHint { parts.append(localizedCerHint) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Localized display strings（★ 2026-11-02，用户："设置英语为系统语言但是好多中文的都没翻译过来"）

    /// spec 数据以中文撰写（主要受众），英文 UI 从 en.lproj 读 `asr.cloud.<id>.*`
    /// 键，键缺失时回落到这里的中文值——zh-Hans 不需要建键。
    var localizedName: String { NSLocalizedString("asr.cloud.\(id).name", value: name, comment: "") }
    var localizedTagline: String { NSLocalizedString("asr.cloud.\(id).tagline", value: tagline, comment: "") }
    var localizedConsole: String { NSLocalizedString("asr.cloud.\(id).console", value: console, comment: "") }
    var localizedNote: String? {
        note.map { NSLocalizedString("asr.cloud.\(id).note", value: $0, comment: "") }
    }
    var localizedRecommendation: String? {
        recommendation.map { NSLocalizedString("asr.cloud.\(id).recommendation", value: $0, comment: "") }
    }
    var localizedPrice: String? {
        pricePerHour.map { NSLocalizedString("asr.cloud.\(id).price", value: $0, comment: "") }
    }
    var localizedCerHint: String? {
        cerHint.map { NSLocalizedString("asr.cloud.\(id).cer", value: $0, comment: "") }
    }

    /// ★ 2026-11-05（用户截图：英文界面下模型选择页全是中文）：
    /// `models` 里存的是**要发给 API 的真名**（"录音文件识别（Paraformer）"），
    /// 存进 config 的必须是原值——这里只翻译**显示层**。英文 UI 从 en 表读
    /// `asr.cloud.<id>.models.<序号>`，键缺失回落原值（zh-Hans 不用建键）。
    func localizedModel(_ raw: String) -> String {
        guard let index = models.firstIndex(of: raw) else { return raw }
        return NSLocalizedString("asr.cloud.\(id).models.\(index)", value: raw, comment: "")
    }

    /// ★ 2026-11-05：选型建议是不是"正面的"（绿色）。上一版用
    /// `recommendation.hasPrefix("推荐")` 判断——英文翻译不以"推荐"开头，
    /// 于是英文界面所有厂商都掉进橙色分支，"Recommended" 也显示成橙色。
    /// 数据侧只认中文原值的这个前缀（en 翻译爱怎么写怎么写）。
    var recommendationIsPositive: Bool {
        recommendation?.hasPrefix("推荐") ?? false
    }

    /// Tile colour, same shape as `LLMProviderSpec.tint`.
    /// ★ 2026-11-02（用户："asr 的这些模型图标要按照 Apple Store 的 app 图标来"）：
    /// 这批厂商的 `brandAsset` 已换成 App Store 官方 App 图标的**彩色位图**
    /// （渲染时不能套 template/白色着色）。腾讯云没有官方移动 App，微信生态
    /// 之外的 Deepgram / AssemblyAI / Gladia / Watson 也无消费级 App——保留单色瓦片。
    var usesAppStoreIcon: Bool {
        switch id {
        case "aliyun", "baidu", "xfyun", "google", "aws":
            return true
        default:
            return false
        }
    }

    var tint: (r: Double, g: Double, b: Double) {
        switch id {
        case "aliyun":     return (0.98, 0.43, 0.02)   // Aliyun orange
        case "baidu":      return (0.16, 0.20, 0.88)   // Baidu blue
        case "xfyun":      return (0.10, 0.36, 0.95)   // iFlytek blue
        case "tencent":    return (0.00, 0.32, 0.85)   // Tencent cloud blue
        case "google":     return (0.26, 0.52, 0.96)
        case "aws":        return (0.90, 0.55, 0.10)
        case "deepgram":   return (0.05, 0.62, 0.53)
        case "assemblyai": return (0.35, 0.34, 0.84)
        case "gladia":     return (0.13, 0.13, 0.15)
        default:           return (0.21, 0.31, 0.86)   // IBM Watson
        }
    }

    // ★ 2026-10-22 ("国内 ASR 语音也要加入进去"): the four Chinese vendors lead
    // the list — this app's primary audience transcribes Chinese, and scrolling
    // past six western vendors to reach Aliyun would read as an afterthought.
    static let all: [ASRCloudSpec] = [aliyun, baidu, xfyun, tencent,
                                      google, aws, deepgram, assemblyAI, gladia, watson]

    static func find(_ id: String) -> ASRCloudSpec? { all.first { $0.id == id } }

    // MARK: - Catalogue

    // ★ 2026-10-22: Aliyun is wired into the transcription engine
    // (`AliyunFileASR` — OSS upload → presigned link → SubmitTask → poll), so its
    // sheet shows a "wired" note instead of the not-wired scope warning.
    static let aliyun = ASRCloudSpec(
        id: "aliyun",
        name: "阿里云智能语音",
        brandAsset: "BrandAliyun",
        tagline: "Paraformer · 中文识别强项",
        fields: [
            Field(id: "accessKeyId", kind: .secret, label: "AccessKey ID",
                  placeholder: "LTAI…"),
            Field(id: "accessKeySecret", kind: .secret, label: "AccessKey Secret",
                  placeholder: "••••••••"),
            // Not part of the token probe (which only checks the AK pair), but
            // file transcription cannot run without them — re-validated when the
            // engine actually runs.
            Field(id: "appKey", kind: .plain, label: "项目 Appkey",
                  placeholder: "nls-portal 项目列表里的 Appkey", required: false),
            Field(id: "ossBucket", kind: .plain, label: "OSS Bucket",
                  placeholder: "与区域一致的 bucket 名", required: false),
            Field(id: "region", kind: .plain, label: "OSS Region",
                  placeholder: "cn-hangzhou（跟着 Bucket 走）", required: false),
        ],
        defaultEndpoint: "https://nls-meta.cn-shanghai.aliyuncs.com",
        endpointEditable: false,
        models: ["录音文件识别（Paraformer）", "一句话识别", "实时语音识别"],
        console: "① nls-portal.console.aliyun.com → 项目列表 拿 Appkey；② ram.console.aliyun.com 创建 AccessKey（需同时授权 OSS 读写）；③ 与区域一致建一个 OSS Bucket",
        consoleURL: URL(string: "https://nls-portal.console.aliyun.com/"),
        note: "转写流程：音频先上传到你的 OSS Bucket（私有），生成 2 小时有效的预签名链接交给阿里云识别（file_link 必须公网可下载，这是它的接口要求），识别完取回结果。这里填的是 **OSS 区域**（Bucket 建在杭州就填 cn-hangzhou）——填错会自动按 OSS 返回的 endpoint 纠正一次；实时字幕的网关区域与它无关，会自动归一化。实时字幕走它家的实时语音识别 WebSocket（同一个 Appkey），在「录音与转写 → 实时识别引擎」里选阿里云即可。",
        pricePerHour: "约 0.1 元/小时（百炼 qwen-audio）",
        supportsDiarization: true,
        recommendation: "推荐 · 中文首选",
        // ★ 2026-11-06（P0-2）：饭耳 1.0 卡片原文口径（FLEURS 测试集）。
        cerHint: "中文 CER 2.25% · 英文 WER 4.72%"
    )

    static let baidu = ASRCloudSpec(
        id: "baidu",
        name: "百度智能云语音",
        brandAsset: "BrandBaidu",
        tagline: "短语音识别 · 中文基础好",
        fields: [
            Field(id: "apiKey", kind: .secret, label: "API Key",
                  placeholder: "应用 API Key"),
            Field(id: "baiduSecretKey", kind: .secret, label: "Secret Key",
                  placeholder: "••••••••"),
        ],
        defaultEndpoint: "https://aip.baidubce.com",
        endpointEditable: false,
        models: ["短语音识别-标准版", "短语音识别-极速版", "远场语音识别"],
        console: "console.bce.baidu.com → 语音技术 → 应用列表（创建应用后才有 AK/SK）",
        consoleURL: URL(string: "https://console.bce.baidu.com/ai-engine/old/#/ai/speech/app/list"),
        note: "鉴权走 OAuth2：AK/SK 换 access_token，转写也用同一个 token，所以探测通过即代表凭据可用。",
        pricePerHour: "约 12 元/小时（短语音按秒计）",
        supportsDiarization: false,
        recommendation: "短语音为主 · 长音频偏贵"
    )

    static let xfyun = ASRCloudSpec(
        id: "xfyun",
        name: "讯飞开放平台",
        brandAsset: "BrandXfyun",
        tagline: "听写/转写 · 中文老牌",
        fields: [
            Field(id: "appId", kind: .plain, label: "APPID",
                  placeholder: "控制台里的 APPID"),
            Field(id: "apiKey", kind: .secret, label: "API Key",
                  placeholder: "APIKey"),
            Field(id: "apiSecret", kind: .secret, label: "API Secret",
                  placeholder: "••••••••"),
        ],
        defaultEndpoint: "https://iat-api.xfyun.cn/v2/iat",
        endpointEditable: false,
        models: ["听写 iat（短语音/实时）", "语音转写 asr（长音频）"],
        console: "console.xfyun.cn → 语音听写/语音转写 → 服务接口认证信息",
        consoleURL: URL(string: "https://console.xfyun.cn/"),
        note: "鉴权是 host+date 的 HMAC-SHA256 签名（date 与服务器时差要在 5 分钟内）。探测成功返回 HTTP 101——它家的识别入口是 WebSocket，握手通过即签名有效。",
        pricePerHour: "转写约 0.33 元/分钟",
        supportsDiarization: true,
        recommendation: "中文老牌 · 偏贵"
    )

    static let tencent = ASRCloudSpec(
        id: "tencent",
        name: "腾讯云语音识别",
        brandAsset: "BrandTencent",
        tagline: "录音文件/实时 · 一句话",
        fields: [
            Field(id: "secretId", kind: .secret, label: "SecretId",
                  placeholder: "AKID…"),
            Field(id: "tencentSecretKey", kind: .secret, label: "SecretKey",
                  placeholder: "••••••••"),
            Field(id: "region", kind: .plain, label: "Region",
                  placeholder: "ap-shanghai"),
        ],
        defaultEndpoint: "",
        endpointEditable: false,
        models: ["16k_zh 普通话", "16k_en 英语", "16k_yue 粤语", "16k_zh_medical 医疗"],
        console: "console.cloud.tencent.com → 访问管理 → API 密钥管理",
        consoleURL: URL(string: "https://console.cloud.tencent.com/cam/capi"),
        note: "地址固定 asr.tencentcloudapi.com，区域是请求参数（TC3-HMAC-SHA256 签名）。探测调 DescribeTaskStatus（不存在的任务 ID）——只验证签名，不上传音频；热词表接口（DescribeVocabList 等）已在 asr 2019-06-14 下线，不要用它做探测。",
        pricePerHour: "约 0.8 元/小时（录音识别大模型 2.0）",
        supportsDiarization: true,
        recommendation: "国内均衡 · 中英粤均可"
    )

    static let google = ASRCloudSpec(
        id: "google",
        name: "Google Cloud",
        brandAsset: "BrandGoogleCloud",
        tagline: "Speech-to-Text v1 · 125+ 语言",
        fields: [Field(id: "apiKey", kind: .secret, label: "API key",
                       placeholder: "AIza…")],
        defaultEndpoint: "https://speech.googleapis.com/v1",
        endpointEditable: false,
        models: ["latest_long", "latest_short", "phone_call", "video",
                 "command_and_search", "default"],
        console: "console.cloud.google.com → APIs & Services → Credentials",
        consoleURL: URL(string: "https://console.cloud.google.com/apis/credentials"),
        note: "模型是 v1 的识别器类型：会议/长音频用 latest_long，短指令用 command_and_search，电话录音用 phone_call。",
        pricePerHour: "约 $0.024/分钟（约 $1.4/小时）",
        supportsDiarization: true,
        recommendation: "多语种 · 国内访问不稳"
    )

    static let aws = ASRCloudSpec(
        id: "aws",
        name: "AWS Transcribe",
        brandAsset: "BrandAWS",
        tagline: "批量转写 · 说话人分离",
        fields: [
            Field(id: "accessKey", kind: .secret, label: "Access key ID",
                  placeholder: "AKIA…"),
            Field(id: "secretKey", kind: .secret, label: "Secret access key",
                  placeholder: "••••••••"),
            Field(id: "region", kind: .plain, label: "Region",
                  placeholder: "ap-northeast-1"),
        ],
        defaultEndpoint: "",
        endpointEditable: false,
        models: ["standard", "medical"],
        console: "console.aws.amazon.com → IAM → 用户 → 安全凭证",
        consoleURL: URL(string: "https://console.aws.amazon.com/iam/home#/security_credentials"),
        note: "地址由区域拼出（transcribe.<region>.amazonaws.com）。只读权限即够探测；转写还需要该账号能访问 S3（Transcribe 是异步任务型接口）。",
        pricePerHour: "约 $0.024/分钟（约 $1.4/小时）",
        supportsDiarization: true,
        recommendation: "企业级 · 需要 S3"
    )

    static let deepgram = ASRCloudSpec(
        id: "deepgram",
        name: "Deepgram",
        brandAsset: "BrandDeepgram",
        tagline: "Nova 系列 · 实时与批量都便宜",
        fields: [Field(id: "apiKey", kind: .secret, label: "API key",
                       placeholder: "Deepgram API key")],
        defaultEndpoint: "https://api.deepgram.com/v1",
        endpointEditable: false,
        models: ["nova-3", "nova-2", "nova-2-phonecall", "nova-2-medical",
                 "nova-2-meeting", "enhanced", "base", "whisper-large"],
        console: "console.deepgram.com → API Keys",
        consoleURL: URL(string: "https://console.deepgram.com/"),
        note: "鉴权头是 `Authorization: Token <key>`，不是 Bearer——这家是特例，已按它的协议发。",
        pricePerHour: "约 $0.3/小时",
        supportsDiarization: true,
        recommendation: "英文强 · 便宜"
    )

    static let assemblyAI = ASRCloudSpec(
        id: "assemblyai",
        name: "AssemblyAI",
        brandAsset: "BrandAssemblyAI",
        tagline: "Universal-2 · 摘要/话题一体",
        fields: [Field(id: "apiKey", kind: .secret, label: "API key",
                       placeholder: "AssemblyAI API key")],
        defaultEndpoint: "https://api.assemblyai.com/v2",
        endpointEditable: false,
        models: ["best", "nano", "slam-1"],
        console: "assemblyai.com/dashboard → API keys",
        consoleURL: URL(string: "https://www.assemblyai.com/app/dashboard/api-keys"),
        note: "模型字段在它的协议里叫 speech_model：best 最准，nano 最快，slam-1 面向实时通话。",
        pricePerHour: "约 $0.4/小时",
        supportsDiarization: true,
        recommendation: "英文强 · 附带摘要能力"
    )

    static let gladia = ASRCloudSpec(
        id: "gladia",
        name: "Gladia",
        brandAsset: "BrandGladia",
        tagline: "Solaria · 多语种与说话人",
        fields: [Field(id: "apiKey", kind: .secret, label: "API key",
                       placeholder: "Gladia API key")],
        defaultEndpoint: "https://api.gladia.io/v2",
        endpointEditable: false,
        models: ["solaria-1", "solaria-mini", "whisper-large-v3"],
        console: "app.gladia.io → API keys",
        consoleURL: URL(string: "https://app.gladia.io/"),
        note: "鉴权头是 `x-gladia-key`。",
        pricePerHour: "约 $0.6/小时（Pro 档）",
        supportsDiarization: true,
        recommendation: "多语种 · 实时可用"
    )

    static let watson = ASRCloudSpec(
        id: "watson",
        name: "IBM Watson",
        brandAsset: "BrandWatson",
        tagline: "Speech to Text · 老牌稳定",
        fields: [
            Field(id: "apiKey", kind: .secret, label: "API key",
                  placeholder: "Watson API key"),
            Field(id: "region", kind: .plain, label: "Region",
                  placeholder: "us-south"),
        ],
        defaultEndpoint: "",
        endpointEditable: false,
        models: ["en-US_BroadbandModel", "en-US_Telephony", "en-US_Multimedia",
                 "zh-CN_BroadbandModel", "zh-CN_Telephony"],
        console: "cloud.ibm.com → 资源列表 → Speech to Text → 凭证",
        consoleURL: URL(string: "https://cloud.ibm.com/resources"),
        note: "地址按区域拼出（api.<region>.speech-to-text.watson.cloud.ibm.com）。鉴权是 Basic，用户名固定写 apikey。它有自己的 /v1/models，刷新会拿到真实模型清单。",
        pricePerHour: "约 $0.02/分钟（约 $1.2/小时）",
        supportsDiarization: true,
        recommendation: "老牌稳定 · 有中文模型"
    )

    // MARK: - Derived

    /// Watson and AWS have no fixed host: the region is part of the address.
    /// Returning it here keeps the sheet from having to special-case them.
    func endpoint(values: [String: String]) -> String {
        let region = values["region"]?.trimmingCharacters(in: .whitespaces) ?? ""
        switch id {
        case "watson":
            let r = region.isEmpty ? "us-south" : region
            return "https://api.\(r).speech-to-text.watson.cloud.ibm.com"
        case "aws":
            let r = region.isEmpty ? "us-east-1" : region
            return "https://transcribe.\(r).amazonaws.com"
        case "tencent":
            // Fixed host by design; the region travels as an X-TC-Region header.
            return "https://asr.tencentcloudapi.com"
        default:
            return defaultEndpoint
        }
    }

    /// Only these two expose a model list we can read.
    var canFetchModels: Bool { id == "watson" || id == "deepgram" }
}
