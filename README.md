# Nomily iOS

Native iOS implementation — connects to a D·NOTE recording device over BLE, browses and transfers recordings, drives device settings, and runs ASR (Azure or local Whisper). Project overview and licence: [nomily-app](https://github.com/Nomily-Ai/nomily-app).

## Status

Full-featured companion app: BLE scan/connect, complete device control, recording browse / transfer / decrypt, on-device and Apple Watch recording, live and file transcription (Azure or local Whisper), and Fast Transfer over Wi-Fi.

- Scan + connect with escalating-timeout retries.
- Full Device sheet: switches, mic-gain / NR sliders, idle-off picker, Bluetooth-name editor with live byte counter, sync-time, and Format / Factory-reset / Shut-down with destructive confirmations.
- Recordings tab has two segments:
  - **Device** — lists device files, transfers them over BLE with live progress, cancel mid-transfer, swipe-to-delete. Each download is ChaCha20-decrypted (if a key is configured) and OGG-wrapped via in-app `OpusOgg`, so every clip lands as a real Ogg-Opus container. A per-row `text.bubble` button ships the file to the configured ASR provider; transcripts are written as `{name}.txt` + `{name}.asr.json` next to the audio. When the pending backlog exceeds 512 KB, a **Fast Transfer** button appears at the bottom — tapping it asks the device to bring up its Wi-Fi access point, joins it via `NEHotspotConfigurationManager`, and pulls the queue over that link (~20× faster than BLE).
  - **Library** — lists all clips on disk, sorted newest-first, with file size, Ogg-derived duration, and a transcript-ready badge. Tap → Clip detail (filename / size / duration / mtime hero, AVAudioPlayer-backed play/pause + scrubber, transcript reader with speaker labels, Transcribe / Re-transcribe buttons, delete-locally action).
- Stream tab starts/stops the real-time OPUS stream and, with the Live Transcription toggle on, pipes every OPUS frame through a WebSocket to the local faster-whisper server (`ws://{host}:{port}/v1/listen`). A transcript panel renders committed segments plus the current italic-grey partial.
- Settings tab is fully bound to `config.json` (ASR providers, Azure key/region, local server, ChaCha20 key, Wi-Fi AP creds, known devices). `min_transcribe_duration` is enforced before the network call.
- **Apple Watch companion** (`Watch/`, embedded in the iPhone app) — a single recorder screen:
  - **Watch** — records AAC/M4A at 24 kHz mono / 48 kbps (~21 MB/hour) straight from the wrist, standalone, with `audio` background mode so a session survives screen-off. Clips are named `yyyyMMddHHmmss.m4a` and queued to the iPhone via `WCSession.transferFile`; the watch-side copy is deleted only once the phone acknowledges it *stored* the clip, and anything still local is re-queued on launch. On the phone they land in `audio_clips/decrypted/` like any other clip, get a manifest entry with `transport: "watch"` (the Library row shows an `applewatch` badge), and honour the same **Auto-transcribe after download** toggle.
  - **Settings → Apple Watch** on the phone shows whether a watch is paired and whether the companion app is installed, with the install steps inline — a bundled watch app otherwise arrives with no prompt at all.
  - **Action Button** — `ToggleRecordingIntent` is published as an App Shortcut, so the Ultra's Action Button can start/stop a wrist recording (Settings → Action Button → Action: **Shortcut**, then pick it). One action, so it toggles.

Still missing: libopus binary target for iOS 16 `.opus` playback (iOS 17+ plays Opus natively today).

## Requirements

- macOS with Xcode 15+
- iOS 16.0+ device (BLE not available in the simulator)
- watchOS 10.0+ paired Apple Watch, for the companion app (mic, background recording and battery behaviour can't be verified in the simulator)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```bash
cd ios
xcodegen generate          # produces nomily_ios.xcodeproj from project.yml
open nomily_ios.xcodeproj
```

In Xcode:

1. Select the `nomily_ios` target → Signing & Capabilities → set your Team and a unique bundle ID (default: `com.nomily.app`).
2. Do the same for the `nomily_watch` target. Its bundle ID **must** stay `{iPhone bundle ID}.watchkitapp`, and `WKCompanionAppBundleIdentifier` in `project.yml` must match the iPhone ID — a mismatch installs the watch app as an orphan that never pairs.
3. Plug in an iPhone, select it as the run destination, ⌘R. The watch app is embedded in the iPhone app; you don't run the watch scheme separately unless you're debugging it. With **Automatic App Install** on (Watch app → General), it lands on the wrist by itself a few minutes later — otherwise open the Watch app on the iPhone → **Available Apps** → **Install** next to Nomily AI. The app's own Settings → Apple Watch row reports which state you're in.
4. First launch will request Bluetooth permission. Grant it. The watch app asks for microphone permission the first time you record on the wrist.

## Layout

```
Sources/
├── App/                  # @main, RootView, Info.plist, entitlements
├── Components/           # Reusable views (ConnectionPill, RSSIBars, …)
├── Features/
│   ├── Recordings/       # Device + Library segments, Clip detail, playback
│   ├── Stream/           # Live transcription
│   ├── Settings/         # ASR providers, keys, known devices
│   ├── Device/           # Modal sheet for device info + settings
│   └── Scanner/          # BLE scan + connect sheet
├── Services/
│   ├── ASR/              # AsrTypes, AzureASR, LocalASR, LiveStreamASR, OnDeviceASR, TranscriptionService
│   ├── BLE/              # CoreBluetooth: protocol, codec, scanner, client
│   ├── Crypto/           # ChaCha20 raw stream cipher (RFC 8439)
│   ├── Audio/            # OpusOgg (raw frames → Ogg-Opus container)
│   ├── Storage/          # config.json, library manifest, PostDownload pipeline
│   ├── Watch/            # WatchSyncService (phone side) + the shared wire contract
│   └── Wifi/             # WifiClient + HotspotJoiner (NEHotspotConfiguration)
└── Resources/
    └── Assets.xcassets/

Watch/                    # watchOS target: @main, WatchLink (WCSession), recorder, Action Button intent
```

Three files are compiled into **both** targets so phone and watch can't drift: `Sources/Services/Watch/WatchLinkMessage.swift` (the WatchConnectivity wire contract), `Sources/Services/Storage/RecordingName.swift` (the `yyyyMMddHHmmss` clip-naming convention) and `Sources/App/L10n.swift` + `Sources/Resources/*.lproj` (the same 10 localizations). See the `sources:` list on the `nomily_watch` target in `project.yml`.

## Logs

- After a run on a physical device, collect the log archive:
```
rm -rf .logs/dnote.logarchive
sudo log collect --device --last 3m --output ./.logs/dnote.logarchive
# BEGINSWITH, not ==: the app logs under com.nomily.app.ios and the
# watch app under com.nomily.app.watch
log show ./.logs/dnote.logarchive \
    --predicate 'subsystem BEGINSWITH "com.nomily.app"' \
    --info --debug > ./.logs/dnote.log
```

  The run is then readable in `./.logs/dnote.log`.

## Transcription

Three providers, picked in Settings → Speech Recognition and tried in the order
`primary → fallbacks → on-device`:

| Provider | Needs | Live | Notes |
|---|---|---|---|
| Azure Speech | key + region | yes (and live translation) | best quality, costs money |
| Local server | faster-whisper box on the LAN | yes | `ws://host:port/v1/listen` |
| **On-device** | nothing | yes, in ~3 s batches | Apple Speech, `requiresOnDeviceRecognition` — audio never leaves the phone |

The on-device path (`Sources/Services/ASR/OnDeviceASR.swift`) exists for two reasons:

- **It closes the last gap that required an account.** With no key and no server, live
  transcription used to fail inside `openASR` **before** the card was told to record — the
  symptom was "the record button did nothing", not "no text". Recording and transcription are now independent:
  if no service is available the session still records and streams, says so, and the saved clip
  is transcribed afterwards.
- **The decoder.** Everything our recorders produce is Opus in Ogg and `SFSpeechRecognizer`
  wants LPCM. `OnDeviceASR` decodes with `AVAssetReader` (16 kHz mono Int16) — the same path
  `AudioExporter.exportAsWAV` already uses. `AudioConverter` with `kAudioFormatOpus` was tried
  and rejected: the platform decoder latches end-of-stream after the first fill that drains its
  input, so it cannot be fed packet-by-packet.

Live on-device recognition batches ~3 s of packets, wraps them into an Ogg container in a temp
file, decodes, and appends the PCM to a running recognition request — so text arrives in phrase
bursts rather than word by word. A configured Azure/whisper service, when present, wins on
quality and is tried first.

**Summarize right after transcribing** (Settings, on by default) hands each fresh transcript to the
configured LLM as a summary job. It is skipped when no LLM is configured, and it never
overwrites a summary that already exists on disk.

### One-prompt setup for local ASR + Ollama (no keys, no cloud)

The **Local server** (faster-whisper) and **Ollama** providers need no account and no API key —
but they do have to be installed and started on a computer that shares the phone's Wi-Fi.
If that sounds like sysadmin work, let an AI do it: open **ChatGPT** or **Claude Code** on
that computer, paste the prompt below, and let it install, write and start everything.
When it finishes it prints the exact values to type into the app. The same prompt is
copyable from inside the app: **Settings → 转录 → Local ASR server → 复制 AI 配置助手提示词**.

<details>
<summary><strong>复制这段话给 ChatGPT / Claude Code（中文）</strong></summary>

```text
请帮我把这台电脑部署成 Nomily AI 录音 App 的本地语音服务，做完后把要填进 App 的信息打印给我。分三步：
第一步，安装并启动 Ollama，设置开机自启并允许局域网访问（OLLAMA_HOST=0.0.0.0），再拉一个适合本机内存的中文对话模型（内存 8G 用 qwen2.5:3b，16G 及以上用 qwen2.5:7b）。
第二步，用 pip 安装 faster-whisper，写一个 Python 服务（FastAPI + uvicorn + websockets）并在后台常驻（macOS 用 launchd，Windows/Linux 用 systemd 或任务计划），同时放行防火墙的 12300 和 12301 端口。它要实现两个接口：
· HTTP 批量转录：监听 12301 端口，POST /v1/transcribe，请求体是原始音频字节（Content-Type: application/octet-stream，一般是 Ogg-Opus 容器，用 faster-whisper 直接解码），返回 JSON：{"text": "完整文本", "segments": [{"start": 开始秒, "end": 结束秒, "text": "分段文本"}]}。
· WebSocket 实况流：监听 12300 端口，路径 /v1/listen。客户端会持续发来等长的 Opus 裸包（二进制帧，不带容器头，需要按固定包长拼接解码成 PCM 再喂给 faster-whisper 的 VAD 流式识别），服务器每识别出一段就用 JSON 文本帧回发 {"text": "这段文字", "is_final": true 或 false}；收到 {"type":"CloseStream"} 文本帧时冲刷剩余音频、补发最后一段，然后关闭连接。
第三步，全部跑通后打印四行信息：① 这台电脑的局域网 IP（用 ifconfig 或 ipconfig 查，192.168 或 10 开头的那个）；② Nomily AI「设置 → 转录 → 本地 ASR 服务」里要填的主机名（就是上面的局域网 IP）；③ 该页要填的端口（固定填 12300）；④ 「设置 → AI 服务 → Ollama」里要填的地址（http://局域网IP:11434）和模型名。最后提醒我：手机和电脑必须连同一个 Wi-Fi，App 两个页面里的验证按钮都通过才算部署成功。
```

</details>

<details>
<summary><strong>The prompt (English)</strong></summary>

```text
Set up this computer as the local speech backend for the Nomily AI recorder app, then print exactly what I should type into the app. Three steps:
1. Install and start Ollama, enable auto-start, expose it to the LAN (OLLAMA_HOST=0.0.0.0), and pull a chat model that fits this machine's RAM (qwen2.5:3b for 8 GB, qwen2.5:7b for 16 GB+).
2. pip-install faster-whisper and write a Python service (FastAPI + uvicorn + websockets) that runs at login (launchd on macOS, systemd/Task Scheduler elsewhere) with firewall ports 12300 and 12301 open. It must implement:
- HTTP batch transcription: listen on port 12301, POST /v1/transcribe, request body is raw audio bytes (Content-Type: application/octet-stream, usually an Ogg-Opus container that faster-whisper decodes directly), respond with JSON: {"text": "full text", "segments": [{"start": sec, "end": sec, "text": "segment"}]}.
- WebSocket live stream: listen on port 12300 at path /v1/listen. The client streams equal-length raw Opus packets (binary frames, no container header — reassemble by fixed packet length, decode to PCM, feed a streaming VAD + faster-whisper). For each recognized segment reply with a JSON text frame {"text": "...", "is_final": true or false}; on receiving the text frame {"type":"CloseStream"}, flush remaining audio, emit the final segment, and close.
3. When everything runs, print four lines: (1) this computer's LAN IP (from ifconfig/ipconfig, the 192.168.x or 10.x one); (2) the host to enter in Nomily AI under Settings → Transcription → Local ASR server (that LAN IP); (3) the port for that page (always 12300); (4) the address for Settings → AI Providers → Ollama (http://LAN-IP:11434) and the model name. Remind me the phone and this computer must be on the same Wi-Fi, and deployment is done only when both verify buttons in the app pass.
```

</details>

**What to type into Nomily AI afterwards** (the AI prints these too):

| Settings page | Field | Value |
|---|---|---|
| 设置 → 转录 → Local ASR server | Host / Port | the computer's LAN IP / `12300` |
| 设置 → AI 服务 → Ollama | Endpoint / Model | `http://<LAN-IP>:11434` / e.g. `qwen2.5:3b` |

Then tap both **verify** buttons — a green result is the whole deployment check. The port
convention is fixed: `12300` is the live WebSocket, batch transcription rides `12301`
(port + 1) — the prompt bakes both into the generated server, and the app does the same
(see `LocalASR` / `LiveStreamASR`).

Notes for the curious: the phone and the computer must stay on the same Wi-Fi; iOS asks
for **Local Network** permission on first use, grant it; a CPU-only box is fine for
faster-whisper (an hour of audio takes minutes), while the summary quality is bounded by
the Ollama model size. With both wired up, turn on **Auto-transcribe imported recordings**
and **Summarise right after transcribing** and the whole pipeline — record → transcribe →
summarize — runs without a single tap or a single key.

## Notes

- Bluetooth, hotspot configuration, and an app group are declared in `Sources/App/nomily_ios.entitlements`. The hotspot capability requires a paid Apple Developer account (free profiles cannot enable it).
- Sources are organised by feature; the BLE service is the foundation everything else depends on.
- The watch recorder started life as the standalone `apple-watch-recorder` prototype (Apple Watch Ultra long-recording experiment); the audio settings and the screen-off background-mode approach carry over from it.
- Watch-target resources are declared under `sources:` with `buildPhase: resources`, not under `resources:`. XcodeGen dedupes a path already claimed by another target's `resources:`, which silently ships a watch bundle with no `.lproj` and no asset catalog — the UI then renders raw localization keys.

## What's next

- iOS 16 `.opus` playback via libopus + libogg SPM binary target. iOS 17+ already plays Ogg-Opus natively through `AVAudioPlayer`.
- Fast Transfer polish: mid-BLE-transfer handoff (cancel in-flight downloads when the user taps the button).
- Watch: verify multi-hour screen-off recording on real hardware (the prototype's open question), and consider an Action-Button / complication launch path.
