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
/// ⚠️ 豆包 and 火山方舟 used to be two cards and were **one row too many**: 豆包
/// models are served by 火山方舟, so both cards had the identical endpoint
/// `ark.cn-beijing.volces.com/api/v3` and the identical key. 2026-10-22:
/// > "火山引擎的跟豆包好像是同一家去重一下"
/// One card now, and the *model* field takes either form — a model name
/// (`doubao-seed-1-6-…`) or an inference endpoint id (`ep-…`), which is the only
/// option on accounts that can't call models by name. Old `ark` configs are folded
/// into this one on launch, see `ConfigService.mergeArkIntoDoubao`.
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

    static let all: [LLMPreset] = [qwen, deepseek, doubao, kimi, zhipu, minimax]

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

    /// 豆包 = 火山方舟. One card, because they are one service — the only thing
    /// that differed was what you paste into "model".
    static let doubao = LLMPreset(
        id: "doubao",
        name: "豆包 · 火山方舟",
        mark: "豆",
        endpoint: "https://ark.cn-beijing.volces.com/api/v3",
        models: ["doubao-seed-1-6-250615", "doubao-1-5-pro-32k-250115",
                 "doubao-pro-32k-241215", "doubao-lite-128k-240428"],
        console: "console.volcengine.com/ark → API Key",
        note: "豆包由火山引擎方舟提供。模型一栏可以填模型名（doubao-…），也可以填推理接入点 ID（ep-… 开头，账号不能按名调用时用这种）。"
    )

    // ★ 2026-10-29（用户："模型不要区分国内国外…图标将现在有的结合图片里面的都加入"）：
    // 参照截图补齐 Kimi / 智谱 GLM / MiniMax 三家。Kimi 与智谱都是 OpenAI 兼容
    // `/chat/completions`；MiniMax 的对话接口是它自家的 `/text/chatcompletion_v2`，
    // 走不了通用 OpenAI 路径——所以它的"从服务商拉取"不可用，靠下面的精选模型列表。
    static let kimi = LLMPreset(
        id: "kimi",
        name: "Kimi",
        mark: "K",
        endpoint: "https://api.moonshot.cn/v1",
        models: ["kimi-k2-0905-preview", "kimi-k2-turbo-preview",
                 "moonshot-v1-128k", "moonshot-v1-32k", "moonshot-v1-8k"],
        console: "platform.moonshot.cn → API Key 管理",
        note: "月之暗面。长文本能力强，128k 版适合整场会议的全文整理。"
    )

    static let zhipu = LLMPreset(
        id: "zhipu",
        name: "智谱 GLM",
        mark: "智",
        endpoint: "https://open.bigmodel.cn/api/paas/v4",
        models: ["glm-4-plus", "glm-4-air", "glm-4-flash", "glm-4-long"],
        console: "open.bigmodel.cn → API Keys",
        note: "glm-4-flash 免费额度大，整理日常录音够用；要质量选 glm-4-plus。"
    )

    static let minimax = LLMPreset(
        id: "minimax",
        name: "MiniMax",
        mark: "M",
        endpoint: "https://api.minimax.chat/v1",
        models: ["MiniMax-Text-01", "abab6.5s-chat", "abab6.5g-chat"],
        console: "platform.minimaxi.com → 接口密钥",
        note: "MiniMax 的对话接口是它自家的 /text/chatcompletion_v2，「从服务商拉取模型」不可用，请直接从推荐列表选。"
    )
}
