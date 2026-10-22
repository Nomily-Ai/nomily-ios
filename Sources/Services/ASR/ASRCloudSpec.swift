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
/// and the round trip is measured. They are **not** yet routed into the
/// transcription engine (`TranscriptionService` still speaks Azure / local /
/// remote-WSS). Wiring a vendor means writing its audio upload + result parsing,
/// which is a separate change per vendor.
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
    /// Vendor-specific caveat.
    let note: String?

    /// Tile colour, same shape as `LLMProviderSpec.tint`.
    var tint: (r: Double, g: Double, b: Double) {
        switch id {
        case "google":     return (0.26, 0.52, 0.96)
        case "aws":        return (0.90, 0.55, 0.10)
        case "deepgram":   return (0.05, 0.62, 0.53)
        case "assemblyai": return (0.35, 0.34, 0.84)
        case "gladia":     return (0.13, 0.13, 0.15)
        default:           return (0.21, 0.31, 0.86)   // IBM Watson
        }
    }

    static let all: [ASRCloudSpec] = [google, aws, deepgram, assemblyAI, gladia, watson]

    static func find(_ id: String) -> ASRCloudSpec? { all.first { $0.id == id } }

    // MARK: - Catalogue

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
        note: "模型是 v1 的识别器类型：会议/长音频用 latest_long，短指令用 command_and_search，电话录音用 phone_call。"
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
        note: "地址由区域拼出（transcribe.<region>.amazonaws.com）。只读权限即够探测；转写还需要该账号能访问 S3（Transcribe 是异步任务型接口）。"
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
        note: "鉴权头是 `Authorization: Token <key>`，不是 Bearer——这家是特例，已按它的协议发。"
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
        note: "模型字段在它的协议里叫 speech_model：best 最准，nano 最快，slam-1 面向实时通话。"
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
        note: "鉴权头是 `x-gladia-key`。"
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
        note: "地址按区域拼出（api.<region>.speech-to-text.watson.cloud.ibm.com）。鉴权是 Basic，用户名固定写 apikey。它有自己的 /v1/models，刷新会拿到真实模型清单。"
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
        default:
            return defaultEndpoint
        }
    }

    /// Only these two expose a model list we can read.
    var canFetchModels: Bool { id == "watson" || id == "deepgram" }
}
