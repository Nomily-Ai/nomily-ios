import SwiftUI

/// ★ 2026-10-20: the "one-prompt setup" for the two self-hosted providers.
///
/// The local faster-whisper server and Ollama need no account and no API key, but they do
/// need to be installed and started on a computer — and the ordinary user has no idea how.
/// Instead of writing a longer manual nobody reads, we hand them **one prompt** to paste
/// into ChatGPT / Claude Code on that computer: the AI installs everything, writes the
/// server, starts it, and prints the exact values to type into this app's config pages.
///
/// The prompt bakes in the **wire contract** the app actually speaks, so the generated
/// server can't drift from what the client expects:
///   · batch: `POST http://{host}:{port+1}/v1/transcribe`, body = raw audio bytes
///     (`application/octet-stream`, usually an Ogg-Opus container), reply
///     `{"text": ..., "segments": [{"start", "end", "text"}]}` — see `LocalASR`;
///   · stream: `ws://{host}:{port}/v1/listen`, client sends equal-length **raw Opus
///     packets** as binary frames, server replies JSON text frames
///     `{"text": ..., "is_final": bool}`, ends on `{"type":"CloseStream"}` — see
///     `LiveStreamASR`;
///   · the port convention (12300 = stream, 12301 = batch) is the app's default and the
///     server "bakes it in" (comment at the top of `LocalASR`);
///   · Ollama: OpenAI-compatible `{base}/v1/chat/completions` + `/api/tags`, LAN-exposed
///     via `OLLAMA_HOST=0.0.0.0` — see `LLMCompletionService` / `LLMModelService`.
enum SetupAssistant {
    /// The full prompt. Chinese is the primary audience (the app's users read the
    /// zh-Hans settings page); the English variant exists for the README and for
    /// English-language installs. `appLanguage` picks — `nil` counts as Chinese,
    /// the app's origin language.
    static func prompt(appLanguage: String?) -> String {
        if appLanguage?.hasPrefix("zh") == false { return enPrompt }
        return zhPrompt
    }

    static let zhPrompt = """
    请帮我把这台电脑部署成 Nomily AI 录音 App 的本地语音服务，做完后把要填进 App 的信息打印给我。分三步：
    第一步，安装并启动 Ollama，设置开机自启并允许局域网访问（OLLAMA_HOST=0.0.0.0），再拉一个适合本机内存的中文对话模型（内存 8G 用 qwen2.5:3b，16G 及以上用 qwen2.5:7b）。
    第二步，用 pip 安装 faster-whisper，写一个 Python 服务（FastAPI + uvicorn + websockets）并在后台常驻（macOS 用 launchd，Windows/Linux 用 systemd 或任务计划），同时放行防火墙的 12300 和 12301 端口。它要实现两个接口：
    · HTTP 批量转录：监听 12301 端口，POST /v1/transcribe，请求体是原始音频字节（Content-Type: application/octet-stream，一般是 Ogg-Opus 容器，用 faster-whisper 直接解码），返回 JSON：{"text": "完整文本", "segments": [{"start": 开始秒, "end": 结束秒, "text": "分段文本"}]}。
    · WebSocket 实况流：监听 12300 端口，路径 /v1/listen。客户端会持续发来等长的 Opus 裸包（二进制帧，不带容器头，需要按固定包长拼接解码成 PCM 再喂给 faster-whisper 的 VAD 流式识别），服务器每识别出一段就用 JSON 文本帧回发 {"text": "这段文字", "is_final": true 或 false}；收到 {"type":"CloseStream"} 文本帧时冲刷剩余音频、补发最后一段，然后关闭连接。
    第三步，全部跑通后先打印四行人类可读的信息：① 这台电脑的局域网 IP（用 ifconfig 或 ipconfig 查，192.168 或 10 开头的那个）；② Nomily AI「设置 → 转录 → 本地 ASR 服务」里要填的主机名（就是上面的局域网 IP）；③ 该页要填的端口（固定填 12300）；④ 「设置 → AI 服务 → Ollama」里要填的地址（http://局域网IP:11434）和模型名。然后**必须**原样输出下面这个代码块（App 会解析它自动填表）：
    ```NOMILY-SETUP
    asr_host=<局域网IP>
    asr_port=12300
    llm_base_url=http://<局域网IP>:11434
    llm_model=<模型名>
    ```
    最后提醒我：手机和电脑必须连同一个 Wi-Fi，App 两个页面里的验证按钮都通过才算部署成功。
    """

