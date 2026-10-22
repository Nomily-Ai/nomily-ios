import Foundation

/// One-tap LLM provider presets (2026-10-22).
///
/// User's words:
/// > "把 qwen 跟 deepseek 还有豆包跟火山引擎的，按照语音模型图标进行设置，点击图标默认填写好对应网址，
/// >  只需要输入 API 密钥跟选择对应模型即可"
///
/// So the shape is deliberate: an **icon grid**, and the moment one is tapped the
/// endpoint is already filled in. What's left is a key and a model — nothing to
/// look up, nothing to mistype.
///
/// ## Why every preset is OpenAI-compatible
/// All four expose `/chat/completions` with `Authorization: Bearer`, so they ride
/// the existing `openAICompatible` path (streaming + SSE + the non-streaming
/// fallback) instead of being four more bespoke clients. That is also why they can
/// live in one dictionary on `LlmProviders` rather than four top-level fields.
///
/// ⚠️ Doubao and Volcengine Ark are the **same host** on purpose: 豆包 models are
/// served by 火山方舟. The two cards differ only in what you paste into "model" —
/// a model name (`doubao-seed-1-6-…`) versus an inference endpoint id (`ep-…`),
/// which is the only option on accounts that can't call models by name.
struct LLMPreset: Identifiable, Equatable {

    let id: String
    /// Display name for the picker and error copy ("Qwen" reads the same in both languages).
    let name: String
    /// 1–2 glyphs drawn inside the icon tile. Not translated: it is a logo mark.
    let mark: String
    /// Base URL, no trailing slash, **no** `/chat/completions`. The request path is
    /// appended by `LLMCompletionService` so a user editing the field can't end up
    /// with `/v1/v1/chat/completions`.
    let endpoint: String
    /// Shown in the picker before anything is fetched. These are the models that
    /// actually exist today; the "refresh" button replaces them with whatever the
    /// account can really reach.
    let models: [String]
    /// Where the key comes from, shown under the key field.
    let console: String
    /// Caveat specific to this provider (nil = nothing to warn about).
    let note: String?

    static let all: [LLMPreset] = [qwen, deepseek, doubao, ark]

    static func find(_ id: String) -> LLMPreset? { all.first { $0.id == id } }

    // MARK: - Catalogue

    static let qwen = LLMPreset(
        id: "qwen",
        name: "通义千问",
        mark: "通",
        endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        models: ["qwen-max", "qwen-plus", "qwen-turbo", "qwen-long", "qwen3-max", "qwen2.5-72b-instruct"],
        console: "bailian.console.aliyun.com → API-KEY",
        note: nil
    )

    static let deepseek = LLMPreset(
        id: "deepseek",
        name: "DeepSeek",
        mark: "DS",
        endpoint: "https://api.deepseek.com/v1",
        models: ["deepseek-chat", "deepseek-reasoner"],
        console: "platform.deepseek.com → API keys",
        note: nil
    )

    static let doubao = LLMPreset(
        id: "doubao",
        name: "豆包",
        mark: "豆",
        endpoint: "https://ark.cn-beijing.volces.com/api/v3",
        models: ["doubao-seed-1-6-250615", "doubao-pro-32k-241215", "doubao-lite-128k-240428"],
        console: "console.volcengine.com/ark → API Key",
        note: "豆包由火山引擎方舟提供，两个卡片是同一个入口；这里填模型名（doubao-…）即可。"
    )

    static let ark = LLMPreset(
        id: "ark",
        name: "火山方舟",
        mark: "火",
        endpoint: "https://ark.cn-beijing.volces.com/api/v3",
        models: [],
        console: "console.volcengine.com/ark → 在线推理 → 接入点",
        note: "方舟也可以只按接入点调用：模型一栏填 ep- 开头的接入点 ID（形如 ep-2024xxxx-xxxxx）。"
    )
}
