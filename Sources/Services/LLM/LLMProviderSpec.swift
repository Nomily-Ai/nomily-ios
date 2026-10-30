import Foundation

/// Where a provider's settings actually live on `AppConfig.LlmProviders`.
///
/// Three shapes exist because the config grew organically: the three "just a key"
/// providers, the three "key + address" ones, and the one-tap presets in their
/// dictionary. The settings page should not have to care — it reads and writes
/// through these cases, so one sheet can drive all ten providers.
enum LLMProviderStorage: Equatable {
    /// `openai` / `claude` / `gemini` — the address is fixed in code.
    case keyed(String)
    /// `openRouter` / `ollama` / `custom` — the address is part of the config.
    case endpoint(String)
    /// `qwen` / `deepseek` / `doubao` — stored in the `presets` dictionary.
    case preset(String)
}

/// One row in the provider grid: ChatGPT, Claude, Gemini, OpenRouter, Ollama,
/// Custom, plus the three domestic ones.
///
/// 2026-10-22 request:
/// > "下面的 openrouter 也要要国外的主流模型，Claude / chatgpt / gemini，ollama 跟用户自定义的
/// >  模型也要加入进去，然后给这些模型配置对应的图标，然后他们的模型要兼容 —
/// >  能够根据我们支持的模型才可以在里面进行选择"
///
/// Three things fall out of that sentence, and this type is where the first one lives:
/// 1. the grid covers **every** provider, not just the domestic ones;
/// 2. each has its own mark, because recognising the icon *is* the interaction;
/// 3. the model list is filtered to what this app can actually call — see
///    `LLMModelService.chatCapableModels`.
struct LLMProviderSpec: Identifiable, Equatable {

    enum Kind: Equatable {
        /// Vendor's own API (OpenAI / Anthropic / Google).
        case cloud
        /// Aggregator that fronts many vendors.
        case aggregator
        /// Runs on this machine or the user's own server.
        case local
        /// Chinese providers, all OpenAI-compatible, all one-tap.
        case domestic
    }

    let id: String
    let name: String
    /// 1–2 glyphs drawn inside the icon tile when there is no brand artwork.
    /// Never translated — it is a logo.
    let mark: String
    let kind: Kind
    let storage: LLMProviderStorage
    /// Pre-filled address. Empty when the user has to supply one (`custom`).
    let defaultEndpoint: String
    /// `false` only where the endpoint is fixed by the API (OpenAI/Claude/Gemini).
    let endpointEditable: Bool
    /// Ollama and Custom legitimately run without a key.
    let keyRequired: Bool
    /// Hand-picked models shown before anything is fetched. Also the fallback when
    /// the provider has no model-list endpoint.
    let curatedModels: [String]
    /// Where the key comes from.
    let console: String?
    /// Provider-specific caveat.
    let note: String?

    /// Tile colour, as components so this file stays free of SwiftUI.
    var tint: (r: Double, g: Double, b: Double) {
        switch id {
        case "openai":     return (0.10, 0.62, 0.49)
        case "claude":     return (0.85, 0.47, 0.34)
        case "gemini":     return (0.26, 0.52, 0.96)
        case "openRouter": return (0.36, 0.36, 0.44)
        case "ollama":     return (0.20, 0.20, 0.24)
        case "custom":     return (0.45, 0.47, 0.52)
        case "qwen":       return (0.42, 0.36, 1.00)
        case "deepseek":   return (0.28, 0.42, 0.98)
        case "kimi":       return (0.08, 0.08, 0.10)   // Kimi 黑
        case "zhipu":      return (0.25, 0.45, 0.95)   // 智谱蓝
        case "minimax":    return (0.90, 0.25, 0.35)   // MiniMax 红橙
        default:           return (0.16, 0.44, 0.84)   // 豆包 / 火山方舟
        }
    }

    /// Asset-catalog name of the vendor's real logo, or `nil` where there is no
    /// logo to show. 2026-10-22:
    /// > "不要文字字幕做图标，需要按照当前他们模型 Logo 做图标"
    ///
    /// The SVGs are single-path monochrome marks (`@lobehub/icons-static-svg`),
    /// imported as **template** images, so the tile only supplies a colour and one
    /// file works in light and dark mode. Custom has no vendor, hence the fallback
    /// to `mark`.
    var brandAsset: String? {
        switch id {
        case "openai":     return "BrandOpenAI"
        case "claude":     return "BrandClaude"
        case "gemini":     return "BrandGemini"
        case "openRouter": return "BrandOpenRouter"
        case "ollama":     return "BrandOllama"
        case "qwen":       return "BrandQwen"
        case "deepseek":   return "BrandDeepSeek"
        case "doubao":     return "BrandDoubao"
        default:           return nil
        }
    }