    static let enPrompt = """
    Set up this computer as the local speech backend for the Nomily AI recorder app, then print exactly what I should type into the app. Three steps:
    1. Install and start Ollama, enable auto-start, expose it to the LAN (OLLAMA_HOST=0.0.0.0), and pull a chat model that fits this machine's RAM (qwen2.5:3b for 8 GB, qwen2.5:7b for 16 GB+).
    2. pip-install faster-whisper and write a Python service (FastAPI + uvicorn + websockets) that runs at login (launchd on macOS, systemd/Task Scheduler elsewhere) with firewall ports 12300 and 12301 open. It must implement:
    · HTTP batch transcription: listen on port 12301, POST /v1/transcribe, request body is raw audio bytes (Content-Type: application/octet-stream, usually an Ogg-Opus container that faster-whisper decodes directly), respond with JSON: {"text": "full text", "segments": [{"start": sec, "end": sec, "text": "segment"}]}.
    · WebSocket live stream: listen on port 12300 at path /v1/listen. The client streams equal-length raw Opus packets (binary frames, no container header — reassemble by fixed packet length, decode to PCM, feed a streaming VAD + faster-whisper). For each recognized segment reply with a JSON text frame {"text": "...", "is_final": true or false}; on receiving the text frame {"type":"CloseStream"}, flush remaining audio, emit the final segment, and close.
    3. When everything runs, first print four human-readable lines: (1) this computer's LAN IP; (2) the host for Settings → Transcription → Local ASR server; (3) the port (always 12300); (4) the address for Settings → AI Providers → Ollama (http://LAN-IP:11434) and the model name. Then you **must** output this code block verbatim (the app parses it to auto-fill the forms):
    ```NOMILY-SETUP
    asr_host=<LAN-IP>
    asr_port=12300
    llm_base_url=http://<LAN-IP>:11434
    llm_model=<model-name>
    ```
    Finally remind me the phone and this computer must be on the same Wi-Fi, and deployment is done only when both verify buttons in the app pass.
    """

    // MARK: - NOMILY-SETUP paste protocol (★ 2026-10-28, 饭耳逆向规格 §1.3)

    /// 解析结果——只收四个已知字段，其余行忽略。
    struct ParsedSetup: Equatable {
        var asrHost: String?
        var asrPort: Int?
        var llmBaseURL: String?
        var llmModel: String?

        var isEmpty: Bool {
            asrHost == nil && asrPort == nil && llmBaseURL == nil && llmModel == nil
        }
    }

