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
│   ├── ASR/              # AsrTypes, AzureASR, LocalASR, LiveStreamASR, TranscriptionService
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

## Notes

- Bluetooth, hotspot configuration, and an app group are declared in `Sources/App/nomily_ios.entitlements`. The hotspot capability requires a paid Apple Developer account (free profiles cannot enable it).
- Sources are organised by feature; the BLE service is the foundation everything else depends on.
- The watch recorder started life as the standalone `apple-watch-recorder` prototype (Apple Watch Ultra long-recording experiment); the audio settings and the screen-off background-mode approach carry over from it.
- Watch-target resources are declared under `sources:` with `buildPhase: resources`, not under `resources:`. XcodeGen dedupes a path already claimed by another target's `resources:`, which silently ships a watch bundle with no `.lproj` and no asset catalog — the UI then renders raw localization keys.

## What's next

- iOS 16 `.opus` playback via libopus + libogg SPM binary target. iOS 17+ already plays Ogg-Opus natively through `AVAudioPlayer`.
- Fast Transfer polish: mid-BLE-transfer handoff (cancel in-flight downloads when the user taps the button).
- Watch: verify multi-hour screen-off recording on real hardware (the prototype's open question), and consider an Action-Button / complication launch path.