    /// ★ 2026-10-29（按截图补）：注册页直链——"还没有 key？去注册 ↗" 那一行。
    var signupURL: String? {
        switch id {
        case "openai":     return "https://platform.openai.com/api-keys"
        case "claude":     return "https://console.anthropic.com/settings/keys"
        case "gemini":     return "https://aistudio.google.com/apikey"
        case "openRouter": return "https://openrouter.ai/keys"
        case "qwen":       return "https://bailian.console.aliyun.com/?apiKey=1"
        case "deepseek":   return "https://platform.deepseek.com/api_keys"
        case "kimi":       return "https://platform.moonshot.cn/console/api-keys"
        case "zhipu":      return "https://open.bigmodel.cn/usercenter/apikeys"
        case "minimax":    return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case "doubao":     return "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey"
        default:           return nil   // ollama / custom：没有"注册"一说
        }
    }

    // MARK: - Catalogue

    /// One flat list. 2026-10-22:
    /// > "不要分国内外，直接都按照模型加入进去"
    ///
    /// So the 主流服务商 / 国内大模型 split is gone. It never bought anything: the
    /// sheet is the same three fields for all of them, and "which country is this
    /// vendor in" is not a fact the app acts on. Order is by how likely someone is
    /// to reach for it — the three big cloud APIs, the three Chinese ones, then the
    /// aggregator, the local runtime, and finally the catch-all.
    static let all: [LLMProviderSpec] = [
        chatgpt, claude, gemini,
        qwen, deepseek, doubao, kimi, zhipu, minimax,
        openRouter, ollama, custom,
    ]

    static func find(_ id: String) -> LLMProviderSpec? { all.first { $0.id == id } }

    static let chatgpt = LLMProviderSpec(
        id: "openai",
        name: "ChatGPT",
        mark: "GPT",
        kind: .cloud,
        storage: .keyed("openai"),
        defaultEndpoint: "https://api.openai.com/v1",
        endpointEditable: false,
        keyRequired: true,
        curatedModels: ["gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini", "o3", "o4-mini"],
        console: "platform.openai.com → API keys",
        note: nil
    )

    static let claude = LLMProviderSpec(
        id: "claude",
        name: "Claude",
        mark: "C",
        kind: .cloud,
        storage: .keyed("claude"),
        defaultEndpoint: "https://api.anthropic.com/v1",
        endpointEditable: false,
        keyRequired: true,
        curatedModels: [
            "claude-opus-4-0-20250514", "claude-sonnet-4-0-20250514",
            "claude-3-7-sonnet-20250219", "claude-3-5-haiku-20241022",
        ],
        console: "console.anthropic.com → API keys",
        note: nil
    )

    static let gemini = LLMProviderSpec(
        id: "gemini",
        name: "Gemini",
        mark: "G",
        kind: .cloud,
        storage: .keyed("gemini"),
        defaultEndpoint: "https://generativelanguage.googleapis.com/v1beta",
        endpointEditable: false,
        keyRequired: true,
        curatedModels: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"],
        console: "aistudio.google.com → API key",
        note: nil
    )

    static let openRouter = LLMProviderSpec(
        id: "openRouter",
        name: "Open Router",
        mark: "OR",
        kind: .aggregator,
        storage: .endpoint("openRouter"),
        defaultEndpoint: "https://openrouter.ai/api/v1",
        endpointEditable: true,
        keyRequired: true,
        curatedModels: [
            "anthropic/claude-sonnet-4", "openai/gpt-4.1",
            "google/gemini-2.5-pro", "deepseek/deepseek-chat",
        ],
        console: "openrouter.ai/keys",
        note: "一个 key 通吃各家模型；模型名要带厂牌前缀（anthropic/… 、openai/…）。"
    )

    static let ollama = LLMProviderSpec(
        id: "ollama",
        name: "Ollama",
        mark: "OL",
        kind: .local,
        storage: .endpoint("ollama"),
        defaultEndpoint: "http://localhost:11434",
        endpointEditable: true,
        keyRequired: false,
        curatedModels: [],
        console: nil,
        note: "跑在本机或局域网里的电脑上，不联网、不花钱。要填电脑的地址而不是名字。"
    )

    static let custom = LLMProviderSpec(
        id: "custom",
        name: "自定义接口",
        mark: "＋",
        kind: .local,
        storage: .endpoint("custom"),
        defaultEndpoint: "",
        endpointEditable: true,
        keyRequired: false,
        curatedModels: [],
        console: nil,
        note: "任何 OpenAI 兼容的 /v1 地址（中转、自建 vLLM、LM Studio 都算）。密钥可以留空。"
    )

    // Domestic presets, derived from `LLMPreset` so the endpoint/model lists are
    // written down exactly once.
    static let qwen = from(LLMPreset.qwen)
    static let deepseek = from(LLMPreset.deepseek)
    static let doubao = from(LLMPreset.doubao)
    // ★ 2026-10-29 (按截图补齐): Kimi / 智谱 GLM / MiniMax。
    static let kimi = from(LLMPreset.kimi)
    static let zhipu = from(LLMPreset.zhipu)
    static let minimax = from(LLMPreset.minimax)

    private static func from(_ preset: LLMPreset) -> LLMProviderSpec {
        LLMProviderSpec(
            id: preset.id,
            name: preset.name,
            mark: preset.mark,
            kind: .domestic,
            storage: .preset(preset.id),
            defaultEndpoint: preset.endpoint,
            endpointEditable: true,
            keyRequired: true,
            curatedModels: preset.models,
            console: preset.console,
            note: preset.note
        )
    }
}