    /// 从任意文本里抠出 `NOMILY-SETUP` 块（``` 围栏可有可无）；整段找不到时
    /// 退回宽松兜底：直接在全文里认 `key=value` 行。行格式容错：
    /// `asr_host=192.168.1.5`、`asr_host：192.168.1.5`、`- asr_host = 192.168.1.5` 都认。
    static func parseResult(_ text: String) -> ParsedSetup {
        var payload = text
        if let range = payload.range(of: "NOMILY-SETUP") {
            payload = String(payload[range.upperBound...])
            // 只取到围栏结束或块外第一个明显非键值内容之前——宽松处理：取其后 40 行。
            let lines = payload.components(separatedBy: .newlines).prefix(40)
            payload = lines.joined(separator: "\n")
        }
        var out = ParsedSetup()
        for rawLine in payload.components(separatedBy: .newlines) {
            let line = rawLine
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*`"))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let normalized = line
                .replacingOccurrences(of: "：", with: "=")
                .replacingOccurrences(of: " =", with: "=")
                .replacingOccurrences(of: "= ", with: "=")
            guard let eq = normalized.firstIndex(of: "=") else { continue }
            let key = normalized[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = normalized[normalized.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "asr_host", "asr_ip", "host", "ip":
                if out.asrHost == nil { out.asrHost = value }
            case "asr_port", "port":
                if out.asrPort == nil, let p = Int(value), (1...65535).contains(p) { out.asrPort = p }
            case "llm_base_url", "llm_url", "base_url", "ollama_url":
                if out.llmBaseURL == nil, value.hasPrefix("http") { out.llmBaseURL = value }
            case "llm_model", "model":
                if out.llmModel == nil { out.llmModel = value }
            default:
                break
            }
        }
        return out
    }
}

/// The copyable row shown under the local-ASR and Ollama config sections.
///
/// A row rather than a footer link: the whole point is that the user copies the prompt
/// *on the phone* (AirDrop / WeChat it to the computer), not that they find the README.
struct SetupAssistantRow: View {
    @EnvironmentObject private var configService: ConfigService
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = SetupAssistant.prompt(
                appLanguage: configService.config.appLanguage
            )
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                copied = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                    .foregroundStyle(copied ? Color.green : Color.appAccent)
                    .font(.body.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(copied ? L10n.Setup.assistantCopied : L10n.Setup.assistantTitle)
                    Text(L10n.Setup.assistantHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? L10n.Setup.assistantCopied : L10n.Setup.assistantTitle)
    }
}

/// ★ 2026-10-28（饭耳逆向规格 §1.3「点我粘贴结果」）：解析 AI 输出的
/// `NOMILY-SETUP` 块（或人类可读的四行信息），把 host/port/地址/模型名
/// 自动回填进配置——用户不用再对着两个页面手抄。
///
/// 放在 `SetupAssistantRow` 旁边（本地 ASR 页 + Ollama 页各一处）：
/// 复制提示词 → 桌面 AI 跑完 → 回到 App 点这里，闭环在 30 秒内走完。
struct SetupAssistantPasteRow: View {
    @EnvironmentObject private var configService: ConfigService
    /// 只回填对应目标：本地 ASR 页传 `.asr`，Ollama 页传 `.ollama`；
    /// `nil`（设置总页）= 两个都填。
    var target: Target?

    enum Target { case asr, ollama }

    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Button {
            pasteAndApply()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "doc.badge.plus")
                    .foregroundStyle(failed ? Color.orange : Color.appAccent)
                    .font(.body.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Setup.pasteTitle)
                    if let result {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(failed ? .orange : .secondary)
                    } else {
                        Text(L10n.Setup.pasteHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Setup.pasteTitle)
    }

    private func pasteAndApply() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            failed = true
            result = L10n.Setup.pasteEmpty
            return
        }
        let parsed = SetupAssistant.parseResult(text)
        guard !parsed.isEmpty else {
            failed = true
            result = L10n.Setup.pasteNotFound
            return
        }
        var filled: [String] = []
        if target != .ollama, let host = parsed.asrHost, !host.isEmpty {
            var local = configService.config.asrProviders.local ?? AppConfig.AsrProviders.Local(host: "", port: 12_300)
            local.host = host
            if let port = parsed.asrPort { local.port = port }
            configService.config.asrProviders.local = local
            filled.append("ASR \(host):\(local.port)")
        }
        if target != .asr, let url = parsed.llmBaseURL, !url.isEmpty {
            var ollama = configService.config.llmProviders.ollama
                ?? AppConfig.LlmProviders.EndpointProvider(endpoint: "", model: nil)
            ollama.endpoint = url
            if let model = parsed.llmModel, !model.isEmpty { ollama.model = model }
            configService.config.llmProviders.ollama = ollama
            configService.config.llmProviders.autoSelectPrimaryIfFirst()
            filled.append("Ollama \(url)")
        }
        if filled.isEmpty {
            failed = true
            result = L10n.Setup.pasteNotFound
            return
        }
        failed = false
        result = L10n.Setup.pasteDone(filled.joined(separator: " · "))
        configService.saveNow()
    }
}
