import Foundation

/// Wire protocol a *custom* endpoint speaks.
///
/// ★ 2026-11-04（用户："当前自定义的需要支持这种不只是 openai 的"）：
/// 自定义渠道原先只有一个假设——`{base}/chat/completions` 就是 OpenAI 的补全接口。
/// 但用户手里的 key 往往来自一个"业务空间专属端点"（阿里云百炼的
/// `https://ws-….maas.aliyuncs.com/compatible-mode/v1`），控制台同时给出
/// OpenAI 兼容与 Anthropic 兼容两个 Base URL；只认 OpenAI 的那一套会在两种情况下悄悄失效：
/// 1. base 自己已经带了版本段（`/compatible-mode/v1`、`/api/v3`），再拼 `/v1` 就成
///    `/v1/v1/models`——模型列表永远 404，用户看到的是"这个渠道不能用"；
/// 2. 端点只提供 Anthropic Messages 格式，OpenAI 的 `/chat/completions` 根本不存在。
///
/// So the sheet asks which protocol it is, and the URLs are built by `LLMEndpoint`
/// instead of string-concatenated at each call site.
enum LLMWireProtocol: String, CaseIterable, Identifiable {
    case openai
    case anthropic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai:    return L10n.LLM.protocolOpenAI
        case .anthropic: return L10n.LLM.protocolAnthropic
        }
    }

    var hint: String {
        switch self {
        case .openai:    return L10n.LLM.protocolOpenAIHint
        case .anthropic: return L10n.LLM.protocolAnthropicHint
        }
    }

    static func parse(_ raw: String?) -> LLMWireProtocol {
        LLMWireProtocol(rawValue: (raw ?? "").lowercased()) ?? .openai
    }
}

/// URL building for OpenAI-compatible / Anthropic-compatible endpoints.
///
/// The rule the whole app needs: **never assume the user's base has no version segment.**
/// Vendors hand out every shape — `https://api.openai.com/v1`, `…/compatible-mode/v1`,
/// `…/api/v3`, `https://api.groq.com/openai`, or a bare `http://192.168.1.9:8000` —
/// and one base cannot be concatenated with one fixed suffix.
enum LLMEndpoint {

    /// Trims the input down to a base: no whitespace, no trailing slash, and no
    /// endpoint tail the user pasted from a curl example (`/chat/completions`, `/messages`).
    static func base(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        for tail in ["/chat/completions", "/messages", "/models"] where s.hasSuffix(tail) {
            s.removeLast(tail.count)
            break
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Whether the base already names an API version (`…/v1`, `…/compatible-mode/v1`,
    /// `…/api/v4`, `…/v1beta`).
    static func hasVersionSegment(_ base: String) -> Bool {
        guard let last = base.split(separator: "/").last else { return false }
        let seg = last.lowercased()
        // `v1` / `v4` / `v1beta` / `v4.1` — a leading v followed by a digit.
        if seg.first == "v", seg.count >= 2, seg.dropFirst().first?.isNumber == true { return true }
        // Gateways that put the version behind a fixed path — checking the whole
        // string catches `…/compatible-mode/v1/` written with a project suffix.
        if base.contains("/compatible-mode/v") { return true }
        if base.contains("/api/paas/v") { return true }
        if base.contains("/openai/deployments") { return true }
        return false
    }

    /// `{base}/v1/chat/completions` when the base is bare, `{base}/chat/completions` when it
    /// already carries the version.
    static func chatURL(_ raw: String) -> String {
        let b = base(raw)
        guard !b.isEmpty else { return "" }
        return hasVersionSegment(b) ? b + "/chat/completions" : b + "/v1/chat/completions"
    }

    /// Same rule for the model list. This is the one that used to 404 on
    /// `…/compatible-mode/v1` because the old code appended `/v1/models`.
    static func modelsURL(_ raw: String) -> String {
        let b = base(raw)
        guard !b.isEmpty else { return "" }
        return hasVersionSegment(b) ? b + "/models" : b + "/v1/models"
    }

    /// Anthropic Messages API.
    static func messagesURL(_ raw: String) -> String {
        let b = base(raw)
        guard !b.isEmpty else { return "" }
        return hasVersionSegment(b) ? b + "/messages" : b + "/v1/messages"
    }

    /// Whether a base points at this machine or the LAN.
    ///
    /// It decides two things for the custom channel: whether to use the long-timeout
    /// session (a LAN box may take minutes of prefill) and which output cap to send.
    /// A cloud relay behind a bare hostname is common enough that guessing "custom ⇒ local"
    /// used to halve every summary: 2048 tokens instead of 8192.
    static func isPrivate(_ raw: String) -> Bool {
        let b = base(raw)
        guard let host = URL(string: b)?.host()?.lowercased() else {
            // No scheme at all (`192.168.1.9:8000`) — treat as private; the caller
            // will fail on the URL anyway and the message is clearer with the long timeout.
            return true
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 { return true }
            if parts[0] == 192, parts[1] == 168 { return true }
            if parts[0] == 172, (16...31).contains(parts[1]) { return true }
            if parts[0] == 169, parts[1] == 254 { return true }
        }
        return false
    }
}
