import CoreBluetooth
import Foundation

// MARK: - TicNote recording card (NE-79) adapter
//
// Fact source: official App `com.mobvoi.ticnote` static reverse engineering (DEX + Dart AOT snapshot + native SO).
// Complete evidence (including source file and line number for each conclusion) see `ticnote-re/protocol-notes.md`.
//
// ┌────────────────────────────────────────────────────────────────────┐
// │ Status (Round 8: protocol layer integrated into App, and real-device capture nailed the protocol byte by byte)        │
// │  GATT layer ✅|advertising identification ✅|frame format ✅|file list (0x1A) ✅              │
// │  connection sequence / no fragmentation / mtu-3 ✅｜write type ✅ without response                     │
// │  ★ read file command = 0x1C (not the statically guessed 0x38)✅ real-device proof             │
// │  ★ voice frame = 90 bytes [0x02][sid u32][offset u32][len u8][80B] ✅      │
// │  ★ recording record = 160 bytes = 20 ms ✅                                   │
// │  ✅ audio **unencrypted**: plain Opus — 160 B/packet, TOC always 0xBC          │
// │     (CELT wideband 20 ms stereo), 64 kbps, 3522 packets = 70.44 s           │
// │     Evidence: official Opus2Ogg (+9600 per page) + ffmpeg extracts voice + afinfo verifies  │
// │  ★★ end-to-end playback ✅: real-device capture whole segment fed to `TicNoteSession`, 353 requests one by one     │
// │     reconciliation + 563,520 bytes + Ogg 576,664 B all match byte-for-byte with independent Python implementation  │
// │     consistent (self-check §18, 49 assertions)                                     │
// │  ★ integrated into App: registry driver scan + `TicNoteLink` (CoreBluetooth) +       │
// │     scan page "Recorders" section (Beta tag) + download and store (self-check §19)       │
// │  ⏳ remaining tasks: run end-to-end on real device once / broadcast pairing / iOS playback / Wi‑Fi fast transfer  │
// │     ⇒ `isVerified` still false, but **reason changed** (see file end `exposure`)  │
// └────────────────────────────────────────────────────────────────────┘
//
// Key source quick reference:
//   ── Real-device capture (hardest) ──────────────────────────────────────────────
//   captures/btsnoop_20261008_134057_d.cfa   session 0x6AC74377 full download
//   captures/att-stream2.txt                 ATT stream exported by tshark (8543 packets)
//   tools/decode_att2.py                     frame-level decoding + entropy detection
//   tools/frame_detail.py                    detailed parsing of 0x02 / 0x1C / 0x1A
//   tools/rebuild_audio.py                   reconstruct file by offset + envelope determination
//   tools/crypto_forensics.py                keystream periodicity / bitplane / chi‑square
//   tools/try_opus.py                        5 Opus hypotheses → Ogg → ffmpeg
//   ── Dart AOT snapshot (libapp.so, blutter disassembly) ─────────────────────
//   watch_audio_command.dart  —— 20 buildXxx() constructors, the sole authority on command bytes
//   watch_audio_parser.dart   —— parse() / _parseVoiceData() / _readShort()
//   watch_audio_service.dart  —— _sendCommand() / _handleClipDeviceData() dispatch table
//   ── Java/Kotlin DEX ──────────────────────────────────────────────
//   com/mobvoi/watch_plugin/WatchPlugin.java
//        · parseScanRecordForSN(byte[])  ← SN parsing in advertising (advertising identification authority)
//        · createScanDeviceMap()         ← field names sent to Dart from scan results
//        · handleSendDataToClipDevice()  ← Dart method channel entry point
//   com/mobvoi/watch_plugin/RecordingDeviceManager.java
//        · sendDataToClipDevice → UteBleClient.getUteBleConnection().sendDataToClipDevice
//   com/yc/nadalsdk/ble/open/UteBleConnection.java   ← interface definition
//   utejxif/utejxif.java        ← **UTE SDK full BLE UUID constant table**
//   utejxdo/utejxif.java        ← connection management + vendor write channels + notify registration dispatch + CCCD write
//   utejxdo/utejxtry.java       ← ClipDevice's BluetoothGattCallback (connection/MTU/write callback sequence)
//   utejxdo/utejxfor.java       ← external façade for sendDataToClipDevice / JlDevice / OLVDevice
//   utejxfor/utejxtry.java      ← final forwarding of ClipDevice write channel (3 lines)
//   utejxbyte/utejxtry.java     ← ⚠️ SDK's **sub‑packetizer** (SubPackageUtil), belongs to 0x01 dialect, **not used by this card**
//   utejxint/utejxdo.java       ← ⚠️ another recording device dialect (type=0x01), **not** this card's
//   ── Native SO (Round 5 new findings) ──────────────────────────────────────
//   libnveasysdk.so   · `_Z7initKeyv` = initKey(), seeded with `/dev/urandom`
//                       `std::random_device` generates **16‑byte random key**;
//                       `Java_com_nveasy_ble_Auth_init/_auth/_encrypt` + `AES_ECB_decrypt`
//                       + `aes_encryption_cbc` are all part of this **session handshake**, not audio keys.
//   libnveasyopus.so  · `Java_com_nveasy_audio_Opus_*` + CodecOpus — used for local encoding/decoding
//                       (App side converts PCM to wav/mp3/opus/aac), does not indicate the device-side format.

// MARK: - Write characteristic type (third correction)
//
// ⛔ **This section has been disproved by real-device capture (2026-10-08).**
//
// Static reverse engineering reasoning: UTE native write path lacks `setWriteType` → falls back to Android default
// `WRITE_TYPE_DEFAULT`(2) = write with response. The reasoning itself is correct, **but the premise is wrong** ——
// The official App's application-layer commands do not go through that native path at all, but use Dart's
// `flutter_reactive_ble`（`writeCharWithoutResponse` → `setWriteType(1)`）。
//
// **Real-device HCI log (btsnoop_20261008.cfa) behavior evidence:**
//   · `0x52` Write Command (without response) = **14 times**, all are application-layer command frames
//   · `0x12` Write Request (with response) = only 2 times:
//       - one is `01 1D 00` (getSessionState, see `TicNoteObservedCommand`)
//       - one is writing CCCD (0x2902), which should use a write with response
//   · The characteristic's own properties are `WRITE | WRITE NO RESPONSE` (both allowed)
//
// → **iOS side uses `.withoutResponse` as the default write type**;
//   `.withResponse` is reserved for CCCD and single initialization commands that require reliable delivery.


// MARK: - GATT constants

/// TicNote recording card (internal code `ClipDevice` / `juzhicard`) BLE channel constants.
///
/// ⚠️ **Important correction**: early versions of this file treated `e49a25f8 / e49a25e0 / e49a28e1`
/// as this card's FIFO service — **that was wrong**. Those three UUIDs belong to
/// `com.actions.ibluz` (Juzhi Actions iBluz), the official App only uses them for
/// `watch_plugin.actota.ActsOtaUtil` OTA channel, unrelated to recording data.
///
/// Evidence chain for this card's write channel (each hop traceable):
/// ```
/// Dart watch_audio_service._sendCommand()
///   → method channel "sendDataToClipDevice"
///   → WatchPlugin.handleSendDataToClipDevice()
///   → UTEBleEngine.sendDataToClipDevice()
///   → RecordingDeviceManager.sendDataToClipDevice()          // log tag "APK--->BLE CLIP"
///   → UteBleConnection.sendDataToClipDevice()                // interface
///   → utejxdo.utejxfor.sendDataToClipDevice()                // implementation
///   → utejxfor.utejxtry.utejxdo().utejxdo(bArr)
///   → utejxdo.utejxif.utejxint().utejxnew(bArr)              // ← the actual read/write method
///   → gatt.getService(00001910…).getCharacteristic(00002bb1…)
/// ```
/// Source: `utejxdo/utejxif.java` lines 515–531 — before writing, first
/// `setValue(bArr)` + `writeCharacteristic()`, on failure `sleep(20ms)` and retry.
///
/// Notification channel evidence: `utejxdo/utejxif.java` lines 843–852 notify registration dispatch
/// (log string `notifySet7 = `) uses **the same** Service `00001910` with `00002bb0` to enable notifications;
/// and the write callback in `utejxdo/utejxtry.java` lines 285–288 dispatches via `00002bb1`
/// `UteListenerManager.onClipDeviceWrite(...)`. The two are mirror images, 2bb0/2bb1 are paired
/// notify/write characteristics.
enum TicNoteGATT {
    /// Service — UTE SDK constant `utejxif.utejxreturn`
    static let clipService = CBUUID(string: "00001910-0000-1000-8000-00805f9b34fb")
    /// Notify (card → App) — UTE SDK constant `utejxif.utejxswitch`
    static let notifyCharacteristic = CBUUID(string: "00002bb0-0000-1000-8000-00805f9b34fb")
    /// Write (App → card) — UTE SDK constant `utejxif.utejxstatic`
    static let writeCharacteristic = CBUUID(string: "00002bb1-0000-1000-8000-00805f9b34fb")

    /// Enabling notifications requires writing the CCCD (standard value) — UTE SDK constant `utejxif.utejxsuper`
    static let clientCharacteristicConfiguration = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")

    /// **Application-layer command write type: without response (`.withoutResponse`)** — real-device capture proof.
    ///
    /// The characteristic itself declares both `WRITE` and `WRITE NO RESPONSE`, but the official App's
    /// 14 application-layer commands all use `0x52 Write Command` (without response), only
    /// `01 1D 00` (getSessionState) and CCCD use `0x12 Write Request`.
    /// Source: `ticnote-re/captures/btsnoop_20261008.cfa`.
    static let usesWriteWithoutResponse = true

    /// The card itself initiates MTU exchange (real-device test requests **93**), a rare behavior:
    /// Normally the phone side calls `requestMtu`. iOS CoreBluetooth does not allow peripheral initiation,
    /// so the value we read via `maximumWriteValueLength` is the iPhone‑negotiated result,
    /// no need to force 93. Available payload is `mtu - 3`.
    static let cardRequestedMTU = 93

    /// Desired negotiated MTU. `com.nveasy.ble.utils.Constant.DEFAULT_RECORD_MTU = 512`
    /// (`Constant.java:186`) — this is a **requested value**, not a fragmentation value.
    /// Official SDK accounting for MTU is in `phoneMTUKey`: negotiated result minus ATT overhead 3 is the usable payload.
    static let defaultMTU = 512

    /// UTE SDK side persistent default MTU: `SPUtil.getPhoneMtu()` reads SharedPreferences
    /// key `phone_mtu_sp`, **default 20** (source `SPUtil.java:173–175`).
    /// Thus when MTU negotiation fails, the SDK works with 20 bytes (= 17‑byte payload) by default.
    static let fallbackMTU = 20

    /// Protocol overhead of ATT write operation: `mtu - 3` is the bytes per packet.
    /// Source `utejxdo/utejxtry.java:360` — `onMtuChanged` uses `mtu - 3` compared with stored value,
    /// indicating the SDK's own writable payload is `mtu - 3`.
    ///
    /// **This card sends without fragmentation** (see `usesSubPacketFraming`), so a frame must be ≤ `mtu - 3`.
    /// On iOS, please use `peripheral.maximumWriteValueLength(for: .withResponse)` directly,
    /// it returns exactly that same number.
    static let writePayloadOverhead = 3

    /// ★ This card's transmission **does not perform application-layer fragmentation** — a single write is a whole frame.
    ///
    /// Evidence: the full implementation of `sendDataToClipDevice(byte[])` is
    /// `utejxdo/utejxfor.java:791` → `utejxfor/utejxtry.java:20–22` (a 3‑line class,
    /// only forwards) → `utejxdo/utejxif.java:515`'s `utejxnew()` → `setValue` + `writeCharacteristic`. 
    /// The entire chain **has no** slicing, no sub‑packet header, no checksum tail.
    ///
    /// Cross reference: UTE SDK indeed has a sub‑packetizer `utejxbyte.utejxtry` (log prefix
    /// `SubPackageUtil--`), its sub‑packet structure is
    /// `[cmdHead u16 BE][flag u16 BE][section u8][≤ MTU-5 byte payload]`,
    /// the terminating packet is `… 0xFD + CRC8` or `… 0xFD + CRC32 BE`.
    /// but it only serves the `0x01` dialect (watch family, frames like `01E1AA02…` / `01A4AAAA…`),
    /// **This card's ClipDevice link does not pass through it**.
    /// → Therefore: **do not** add length prefixes or sub‑packet headers to this card's frames, otherwise the peer will treat them as command codes.
    static let usesSubPacketFraming = false

    /// Before each write operation, UTE SDK acquires a timeout‑based “device busy” lock:
    /// `this.utejxfloat.utejxdo(3000L)` → if not acquired (>3000ms) the **entire command is discarded**.
    /// Writing CCCD to enable notifications uses the **same lock** (`utejxif.java:1029` third condition).
    /// Thus the client must queue itself, cannot write concurrently. Source: `utejxdo/utejxif.java` line 518.
    static let busyLatchTimeoutMillis = 3000

    /// Retry interval after write failure: `Thread.sleep(20L)` then retry once in place (only one retry).
    /// Source: `utejxdo/utejxif.java` line 526.
    static let writeRetryDelayMillis = 20

    /// Requeue interval when device is busy (`device busy, wait 40ms`). Source: `utejxdo/utejxif.java` lines 115/127/139/151.
    static let busyRequeueDelayMillis = 40

    // MARK: Connection timing (new this round, all from `utejxdo/utejxtry.java` Handler state machine)

    /// After connection, **wait 800 ms before `discoverServices()`**.
    /// Source `utejxdo/utejxtry.java:320` — `onConnectionStateChange` receives
    /// `newState == STATE_CONNECTED(2)` and calls `utejxdo(1, 800)`, while
    /// `utejxdo(int,int)` (`:475–482`) is `sendEmptyMessageDelayed(0, 800)`,
    /// `what == 0` is exactly “start service discovery”.
    ///
    /// ⚠️ This **replaces** the earlier note saying "write CCCD then wait 1 second" — that 1 second was copied from
    /// the Actions SDK; the UTE chain never has it.
    static let postConnectDiscoverDelayMillis = 800

    /// Dispatch delay after service discovery completes: `onServicesDiscovered` contains `sendEmptyMessageDelayed(3, 200L)`.
    /// Source `utejxdo/utejxtry.java:430`.
    static let servicesDiscoveredDispatchDelayMillis = 200

    /// Wait after MTU negotiation callback before flushing the pending queue: `onMtuChanged` contains `Thread.sleep(100L)`.
    /// Source `utejxdo/utejxtry.java:364`.
    /// iOS has no equivalent MTU callback; the equivalent approach is to send the first command after
    /// `peripheral(_:didWriteValueFor:)` / the first successful notify.
    static let mtuChangedFlushDelayMillis = 100

    /// Retry interval after service discovery failure (up to 3 times). Source `utejxdo/utejxtry.java:63`.
    static let discoverRetryDelayMillis = 500

    /// Timeout for service discovery (`what == 5`). Source `utejxdo/utejxtry.java:55`.
    static let discoverTimeoutMillis = 8000

    /// Explanation: Enabling notification (`setCharacteristicNotification` + write CCCD `0x0100`) on this path
    /// **has no sleep** (`utejxdo/utejxif.java:994–1059`), the return value is directly
    /// `registerNotify && writeResult`. Therefore “wait for CCCD to stabilize” is not a protocol requirement,
    /// it is only a conservative habit of the Android stack; on iOS you should wait
    /// `peripheral(_:didUpdateNotificationStateFor:error:)` callback.
    static let requiresNotificationStateSettle = false

    // MARK: Measured size of audio transmission (5th round real-device capture, fully supported by samples)

    /// Full-frame byte count of a voice data frame: all 7398 real-device frames are 90 bytes, without exception.
    ///
    /// `90 == 93 - 3`, which exactly equals the MTU negotiated by the card minus ATT overhead —
    /// In other words, the card fills each notify completely.
    static let voiceFrameBytes = 90

    /// Audio byte count in a voice frame: `90 - 10 = 80`.
    ///
    /// Offset `[9]` within the frame is a length byte (real device always `0x50` = 80), and audio starts at `[10]`.
    /// ⚠️ This **overturns** the earlier note that “the card has no length byte, audio starts at offset 9” —
    /// that claim was inferred from the Dart side `_parseVoiceData()` `_readInt()` call,
    /// but real-device data shows `[9]` is always 80 and the `offset` stride is always 80; both can only hold simultaneously
    /// iff `[9]` is the length byte and audio begins at `[10]`.
    static let voicePayloadBytes = 80

    /// ★ The recorded length of a single audio entry in the **file**: **160 bytes = 20 ms**.
    ///
    /// This is not a guess — cross-validated four existing recordings using the duration shown by the app:
    ///
    /// | File bytes | ÷160 | App display | Converted at 20 ms per entry |
    /// |---|---|---|---|
    /// | 42,240 | 264 | 6s | 5.28 s ✅ |
    /// | 585,600 | 3660 | 1m14s | 73.2 s ✅ |
    /// | 23,692,320 | 148,077 | **49m22s** | **2961.5 s ✅** |
    /// | 16,800 | 105 | 3s | 2.1 s ✅ |
    ///
    /// Thus bitrate = `160 B / 0.02 s = 8,000 B/s = 64 kbps`.
    /// ✅ **Round 6 correction**: the payload **is Opus** — `160 B / 20 ms = 64 kbps` is not a coincidence,
    /// this matches the bitrate reported by official `Opus2Ogg`, ffmpeg decoding, and Apple `afinfo`.
    static let recordUnitBytes = 160
    static let recordUnitMillis = 20

    // MARK: Opus packet structure (added in round 6: corroborated by official APK, ffmpeg, and afinfo)

    /// Each Opus packet is always **160 bytes** = 20 ms.
    ///
    /// * Official `com.mobvoi.wifi_plugin.socket.Opus2Ogg` — reads 1600 B each time, segment table writes `0xA0` (=160),
    ///   i.e., 10 packets of 160 B per page;
    /// * Official `AudioConvertPlugin.convertOpus2WavWithFrameSize` — default `frameSize = 160`,
    ///   log text `frameSize=160 bytes/frame`;
    /// * Apple `afinfo` —— `audio packets: 3522`、`packet size upper bound: 160`，
    ///   And 563520 / 3522 = 160.
    static let opusPacketBytes = 160

    /// The **first TOC byte** of each Opus packet: real device **3522/3522** always `0xBC`.
    ///
    /// `0xBC = 0b1011_1100` → `config = 0xBC >> 3 = 23` (CELT-only / wideband / 20 ms),
    /// `stereo = (0xBC >> 2) & 1 = 1`, frame code `= 0xBC & 3 = 0` (1 frame/packet).
    /// All three fields are **constant** ⇒ **fixed‑configuration CELT encoder**.
    ///
    /// Negative validation (the decisive criterion this round): interpret using “TOC takes the 2nd byte of each 160 B”,
    /// or slice at 80 B; `config` immediately becomes a uniform distribution covering 0…31 — that would look like random bytes.
    /// A real encoder cannot hop between NB / MB / WB / hybrid bandwidths.
    static let opusTOC: UInt8 = 0xBC

    /// The codec’s internal sampling rate is always **48 kHz** (granule unit of Ogg Opus),
    /// Each packet contains **960 samples = 20 ms**.
    /// Source: `(i2 - 1) * 9600` in `Opus2Ogg.createPxOggHeadStruct` (10 packets per page × 960),
    /// and `afinfo` reports `2 ch, 48000 Hz, opus`.
    static let opusSampleRate = 48000
    static let opusFrameSamples = 960

    /// Channel count = 2. The TOC stereo bit is 1, and `OpusHead` also writes `channels = 2`
    /// (`Opus2Ogg.createP0OggBodyStruct` contains `{1, 19, "OpusHead", 1, 2, ...}`).
    /// **Note**: this only indicates that the Opus stream is encoded in stereo, not that two microphones were recorded.
    static let opusChannels = 2

    /// Bitrate = `160 B / 20 ms` = **64 kbps** (`afinfo` original text `bit rate: 64000 bits per second`).
    static let opusBitrate = 64_000

    /// ⚠️ Packet lengths from other product lines of the same vendor, **not this card**: `OpusAudioTrackPlayer.OPUS_PACKET_BYTES = 80`
    /// (16 kHz mono, about 16 kbps), and `LocalOpusPlayer` uses 40 B/packet.
    /// Captured data has been filtered out using the TOC structure (see negative validation of `opusTOC`).
    /// It remains here to prevent future developers from using those two constants to “fix” this card.
    static let foreignProductPacketBytes = [40, 80]

    /// ⚠️ Old name, deprecated — it **is not** a “record sync byte”, but the **first TOC byte of Opus**.
    ///
    /// Real device **3522/3522 all** are `0xBC` (at offsets ≡ 0 mod 160),
    /// Offsets ≡ 80 mod 160 have only 15/3522 accidental hits (= 1/256 random baseline).
    /// The name is kept only for compatibility with existing call sites; new code should use `opusTOC`.
    static let recordSyncByte: UInt8 = opusTOC

    /// Record header length = **0 bytes**.
    ///
    /// ⚠️ **Round 6 correction**: this originally wrote `2`, based on
    /// “`pos0` entropy 0, `pos1` entropy 4.66, so the first two bytes are plaintext header and ciphertext starts at byte 3”.
    /// That reasoning was wrong by treating **Opus TOC + CELT frame first bit** as “plaintext header + ciphertext”:
    ///
    /// * `pos0` is always `0xBC` = TOC (config 23 / stereo 1 / 1 frame), **there is only one possible value**;
    /// * `pos1` low entropy = CELT frame first bit = silence flag (`logp=15`, always 0 → therefore always `< 0x80`),
    ///   followed by band0's 6‑bit coarse energy;
    /// * `pos2` from entropy 7.6–7.95 = normal output of the arithmetic encoder.
    ///
    /// All three are **the encoded stream itself**. Decoding by “stripping 2 bytes” would misalign the entire stream by 2 bytes, inevitably producing noise —
    /// This is exactly the cause of the round‑5 misjudgment that it was “ciphertext”.
    static let recordHeaderBytes = 0

    /// Byte count covered by a single `0x1C` fragment request: real device **354/355** times exactly `0x640 = 1600`
    /// (= 20 records), and the final request is `0x140 = 320` (= 4 records).
    static let syncChunkBytes = 1600

    /// End sentinel: a voice frame with `offset == 0xFFFF_FFFF` indicates the request interval has been fully transmitted.
    /// (Old conclusion retained ✅ — the real device shows this at each request’s end and on the old session’s `0x1C`.)
    static let offsetEndSentinel: UInt32 = 0xFFFF_FFFF
}

// MARK: - Raw Opus packet stream → Ogg Opus encapsulation (added in round 6)

/// A TicNote audio file **is not a container**; it is a long sequence of fixed‑length Opus packets (`opusPacketBytes` = 160).
///
/// To hand it to the system decoder (`AVAudioFile` / `AudioConverter` / `AVPlayer`), it must first be wrapped into Ogg Opus.
/// This type copies the encapsulation method from the official `com.mobvoi.wifi_plugin.socket.Opus2Ogg`,
/// and the parameters have been reconciled with `afinfo`:
///
/// * **10 packets per page** (= 1600 B), Ogg segment table = 10 entries of `0xA0` (= 160);
/// * granule increments **+9600** per page (10 × 960), unit is 48 kHz samples;
/// * first page `OpusHead` (version 1 / channels 2 / 48 kHz), second page `OpusTags`.
///
/// Acceptance criteria (`afinfo` original output for this type):
/// `2 ch, 48000 Hz, opus` / `audio packets: 3522` / `bit rate: 64000 bits per second` /
/// `packet size upper bound: 160` / `estimated duration: 70.44 sec`。
enum TicNoteOpusStream {

    // MARK: Shape validation

    /// Does this byte sequence **look like** a TicNote recording?
    ///
    /// Three criteria, all derived from real-device statistics rather than guesses:
    /// 1. Length is non‑zero and a multiple of `opusPacketBytes`;
    /// 2. **Every** packet’s TOC equals `opusTOC` (`0xBC`);
    /// 3. The first byte of each packet is `< 0x80` (the CELT silence flag is normally 0, so the high bit is always 0).
    ///
    /// Criterion 2 is the strongest: real device **3522/3522** satisfies it, whereas random bytes would hit only 1/256 per packet.
    /// Conversely, if the peer changes the encoding configuration (TOC changes), this will return `false` —
    /// In that case you should **reject saving and report it**, rather than storing the bytes as audio.
    static func looksLikeOpus(_ data: Data) -> Bool {
        let packetBytes = TicNoteGATT.opusPacketBytes
        guard !data.isEmpty, data.count % packetBytes == 0 else { return false }
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == TicNoteGATT.opusTOC else { return false }
            guard index + 1 < bytes.count, bytes[index + 1] < 0x80 else { return false }
            index += packetBytes
        }
        return true
    }

    /// Packet count = byte count / 160.
    static func packetCount(_ data: Data) -> Int {
        data.count / TicNoteGATT.opusPacketBytes
    }

    /// Split into Opus packets using `opusPacketBytes`. No validation; please run `looksLikeOpus` before calling.
    static func packets(from data: Data) -> [Data] {
        let packetBytes = TicNoteGATT.opusPacketBytes
        var result: [Data] = []
        result.reserveCapacity(data.count / packetBytes)
        var offset = data.startIndex
        while offset + packetBytes <= data.endIndex {
            result.append(data[offset..<(offset + packetBytes)])
            offset += packetBytes
        }
        return result
    }

    /// Estimate duration. **Do not trust the card’s timestamp** (its RTC does not match the phone clock),
    /// Compute directly using `recordUnitMillis` per packet: 3522 × 20 ms = 70.44 s.
    static func estimatedDuration(_ data: Data) -> TimeInterval {
        Double(packetCount(data)) * Double(TicNoteGATT.recordUnitMillis) / 1000
    }

    // MARK: Failure forensics + salvage (2026-10-23)

    /// One line describing *why* `looksLikeOpus` failed, for the LIVE diag tag.
    ///
    /// 2026-10-23 real-device hit: a live session accumulated 79 680 B
    /// (= 160 × 498, so the length check passed) yet the TOC check failed —
    /// without these numbers we could not tell "mid-stream byte loss shifted the
    /// framing" from "the card changed packet size/codec" from "an Ogg arrived".
    /// The report answers all three in one line.
    static func malformedReport(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let packetBytes = TicNoteGATT.opusPacketBytes
        var bestOffset = 0
        var bestHits = 0
        if bytes.count >= packetBytes * 3 {
            for offset in 0..<packetBytes {
                var hits = 0
                var total = 0
                var index = offset
                while index + packetBytes <= bytes.count {
                    total += 1
                    if bytes[index] == TicNoteGATT.opusTOC { hits += 1 }
                    index += packetBytes
                }
                if hits > bestHits {
                    bestHits = hits
                    bestOffset = offset
                }
            }
        }
        let alignedAtZero = bytes.enumerated()
            .filter { $0.offset % packetBytes == 0 }
            .filter { $0.element == TicNoteGATT.opusTOC }
            .count
        let oggS = Array("OggS".utf8)
        let hasOggS = bytes.count >= 4 && Array(bytes.prefix(4)) == oggS
        let hex = bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let ratio = bestHits > 0 && bytes.count >= packetBytes
            ? Double(bestHits) / Double((bytes.count - bestOffset) / packetBytes)
            : 0
        return String(format: "malformed stream: %d B (%%160=%d) first16=[%@] oggS=%d TOC@0=%d bestAlign=%d(%.1f%%)",
                      bytes.count, bytes.count % packetBytes, hex,
                      hasOggS ? 1 : 0, alignedAtZero, bestOffset, ratio * 100)
    }

    struct Salvage {
        var data: Data
        var kept: Int
        var total: Int
        var alignmentOffset: Int
    }

    /// Best-effort recovery of a stream that failed the strict `looksLikeOpus`
    /// check. Two independent defects can be repaired without losing the take:
    ///
    /// 1. **Prefix misalignment** (a few bytes lost before/at stream start): every
    ///    packet boundary is shifted by the same offset `o < 160`. Trying each `o`
    ///    and re-slicing recovers *all* packets after the offset.
    /// 2. **Scattered bad packets** (a corrupted frame mid-stream): the valid
    ///    packets around it are self-contained CELT frames — dropping the bad
    ///    ones costs a 20 ms gap each, not the recording.
    ///
    /// Returns nil when the stream does not look recoverable (kept ratio too low
    /// or too few packets survived) — the caller should then keep the original
    /// hard failure rather than save garbage.
    static func salvage(_ data: Data, minKeepRatio: Double = 0.6, minPackets: Int = 10) -> Salvage? {
        let bytes = [UInt8](data)
        let packetBytes = TicNoteGATT.opusPacketBytes
        guard bytes.count >= packetBytes else { return nil }

        // Find the alignment offset that makes the most packets start with the TOC.
        var bestOffset = 0
        var bestHits = 0
        for offset in 0..<packetBytes {
            var hits = 0
            var index = offset
            while index + packetBytes <= bytes.count {
                if bytes[index] == TicNoteGATT.opusTOC { hits += 1 }
                index += packetBytes
            }
            if hits > bestHits {
                bestHits = hits
                bestOffset = offset
            }
        }
        guard bestHits >= minPackets else { return nil }

        var kept = Data()
        var keptCount = 0
        var totalCount = 0
        var index = bestOffset
        while index + packetBytes <= bytes.count {
            totalCount += 1
            if bytes[index] == TicNoteGATT.opusTOC {
                kept.append(contentsOf: bytes[index..<(index + packetBytes)])
                keptCount += 1
            }
            index += packetBytes
        }
        guard totalCount > 0, Double(keptCount) / Double(totalCount) >= minKeepRatio else {
            return nil
        }
        return Salvage(data: kept, kept: keptCount, total: totalCount, alignmentOffset: bestOffset)
    }

    // MARK: Ogg encapsulation

    /// Ogg CRC32: polynomial `0x04c11db7`, no reflection, initial value 0 — matches the official `Opus2Ogg`.
    ///
    /// Changed to `internal` (removed `private`) so that self‑check can directly reconcile the first few entries of the official 256‑item table;
    /// If that table is miscalculated, the entire Ogg will be deemed corrupted by the system decoder, warranting a dedicated assertion.
    static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var remainder = UInt32(i) << 24
            for _ in 0..<8 {
                remainder = (remainder & 0x8000_0000) != 0
                    ? ((remainder << 1) ^ 0x04c1_1db7)
                    : (remainder << 1)
            }
            table[i] = remainder
        }
        return table
    }()

    static func oggCRC(_ bytes: [UInt8]) -> UInt32 {
        var remainder: UInt32 = 0
        for byte in bytes {
            remainder = (remainder << 8) ^ crcTable[Int((remainder >> 24) & 0xFF) ^ Int(byte)]
        }
        return remainder
    }

    /// Assemble one Ogg page. `segments` is the segment table (lacing values), `body` is the data area.
    private static func page(
        segments: [UInt8],
        body: [UInt8],
        granule: UInt64,
        serial: UInt32,
        sequence: UInt32,
        headerType: UInt8
    ) -> [UInt8] {
        var header = Array("OggS".utf8)
        header.append(0)              // Stream structure version
        header.append(headerType)     // 0x02 first page / 0x04 last page / 0x00 normal
        for shift in stride(from: 0, through: 56, by: 8) {
            header.append(UInt8((granule >> UInt64(shift)) & 0xFF))
        }
        for shift in stride(from: 0, through: 24, by: 8) {
            header.append(UInt8((serial >> UInt32(shift)) & 0xFF))
        }
        for shift in stride(from: 0, through: 24, by: 8) {
            header.append(UInt8((sequence >> UInt32(shift)) & 0xFF))
        }
        header.append(contentsOf: [0, 0, 0, 0])          // CRC placeholder, to be filled later
        header.append(UInt8(segments.count))             // Number of segments
        header.append(contentsOf: segments)

        let crc = oggCRC(header + body)
        header[22] = UInt8(crc & 0xFF)
        header[23] = UInt8((crc >> 8) & 0xFF)
        header[24] = UInt8((crc >> 16) & 0xFF)
        header[25] = UInt8((crc >> 24) & 0xFF)
        return header + body
    }

    /// Number of packets per page — matches the official `Opus2Ogg` 1600 B per page.
    static let packetsPerPage = 10

    /// Wrap the raw packet stream into Ogg Opus. Returns `nil` to indicate shape validation failed (see `looksLikeOpus`).
    ///
    /// - Parameter preSkip: `OpusHead` pre-skip, unit is 48 kHz samples.
    ///   Default 312 (standard lookahead for libopus @48 kHz). The official `Opus2Ogg` writes
    ///   **16000** (≈333 ms), meaning differs; if you want **byte‑for‑byte replica of the official output**, pass 16000.
    ///   To **fully align with what the App hears** (App uses native raw decoding without any pre‑skip), pass 0.
    ///
    /// ⚠️ This function only wraps, **does not decrypt** — because this payload is not encrypted.
    static func oggOpus(
        from data: Data,
        serial: UInt32 = 0x5449_4E43,   // "TINC"
        preSkip: UInt16 = 312
    ) -> Data? {
        guard looksLikeOpus(data) else { return nil }
        let packets = packets(from: data)
        var output: [UInt8] = []

        // Page 0: OpusHead
        var head = Array("OpusHead".utf8)
        head.append(1)                                             // Version
        head.append(UInt8(TicNoteGATT.opusChannels))               // Channel count
        head.append(UInt8(preSkip & 0xFF))                         // pre-skip LE
        head.append(UInt8((preSkip >> 8) & 0xFF))
        for shift in stride(from: 0, through: 24, by: 8) {         // Input sample rate LE
            head.append(UInt8((UInt32(TicNoteGATT.opusSampleRate) >> UInt32(shift)) & 0xFF))
        }
        head.append(contentsOf: [0, 0])                            // Output gain
        head.append(0)                                             // Channel mapping family 0
        output += page(segments: [UInt8(head.count)], body: head,
                       granule: 0, serial: serial, sequence: 0, headerType: 0x02)

        // Page 1: OpusTags (vendor and comments left empty)
        var tags = Array("OpusTags".utf8)
        tags.append(contentsOf: [0, 0, 0, 0])                      // vendor string length 0
        tags.append(contentsOf: [0, 0, 0, 0])                      // comment count 0
        output += page(segments: [UInt8(tags.count)], body: tags,
                       granule: 0, serial: serial, sequence: 1, headerType: 0x00)

        // Page 2…: packetsPerPage packets per page
        var sequence: UInt32 = 2
        var granule: UInt64 = 0
        var index = 0
        while index < packets.count {
            let end = min(index + packetsPerPage, packets.count)
            var segments: [UInt8] = []
            var body: [UInt8] = []
            for packet in packets[index..<end] {
                // 160 < 255, a lacing value fits; when using variable‑length packets it must be changed to 255 segments.
                segments.append(UInt8(packet.count))
                body.append(contentsOf: packet)
            }
            granule += UInt64(TicNoteGATT.opusFrameSamples * (end - index))
            let isLast = end >= packets.count
            output += page(segments: segments, body: body, granule: granule,
                           serial: serial, sequence: sequence,
                           headerType: isLast ? 0x04 : 0x00)
            sequence += 1
            index = end
        }
        return Data(output)
    }
}

// MARK: - Broadcast identification (manufacturer data)

/// Identity information extracted from the card's broadcast.
struct TicNoteAdvertisement {
    /// Card serial number (ASCII). This is the primary key the official App uses to identify the card
    /// (`[CardOta] device distinguishes sn=`, during binding `checkDeviceBind: `, cloud `deviceInfo.sn`).
    let sn: String
    /// Bytes skipped before the SN in the manufacturer data. Kept only for matching real‑device broadcasts,
    /// the official code does not read it (presumably model / hardware version, etc.).
    let reserved: Data
}

/// Parser for the card broadcast's "manufacturer custom data".
///
/// The authoritative implementation is the native side **`WatchPlugin.parseScanRecordForSN(byte[])`**
/// (`com/mobvoi/watch_plugin/WatchPlugin.java` lines 3359–3396).
/// It is called by `createScanDeviceMap()` (lines 149–164) in each scan callback,
/// After extracting `sn`, it is placed into the map sent to Dart: `{type, deviceName, deviceAddress, rssi, sn?}`
/// (event name `scan` / `complete` when finished).
///
/// The Dart AOT snapshot **contains no** manufacturer data parsing (full‑text searched) — so this is the only authoritative source.
///
/// Byte‑level reconstruction of the official algorithm (`i2` is the start of the current AD structure, `i = scanRecord[i2]` is the length of that segment):
/// ```
/// Offset (within manufacturer data)  Length   Meaning
///   0..1              2     Company identifier (Company ID), little‑endian = 0x0259 = 601
///   2                 1     【Not read by official】
///   3                 1     【Not read by official】
///   4                 1     N — number of bytes skipped afterwards
///   5 .. 4+N          N     Skipped (reserved segment)
///   5+N               1     L — SN length
///   6+N .. 5+N+L      L     SN（US-ASCII）
/// ```
/// Validation (official implementation is fail‑closed; any out‑of‑bounds returns null, never guessed):
/// `data.count >= 6`、`5+N < data.count`、`6+N+L <= data.count`。
///
/// ⚠️ The two bytes `[2]`/`[3]` are indeed not read by the official code. They are most likely "sub‑version + payload type",
/// but they do not affect SN location — when implementing, **copy the official offsets** verbatim, don't be clever.
/// Method to verify on a real device is in `CAPTURE-MANUAL.md` (just capture a detailed screenshot with nRF Connect).
enum TicNoteAdvertisementParser {

    /// Bluetooth SIG company identifier. `0x0259 = 601`, little‑endian on the wire is `59 02`.
    /// This is **the first and only gate for identifying the card** (more reliable than device name: the official App allows renaming).
    static let companyID: UInt16 = 601

    /// AD type of manufacturer custom data in the scanned AD structure.
    static let manufacturerSpecificDataType: UInt8 = 0xFF

    /// Parsed from CoreBluetooth's `CBAdvertisementDataManufacturerDataKey`.
    ///
    /// The `manufacturerData` provided by CoreBluetooth **does not include** the AD length and type two bytes,
    /// starts directly from the company identifier — exactly aligns with the segment after `i2 + 2` in the official algorithm.
    static func parse(manufacturerData: Data) -> TicNoteAdvertisement? {
        let b = [UInt8](manufacturerData)
        guard b.count >= 6 else { return nil }
        guard UInt16(b[0]) | (UInt16(b[1]) << 8) == companyID else { return nil }

        let n = Int(b[4])
        let lengthIndex = 5 + n
        guard lengthIndex < b.count else { return nil }

        let l = Int(b[lengthIndex])
        let snStart = lengthIndex + 1
        let snEnd = snStart + l
        guard snEnd <= b.count, l > 0 else { return nil }

        // The official code decodes using US_ASCII. Anything outside ASCII is rejected to avoid treating binary noise as SN.
        guard let sn = String(bytes: b[snStart..<snEnd], encoding: .ascii) else { return nil }
        return TicNoteAdvertisement(sn: sn, reserved: Data(b[5..<lengthIndex]))
    }

    /// Parsed from the **raw scan record** (full AD structure string).
    ///
    /// Used to obtain raw broadcast bytes outside of `CBPeripheral` contexts (e.g., Android's
    /// `ScanResult.getScanRecord()`, or packet capture logs). Traversal rules match the official one:
    /// Each segment `[len][type][len-1 bytes of data]`, `len == 0` terminates, cursor advances `len + 1`.
    static func parse(scanRecord: Data) -> TicNoteAdvertisement? {
        let b = [UInt8](scanRecord)
        var cursor = 0
        while cursor < b.count {
            let len = Int(b[cursor])
            if len == 0 || cursor + len >= b.count { break }
            if b[cursor + 1] == manufacturerSpecificDataType {
                // Manufacturer data is at cursor+2 in the AD, length len-1
                let payload = Data(b[(cursor + 2)..<(cursor + len + 1)])
                if let adv = parse(manufacturerData: payload) { return adv }
            }
            cursor += len + 1   // Official equivalent code `i2 += i + 1`
        }
        return nil
    }
}

// MARK: - Packet type (first byte of frame header)

/// The first byte of the TicNote frame header — **payload class bits**, not direction bits.
///
/// ⚠️ Early notes claimed "`0x02` is the value for App → card command packets", **which is incorrect**.
/// Statistics from the 5th round of real‑device HCI capture (`captures/att-stream2.txt`, 8543 ATT packets):
/// ```
///   Outbound direction App→Card wrote 371 entries → all 371 are type=0x01, none type=0x02
///   Inbound direction Card→App 8187 entries → 7398 type=0x02 (voice payload) + 789 type=0x01 (control)
/// ```
/// Thus `0x01` / `0x02` distinguish **control frames / voice payload**, and both directions use `0x01` for control frames;
/// Direction can only be distinguished by ATT opcode (write vs notify). The same command code appears in both directions
/// (e.g., `0x1C` request 16 bytes, response 8 bytes), which directly proves "use opcode, not type, to differentiate direction".
enum TicNotePacketType: UInt8 {
    /// 0x01 — **control frame** (bidirectional): command, command response, notification. Real device outbound 371/371.
    case commandResponse = 0x01
    /// 0x02 — **voice/recording data** (this round only saw Card→App direction, 7398 entries).
    /// In voice frames, `[1..2]` is not a command code but the low 16 bits of `sessionId`, so it cannot be used for command dispatch.
    case voiceData = 0x02
    /// 0x03 — real‑time audio stream, handled by `_parseRealtimeAudioStream()`, not part of command dispatch.
    case realtimeAudio = 0x03
}

// MARK: - Command code

/// App → Card command code. **Each value corresponds to a `buildXxx()` constructor**, no speculation.
///
/// Frame header is fixed as `[0x01][cmd low byte][cmd high byte]` (the earlier `0x02` was disproved by real devices,
/// see `TicNotePacketType`). All known commands are < 0x100, so the high byte is always `0x00` ——
/// but **it must actually be written** because the peer reads it as little‑endian uint16.
/// （`WatchAudioParser._readShort()`：`return (b1 << 8) | b0`）。
///
/// ## ⚠️ The stored value here is a **Smi tag value**, not the on‑wire value — `wireValue` is the on‑wire byte
///
/// Dart AOT stores `int` as **Smi**, i.e., `tagged = actual << 1` (low bit used as type tag).
/// In blutter's comments, `r16 = 40` / `mov x16, #0x28` emit a **tagged word**, so each
/// constant copied from disassembly must be `>> 1` to get the actual value.
///
/// **This is no longer speculation — the disassembly directly shows the tag/untag instructions** (reviewed 2026-10-10):
/// ```
///   Untag (compute list length): sbfx x3, x1, #1, #0x1f   ← arithmetic right shift 1
///   Tag (store input into list): lsl w5, w2, #1        ← left shift 1
/// ```
/// Both appear in the same function body `WriteCmd::recordStart` (`writeBle.dart` 0x13b2afc
/// and 0x13b2b38), they are inverse operations, so "tag = actual × 2" is **derived**, not guessed.
///
/// Independent verification (left = this enum, right = real‑device ATT capture measurements):
/// ```
///   getStatusInfo  0x06 / 2 = 0x03   real device out 1 in 3  type=0x01 cmd=0x0003  ✅
///   getBattery     0x12 / 2 = 0x09   real device out 2 in 7  type=0x01 cmd=0x0009  ✅
///   generalSetting 0x10 / 2 = 0x08   real device out 2 in 2  type=0x01 cmd=0x0008  ✅
///   setUsbMode     0x18 / 2 = 0x0C   real device out 1 in 1  type=0x01 cmd=0x000C  ✅
///   recordStart    0x28 / 2 = 0x14   real device in 2     type=0x01 cmd=0x0014  ✅
///   recordStop     0x2E / 2 = 0x17   real device in 2     type=0x01 cmd=0x0017  ✅
///   getSessionList 0x34 / 2 = 0x1A   real device out 4 in 4  type=0x01 cmd=0x001A  ✅
///   syncFile       0x38 / 2 = 0x1C   real device out 355 in 355 cmd=0x001C        ✅
///   syncFileStop   0x3A / 2 = 0x1D   real device in 354    cmd=0x001D           ✅
///   deleteRecord   0x3C / 2 = 0x1E   real device in 2     cmd=0x001E           ✅
/// ```
/// Each converted entry **is correct**, so this table can be used confidently (early interpretation as "switch table index ×2"
/// was wrong — the conclusion is the same, but that explanation does not survive disassembly review).
///
/// The toughest calibration is `WriteCmd::recordEnd`: disassembly list = `[2, 46, 0]` (tagged words),
/// `2>>1=1`, `46>>1=23=0x17` → on‑wire `01 17 00`, matching the capture byte‑for‑byte.
///
/// Commands not seen on a real device (e.g., `sendTranscription`) use the same conversion — this layer remains **assumed**,
/// When first used, they must be verified with a real‑device capture. **All tested commands go through `TicNoteObservedCommand`.**
enum TicNoteCommand: UInt16 {

    // ── Status query ──────────────────────────────────────────────
    /// `02 06 00`｜response 0x06 → `_handleDeviceStatusResponse`
    case readStatus = 0x06
    /// `02 10 00 <u8>`｜response 0x10 → `_handleGeneralSettingResponse`
    case generalSetting = 0x10
    /// `02 12 00`｜response 0x12 → `_handleBatteryResponse`
    case getBattery = 0x12
    /// `02 14 00`｜open Wi‑Fi fast transfer
    case openWifi = 0x14
    /// `02 16 …`｜audio type (only seen 0x16 on the **response** side → `_handleAudioTypeResponse`)
    case audioType = 0x16
    /// `02 18 00 00`｜switch USB mode (charging / storage)
    case setUsbMode = 0x18

    // ── Recording control ──────────────────────────────────────────────
    /// `01 14 00 | 01 <scene> 00 00 00 00`｜**start recording** (9 bytes, payload fixed 6 bytes)
    ///
    /// ★ The card **also uses `0x14`** to push this event back (`01 14 00 <sid:4> <scene> 00×4 <status>`),
    /// Thus this code is bidirectional, **distinguished by direction**: App→Card = command to start recording; Card→App = "I am already recording".
    /// The reverse `0x14` is the actual "recording start acknowledgment" — see `TicNoteRecordingState`.
    case recordStart = 0x28
    /// `02 2A 00 <u32 LE>`｜pause
    case recordPause = 0x2A
    /// `02 2C 00 <u32 LE>`｜resume
    case recordResume = 0x2C
    /// `02 2E 00`｜stop
    case recordStop = 0x2E

    // ── Recording files ──────────────────────────────────────────────
    /// `02 34 00 <u32 LE> <u32 LE> <u8>` (12 bytes)｜retrieve recording file list.
    /// The two u32 likely represent `uid / start_session` (corroborated by the same SDK's
    /// `RequestAudioRecordFileInfo{uid, start_session, only_one}` which is framed in this order,
    /// see `utejxint/utejxdo.java` lines 282–293).
    /// ⚠️ Its **response** has not yet been found a parsing point on the Dart side (logs show the list goes through the native `downFileList` plugin),
    /// and is **not** the same as the `0x26` frame below — see protocol‑notes.md §12.
    case getSessionList = 0x34
    /// `02 38 00 <u32 LE> <u32 LE> <u32 LE> <u8>`｜**Read file fragment** (core)
    /// The three u32 are presumed to be `sessionId / offset / length`, u8 is a flag — see §7, to be confirmed
    case syncFile = 0x38
    /// `02 3A 00`｜End read file
    case syncFileStop = 0x3A
    /// `02 3C 00 <u32 LE> <u8>`｜Delete a recording
    case deleteRecord = 0x3C

    // ── Cloud / Text ───────────────────────────────────────────
    /// `02 40 00 <u32> <u32> <u8> <utf8…> <u8>`｜Send transcribed text back to the card
    case sendTranscription = 0x40
    /// `02 42 00 <u32> <u32> <u8> <utf8…> <u8>`｜Send meeting minutes back to the card
    case sendMeetingSummary = 0x42
    /// `02 44 00 <u8> <u8>`｜Real-time transcription switch
    case setRealtimeTranscriptionEnable = 0x44

    // ── Card-initiated request, App must respond ───────────────────────────────
    /// `02 46 00 <u8>`｜Respond to the card's 0x46 request (real-time transcription)
    case ackRealtimeTranscriptionRequest = 0x46
    /// `02 48 00 00`｜Respond to the card's 0x48 notification (recording bookmark)
    case ackBookmarkNotify = 0x48
    /// `02 4A 00 00`｜Respond to the card's 0x4A (display mode switch)
    case ackDisplayModeSwitch = 0x4A
    /// `02 4C 00 <u32 LE>`｜Bookmark synchronization request
    case bookmarkSync = 0x4C

    /// **Upper bound** = static reverse value ÷ 2. Frame assembly must use this, do not use `rawValue` directly.
    /// Conversion basis and per-item verification are in this enum's documentation comments; tested commands also see `TicNoteObservedCommand`.
    var wireValue: UInt16 { rawValue >> 1 }

    /// Fixed payload (in Dart it's a literal list, no input parameters involved in calculation).
    /// `nil` indicates that the command's payload requires parameters; use the constructor of `TicNoteFrameCodec`.
    var fixedPayload: Data? {
        switch self {
        case .readStatus, .getBattery, .openWifi, .recordStop, .syncFileStop:
            return Data()
        case .setUsbMode:
            return Data([0x00])
        case .recordStart:
            // Authoritative bytes (after removing Smi tag): 01 14 00 | 01 <scene> 00 00 00 00
            // ⚠️ The second byte is **recording scene parameter**, not a constant — see `recordStartPayload`.
            return Self.recordStartPayload()
        case .ackRealtimeTranscriptionRequest:
            return Data([0x00])            // Length varies with status bits; this is the "off" value.
        case .ackBookmarkNotify, .ackDisplayModeSwitch:
            return Data([0x00])
        default:
            return nil
        }
    }

    /// Payload of the start-recording command (**6 bytes**).
    ///
    /// ## Byte-by-byte source (`WriteCmd::recordStart`, `writeBle.dart` 0x13b2990…0x13b2c38)
    /// Disassembly is 9 consecutive element appends, **the first 3 are the frame header** (type + cmd u16 LE):
    /// ```
    ///   Element  Tag word (blutter)  Real value (= tag word >> 1)  Description
    ///   [0]   0x02             0x01                 type = control frame
    ///   [1]   0x28             0x14                 cmd low byte = 0x14 (= 20)
    ///   [2]   0x00             0x00                 cmd high byte
    ///   [3]   0x02             0x01   ← ★ constant     payload[0]
    ///   [4]   <input & 0xFF>    <scene>              payload[1] = recording scene
    ///   [5..8] 0x00            0x00                 payload[2..5] = 0
    /// ```
    ///
    /// ⚠️ **payload first byte is `0x01`, not `0x02`**. Early versions wrote `0x02` because
    /// the element `[3]`'s **tag word** `0x02` was taken directly as the byte value (while the same line's `0x28` was correctly
    /// >>1` became `0x14`) — half the list was converted, half not, resulting in a one-byte error.
    /// In the disassembly, `lsl w5, w2, #1` (left-shift input by 1 before storing into the list) is solid evidence that "elements store the tag word".
    ///
    /// Default scene see `TicNoteRecordingScene`; callers should preferably pass the **rec_scene read from the card**
    /// (The official `beginRec` does this: read general settings first, then use its value to start recording).
    /// Corroboration: the scene byte in the card's returned `0x14` is `0x02` on real device, matching `0x08`'s `rec_scene: 2`.
    static func recordStartPayload(scene: UInt8 = TicNoteRecordingScene.defaultScene) -> Data {
        Data([0x01, scene, 0x00, 0x00, 0x00, 0x00])
    }
}

// MARK: - Command newly confirmed by real-device capture (2026-10-08, vivo V2172A / Android 15 + btsnoop)

/// These command codes **are not** in the official App's Dart distribution list (so static reverse engineering didn't see them),
/// All come from real-device HCI log `btsnoop_20261008.cfa` ATT stream decoding (see
/// `ticnote-re/captures/att-decoded.txt`). Frame structure matches the known
/// `[type][cmd u16 LE][payload]` is completely identical.
enum TicNoteObservedCommand: UInt16 {
    /// App→Card `01 01 00 02 01 00` (query) / `… 01 <16B bondID> <len> <UTF-8 name>`
    /// In real-device sample, bondID = "1234567890000000", name = "clip c1 pro" (13 bytes)
    case setDeviceIdentity      = 0x01
    /// Card→App, 61-byte response (mostly zeros, tail `56 07 00 00`)
    case deviceIdentityResponse = 0x02
    /// App→Card (empty payload) → Card returns 9 bytes
    case getStatusInfo          = 0x03
    /// ★ **Time synchronization command** — previously static reverse assumed "no time sync command in the whole table", real device disproved this.
    /// App→Card `<u32 timestamp LE><u8>`; Card returns `<u32 timestamp LE><u8><u8>`
    /// Real-device example: `45 3A C7 6A 08` (0x6AC73A45 = 2026-10-08 14:37:57 +08)
    /// (The same code is reused bidirectionally, direction distinguished by frame header type — same pattern as 0x28/0x2A/0x2E)
    case syncTime               = 0x04
    /// ★ **Unbind device** (`0x05`). Online frame `01 05 00 | 00`.
    ///
    /// Source: `WriteCmd::unbind` (`blutter_out/asm/…/dartBle/writeBle.dart`)
    /// Disassembly list is `[2, 10, 0, 0]` → remove Smi tag → `01 05 00 00`
    /// (`tools/dart_write_layout.py unbind` verification matches).
    ///
    /// **This conversion itself is trustworthy**, because two other entries in the same table have been matched byte-by-byte with the real device:
    /// ```
    /// readStatus       → 01 03 00   real device 01 03 00  ✅
    /// getStorageVolume → 01 06 00   real device 01 06 00  ✅
    /// ```
    ///
    /// ⚠️ But **`0x05` has zero occurrences in all real-device captures** (`captures/hci-all/` TicNote only has
    /// **2 independent connections**, plus 2 captures of D·NOTE V05E — see `protocol-notes.md` §31.1),
    /// payload fourth byte `0x00`
    /// meaning (whether it's a "clear data" switch) **has no sample evidence** — therefore copy the official byte,
    /// do not add parameters yourself, and label it clearly as "Unbind" in the UI (no promise to "erase recordings on the card").
    case unbindDevice           = 0x05
    /// ★★ **Check storage usage** (`0x06`). App→Card `01 06 00`; Card→App `01 06 00 | <13 B>`.
    ///
    /// Field layout, real-device samples, and correspondence with official data class are in `TicNoteStorageInfo`.
    /// The official side reads it via `UteBleConnection.getDeviceStorageInfo()`
    /// → `com.yc.nadalsdk.bean.recorder.DeviceStorageInfo`。
    ///
    /// ⚠️ **This command will not appear spontaneously on the card**: in HCI captures it appears only twice in total
    /// (Each time just before `0x08`) — meaning you must **actively query** to obtain it.
    ///
    /// ⚠️ But **the frequency in App diagnostic logs is far higher than in HCI captures**: `app-diag-2026-10-10-1541.log`
    /// It appears in the **four-shot burst** of `0x03 / 0x06 / 0x09 / 0x1A`, **each with a response**. So
    /// "Rare in HCI" **does not mean** "the card rarely handles it", just that the connection wasn't fully captured. Sample:
    /// ```
    /// → WC  01 06 00
    /// ← CTL 01 06 00 00 E2 A3 03 40 E5 A0 03 40 9C 00 00 00
    ///                total      free       thirdField    state
    /// ```
    /// In the same recording, `free` decreases monotonically (`…E540` → `…E500` → `…E4E0`), `total` stays constant at `0x03A3E200`.
    case queryStorage           = 0x06
    /// **General settings: read/write bidirectional reuse** (`0x08`).
    ///
    /// ```
    /// Read: App→Card 01 08 00 01        Card→App 01 08 00 00 02 00 01 7F 00 00
    /// Write: App→Card 01 08 00 02 <led> <scene> <mode> <row_data> <micCode>
    /// ```
    ///
    /// ★ The 4th byte is **direction flag**: `0x01` = request current settings; `0x02` = this is a new setting.
    /// The 6-byte payload of the write frame comes byte-by-byte from official `MyDeviceLogic::changeVolume`
    /// (see `TicNoteMicrophoneGain` and `TicNoteGeneralSetting.writePayload`).
    case getConfig              = 0x08
    /// App→Card (empty) → Card returns `00 64`; `0x64` = 100, exactly the battery percentage
    case getBattery             = 0x09
    /// Card→App `01`
    case notifyB                = 0x0B
    /// App→Card `00` → Card returns `03 00 00`
    case setC                   = 0x0C
    /// ★ **Card→App: recording start** (`0x14`). payload **fixed length 10 bytes**:
    ///
    /// ```
    /// <u32 sessionId> <u8 scene> <u32 startTime> <u8 status>
    /// f1 38 c7 6a      02          00 00 00 00       00
    /// ```
    ///
    /// * `sessionId` = **the recording's start Unix seconds** (`0x6AC738F1` → 2026-10-08).
    ///   It also serves as the "filename" — both `0x1A` list and `0x1C` request use this value as the key.
    /// * `scene` on real device = `0x02`, exactly matching `0x08` general setting's `rec_scene: 2`
    ///   (This is the cleanest corroboration that "this frame = start-recording event").
    /// * `startTime` on real device always 0; `status` always 0 (**meaning unknown, no speculation**).
    ///
    /// ## Why this frame matters
    /// ⚠️ **2026-10-12 correction (see `protocol-notes.md` §31.3①)**: previously it said
    /// "it **is** the `0x14` start-recording command's acknowledgment" — **this statement is wrong, retracted**.
    ///
    /// `captures/app-diag-2026-10-10-1541.log` shows App start recording **8 times**,
    /// each time the card returns `0x18` (`01 18 00 <sid> 02 …`); whereas the inbound direction of `0x14`
    /// appears only **once** in the entire 40‑minute log, and does not belong to any App start recording.
    ///
    /// Do not mix the three frame types (**distinguish by direction + frame length**):
    /// * `App→Card 01 14 00 01 <scene> 00 00 00 00` (9 B) = **start recording request**
    /// * `Card→App 01 18 00 <sid> <scene> <recordedBytes> <status>` (13 B)
    ///   = **start recording accepted + real-time progress** (**this is the acknowledgment**)
    /// * `Card→App 01 14 00 <sid> <scene> <startTime> <status>` (13 B)
    ///   = **Card-initiated recording** (physical button; the two instances in `bug2` are this)
    ///
    /// The meaning of this frame hasn't changed: it is **the device truth that "the card is indeed recording"** (physical button path),
    /// The App side should no longer guess using a local timer (see `TicNoteLink.streamingVoice`).
    case notifySession          = 0x14
    /// Card→App: **recording pause**. `<u32 sessionId> <u8 status> <u32 size>`
    /// (Layout from `ReviceCmd` registry, not yet captured on real device).
    case notifyRecordingPaused  = 0x15
    /// Card→App: **recording resume**. `<u32 sessionId> <u8 status> <u32 size>`
    /// (Same as above, no real-device sample yet).
    case notifyRecordingResumed = 0x16
    /// ★ **Card↔App bidirectional reuse: recording end / stop recording** (`0x17`).
    ///
    /// ⚠️ **2026-10-12 addition (see `protocol-notes.md` §31.3②)**: previously only the inbound direction was recorded here.
    /// On real device, **App→Card direction occurs 7 times**, all **bare frames `01 17 00` (3 B)**, each exactly matching
    /// the App's "stop recording" action:
    ///
    /// ```
    /// App→Card 01 17 00                                   (3 B)  = stop recording
    /// Card→App 01 17 00 <sid> <status> <isSave> <fileSize> (14 B) = recording status report
    /// ```
    ///
    /// Inbound direction payload **fixed length 10 bytes**:
    ///
    /// ```
    /// <u32 sessionId> <u8 status> <u8 isSave> <u32 fileSize>
    /// 77 43 c7 6a      01          01          40 99 08 00
    /// ```
    ///
    /// * `fileSize` = the recording's **final byte count** (0x00089940 = 563,520).
    ///   Matches the size in the `0x1A` list and the end of the last `0x1C` request **exactly** —
    ///   this capture provides the cleanest three-way cross verification.
    /// * `isSave` on real device = `0x01` (saved); `status` meaning **still unknown (no speculation)**,
    ///   but 9 real-device samples from 2026-10-12 show distribution: most are `0x02`, **two long recordings are `0x01`**
    ///   (`fileSize` 1982400 / 34560) — therefore `status` **is not** the "save or not" switch
    ///   (that is `isSave`), more like "termination mode / whether normal closure".
    ///
    /// 9 inbound real-device samples (`captures/app-diag-2026-10-10-1541.log`):
    /// ```
    /// sid=6AC9E2C6 status=02 saved=01 fileSize=24960
    /// sid=6AC9E307 status=02 saved=01 fileSize=18240
    /// sid=6AC9E3C9 status=02 saved=01 fileSize=10080
    /// sid=6AC9E3DB status=02 saved=01 fileSize=165120
    /// sid=6AC9E49E status=02 saved=01 fileSize=17280
    /// sid=6AC9E554 status=01 saved=01 fileSize=1982400   ← status=01
    /// sid=6AC9E733 status=02 saved=01 fileSize=185280
    /// sid=6AC9EB7C status=02 saved=01 fileSize=50400
    /// sid=6AC9EB89 status=01 saved=01 fileSize=34560    ← status=01
    /// ```
    ///
    /// ⚠️ Different layout from `0x14` (**the 5th byte is scene in one, status in the other**),
    /// parsing must be handled separately per cmd — see `TicNoteRecordingState.parse`.
    ///
    /// ⚠️ When recording starts, it also sends a **fileSize = 0** message (real device #14848):
    /// Using it as "recorded duration" will freeze the timer at 0:00 (reported by users).
    /// Therefore only values **greater than 0** are trusted.
    case notifyRecordingState   = 0x17
    /// ★★★ **Card→App: recording status report** (`0x18`) — **19th round real-device new finding**
    ///
    /// This command code **is not in any static reverse‑engineering table**, discovered on 2026-10-10 with `tools/bleprobe rec`
    /// It is returned by the card after sending `0x14` on a real device. It is **currently the only way to read the "recorded byte count" in real time**.
    ///
    /// ## Candidate layout (all four real‑device samples are self‑consistent)
    /// ```
    /// <u8 len=0x0a> <u32 sessionId> <u32 recordedBytes> <u8 status>
    /// ```
    ///
    /// Four samples (`tools/bleprobe` 19th round log, byte‑by‑byte extraction):
    ///
    /// | Timing | payload | sessionId | recordedBytes | status |
    /// |---|---|---|---|---|
    /// | After start 1.6 s | `0a 7b db c9 02 00 00 00 00 00` | `0x02C9DB7B` | **0** | 00 |
    /// | After start 4.3 s | `0a 7b db c9 02 c0 4e 00 00 00` | `0x02C9DB7B` | **20,160** | 00 |
    /// | After A segment frame of A/B 1.6 s | `0a cc da c9 02 00 00 00 00 00` | `0x02C9DACC` | **0** | 00 |
    /// | After B segment frame of A/B 0.06 s | `0a cc da c9 02 00 f0 00 00 04` | `0x02C9DACC` | **61,440** | 04 |
    ///
    /// ## Why we can claim `recordedBytes` is the byte count (triple independent verification)
    /// 1. **Both values are multiples of 80** — and a `0x02` voice frame is exactly 80 bytes of plaintext
    ///    （`20,160 = 252 × 80`、`61,440 = 768 × 80`）。
    /// 2. **The rate matches**: `(20,160 − 0) B ÷ 2.670 s = 7,551 B/s ≈ 94 frames/s`,
    ///    which is on the same order as the measured ~100 frames/s of the `0x02` voice stream.
    /// 3. **The byte count of the stop‑record frame matches the wall clock**: the same round's `0x17` reports `0x0000C4E0 = 50,400`,
    ///    and `50,400 ÷ 8,000 B/s = 6.3 s`, which is exactly the interval from "card starts recording (1.6 s after start frame) → stop‑record frame".
    ///    **Not an estimate, but a calculation**.
    ///
    /// ## Also verified the `sessionId` entry
    /// `0x02C9DB7B` differs from the other round's `0x02C9DACC` by **0xAF = 175 seconds**, and the wall‑clock interval between the two experiments
    /// is exactly 14:30:19 − 14:27:24 = **175 seconds**. The two are synchronized to the second — indicating that this field
    /// is the card's **post‑sync timestamp**.
    /// ⚠️ However it lacks the high 6 bits of a true Unix second (`0x6AC9DB7B & 0x03FFFFFF = 0x02C9DB7B`),
    /// i.e., **truncated to 26 bits**. Therefore it **cannot** be used for date display (`startedAt` will reject it).
    ///
    /// ## Why this command is critical
    /// The card **does not spontaneously push `0x02` voice frames** — the 563,520 B voice stream at 73 s was generated by the official App
    /// by issuing 351 `0x1C` requests to pull it piece by piece (§20.7). Therefore:
    /// * "Is recording?" **cannot** be determined solely by voice frames (they will never appear);
    /// * `0x18` is the **card‑initiated signal that reflects recording progress in real time**.
    /// Empirically, the trigger condition: after sending `0x14` (start) or `0x1A` (list files), the card always returns a message.
    ///
    /// ## ★ 2026-10-12 Addendum: it is actually a **start‑recording acknowledgment**, and it is high‑frequency (see §31.3①)
    /// `captures/app-diag-2026-10-10-1541.log` contains over 200 `0x18` entries covering the entire recording process,
    /// spanning 8 sessions. **The App starts recording 8 times, and each time the card returns this** (not `0x14`) —
    /// so the criterion for "start successful" should be "receiving `0x18`".
    ///
    /// ✅ **2026-10-12 decision (§32.1): two frame formats, differing by a 1‑byte optional length prefix.**
    /// Both records **are 13 B ATT / 10 B payload**, the only difference is the nature of the first byte:
    /// ```
    /// Format A — official App (`app-diag-2026-10-10-1541.log` 200+ entries)
    ///   01 18 00 | B5 B2 CC 6A 02 00 00 00 00 00
    ///              └─ sid(4) ─┘ 02 bytes(4) st   → sid offset 0 = 0x6ACCB2B5 (timestamp)
    /// Format B — probe (`bleprobe-rec-2026-10-10.log:53`, log marks it as "guess")
    ///   01 18 00 | 0a 7b db c9 02 00 00 00 00 00
    ///              ↑length  └─ sid(4) ─┘ bytes(4) st → sid offset 1 = 0x02C9DB7B
    /// ```
    /// Criterion: `payload.count <= 255 && Int(b[0]) == payload.count` ⇒ includes length prefix.
    /// **The only invariant is that `bytes` always reside in `b[5..8]` and `status` always in `b[9]`** — only the start of sid changes.
    ///
    /// ⛔ Previously inferred from Format B that "sid was truncated to 26 bits", **that conclusion has been retracted**: `0x02C9DB7B`
    /// is the result of a "right shift by one byte", not a genuine 26‑bit timestamp reported by the card. The full specimen is shown in
    /// `TicNoteRecordingState.parse()` documentation.
    case notifyRecordState      = 0x18
    /// ★ **Get file list** — request/response structure see `TicNoteFileList`.
    ///
    /// In real‑device requests, `flag` is an **incrementing sequence number** (1→2→3→4), and `since` is the **card's own RTC**
    /// (2026-04-11, about half a year slower than real time — which explains the presence of the sync command `0x04`).
    case getFileList            = 0x1A
    /// ★★ **Read file fragment (the real core command)** — payload is **isomorphic** to the static table's `0x38`:
    ///
    /// ```
    /// 01 1C 00 <u32 sessionId> <u32 start> <u32 end> <u8 flags>
    /// ```
    ///
    /// ⛔ **This section overturns the static reverse‑engineering conclusion.** The static table assumes reading a file uses `0x38 SYNC_FILE`
    /// (`buildSyncFile()` verified byte‑by‑byte that the payload is 13 bytes). However, on a real device, 355 fragment requests
    /// **all** are `0x1C`, and `0x38` **never appears**.
    /// In other words: `0x38` is either for a different device/firmware version, or has been replaced by `0x1C` in this version.
    /// **Use the real device as reference → use `0x1C`**, keep `0x38` in `TicNoteCommand` for reference.
    ///
    /// Real‑device behavior (`att-stream2.txt`, session `0x6AC74377`):
    /// · `start` begins at 0, each increment +`0x640` (1600), **strictly consecutive without overlap**;
    /// · Final `end` = `0x89940` = **563,520** = total bytes of the recording;
    /// · Card returns `01 1C 00 <u32 sessionId> <u8 status>`, then starts pushing `0x02` voice frames.
    case syncFile               = 0x1C
    /// ★★★ **`0x1D` — different semantics in each direction, do not mix.**
    ///
    /// | Direction | payload | official capture count | meaning |
    /// |---|---|---|---|
    /// | App→Card | `01 1d 00` (**2 B**, no payload) | **2** | **Download session pre‑amble**: each download segment **sent once** |
    /// | Card→App | `01 1d 00 <u32 sid> ff ff` (**9 B**) | **354** | Card **pushes a status report after each fragment** |
    ///
    /// Criterion (full‑capture stats from `captures/hci-all/bug2-20261008.att.txt`): the two messages sent by the App
    /// each immediately follows the card's `0x14`, **exactly** receives a `0x1E` response, then the `0x1C` loop;
    /// while `0x1C` occurs 355 times and the card's acknowledgments also 355 times — the card's `0x1D` is of the same magnitude as the acknowledgments,
    /// it is a **in‑loop** product, not a pre‑amble.
    ///
    /// ⚠️ **Use the real device for write type, do not copy the capture**: in the capture, the official entry is an ATT **Write Request**
    /// (`0x12`, with a matching `0x13` Write Response), but on **our card** testing shows
    /// Write Request **remains silent throughout**, and only Write Command (`0x52`) receives per‑message acknowledgments ——
    /// See the reference table in `TicNoteLink.stopSynchronization()`. Hence online we use `.withoutResponse`.
    ///
    /// ⚠️ **The card's 9 B `0x1D` does not require a response**: the official side never replies (`0x1E` appears exactly twice in all captures).
    /// Treating it early as a "status query requiring a response" would add meaningless writes to the loop.
    case getSessionState        = 0x1D
    /// Card→App: `01 1e 00` (**2 B, empty payload**). **Signal that the `0x1D` pre‑amble was accepted by the card**.
    ///
    /// Measured latency: real device 33 ms (`16:06:28.523 → 0x1D` / `16:06:28.556 ← 0x1E`).
    /// If not received ⇒ the card never enters the "will reply `0x1C`" state ⇒ every subsequent `0x1C` fragment disappears
    /// (real device 13/13 all silent, no exceptions) ⇒ the root cause **must** be in the segment before `0x1D`
    /// (handshake / write type / connection state), not in the bytes of `0x1C`.
    ///
    /// ⚠️ **Same code, different use (2026-10-12 addendum, see `protocol-notes.md` §31.3④)**:
    /// `0x1E` **outgoing direction** is the official **delete recording** (`WriteCmd::delRecord`) —
    /// `tools/dart_write_layout.py` disassembles to `01 1e 00 <4 parameters>`
    /// (blutter marks `0x2 0x3c 0 <<r6>> <<r6>> <<r6>> <<r4>>`, `0x3c >> 1 = 0x1e`).
    /// ⛔ However **the outgoing direction never appears in any real‑device capture** (we have never deleted),
    /// the semantics of those 4 parameters have **zero samples, no speculation**. The delete feature must be backed by a real‑device capture before implementation.
    case sessionStateResponse   = 0x1E
}

// MARK: - Device information query (cmd 0x01 / 0x03 / 0x08 / 0x09)

/// The commands to send for a single "read device info" request, and the **expected response command code** for each.
///
/// All bytes taken from real‑device capture `captures/att-decoded.txt` (official App session,
/// ATT numbers #29960–#29998). Left side is the full frame we sent, right side is the full frame returned by the card:
///
/// ```
/// APP->CARD  01 01 00 | 02 01 00                        identity **query**
/// CARD->APP  01 02 00 | 00×56 56 07 00 00 01            61 B identity response
/// APP->CARD  01 03 00                                   read status
/// CARD->APP  01 03 00 | 01 00 00 00 00 00 00 01 00      9 B
/// APP->CARD  01 08 00 | 01                              read configuration
/// CARD->APP  01 08 00 | 00 02 00 01 7F 00 00            7 B
/// APP->CARD  01 09 00                                   battery
/// CARD->APP  01 09 00 | 00 64                           2 B  ← 0x64 = 100%
/// ```
///
/// ★ **`0x01` is the only "request code ≠ response code"** (request `0x01`, response `0x02`).
/// The other three use the same code for request and response.
///
/// ⛔ **The previous version said "the symptom of this mistake is easy to recognize: identity never reads, battery reads" —— that statement is wrong; on a real device it is the opposite**:
/// Putting `0x01` and the read commands into the same burst,
/// identity **is readable** (card returns `0x02`), while the subsequent three read commands **receive no responses**.
/// Full evidence and batching rules are described in the comments of `greetingSteps` / `readSteps` below.
///
/// ⚠️ Relation to §17.1: the official 45‑byte binding frame (`02 01 01 <16B token> <len> <name>`)
/// differs from the **identity query** here by only the third byte (`0x00` = read‑only, `0x01` = write).
/// **Do not** send `TicNoteWifiProvisioning.sendTokenFrame` as a query — it would change the card's hotspot name.
enum TicNoteDeviceInfoQuery {

    /// A single read command.
    struct Step {
        /// **Online command code** — use `TicNoteObservedCommand` directly, do not convert by ÷2.
        let cmd: UInt16
        let payload: Data
        /// Expected response command code (the 0x01 entry expects 0x02)
        let reply: UInt16
        /// Short name for logs/notes
        let label: String
    }

    /// ★★★ 2026-10-12 real‑device decision: **identity query must be sent in a separate burst from the read commands**,
    /// otherwise the subsequent three read commands **receive no responses**.
    ///
    /// ## Evidence (`/tmp/t5.log`, one device, 4 sessions)
    /// Group outbound frames into bursts where the "interval > 12 ms", then examine inbound responses within 2.5 s:
    /// ```
    /// Send [0x01 (identity), 0x03, 0x08, 0x09]  → Receive [0x02]                          ✗ 6/6 all empty
    /// Send [0x03, 0x06, 0x09, 0x1A]        → Receive [0x03, 0x06, 0x09, …list]        ✓
    /// Send [0x08]                          → Receive [0x08]                          ✓
    /// Send [0x09]                          → Receive [0x09] (occasionally only 0x0B)           ✓
    /// ```
    /// Those 6 failures represent the only previous read path in this file (`readDeviceInfo` packs the binding frame +
    /// identity query + three reads **squeezed into a single instantaneous burst**) , inbound always contains only one `01 02 00 …`.
    /// Direct consequence: **battery cannot be read**, `readDeviceInfo` can only fall back to "the cache previously pushed by the card",
    /// and that cache is written only during recording by a 1 Hz poll — the user sees that
    /// "**battery appears only after recording finishes**".
    ///
    /// Why the card behaves this way: `0x01` appears to reset the card's own command pipeline,
    /// causing frames following it in the same burst to be entirely dropped (even the `0x0B` rejection acknowledgment is not provided).
    /// **The mechanism is not fully understood, but the criteria are verifiable per frame**, so it is implemented as "no same-burst".
    /// Note that the official implementation arranges it this way as well —— its `init` sequence places the identity query and that 45-byte binding frame
    /// in separate write operations, separated by the system queue (see the comparison table in §17.1).
    static let greetingSteps: [Step] = [
        Step(cmd: TicNoteObservedCommand.setDeviceIdentity.rawValue,        // 0x01
             payload: identityQueryPayload,
             reply: TicNoteObservedCommand.deviceIdentityResponse.rawValue, // 0x02
             label: "identity"),
    ]

    /// Read-only command. **Must be sent in a single burst** (reasons see `greetingSteps`).
    ///
    /// Intentionally **excludes** the other two from the official `init`: `0x0C` (write) and `0x04` (time sync).
    /// This read is positioned as "read-only"; time sync has a separate independent path via `RecorderLink.syncTime`.
    ///
    /// ## `0x06` (storage) was added on 2026-10-12, **placed at the end intentionally**
    ///
    /// The first three `[0x03, 0x08, 0x09]` are **the exact sequence currently running in production**; not a single byte is changed;
    /// `0x06` is appended to the end. There are two specific reasons for this:
    /// 1. Real-device `/tmp/t5.log` has confirmed that **four-burst transmissions** like `[0x03, 0x06, 0x09, 0x1A]` always get responses,
    ///    so length is not an issue — but keeping "the first three bytes identical to the verified sequence" is still more robust than "reordering them";
    /// 2. `readDeviceInfo` already tolerates **partial responses**: if a certain firmware does not recognize `0x06`,
    ///    only the storage item is lost, while battery and scene data are still retrieved normally (if the order were swapped, it would be harder to say).
    static let readSteps: [Step] = [
        Step(cmd: TicNoteObservedCommand.getStatusInfo.rawValue,            // 0x03
             payload: Data(),
             reply: TicNoteObservedCommand.getStatusInfo.rawValue,
             label: "status"),
        Step(cmd: TicNoteObservedCommand.getConfig.rawValue,                // 0x08
             payload: Data([TicNoteGeneralSetting.readFlag]),
             reply: TicNoteObservedCommand.getConfig.rawValue,
             label: "config"),
        Step(cmd: TicNoteObservedCommand.getBattery.rawValue,               // 0x09
             payload: Data(),
             reply: TicNoteObservedCommand.getBattery.rawValue,
             label: "battery"),
        Step(cmd: TicNoteObservedCommand.queryStorage.rawValue,              // 0x06
             payload: Data(),
             reply: TicNoteObservedCommand.queryStorage.rawValue,
             label: "storage"),
    ]

    /// All steps (= greeting + read). **For documentation and self-check only** ——
    /// When actually sending, you must split into `greetingSteps` / `readSteps` **in batches**,
    /// Sending the entire `steps` at once is the old bug itself.
    static let steps: [Step] = greetingSteps + readSteps

    /// Payload for identity **query**: real device `02 01 00`.
    static let identityQueryPayload = Data([0x02, 0x01, 0x00])

    /// A `0x09` response packet yields **two** fields: battery level + charging flag.
    ///
    /// The struct is defined at the **top level of the file** (see `TicNoteBatteryReading` below),
    /// at the same level as `TicNoteStorageInfo` / `TicNoteGeneralSetting` —
    /// it is data, not a command, and both the link layer and UI layer use it.
    ///
    /// ## Byte
    /// ```
    /// 01 09 00 | 00 64      Not charging, battery 100%
    /// 01 09 00 | 01 64      Charging, battery 100%
    /// ```
    /// In real device samples, the first byte only takes two values: `00` (majority) and `01` (minority); the last byte is **always `0x64` = 100** (consistent with the 100% reported by the standard Battery Service on the card).
    /// 
    ///
    /// ## ★ Evidence chain for the first byte being "charging" (**not** derived from this single byte alone)
    /// The criterion is that **two mutually independent fields flip simultaneously** within the same session:
    ///
    /// ```
    /// 10 captured `0x03` (device status) payloads have only two variants:
    ///   01 03 00 | 01 00 00 00 00 00 00 01 00   × 9   state = 0x00000001
    ///   01 03 00 | 01 20 00 00 00 00 00 01 00   × 1   state = 0x00002001
    ///
    /// And for the **only** sample with 0x2000 set, the 0x09 in the same batch of responses is `01 64`
    /// (the other 9 batches are all `00 64`).
    /// ```
    /// When two unrelated fields flip simultaneously in the **same** session, the simplest explanation is "external power supply".
    ///
    /// The same thing can be read directly in the official App: its device status decoding table hardcodes
    /// `state == 0x4002` to the string "USB Connected (Charging)"
    /// （`blutter_out/asm/ticnote/util/tools/watchBle/audio_services/watch_audio_service.dart`
    /// the `_handleDeviceStatusResponse` in `blutter_out/asm/ticnote/util/tools/watchBle/audio_services/watch_audio_service.dart`) — the manufacturer itself treats "USB connected == charging".
    ///
    /// ⚠️ **The official charging values are `0=Not Charging, 1=Charging, 2=Fully Charged` (three states)**
    /// (see the comment after `Battery Status Update: Battery Level=… %, Charging Status=…` in the same official package).
    /// Only `0` and `1` appeared in the 10 local captures, **with no sample for `2`**,
    /// so this bit currently only serves as "is charging": `2` falls back to `nil` (unknown),
    /// the UI displays `—` instead of guessing "Charging" or "Fully Charged" for the user.
    /// To support the "Fully Charged" state, a real device sample with `0x09` header byte `0x02` is needed ——
    /// once obtained, it can be added according to the official table.
    ///
    /// ## ⚠️ Confidence: Correlation from 10 samples, **not** from vendor documentation
    /// So `isCharging` is **ternary**: unrecognized flags are always `nil` ("unknown"),
    /// **never** guessing `false` for the user — that would misinterpret "not read" as "not charging".
    /// The raw flag byte remains in `flag`, so the UI/logs can print it for reconciliation.
    ///
    /// ⚠️ Prefer returning `nil` over a guessed value: battery `> 100` is always treated as "not battery data"
    /// (If this actually occurs, it indicates the peer has changed the message format; reporting "unreadable" is far better than reporting "255% battery").
    /// Single-byte replies have no flag bits to read, so they are also treated as "unreadable" — the old function `batteryPercent`
    /// only takes the last byte and will **still return it** for single-byte replies; this lenient approach is reserved only for the old function.
    static func batteryReading(fromReplyPayload payload: Data) -> TicNoteBatteryReading? {
        guard payload.count >= 2, let flag = payload.first, let raw = payload.last else {
            return nil
        }
        guard raw <= 100 else { return nil }
        let charging: Bool?
        switch flag {
        case 0x00: charging = false
        case 0x01: charging = true
        // For firmware updates or message format changes → say "I don't know"; do not guess. See the confidence notes in `TicNoteBatteryReading`.
        default:   charging = nil
        }
        return TicNoteBatteryReading(percent: Int(raw), isCharging: charging, flag: flag)
    }

    /// Battery report → percentage (**legacy rule**: only take the last byte, `> 100` means invalid).
    ///
    /// Real device 7 `0x09` samples:
    /// ```
    /// #14790 00 64 | #19609 01 64 | #28378 00 64 | #28385 01 64
    /// #28675 00 64 | #29983 00 64 | #32160 00 64
    /// ```
    /// The first byte jumps between `00`/`01` (that's the charging flag, see `batteryReading`),
    /// The last byte **is always `0x64` = 100**, so for battery level just look at the last byte.
    ///
    /// ⚠️ Keep it because the call sites care only about "battery level" and shouldn't be forced to understand the charging flag.
    /// Use `batteryReading(fromReplyPayload:)` when both are needed.
    static func batteryPercent(fromReplyPayload payload: Data) -> Int? {
        guard let last = payload.last else { return nil }
        let value = Int(last)
        return value <= 100 ? value : nil
    }

    /// A sentence for the reply payload to be written into `RecorderDeviceInfo.notes`
    /// — Answering the user's question of "why is there a hexadecimal value here".
    static func note(forLabel label: String, payload: Data) -> String? {
        switch label {
        case "identity":
            // On actual devices, this reply payload is almost entirely zeros (trailing `56 07 00 00 01`), **so the SN cannot be determined**.
            // The card's identity primary key is the ASCII string in the advertisement, not this frame — this must be clarified,
            // otherwise seeing an "all-zero identity reply" might lead one to believe the card is faulty.
            return "Identity reply is \(payload.count) B and field semantics are not "
                 + "decoded. The card's serial number comes from the Bluetooth "
                 + "advertisement, not from this frame."
        case "status":
            return "Device status reply is \(payload.count) B; field semantics not decoded."
        case "config":
            return "Device config reply is \(payload.count) B; field semantics not decoded."
        case "storage":
            // This storage note is different: it **is** decoded, so the remark shows actual usage instead of "not decoded".
            // When decoding fails (due to incorrect frame length), state that it cannot be decoded; do not let the UI display a fake 0 B progress bar.
            guard let info = TicNoteStorageInfo.parse(payload) else {
                return "Storage reply is \(payload.count) B and its length is not what "
                     + "this build expects, so the used/free figures are not shown."
            }
            return "Used \(info.usedText) of \(info.totalText) (\(info.freeText) free)."
        default:
            return nil
        }
    }
}

// MARK: - Battery level + charging flag (0x09 response packet)

/// A `0x09` response packet yields **two** fields: battery percentage + charging flag.
///
/// Placed at the **top level of the file** rather than nested inside `TicNoteDeviceInfoQuery`: it is **data**, not a command —
/// on the same level as `TicNoteStorageInfo` / `TicNoteGeneralSetting`,
/// since both the link layer and UI layer need to use it (nested types would require fully qualified names in other files, which is purely self-inflicted trouble).
///
/// ## Why does a response packet contain "charging" information
/// The card does not have an independent "charging status" query command — it places the flag in the **first byte** of the battery response packet:
/// ```
/// 01 09 00 | 00 64      Not charging, battery 100%
/// 01 09 00 | 01 64      Charging, battery 100%
/// ```
/// The complete evidence chain (why we confidently assert the first byte is the charging flag) is documented in
/// `TicNoteDeviceInfoQuery.batteryReading(fromReplyPayload:)`.
///
/// ## `isCharging` is **ternary**, not over-engineering
/// The criteria are based on only 10 real-device samples (**not** vendor documentation), so:
/// `true` / `false` are only returned when the card explicitly reports `0x01` / `0x00`,
/// all other values are `nil` ("unknown"). The UI displays `—` based on this,
/// **never** render "not read" as "not charging" — users look at this line to decide whether to plug in.
struct TicNoteBatteryReading: Equatable {
    /// Battery level 0…100 (last byte of response).
    let percent: Int
    /// `true` = charging, `false` = not charging, `nil` = flag unrecognized (including the official "fully charged" case, no sample yet).
    let isCharging: Bool?
    /// Original flag byte (first byte of the response packet). Used only for display and log reconciliation —
    /// When capturing packets on the real device next time, this single byte will serve as the evidence for "whether the judgment criteria are correct".
    let flag: UInt8
}

// MARK: - Unbind device (cmd 0x05)

/// All protocol knowledge for the "unbind device" frame.
///
/// ## Bytes
/// ```
/// 01 05 00 | 00
/// ```
/// Source: `WriteCmd::unbind` (`writeBle.dart`) disassembly list `[2, 10, 0, 0]`
/// → Remove Smi tag. Same table: `readStatus → 01 03 00`, `getStorageVolume → 01 06 00`
/// Both have matched the real device byte-by-byte, so this conversion is reliable (see `TicNoteObservedCommand.unbindDevice`).
///
/// ## Why the payload is always `00` with no parameters
/// The official command **has no input parameters** (`WriteCmd::unbind()` is a zero-argument function, and the
/// 4th `0` in `[2,10,0,0]` is a constant, not a variable). This frame was **never captured** on the actual device,
/// so whether "this byte is a switch for clearing data" **cannot be verified**.
/// When facing questions like "will a certain parameter accidentally wipe user recordings," the correct answer is **do not add parameters**.
///
/// ## Differences from D·NOTE's "unbind" approach (do not confuse)
/// `DeviceSheet.unbindAndRemove()` is a four-step process (disable encryption → clear password → format → unbind),
/// which belongs to D·NOTE's capability set. On the card side, only this single frame exists; "clear data" is **another command**
/// in the card's command table (`WriteCmd::clearData` = `01 68 00`), and **this implementation deliberately does not send it** ——
/// users want "unbind", not "delete my recordings".
enum TicNoteUnbind {

    /// The payload after the frame header. Always `00`, reason see this enum's documentation.
    static let payload = Data([0x00])

    /// Complete frame `01 05 00 00`.
    static var frame: Data {
        TicNoteFrameCodec.frame(rawCmd: TicNoteObservedCommand.unbindDevice.rawValue,
                                payload: payload)
    }

    /// Official confirmation text (`myNewDevice_tip1` / `myNewDevice_tip2`, verbatim from
    /// `blutter_out/asm/ticnote/generated/intl/messages_zh_CN.dart`）：
    ///
    /// Unbinding will clear all device data. TicNote can be bound to a different account. Are you sure you want to unbind?
    /// All settings have been reset to default. TicNote can be bound to a different account. Are you sure you want to unbind?
    ///
    /// ⚠️ The official body text says "clear all device data", but **this frame does not carry the clear-data parameter**,
    /// and its command table has `clearData` as **a separate entry**. So that text describes the official
    /// entire flow (unbind + clear data), not the effect of this frame. Therefore, our UI **does not say**
    /// "recordings will be deleted" (since that's not what we do); it only says "reconnect/pair after unbinding".
    static let officialConfirmationText =
        "Unbinding will clear all device data. TicNote can be bound to different accounts. Are you sure you want to unbind?"
}

// MARK: - Recording Status / Session Notifications (cmd 0x14 / 0x17)
//
// ★ 2026-10-10 Refactored: The previous version's field names (`mode` / `flag`) forced two frames with **different layouts**
//   into the same schema, making the semantics incorrect. Now parsed according to their actual layouts.
//
// Source: bug2-20261008.att.txt (that 13.8 MB capture, which **really does contain a 72-second recording**)
//   Rec start #14818 / #38087  CARD->APP  01 14 00 | f138c76a 02 00 00 00 00 00
//   Rec stop #14848 / #47766  CARD->APP  01 17 00 | f138c76a 01 01 00 00 00 00
//
// The interval between `0x14` and `0x17` for the two recordings and the file size are perfectly consistent:
//   · Session `0x6AC74377`: #38087 t=5774.351 → #47766 t=5846.503 = **72.15 s**
//   · For the same session, the `0x17` report's fileSize = 563,520 B ÷ 8000 B/s = **70.44 s**
//   → Therefore, `0x14` = **Recording Start**, `0x17` = **Recording End**, not "Session Metadata".

/// Decoding of the two **active notifications** "Recording Start / Recording End" on the card.
///
/// ## The layout of the two frames **differs** (this was the biggest mistake in the previous version)
/// ```
/// 0x14 Recording Start   <u32 sessionId> <u8 scene> <u32 startTime> <u8 status>
///                 f1 38 c7 6a      02         00 00 00 00       00
///
/// 0x17 Recording end   <u32 sessionId> <u8 status> <u8 isSave> <u32 fileSize>
///                 77 43 c7 6a      01          01         40 99 08 00
/// ```
/// Field names and order are extracted field-by-field from `ReviceCmd::_initializeCommands`
/// （`tools/dart_cmd_layout.py`，cmd 20 = 0x14 / cmd 23 = 0x17），
/// and corroborated by real-device values: the real-device `scene` for `0x14` is `0x02`, matching the
/// `rec_scene: 2` in the `0x08` general settings **exactly** (this is the cleanest corroborating evidence for "`0x14` = start-recording event").
///
/// ## Why `0x14` is the "start-recording acknowledgment"
/// `0x14` **bidirectional reuse**: App→Card sends `01 14 00 01 <scene> …` to order start recording
/// (confirmed byte-by-byte in `WriteCmd::recordStart` disassembly), Card→App pushes `01 14 00 <sid> …`
/// saying "I am already recording, and the scene is this." The same code in two directions, distinguished by ATT opcode.
/// When the user long-presses the physical button on the card to start recording, the card **also** pushes this message ——
/// so it is the device truth of "the card is really recording", more trustworthy than the local stopwatch.
///
/// ⚠️ But **it only pushes once** (in the full 8,543 frames, there are exactly 2 instances each of `0x14`/`0x17`, with no periodic reporting),
/// so the truly continuous "recording?" signal is **voice frame rate** — see `TicNoteLink.streamingVoice`.
enum TicNoteRecordingState {

    /// Recording byte rate. On real devices, the `size ÷ duration` for 5 recordings all fall within **7,041–7,952 B/s**,
    /// with the central value being **8,000 B/s**. ★ 2026-10-10 obtained **direct evidence**:
    /// that 72-second recording had 7,044 `0x02` voice frames, each 80 bytes (see §voice),
    /// `7,044 × 80 = 563,520` **exactly equals** the fileSize reported by `0x17`.
    /// Use 8000, **not the measured mean** — the mean includes bytes lost at start/stop boundaries, making it smaller.
    static let bytesPerSecond: Double = 8_000

    /// A recording start / end notification.
    ///
    /// The frame layouts differ, so fields are grouped by event type, and **unused ones are always `nil`**
    /// (No "reasonable-looking default values" are provided — that was exactly why the previous version mistook the `0x17` fileSize for
    /// `0x14`'s "session size", thereby locking the stopwatch at 0:00).
    struct SessionNotice: Equatable {

        /// Session ID. ★ **It is also the start Unix timestamp of this recording**
        /// (`0x6AC74377` → 2026-10-08 15:16 +08, same value as `start` in the `0x1A` list).
        let sessionID: UInt32

        /// Online command codes: `0x14` = recording start; `0x17` = recording end.
        let wireCommand: UInt16

        /// `0x14`: Recording scenario (real device `0x02`, consistent with `rec_scene` in `0x08`). `0x17` → nil.
        let scene: UInt8?

        /// `0x14`: `startTime` field (always `0` on real devices). **Meaning unknown; do not assign semantics to it.**
        let startTime: UInt32?

        /// Status byte. `0x14` takes `[9]` (real device `0x00`), `0x17` takes `[4]` (real device `0x01`).
        /// ⚠️ Both real device values have only one sample, **do not generalize into a "state machine"**.
        let status: UInt8?

        /// `0x17`: Whether it has been saved (device `0x01` = saved). `0x14` → nil.
        let isSaved: Bool?

        /// `0x17`: The **final byte count** of this recording (real device: 563,520). `0x14` → nil.
        /// ★ Cross-validated with third-party sources: matches the `sizeBytes` in the `0x1A` list and the `end` of the last fragment in `0x1C` (`protocol-notes.md` §0ter.3).
        /// `end` completely matches (`protocol-notes.md` §0ter.3).
        let fileSize: Int?

        /// Compatible name: Only the "recording ended" event recognizes the byte count. See `fileSize`.
        var totalBytes: Int? { fileSize }

        /// Whether it is a "recording start" event (`0x14`).
        var isStartEvent: Bool {
            wireCommand == TicNoteObservedCommand.notifySession.rawValue
        }

        /// /// Whether it is a "recording ended" event (`0x17`).
        var isEndEvent: Bool {
            wireCommand == TicNoteObservedCommand.notifyRecordingState.rawValue
        }

        /// Is it the "recording state report" (0x18)? This is the response sent after the card accepts the start-recording command.
        /// It is also **the only signal that allows real-time reading of the number of recorded bytes**. See `notifyRecordState`.
        var isRecordStateEvent: Bool {
            wireCommand == TicNoteObservedCommand.notifyRecordState.rawValue
        }

        /// Device-reported duration (seconds). `nil` when `fileSize == nil` (i.e., `0x14`).
        /// ⚠️ `fileSize` will be 0 when stopping recording (real device #14848), so **callers must filter out 0**
        /// —— see `RecorderSessionModel.adoptDeviceElapsed`.
        var elapsed: TimeInterval? {
            fileSize.map { Double($0) / TicNoteRecordingState.bytesPerSecond }
        }

        /// `sessionId` is the start time restored from Unix seconds, used to calculate "how long has been recorded".
        ///
        /// ⚠️ The card's RTC may not have been set correctly (we've seen real devices off by half a year, which is why the time-sync command
        /// `0x04` exists), so this time is **only used to compute duration**; don't use it to display dates.
        /// Also, when `sessionId` is below the year 2001 (`< 978307200`), it's clearly not a timestamp → nil.
        /// ★ 2026-10-12: this gate now acts as a fallback for **Form B**'s `0x18` — its
        /// sid (real device `0x02C9DB7B`) is on the order of only 47 million, so it will inevitably be rejected.
        /// This isn't a "flaw" but the intended behavior: better no timestamp at all than a fake 1971 date.
        /// Form A's sid (`0x6ACCB2B5`) is a normal timestamp and decodes correctly.
        var startedAt: Date? {
            guard sessionID > 978_307_200 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(sessionID))
        }
    }

    /// Parse the payload of `0x14` / `0x17` / `0x18`. **All are fixed-length 10 bytes**; if shorter, return nil immediately,
    /// Commands other than these also return nil (no "best-effort" truncated parsing: if the frame length is wrong, it means the peer has changed its format,
    /// at which point the guessed sessionId would be a plausible-looking wrong value, which is harder to debug than not getting one at all).
    ///
    /// ## ★★★ 2026-10-12: `0x18` has **two frame formats**, both must be recognized
    ///
    /// Two real-device raw records (both **13-byte ATT**, **10-byte payload**, differing only in the nature of the first byte):
    ///
    /// ```
    /// Form A — Official App (`captures/app-diag-2026-10-10-1541.log` 200+ entries;
    ///           `Documents/ticnote-ble.log` 2026-10-12 real-time transcription start receipt)
    ///   01 18 00 | B5 B2 CC 6A 02 00 00 00 00 00
    ///              └─ sid(4) ─┘ 02 bytes(4)  st     → sid at offset 0 = 0x6ACCB2B5 ✓ timestamp
    ///
    /// Form B —— Probe (`captures/bleprobe-rec-2026-10-10.log`)
    ///   01 18 00 | 0a 7b db c9 02 00 00 00 00 00
    ///              ↑ Length └─ sid(4) ─┘ bytes(4) st → sid at offset 1 = 0x02C9DB7B
    /// ```
    ///
    /// Criterion: **the first byte equals the payload length** (`b[0] == payload.count`) ⇒ it is a length prefix ⇒ Form B.
    /// Form B's `0x0a` is exactly 10; Form A's `B5` is the highest byte of the sid and is unrelated to this frame's length.
    ///
    /// ⚠️ The only risk of this criterion: the highest byte of the sid in Form A happens to equal 10
    ///    (i.e., sid ∈ `0x0A000000…`, around 2022-05). The sid is a Unix timestamp, and the current time is
    ///    2026-10 (`0x6A…`), so a collision is unlikely unless the RTC is severely off.
    ///
    /// /// ## This history is worth keeping (it's a complete specimen of "how wrong values masquerade as conclusions")
    /// /// Initially, only Form B was seen, so it was written as "sid at offset 1", and based on this it was deduced that
    /// /// **"The sid in `0x18` is a timestamp truncated to 26 bits (`0x6AC9DB7B → 0x02C9DB7B`)"**.
    /// /// Later, only Form A was seen, so it was written as "sid at offset 0". **Since each side had only seen half, both were treated as the whole.**
    ///
    /// Cost: During the 2026-10-12 real-time transcription, form A was read at offset 1, and sid was parsed as `0x026ACCB2`,
    /// sending `0x1C` with it got stuck at `02` (rejected), and all 4 candidates failed within 0.13 s —
    /// the user saw "tap to record, the red light flashes once and goes out", **and no error message could point back to this**.
    /// So now both forms are pinned in the code and in self-checks respectively.
    static func parse(cmd: UInt16, payload: Data) -> SessionNotice? {
        guard payload.count >= 10 else { return nil }
        let b = [UInt8](payload)

        // ★ 0x18：`<[u8 len]> <u32 sessionId> <u8 0x02> <u32 recordedBytes> <u8 status>`
        //   The length prefix is **optional**, determined by whether the first byte equals the payload length (see the type documentation above).
        if cmd == TicNoteObservedCommand.notifyRecordState.rawValue {
            let hasLengthPrefix = payload.count <= 255 && Int(b[0]) == payload.count
            return SessionNotice(sessionID: u32le(b, hasLengthPrefix ? 1 : 0),
                                 wireCommand: cmd,
                                 scene: nil,
                                 startTime: nil,
                                 status: b[9],
                                 isSaved: nil,
                                 fileSize: Int(u32le(b, 5)))
        }

        let sid = u32le(b, 0)

        if cmd == TicNoteObservedCommand.notifySession.rawValue {
            // 0x14 Recording start: sid | scene | startTime(u32) | status
            return SessionNotice(sessionID: sid,
                                 wireCommand: cmd,
                                 scene: b[4],
                                 startTime: u32le(b, 5),
                                 status: b[9],
                                 isSaved: nil,
                                 fileSize: nil)
        }
        if cmd == TicNoteObservedCommand.notifyRecordingState.rawValue {
            // 0x17 Recording ended: sid | status | isSave | fileSize(u32)
            return SessionNotice(sessionID: sid,
                                 wireCommand: cmd,
                                 scene: nil,
                                 startTime: nil,
                                 status: b[4],
                                 isSaved: b[5] != 0,
                                 fileSize: Int(u32le(b, 6)))
        }
        return nil
    }

    /// Check if the command code on this line is the "start/end/status" recording notification.
    ///
    /// ★ `0x18` **must be included**: after the card accepts the start-recording command, it responds with `0x18` (verified on real devices),
    /// not `0x14`. If omitted, `TicNoteLink.startRecording`'s "immediate self-verification" will receive
    /// no signal → the card is clearly recording, but the UI reports "card did not start recording" (false failure,
    /// and the most frustrating kind: the feature works, but the UI says it's broken).
    static func isSessionNotice(_ cmd: UInt16) -> Bool {
        cmd == TicNoteObservedCommand.notifySession.rawValue
            || cmd == TicNoteObservedCommand.notifyRecordingState.rawValue
            || cmd == TicNoteObservedCommand.notifyRecordState.rawValue
    }
}

// MARK: - Recording Scene (rec_scene)

/// The **recording scene** (rec_scene) —— the "non-constant" byte in the start-record frame.
///
/// ## Where it comes from (★ This overturns a previous assumption)
/// The 5th byte of the start-recording frame `01 14 00 | 01 <scene> 00 00 00 00` was once treated as a fixed `0x02`
/// and written into `fixedPayload`. After disassembling `WriteCmd::recordStart`, we found it **is a parameter**:
///
/// ```
/// [asm fact] blutter_out/asm/…/writeBle.dart  WriteCmd::recordStart(dynamic _)
///   After taking the lower 8 bits of the argument, it is written to the 5th byte of the payload (the remaining 4 bytes are always 0)
/// [Caller]  ble.dart  BluetoothManager::beginRec:
///               1. stopBleSync()        ← ★ First, close the sync session (see TicNoteLink.startRecording)
///               2. generalSetting()     ← Read general settings, extract rec_scene
///               3. WriteCmd::recordStart(<rec_scene>)
/// [Real device log] captures/bug/bugreport-…txt
///               "General settings received {rec_led_status: 0, rec_scene: 2, rec_mode: 0,
///                                 row_data: 1, dmic_mode: 127}"
/// ```
///
/// That is: the official App **reads the card's scene settings first, then uses this value to start recording**.
/// This enum provides fallback values; actual values should prefer `TicNoteGeneralSetting.recScene`
/// (see `TicNoteLink.startRecording`).
enum TicNoteRecordingScene {

    /// /// Default scene.
    ///
    /// Both **independent** sources point to `2`, so using it as a fallback is safe:
    /// · `rec_scene: 2` in real-device logs;
    /// · The 2nd byte of the `0x08` response `00 02 00 01 7F 00 00` is `0x02`.
    static let defaultScene: UInt8 = 2
}

// MARK: - Storage Usage (cmd 0x06)

/// Card **used / total** capacity. Response payload is **fixed at 13 bytes**:
///
/// ```
/// 01 06 00 | 00 e2 a3 03 | 00 0d a2 03 | 40 9c 00 00 | 00
///            └ total     ┘ └ free      ┘ └ semantics unresolved ┘ └ state
///            u32 LE, KB    u32 LE, KB    u32 LE         u8
/// ```
///
/// ## This is established by "tri-source cross-referencing", not guessed
///
/// **① Official data class** (`decompiled/classes6/…/bean/recorder/DeviceStorageInfo.java`):
/// ```java
/// public DeviceStorageInfo(long total, long free, long recSizePs, int freeSizeState)
/// public static final int HAS_FREE_SPACE = 0;
/// public static final int NO_FREE_SPACE  = 1;
/// ```
/// → The constructor order is `total, free, recSizePs, state`, **corresponding one-to-one with the 13 bytes above**.
///
/// **② Real device sample** (`captures/hci-all/btsnoop_20261008.att.txt` #32162, t=4020.8502080):
/// ```
/// total = 0x03A3E200 = 61,071,872 KB × 1024 = 62,537,596,928 B = 58.24 GiB
/// free  = 0x03A20D00 = 60,951,808 KB × 1024 = 62,414,651,392 B = 58.13 GiB
/// used  = total − free = 120,064 KB = 117.25 MB
/// ```
/// **③ Official App's own display**: At the same moment it shows "Used storage **117 MB / 58.2 GB**" —
/// Both numbers match perfectly. This is the sole reason this type dares to be used.
///
/// ## The unit is **KB** (not bytes, not 512B sectors)
/// If you don't multiply by 1024, total is only 61 MB, which differs from "58.2 GB" by three orders of magnitude and is easily recognizable.
///
/// ## Deliberately **unnamed** 4 bytes
/// `[8..11]` on real device is always `0x00009C40` = 40000, and does not change with recording.
/// It probably corresponds to the official `recSizePs`, but **no sample can prove what it is**
/// (40000 is "reserved KB"? "cluster size"? "segment size"?), so we just call it `thirdField`
/// — naming it would be misleading (consistent with the rule of `RecorderDeviceInfo`).
struct TicNoteStorageInfo: Equatable {

    /// Total capacity (KB). Real device always `0x03A3E200`.
    let totalKB: UInt32
    /// Available capacity (KB). Decreases monotonically with recording.
    let freeKB: UInt32
    /// Third u32 (real device always 40000). **Semantics unknown, do not use it for anything.**
    let thirdField: UInt32
    /// Byte 13. Real device `0x00`, consistent with official `HAS_FREE_SPACE = 0`.
    /// `nil` = this response packet does not include this byte (older firmware with shorter frame).
    let freeState: UInt8?

    var totalBytes: Int64 { Int64(totalKB) * 1024 }
    var freeBytes: Int64 { Int64(freeKB) * 1024 }

    /// Used bytes = total − available. **The actual occupied portion on the card**.
    ///
    /// Wrap with `max(0,)`: in case firmware swaps the two fields someday (or an abnormal frame where free > total),
    /// Prefer showing 0 rather than a negative progress bar (`ProgressView(value:)` crashes on negative values).
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    /// Used ratio 0…1. When total capacity is 0 (frame not parsed) give 0, **no division by zero**.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    /// Whether the card still has free space (semantics of official `DeviceStorageInfo.freeSizeState`).
    /// `nil` = unknown (that byte not received).
    var hasFreeSpace: Bool? { freeState.map { $0 == 0 } }

    /// Parse the response payload of `0x06`.
    ///
    /// The first 12 bytes are three consecutive u32 LE, **missing a byte returns `nil`** ——
    /// A short frame indicates the peer changed its format; at this point the 'best effort' parsed capacity will be a **seemingly reasonable wrong number**
    /// (e.g., treating `state` as the low byte of total, resulting in a fake progress bar of 58 GB / 0 B),
    /// Which is far better than not showing anything (same as `TicNoteGeneralSetting.parse`).
    static func parse(_ payload: Data) -> TicNoteStorageInfo? {
        let b = [UInt8](payload)
        guard b.count >= 12 else { return nil }
        func u32(_ i: Int) -> UInt32 {
            UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
        }
        return TicNoteStorageInfo(
            totalKB: u32(0),
            freeKB: u32(4),
            thirdField: u32(8),
            freeState: b.count >= 13 ? b[12] : nil
        )
    }

    /// "117 MB" / "58.2 GB" —— **Matches the official App**:
    /// The official app shows "117 MB / 58.2 GB" for the same card at the same time, so MB has no decimal, GB has one digit.
    /// Implementation resides in `RecorderStorageInfo.formatBytes` (the cross‑protocol layer); this type only forwards it
    /// — to avoid a second formatting rule if D·NOTE later needs to display capacity.
    static func formatBytes(_ bytes: Int64) -> String {
        RecorderStorageInfo.formatBytes(bytes)
    }

    /// The representation in the cross‑protocol layer (used by `RecorderDeviceInfo.storage`).
    var recorderStorage: RecorderStorageInfo {
        RecorderStorageInfo(totalBytes: totalBytes, freeBytes: freeBytes)
    }

    /// Two strings for direct UI use (`used` / `total`).
    var usedText: String { recorderStorage.usedText }
    var totalText: String { recorderStorage.totalText }
    var freeText: String { recorderStorage.freeText }
}

// MARK: - Microphone gain (official "Microphone Gain" selector)

/// All possible values for the "Microphone Gain" item on the official card device page — only two levels.
///
/// ## Evidence chain (assembled from two files in `blutter_out/asm/ticnote/modules/my_device/`)
///
/// **① UI side** (`my_device_page.dart::_renderDbPop`, `:4212`):
/// ```
/// AllocateArray(2) → [48, 72]  → remove Smi tag → List<int> [24, 36]
/// Text(S.of().myNewDevice_Mic)              ← the title is "Microphone Gain"
/// thatList.asMap().entries.map((entry) { … "$entry.value db" … })
/// ```
/// `[24, 36].asMap()` = `{0: 24, 1: 36}` —— this is exactly the source of a `<int,int>` Map,
/// It also explains why each entry displays **`"24 db"` / `"36 db"`** (using `entry.value`).
///
/// **② Selected state**: the closure compares `entry.key == logic.field_8f.value`
/// → **`field_8f` stores an "index", not a dB value**.
///
/// **③ Logic side** (`my_device_logic.dart`):
/// ```dart
/// // When constructing: field_97 = List<int>[214, 254]        ← 0xD6 / 0xFE
/// //         field_8f.value = field_97.indexWhere((e) => e == reported dmic_mode)
/// //         (if not found, defaults to 0)
/// changeVolume(dB, index) {
///   field_8f.value = index                  ← selected state
///   field_93.value = dB                     ← display state
///   send([1, 8, 0] + [2, led, scene, mode, row_data, field_97[index]])
/// }
/// ```
/// `field_97` is assigned `[214, 254]` at `:8486` (**the only assignment point**),
/// and the 6th byte sent is `field_97[index]`.
///
/// **④ The two levels derived from this, and their respective on‑device bytes**:
///
/// | Index | Official UI | Sent byte |
/// |---|---|---|
/// | 0 | `24 db` | **`0xD6` = 214** |
/// | 1 | `36 db` | **`0xFE` = 254** |
///
/// ## ⚠️ Why there are "two levels" instead of a slider
/// The official side only provides these two values (`field_97` is **constant**, two elements).
/// Turning the UI into a slider would conjure up 20 values that the official firmware has never validated — that's not "more functionality", it's "more likely to brick the card".
///
/// ## ⚠️ The `dmic_mode` reported by the card is not the same field
/// On the real device, the 5th byte of the `0x08` response is `0x7F` (=127), **not in** `[0xD6, 0xFE]` —
/// Therefore the official App will also map to index 0 on this card ("24 db").
/// Direct consequence: **After changing the gain, reading `0x08` cannot verify it** (that byte remains unchanged).
/// Thus the UI does not promise a "read‑back confirmation", only says "sent".
enum TicNoteMicrophoneGain: Int, CaseIterable, Identifiable {

    /// Official index 0 — UI shows `24 db`, on‑device byte `0xD6`.
    case db24 = 0
    /// Official index 1 — UI shows `36 db`, on‑device byte `0xFE`.
    case db36 = 1

    var id: Int { rawValue }

    /// The number shown on the official UI (the `$value` in `"$value db"`).
    var decibels: Int {
        switch self {
        case .db24: return 24
        case .db36: return 36
        }
    }

    /// `0x08` write frame's 6th payload byte — that's the official `field_97[index]`.
    var code: UInt8 {
        switch self {
        case .db24: return 0xD6
        case .db36: return 0xFE
        }
    }

    /// Reverse lookup from official index; out‑of‑range returns `nil` (**does not** silently clamp to a level).
    static func fromIndex(_ index: Int) -> TicNoteMicrophoneGain? {
        TicNoteMicrophoneGain(rawValue: index)
    }

    /// Reverse lookup from **on‑device byte**. Values like `0x7F` that are "not in the table" return `nil`
    /// — the UI then displays "the card‑reported value is not among these two levels", instead of pretending it matches a level.
    static func fromCode(_ code: UInt8) -> TicNoteMicrophoneGain? {
        allCases.first { $0.code == code }
    }

    /// Short name for UI (`"24 dB"`).
    var label: String { "\(decibels) dB" }
}

// MARK: - General settings response (`0x08`)

/// Card's **general settings** response, **fixed length 7 bytes**.
///
/// ## The field layout is defined as "dual‑source cross", not guessed
/// Byte order and field names come from the **print order** of that Dart map in the real‑device log, and values match item by item:
///
/// ```
/// Log  General settings receive {rec_led_status: 0, rec_scene: 2, rec_mode: 0,
///                       row_data: 1, dmic_mode: 127}
/// Capture  01 08 00 → response payload:  00  02  00  01  7F  00  00
///                                 ↑   ↑   ↑   ↑   ↑   └─ 2 unused bytes
///                                 │   │   │   └───┴── row_data = 0x01
///                                 │   │   └────────── rec_mode = 0x00
///                                 │   └────────────── rec_scene = 0x02
///                                 └────────────────── rec_led_status = 0x00
///                                                    dmic_mode = 0x7F = 127
/// ```
///
/// Item‑by‑item matches (especially the three values `2` / `1` / `127` which are unlikely a coincidence), so this table is usable.
/// ⚠️ But **only these 5 fields** are recognized; the last 2 bytes (always 0 on real device) **remain unnamed** ——
/// No sample proves what they are; naming them would be misleading (same rule as `RecorderDeviceInfo`).
struct TicNoteGeneralSetting: Equatable {

    /// `rec_led_status`. `0` = recording indicator off.
    let ledStatus: UInt8
    /// `rec_scene` — ★ used to start recording frames, see `TicNoteRecordingScene`.
    let recScene: UInt8
    /// `rec_mode`。
    let recMode: UInt8
    /// `row_data` (named as in the log, meaning undefined — real device value `1`).
    let rawData: UInt8
    /// `dmic_mode`. Real device value `127` indicates dual‑mic (digital mic).
    let dmicMode: UInt8

    /// Parse the response payload of `0x08`.
    ///
    /// ⚠️ If shorter than 7 bytes, return `nil` directly: incorrect frame length indicates the peer changed its format,
    /// At this point the 'best effort' parsed `recScene` will be a **seemingly reasonable wrong value**,
    /// Using it to start recording is worse than not using it (it would write an incorrect scene).
    static func parse(_ payload: Data) -> TicNoteGeneralSetting? {
        let b = [UInt8](payload)
        guard b.count >= 7 else { return nil }
        return TicNoteGeneralSetting(
            ledStatus: b[0],
            recScene: b[1],
            recMode: b[2],
            rawData: b[3],
            dmicMode: b[4]
        )
    }

    // MARK: Write direction (another use of 0x08)

    /// The 4th payload byte in the read direction ("please report the current settings to me"). Real device `01 08 00 01`.
    static let readFlag: UInt8 = 0x01
    /// The 4th payload byte in the write direction ("this is the new setting").
    static let writeFlag: UInt8 = 0x02

    /// Assemble the 6‑byte payload of the `0x08` **write** frame:
    ///
    /// ```
    /// 01 08 00 | 02 <rec_led_status> <rec_scene> <rec_mode> <row_data> <micCode>
    ///            ↑  └──────────── Echo current settings back ────────────┘  └ target value ┘
    /// ```
    ///
    /// ## Byte‑by‑byte source (`MyDeviceLogic::changeVolume`, `my_device_logic.dart` `:9855`)
    /// In the disassembly it assembles a **6‑element `List<int>`**, the first element is the marker `4` (= actual value `2`):
    /// ```
    /// Element  Source                                   Actual
    /// [0]   Marker 4                               0x02   ← write direction flag
    /// [1]   RxMap["rec_led_status"]                <current>
    /// [2]   RxMap["rec_scene"]                     <current>
    /// [3]   RxMap["rec_mode"]                      <current>
    /// [4]   RxMap["row_data"]                      <current>
    /// [5]   field_97[index]                         0xD6 / 0xFE (see TicNoteMicrophoneGain)
    /// ```
    /// Then `WriteCmd::generalSetting(map)` first builds `[1, 8, 0]` (frame header) and calls
    /// `writeArr(list, map)` — the loop body of `writeArr` is "take element, mask with `& 0xFF`, append"
    /// (The mask constant in the disassembly is `0x1FE`, i.e., `0xFF << 1`, indicating it **keeps the low byte of the marker in Smi space**.)
    /// Thus the on‑device bytes are exactly those 9 bytes above, **no more, no less**.
    ///
    /// ## ⚠️ Three constraints that must be upheld
    /// 1. **Cannot send only the direction flag**. The official side always writes back the 5 current values together; sending only `02`
    ///    would give the card an "incomplete new setting", behavior unknown — therefore this method **requires** a successful read of
    ///    `0x08` (obtaining `TicNoteGeneralSetting`) before allowing a write.
    /// 2. **Writes are "current settings + target gain"**, not "the whole new setting". Hence the other 4 fields
    ///    must use **the values just read from the card**, otherwise the user's recording scene may be unintentionally changed.
    /// 3. The 6th byte is `micCode`, **not** a dB number — do not write `24`/`36` directly.
    ///
    /// - Parameter `gain`: target level.
    /// - Returns: 6‑byte payload (excluding frame header).
    func writePayload(gain: TicNoteMicrophoneGain) -> Data {
        Data([Self.writeFlag, ledStatus, recScene, recMode, rawData, gain.code])
    }
}

// MARK: - Inbound error translation (do not leak D·NOTE wording onto TicNote)

/// Translate low‑level queue errors into **this protocol's** `RecorderLinkError`.
///
/// ## Why this layer is necessary
/// `TicNoteLink`'s inbound queue shares the `NotifyQueue`, and its timeout throws
/// **`DnoteError.timeout`** — which is a D·NOTE enum; `LocalizedError` renders
/// `dnote_error.timeout` as **"Device did not respond within the allotted time."**
///
/// Consequently, a very confusing situation appears on the real device: on a **TicNote** card,
/// a list timeout turns the entire page into "Device did not respond within the allotted time." —
/// The user sees this message without knowing which component timed out or what to investigate,
/// and it suggests a problem in the D·NOTE link rather than the card.
///
/// Pure function, so self‑tests can pin it down (no real device or BLE needed).
enum TicNoteInboundError {

    /// Translation. Non‑`DnoteError` values are returned unchanged (`RecorderLinkError` itself is correct).
    static func map(_ error: Error) -> Error {
        guard let dnote = error as? DnoteError else { return error }
        switch dnote {
        case .timeout:
            return RecorderLinkError.timeout
        case .notConnected:
            return RecorderLinkError.notConnected
        case .transferCancelled:
            return RecorderLinkError.cancelled
        default:
            // The remaining cases are concepts of the D·NOTE link (binding / stream / transmission integrity),
            // On TicNote they will not be thrown by the inbound queue. If they really occur, attach the original English description ——
            // Adding it is easier to troubleshoot than hard‑coding it into a `RecorderLinkError`.
            return RecorderLinkError.malformed("inbound queue error: \(dnote)")
        }
    }
}

// MARK: - Inbound control frame stream (for user view)

/// Card → App **a control frame**, with sequence number and arrival time.
///
/// ## Why this thing must exist
/// "Pressing the record button yields no response" type issues are **indeterminate** when looking only at the App side alone:
/// The command was sent, `writeValue` succeeded, then what? Did the card actually make a sound or not?
/// On a real device the user cannot access `os_log`, so we display every frame the card says on the UI,
/// The user can screenshot to answer that question —— this is far more practical than making them read logs.
///
/// ⚠️ Only receive **control frames** (type `0x01`). Voice frames (type `0x02`) have over 7000 entries per download,
/// Incoming ones will only discard the few useful lines, and they are 7000 copies of the same thing.
struct TicNoteInboundLogEntry: Identifiable, Equatable {

    /// Frame sequence number (auto‑incremented within this connection, starting at 1). **The first frame's sequence number** is the id of this row —
    /// Subsequent frames with identical content are folded into `repeatCount`, no new rows are created.
    let id: Int
    /// Online command code
    let cmd: UInt16
    /// Frame payload (**excluding** the 3‑byte header)
    let payload: Data
    /// **First frame** arrival time
    let at: Date

    /// Arrival time of the most recent frame with the same content.
    var lastAt: Date

    /// This row represents how many identical frames (≥1).
    ///
    /// ★ The reason for folding is practical: `readRecordingStatus()` polls at 1 Hz,
    /// It returns two identical `0x03` / `0x06` messages per second. Without folding, the stream would be filled in 20 seconds by
    /// 40 duplicate rows, and the `0x17` we actually care about would be pushed out.
    /// After folding: **unchanged entries become length counts, changed ones always generate a new row** ——
    /// And "changed" is exactly what we are looking for.
    var repeatCount: Int

    init(id: Int, cmd: UInt16, payload: Data, at: Date, lastAt: Date? = nil, repeatCount: Int = 1) {
        self.id = id
        self.cmd = cmd
        self.payload = payload
        self.at = at
        self.lastAt = lastAt ?? at
        self.repeatCount = repeatCount
    }

    var hex: String {
        payload.isEmpty
            ? "(empty)"
            : payload.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var byteCountLabel: String {
        repeatCount > 1
            ? "\(payload.count) B ×\(repeatCount)"
            : "\(payload.count) B"
    }

    /// Human‑readable short names. **If unrecognizable, use hexadecimal and do not name them** ——
    /// Creating a plausible name ("RecordStarted") may mislead people into thinking the field semantics have already been resolved.
    var label: String {
        switch cmd {
        case TicNoteObservedCommand.deviceIdentityResponse.rawValue: return "Identity reply"
        case TicNoteObservedCommand.getStatusInfo.rawValue:          return "Status"
        case TicNoteObservedCommand.syncTime.rawValue:               return "Sync time"
        case 0x0006:                                                 return "Device status"
        case TicNoteObservedCommand.getConfig.rawValue:              return "Config"
        case TicNoteObservedCommand.getBattery.rawValue:             return "Battery"
        case TicNoteObservedCommand.notifyB.rawValue:                return "Notify B"
        case TicNoteObservedCommand.setC.rawValue:                   return "Set C"
        case TicNoteObservedCommand.notifySession.rawValue:          return "Session notice"
        case TicNoteObservedCommand.notifyRecordingState.rawValue:   return "Recording state"
        case TicNoteObservedCommand.getFileList.rawValue:            return "File list"
        case TicNoteObservedCommand.syncFile.rawValue:               return "File chunk"
        case TicNoteObservedCommand.getSessionState.rawValue:        return "Session state"
        case TicNoteObservedCommand.sessionStateResponse.rawValue:   return "Session state reply"
        default:
            return String(format: "Command 0x%04X", cmd)
        }
    }
}

// MARK: - File list (cmd 0x1A) — ★ Biggest gain from this capture

/// A recording entry in the card's file list.
///
/// **Structure matches real‑device data byte‑by‑byte** (`btsnoop_20261008.cfa` frame #14862 /
/// `#29999`, 5 records and the App list's 5 recordings **exactly correspond**):
///
/// ```
/// Request  APP→CARD  01 1A 00 <u32 flag> <u32 sinceTimestamp> <u8>
/// Response  CARD→APP  01 1A 00 <u32 flag> <u32 count> count × [u32][u32][u16]
/// ```
///
/// Real device: 5 entries (timestamps converted to +08:00, matching the App list entry by entry):
///
/// | startTime | size (bytes) | duration | rate |
/// |---|---|---|---|
/// | 2026-07-09 10:25:50 | 587,904 | 1m14s | 7,944 B/s |
/// | 2026-07-22 10:28:14 | 14,400 | 2s | 7,200 B/s |
/// | 2026-09-14 16:49:45 | 23,559,200 | 49m22s | 7,952 B/s |
/// | 2026-09-14 17:39:12 | 16,800 | 3s | 5,600 B/s |
/// | 2026-09-14 17:39:30 | 42,250 | 6s | 7,041 B/s |
///
/// The rates all fall within 5.6–8.0 KB/s, very close to **16 kHz IMA‑ADPCM (4 bit) = 8,000 B/s**.
/// And `42,250` **is not a multiple of 16** — if it were AES‑CBC ciphertext, the length would have to be a multiple of 16,
/// Thus **the audio is most likely plaintext** (still requires a real download for 100 % verification).
struct TicNoteFileEntry: Equatable {
    /// Start timestamp (Unix seconds, local timezone). **It is also the sessionId** —
    /// This exactly explains why in the sister protocol `RequestSyncAudioRecordFileInfo{sessionId, start, …}`
    /// the two fields are always the same value.
    let startTime: UInt32
    /// File byte size
    let sizeBytes: UInt32
    /// File type; all 5 real‑device entries are `2`
    let fileType: UInt16

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime)) }
}

enum TicNoteFileList {
    /// Request frame payload: `<u32 flag> <u32 sinceTimestamp> <u8>`
    /// On the real device, the two attempts used `flag=1` / `flag=2`, with `sinceTimestamp` set to the same early value,
    /// Both returned all 5 entries — the filtering semantics of `flag` and `since` need further clarification,
    /// To retrieve the full set, send `flag=1` plus a very early timestamp.
    static func requestPayload(flag: UInt32, since: UInt32, tail: UInt8 = 0) -> Data {
        var d = Data()
        d.append(u32le(flag)); d.append(u32le(since)); d.append(tail)
        return d
    }

    /// Parse the part after `01 1A 00`: **`<u32 flag> <u16 total> <u16 offset> page × 10 bytes`**.
    /// Sending the **entire frame** (including the 3‑byte header) is also acceptable; the function will skip the header itself.
    ///
    /// ★★★ **This is a paging protocol, not "single‑frame full data"** (real‑device correction on 2026-10-09).
    ///
    /// When the card has more than **one page of 7 entries**, it pushes the list **in batches** (observed 17 entries = 3 frames):
    /// ```
    /// Frame header                     → flag=1  total=17 offset=0   7 entries
    /// 01 1a 00 01000000 1100 0000 …
    /// 01 1a 00 01000000 1100 0700 …   → flag=1 total=17 offset=7   7 entries
    /// 01 1a 00 01000000 1100 0e00 …   → flag=1 total=17 offset=14  3 entries
    /// ```
    /// `offset` is the index of the first entry of this page in the **overall table**, the App side must concatenate using the offset.
    ///
    /// ⚠️ **The previous implementation parsed it as `<u32 count>`**, relying on the coincidence that "the card only had 5 entries, fitting in a single frame"
    /// That coincidence: `05 00 00 00` can be read as u32=5 or as u16 total=5 + u16 offset=0.
    /// When recordings increased (17 entries), `11 00 07 00` read as u32 yields 458,769 → "count declaration too long" → returns nil
    /// → All three frames are silently discarded → `listRecordings` times out after 8 seconds.
    /// **Lesson**: A parser validated only with single‑page samples inevitably fails when multiple pages appear.
    ///
    /// ⚠️ Implementation note: convert to `[UInt8]` first before processing. Swift's `Data` slices **do not** reset indices
    /// (`dropFirst(3)` leaves `b[0]` as the original buffer's byte 0), so direct indexing reads the wrong position ——
    /// This is exactly the root cause of the self‑test bug where "startTime was correct, fileType was wrong".
    ///
    /// In the return value, `entries` are the **current page** items, while `total` / `offset` are provided for the caller to assemble.
    static func parse(_ data: Data) -> (flag: UInt32, total: Int, offset: Int,
                                        entries: [TicNoteFileEntry])? {
        var a = Array(data)
        if a.count >= 3, a[0] == 0x01, a[1] == 0x1A, a[2] == 0x00 { a = Array(a.dropFirst(3)) }
        guard a.count >= 8 else { return nil }
        let flag = u32le(a, 0)
        let total = Int(u16le(a, 4))
        let offset = Int(u16le(a, 6))
        let body = a.count - 8
        // Entries have a fixed length of 10 bytes: divisibility is not a "quick check", it is the criterion for "whether this frame's structure is valid".
        guard body % 10 == 0 else { return nil }
        let page = body / 10
        // The page must lie entirely within the overall table. Out‑of‑bounds pages should be rejected (fail‑closed),
        // and must not be allowed to corrupt the assembly — a misaligned page causes all subsequent entries to be offset.
        guard offset >= 0, offset + page <= total else { return nil }
        var entries: [TicNoteFileEntry] = []
        entries.reserveCapacity(page)
        for i in 0..<page {
            let o = 8 + i * 10
            entries.append(TicNoteFileEntry(
                startTime: u32le(a, o),
                sizeBytes: u32le(a, o + 4),
                fileType: UInt16(a[o + 8]) | (UInt16(a[o + 9]) << 8)
            ))
        }
        return (flag, total, offset, entries)
    }

    /// Little‑endian uint16 (used for the `total` / `offset` fields).
    /// Like `u32le(_:_:)`, bytes are assembled explicitly without relying on any memory‑layout assumptions.
    private static func u16le(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
}

// MARK: - Read file chunk (cmd 0x1C) — ★ Real‑device‑verified "actual read file" command

/// A single read‑file‑chunk request / response. **The frame format is isomorphic to the `0x38` entry in the static table**,
/// but the real device actually uses `0x1C` (see `TicNoteObservedCommand.syncFile`).
///
/// ```
/// Request  APP→CARD  01 1C 00 <u32 sessionId> <u32 start> <u32 end> <u8 flags>
/// Response  CARD→APP  01 1C 00 <u32 sessionId> <u8 status>
/// ```
///
/// The request is a 16‑byte whole frame (3‑byte header + 3×u32 + 1‑byte flags);
/// The response is an 8‑byte whole frame. `start == end` is meaningless; the real device uses a **left‑closed, right‑open** interval `[start, end)`,
/// Each `end - start` is always `0x640` (1600) or the trailing `0x140` (320).
struct TicNoteSyncRequest {
    let sessionId: UInt32
    /// Chunk start (file byte offset, inclusive)
    let start: UInt32
    /// Chunk end (file byte offset, exclusive)
    let end: UInt32
    let flags: UInt8

    var byteCount: UInt32 { end &- start }

    /// Assemble the complete read‑file‑chunk request frame: `01 1C 00 <u32 sid> <u32 start> <u32 end> <u8 flags>`.
    ///
    /// Using **real‑device measured code** `TicNoteObservedCommand.syncFile`(0x1C), without the ÷2 conversion ——
    /// This path has been verified byte‑by‑byte over 355 real‑device requests and should not rely on any assumptions.
    /// (Side note: `TicNoteCommand.syncFile`(0x38).wireValue also equals 0x1C.)
    static func frame(
        sessionId: UInt32,
        start: UInt32,
        end: UInt32,
        flags: UInt8 = 0
    ) -> Data {
        var p = Data()
        p.append(u32le(sessionId)); p.append(u32le(start)); p.append(u32le(end)); p.append(flags)
        return TicNoteFrameCodec.frame(observed: .syncFile, payload: p)
    }

    /// Parse a full frame `01 1C 00 …` (or raw payload). Returning nil indicates an invalid structure.
    static func parse(_ data: Data) -> TicNoteSyncRequest? {
        var a = Array(data)
        if a.count >= 3, a[0] == 0x01, a[1] == 0x1C, a[2] == 0x00 { a = Array(a.dropFirst(3)) }
        guard a.count >= 13 else { return nil }
        return TicNoteSyncRequest(
            sessionId: u32le(a, 0),
            start: u32le(a, 4),
            end: u32le(a, 8),
            flags: a[12]
        )
    }

    /// Split a complete download into the sequence of chunks the device expects.
    ///
    /// The real device's chunking (`syncChunkBytes` = 1600) aligns perfectly with the "final partial block" of the whole file:
    /// 563,520 ÷ 1600 = 352.2 → 352 × 1600 + 1 × 320, and the real device `0x1C` count is exactly 353.
    /// `flags` are always 0.
    static func plan(sessionId: UInt32, totalBytes: UInt32,
                     chunk: UInt32 = UInt32(TicNoteGATT.syncChunkBytes)) -> [TicNoteSyncRequest] {
        guard chunk > 0, totalBytes > 0 else { return [] }
        var out: [TicNoteSyncRequest] = []
        var start: UInt32 = 0
        while start < totalBytes {
            let end = min(start + chunk, totalBytes)
            out.append(TicNoteSyncRequest(sessionId: sessionId, start: start, end: end, flags: 0))
            start = end
        }
        return out
    }

    /// Reassemble a series of chunk frames by offset into the complete file.
    ///
    /// ⚠️ Contract (derived from real‑device behavior, also the same fail‑closed approach as `WifiClient`):
    /// · End sentinel frame (`offset == 0xFFFFFFFF`) **is not written**;
    /// · When the same offset arrives repeatedly, the content must be **byte‑by‑byte identical** to count as a duplicate (real device reports 0 conflicts),
    ///   otherwise it is considered transmission damage — the real device this time had 7044 blocks with 0 repeats and 0 conflicts;
    /// · Gaps are always kept as zero placeholders, **never use placeholders to masquerade as real data**; after assembly, if `gaps != 0`
    ///   or `conflicts != 0`, the caller **must reject** this audio segment and not write it to storage;
    /// · Two layers of defensive rejection (real‑device data will never trigger, but malformed/misaligned frames will):
    ///   - `offset` not a multiple of `voicePayloadBytes` → counted as `malformed`. Real device stride is always 80;
    ///   - `maxOffset` exceeds 256 MiB → abort immediately. The largest single recording observed is 23.6 MB (≈ 49 minutes),
    ///     256 MiB leaves about ~9 hours of headroom.
    ///   Without these two checks, a frame with a misaligned field could cause this function to expand a GB‑scale buffer using the wrong offset,
    ///   which actually happened in the 5th self‑test round, causing a 1.8 GB allocation to be killed by OOM.
    static func assemble(voiceFrames: [TicNoteVoiceChunk])
        -> (data: Data, gaps: Int, conflicts: Int, malformed: Int) {

        let width = TicNoteGATT.voicePayloadBytes
        var byOffset: [UInt32: Data] = [:]
        var conflicts = 0
        var malformed = 0
        for f in voiceFrames {
            guard !f.isEnd else { continue }
            guard f.offset % UInt32(width) == 0 else { malformed += 1; continue }
            if let existing = byOffset[f.offset] {
                if existing != f.audio { conflicts += 1 }
            } else {
                byOffset[f.offset] = f.audio
            }
        }
        guard let maxOffset = byOffset.keys.max() else {
            return (Data(), malformed, conflicts, malformed)
        }
        guard maxOffset < (256 << 20) else {
            return (Data(), 1, conflicts, malformed + 1)   // Absurd offset → overall assessment is unreliable
        }
        var out = Data()
        var gaps = 0
        var o: UInt32 = 0
        while o <= maxOffset {
            if let chunk = byOffset[o] {
                out.append(chunk)
            } else {
                gaps += 1
                out.append(Data(count: width))   // Zero placeholder; gaps cause the caller to reject
            }
            o &+= UInt32(width)
        }
        return (out, gaps, conflicts, malformed)
    }
}

/// Little‑endian utilities for this section (equivalent to the private implementation in `TicNoteFrameCodec`, but scoped independently).
private func u32le(_ a: [UInt8], _ o: Int) -> UInt32 {
    guard o >= 0, o + 4 <= a.count else { return 0 }
    return UInt32(a[o]) | (UInt32(a[o+1]) << 8) | (UInt32(a[o+2]) << 16) | (UInt32(a[o+3]) << 24)
}

private func u32le(_ v: UInt32) -> Data {
    withUnsafeBytes(of: v.littleEndian) { Data($0) }
}

// MARK: - Card → App response/notification command codes

/// Command codes sent proactively by the card (responses or notifications). Source: the `cmd == N` dispatch chain in `_handleClipDeviceData`
/// (starting at `watch_audio_service.dart` 0x10fdd64).
/// Card → App **response / notification** command codes.
///
/// ⚠️ Shares origin with `TicNoteCommand` (Dart AOT static extraction), so **the numeric values are also twice the online values** ——
/// The device must use `wireValue`. Real‑device verification (left = this enum, right = ATT capture):
/// ```
///   deviceStatus         0x06 / 2 = 0x03  Real device reports 3  ✅
///   generalSetting       0x10 / 2 = 0x08  Real device reports 2  ✅
///   battery              0x12 / 2 = 0x09  Real device reports 7 (returns 1 byte 0x64=100%)✅
///   audioType            0x16 / 2 = 0x0B  Real device reports 3  ✅
///   physicalButtonRecord 0x28 / 2 = 0x14  Real device reports 2  ✅
///   stopRecording        0x2E / 2 = 0x17  Real device reports 2  ✅
///   bookmarkSyncResponse 0x4C / 2 = 0x26  Official parser hard‑codes 0x26 ✅
/// ```
/// ⚠️ `bookmarkSyncResponse` was the **only** entry in this enum written as the actual value (0x26), inconsistent with its peers ——
/// This mixing made it impossible to know whether to use the rawValue or the online value; it has been unified to 0x4C (÷2 yields 0x26).
enum TicNoteInboundCommand: UInt16 {
    case deviceStatus           = 0x06   // → _handleDeviceStatusResponse
    case generalSetting         = 0x10   // → _handleGeneralSettingResponse
    case battery                = 0x12   // → _handleBatteryResponse
    case audioType              = 0x16   // → _handleAudioTypeResponse
    case bookmarkSyncResponse   = 0x4C   // Bookmark sync frame (online code 0x26, = 0x4C>>1): **does not go through cmd dispatch**, parse() pre‑checks with (data[1]|data[2]<<8)==0x26 before handing to parseBookmarkSyncResponse()
    case physicalButtonRecord   = 0x28   // → _handlePhysicalButtonRecordStart (the button on the card)
    case pauseRecording         = 0x2A   // → _handlePauseRecordingResponse
    case resumeRecording        = 0x2C   // → _handleResumeRecordingResponse
    case stopRecording          = 0x2E   // → _handleStopRecordingResponse
    case recordingStatusNotify  = 0x30   // → _handleRecordingStatusNotify
    case sendTranscription      = 0x40   // → _handleSendTranscriptionResponse
    case sendMeetingSummary     = 0x42   // → _handleSendMeetingSummaryResponse
    case realtimeSwitch         = 0x44   // → _handleRealtimeTranscriptionSwitchResponse
    case realtimeRequest        = 0x46   // → _handleWatchRealtimeTranscriptionRequest
    case recordingBookmark      = 0x48   // → _handleRecordingBookmarkNotify
    case displayModeSwitch      = 0x4A   // → _handleWatchDisplayModeSwitch

    /// **Online value** = static reverse value ÷ 2. Same conversion as `TicNoteCommand.wireValue`.
    var wireValue: UInt16 { rawValue >> 1 }
}

// MARK: - Decoding product

/// Voice/recording data frame.
///
/// Online layout (**core of reading recordings**, confirmed byte‑by‑byte on real device in round 5):
/// ```
/// Offset  0        1..4          5..8          9          10..89
///      [0x02] [sessionId u32] [offset u32] [len=0x50] [80 bytes data…]
/// ```
///
/// · Whole frame **always 90 bytes** (real device 7398/7398), `90 - 10 = 80` = length byte declaration value;
/// · `offset` is **file byte offset**, real device step size always 80 (7043/7043);
/// · `offset == 0xFFFFFFFF` is **end/empty** sentinel value;
/// · ⛔ Early notes wrote “this card has no length byte, audio starts at offset 9” — **that is wrong**.
///   Real device data simultaneously satisfies `[9] always 0x50` and `offset step size always 80`, the only self‑consistent explanation
///   is that `[9]` is the length byte, audio starts at `[10]`.
///   (Supporting evidence: the sibling implementation `utejxint/utejxdo.java:141` has the isomorphic frame starting audio at offset **10**,
///   the 9th byte is exactly the length byte — both are consistent here.)
struct TicNoteVoiceChunk {
    let sessionId: UInt32
    /// Byte offset of this fragment in the file; `0xFFFF_FFFF` indicates end
    let offset: UInt32
    /// Length byte at `[9]` within the frame. Real device always `0x50` (= 80 = `audio.count`).
    let declaredLength: UInt8
    let audio: Data

    static let endSentinel: UInt32 = 0xFFFF_FFFF
    var isEnd: Bool { offset == Self.endSentinel }

    /// Whether the length byte matches the actual audio byte count. Real device 100 % consistent;
    /// Inconsistency can only be due to a truncated frame (MTU not negotiated) or the peer changing format — both should be reported.
    var isWellFormed: Bool { Int(declaredLength) == audio.count }
}

/// Card's acknowledgment for a `0x1C` fragment request: `01 1C 00 <sessionId u32> <status u8>`.
///
/// `status == 0` = accepted, data follows; non‑0 = card rejects.
///
/// ⚠️ Non‑zero values **only have a `0x02` sample** (received when probe used sid=0),
/// and that sid did not exist on the card at the time.
/// Therefore this type treats `0` as success,
/// **all other values are treated as failures and the raw value is reported** — we do not hard‑code a “session does not exist” message for `0x02` here, because a single sample cannot support a semantic.
struct TicNoteSyncReceipt: Equatable {
    /// Session ID reported by the card. Normally matches the one we requested.
    let sessionId: UInt32
    let status: UInt8

    var isOK: Bool { status == 0 }
}

/// **Bookmark sync frame** (command code `0x26` within the frame).
///
/// ⚠️ Early versions called it “session list frame”, **the name is wrong**.
/// It is **the bookmark list of a specific recording**: the card reports the “mark” positions pressed on that session (offset in **seconds**) to the App.
///
/// Source: `WatchAudioParser.parseBookmarkSyncResponse()` (address `0xd82014`, length 0x50c)
/// + `parse()` pre‑check (starting at `0xd80238`). Restored step by step:
/// - `data.count >= 9`, otherwise return null (`0xd8203c: cmp x4, #9`)
/// - `(data[1] | data[2] << 8) == 0x26`, otherwise return null (`0xd820bc`)
/// - Read header u32 (little‑endian) + two u8
/// - Loop: cursor starts at 9, **step 4**, each iteration takes 4 consecutive bytes and
///   `b|c<<8|d<<16|e<<24` forms a u32 (`0xd82248`–`0xd82408`, see
///   `lsl #0x10` / `lsl #0x18` with `orr`), appending into a `List<int>`
/// - Elements are stored in the array with a **4‑byte stride** (`add x25, x1, x6, lsl #2`),
///   so this is indeed "one entry per 4 bytes", not a byte stream
///
/// The map returned to the upper layer is `{"cmd": 0x4C, "sessionId": …, "status": …, "offsetSecList": [...]}`
/// — Note that `cmd` is filled with **0x4C** (the command code used by the requester), not the frame’s `0x26`.
struct TicNoteBookmarkFrame {
    /// Card’s sessionId (u32 LE in header)
    let sessionId: UInt32
    /// Card’s self‑reported status
    let status: UInt8
    /// Number of entries carried by this frame (official pre‑check requires `count <= 0x64`, i.e., 100)
    let count: UInt8
    /// Bookmark position list, unit **seconds**
    let offsetSecList: [UInt32]
}

// MARK: - Protocol specification

enum TicNoteRecorderSpec: RecorderProtocolSpec {

    static let identifier = "ticnote"
    static let family = "TicNote"

    // MARK: GATT (confirmed)

    static var serviceUUIDs: [CBUUID] { [TicNoteGATT.clipService] }
    static var rxCharacteristic: CBUUID { TicNoteGATT.writeCharacteristic }
    static var txCharacteristic: CBUUID { TicNoteGATT.notifyCharacteristic }

    /// Recommend calling `requestMtu` to `TicNoteGATT.defaultMTU` after connection.
    static let preferredMTU = TicNoteGATT.defaultMTU

    // MARK: Broadcast identification (confirmed algorithm)

    /// TicNote card identity is based on **ASCII SN in manufacturer data**, not the device name.
    ///
    /// Basis: native `WatchPlugin.parseScanRecordForSN()` only recognizes AD type `0xFF` and
    /// company identifier = `0x0259` (601) broadcasts, and extracts the length‑prefixed ASCII string at a fixed offset
    /// as `sn`; `createScanDeviceMap()` sends it as the `sn` field to Dart.
    /// The official App allows users to change the device name, so **never** fall back to the name — return nil if there is no manufacturer data.
    ///
    /// Note: only `manufacturerData` is needed here. `localName` / `serviceUUIDs` are abstract‑layer
    /// additional clues; this card does not use them (the card will not put private service UUIDs into advertisements).
    ///
    /// ⚠️ This function and `TicNoteAdvertisementParser` are both **directly copied from official byte offsets**,
    /// not yet verified against real device advertisements. Before releasing (`isVerified = true`), please first follow
    /// `CAPTURE-MANUAL.md` to verify with nRF Connect that the SN can be extracted and matches the SN on the card/App.
    static func parseAdvertisement(
        manufacturerData: Data?,
        localName: String?,
        serviceUUIDs: [CBUUID]?
    ) -> RecorderAdvertisement? {
        guard let md = manufacturerData,
              let adv = TicNoteAdvertisementParser.parse(manufacturerData: md)
        else { return nil }

        return RecorderAdvertisement(
            protocolID: identifier,
            family: family,
            modelName: "NE-79",
            firmware: nil,          // Firmware version is not present in the BLE protocol; the official app uses cloud deviceInfo.
            hardware: nil,
            battery: nil,           // Battery level is available only after connecting and sending 0x12 GET_BATTERY.
            powerState: nil,
            identity: Data(adv.sn.utf8),   // SN is the identity primary key.
            raw: [
                "sn": AnyHashable(adv.sn),
                "reserved": AnyHashable(adv.reserved.map { String(format: "%02X", $0) }.joined()),
                "localName": AnyHashable(localName ?? ""),
            ]
        )
    }

    // MARK: Frame encoding/decoding (confirmed)

    static var frameCodec: RecorderFrameCodec { TicNoteFrameCodec() }

    // MARK: Command set (confirmed)

    static var commands: RecorderCommandSet {
        // ⚠️ This table contains **wire bytes**, callers use it directly on the device, so each entry must be a wire value:
        //   · TicNoteObservedCommand.* → already measured values, use .rawValue directly
        //   · TicNoteCommand.* / TicNoteInboundCommand.* → static reverse values, must use .wireValue (÷2)
        // Mixing them causes half‑correct, half‑incorrect values for the same field — a real issue fixed in round five.
        RecorderCommandSet(
            startRecording: UInt8(TicNoteCommand.recordStart.wireValue),          // 0x28>>1 = 0x14
            stopRecording: UInt8(TicNoteCommand.recordStop.wireValue),            // 0x2E>>1 = 0x17
            // Recording status notification actively reported by the card
            recordingStatus: UInt8(TicNoteInboundCommand.recordingStatusNotify.wireValue), // 0x30>>1 = 0x18
            // Physical button on the card starts recording (same wire code 0x14 as App’s recordStart)
            recordingStartedEvent: UInt8(TicNoteInboundCommand.physicalButtonRecord.wireValue),
            recordingStoppedEvent: UInt8(TicNoteInboundCommand.stopRecording.wireValue),
            // Real‑time audio stream uses message type 0x03; here the command code is for "enable/disable live transcription"
            liveStream: UInt8(TicNoteCommand.setRealtimeTranscriptionEnable.wireValue), // 0x44>>1 = 0x22

            // The following five items **use real‑device measured codes** directly, without dividing by 2:
            //    fileTransfer: real device 355 fragment requests all 0x1C (static table 0x38 never appeared)
            //    fileList: real device 4 list requests all 0x1A (static table 0x34)
            //    deviceInfo: real device 0x03
            //    syncTime: real device 0x04 (overturns the static‑period assertion that there is no time sync in the whole table)
            fileTransfer: UInt8(TicNoteObservedCommand.syncFile.rawValue),
            deviceInfo: UInt8(TicNoteObservedCommand.getStatusInfo.rawValue),
            switchInfo: UInt8(TicNoteCommand.generalSetting.wireValue),           // 0x10>>1 = 0x08 (verified on real device)
            fileList: UInt8(TicNoteObservedCommand.getFileList.rawValue),
            fileDelete: UInt8(TicNoteCommand.deleteRecord.wireValue),             // 0x3C>>1 = 0x1E
            // ★ Time sync: real device `01 04 00 <u32 timestamp LE><u8>`, card returns the same code.
            syncTime: UInt8(TicNoteObservedCommand.syncTime.rawValue),

            extended: [
                "battery": UInt8(TicNoteObservedCommand.getBattery.rawValue),     // 0x09 (real device)
                "openWifi": UInt8(TicNoteCommand.openWifi.wireValue),             // 0x14>>1 = 0x0A
                "audioType": UInt8(TicNoteCommand.audioType.wireValue),           // 0x16>>1 = 0x0B (verified on real device)
                "usbMode": UInt8(TicNoteCommand.setUsbMode.wireValue),            // 0x18>>1 = 0x0C (verified on real device)
                "recordPause": UInt8(TicNoteCommand.recordPause.wireValue),       // 0x2A>>1 = 0x15
                "recordResume": UInt8(TicNoteCommand.recordResume.wireValue),     // 0x2C>>1 = 0x16
                "syncFileStop": UInt8(TicNoteCommand.syncFileStop.wireValue),     // 0x3A>>1 = 0x1D
                "sendTranscription": UInt8(TicNoteCommand.sendTranscription.wireValue),    // 0x40>>1 = 0x20
                "sendMeetingSummary": UInt8(TicNoteCommand.sendMeetingSummary.wireValue),  // 0x42>>1 = 0x21
                "bookmarkSync": UInt8(TicNoteCommand.bookmarkSync.wireValue),     // 0x4C>>1 = 0x26 (official parser verification)
                "ack46": UInt8(TicNoteCommand.ackRealtimeTranscriptionRequest.wireValue), // 0x46>>1 = 0x23
                "ack48": UInt8(TicNoteCommand.ackBookmarkNotify.wireValue),       // 0x48>>1 = 0x24
                "ack4A": UInt8(TicNoteCommand.ackDisplayModeSwitch.wireValue),    // 0x4A>>1 = 0x25
                // New confirmation on real device
                "setDeviceIdentity": UInt8(TicNoteObservedCommand.setDeviceIdentity.rawValue),
                "getConfig": UInt8(TicNoteObservedCommand.getConfig.rawValue),
                "setC": UInt8(TicNoteObservedCommand.setC.rawValue),
                "getSessionState": UInt8(TicNoteObservedCommand.getSessionState.rawValue),
            ]
        )
    }

    // MARK: Wi‑Fi fast transfer (aligned with V05E logic, host/port to be measured)

    /// ★ **Following D·NOTE (V05E) logic**: same `0xAA` frame header + same set of ASCII text commands
    /// (`list` / `pull {file} {offset}` / `delete {file}` / `quit`), credentials are also issued by the BLE side.
    ///
    /// ⚠️ However `profile.isVerified == false` — in the 2026-10-08 capture, the user used **BLE**,
    /// there was never an App→card `0x14 OPEN_WIFI`, so the SSID / password / host / port sent by the card have not been obtained.
    /// Confirmed only: trigger command is `0x14`; Wi‑Fi is provided by Realtek **RTL8722CSM**;
    /// The Dart snapshot contains no `192.168.x.x` / `6718` / `0xAA` literals (address is not hard‑coded).
    ///
    /// ✅ **Added official proof in round 6**: the APK contains `com.mobvoi.wifi_plugin.socket.Opus2Ogg`
    /// which packages the received raw Opus stream into Ogg at 1600 B per page — indicating that the Wi‑Fi channel carries
    /// **the same batch of Opus packets** as the BLE channel, just faster.
    /// There is also a full set of `*APP#opusfile#` / `*DEV#opusfile#` / `*APP#filect#` / `*APP#listreq#`
    /// text commands (`com.nveasy.ble.utils.Constant`), sharing the same origin as V05E’s text command style.
    ///
    /// ⚠️ Another factual correction: **this path no longer requires "decryption"** — the payload is already plain Opus
    /// (see `TicNoteClipCipher`). Wi‑Fi’s purpose is simply **faster**.
    ///
    /// ⛔ **Correction (round 8)**: this previously stated “BLE measured 203.7 B/s (563 KB took 46 minutes)” —
    /// **that was a measurement accident**, the true average speed is **8,819 B/s** (≈ real‑time 1:1, 563 KB took 71.9 s).
    /// Cause of error: a **isolated sentinel** frame (t=3083.8) was captured, and throughput was measured using "first‑last span" which included the middle
    /// **45 minutes of idle** time, underestimating by **38×**. See `protocol-notes.md` §0quinquies.1.
    ///
    /// Thus the necessity of Wi‑Fi fast transfer **is not** “Bluetooth is too slow to use”, but:
    /// the largest single recording on the card is 23.6 MB (49 minutes), which at 8.8 KB/s requires **45 minutes** to transfer.
    /// daily recordings of a few minutes are easily handled over BLE (`TicNoteLink` timeout is based on size).
    static var wifiTransfer: RecorderWifiProfile? { .ticnote }

    // MARK: Binding and encryption (partially confirmed)

    /// No process found on the App side that writes a binding identifier to the card (D·NOTE’s 16‑byte bondID in
    /// TicNote’s command table **has no corresponding command**), so fill nil.
    /// The card’s “binding” semantics appear in the official App’s `juzhicard` + SN records, belonging to the App‑side account state.
    ///
    /// Real‑device evidence: `0x01 setDeviceIdentity` indeed includes a 16‑byte identifier in those 45 bytes
    /// (real device value `"1234567890000000"`), but it is confirmed by the **card** via a `0x02` response,
    /// and the entire download/time‑sync process does not depend on it — unlike D·NOTE’s “no recording without binding”.
    static var bondIDLength: Int? { nil }

    /// Always `nil`, meaning **“this protocol has no encryption, no key required”**.
    ///
    /// ⚠️ **Correction in round 6**: this previously stated “encryption confirmed, but envelope and key not yet extracted”.
    /// That conclusion came from the five checks in round 5 (entropy 7.9791 / gzip 1.0004 / unique byte count per 160 B record
    /// = random expectation / 16‑byte block repeat rate 0.000 % / 5 Opus hypotheses yielding white noise) —
    /// **they only prove “high entropy and incompressible”, which does not equal “ciphertext”**:
    /// Opus (CELT/SILK) arithmetic encoder output **is itself** high‑entropy and incompressible.
    /// As for the 5th item “extract white noise”, the root cause is **incorrect frame‑splitting assumption** —
    /// At the time `[TOC][CELT frame first byte]` was treated as “2‑byte plaintext header + ciphertext”,
    /// the whole data was offset by 2 bytes for decoding, causing any encoder to produce only noise.
    ///
    /// Correct conclusion is in `TicNoteClipCipher`: payload is **plaintext Opus**.
    /// (Side evidence: BLE never distributes any key, nor any `encryptSet` type toggle command ——
    /// At that time those two points were read as "constant encryption", but now they appear as "no encryption at all").
    static var fileEncryptionKeyLength: Int? { nil }

    /// ★ Disk write front gate — TicNote's implementation is `TicNoteClipCipher`:
    /// `encryptsClips == false`, `keyLength == nil`, `isEncryptedClip` always false.
    /// Thus `RecorderClipGate.evaluate` yields `.plaintext`, `isDeliverable == true`.
    ///
    /// ⚠️ In round 6, also fix a real issue: `clipDecryptability` originally only checked `keyLength`,
    /// Thus TicNote was incorrectly reported as `.blocked` because `keyLength == nil` (the UI would show "cannot decrypt")—
    /// **"No key needed" does not equal "cannot decrypt"**. Now it will first query `encryptsClips`.
    static var clipCipher: RecorderClipCipher.Type? { TicNoteClipCipher.self }

    // MARK: Release status

    /// ★ Read path (connect → list files → `0x1C` fragment fetch → reassemble full file → decode to audio)
    /// **End‑to‑end verified**: 2026-10-08 packet capture rebuilt **563,520 bytes, 0 gaps, 0 conflicts**,
    /// matching the card‑reported size (`0x17` notification, `0x1A` list) byte‑by‑byte;
    /// the same bytes packaged as Ogg Opus via `opusPacketBytes` **actually decode to human voice** (see `TicNoteClipCipher`).
    static let readPathVerified = true

    /// ⚠️ Still `false` — but **the reason has changed**, do not interpret with the old rationale.
    ///
    /// ~~Old reason: the retrieved data was ciphertext, BLE could not obtain the key~~ ← **deprecated**, the payload was never encrypted.
    ///
    /// Now the three **pure engineering** enumerated finishing tasks block release:
    ///   1. **Broadcast identification not cross‑checked** — `TicNoteAdvertisementParser` is written by copying the official byte offsets,
    ///      still not cross‑checked byte‑by‑byte with real‑device broadcasts (must be done before `isVerified = true`);
    ///   2. **iOS decoding chain not on device** — the product of `TicNoteOpusStream.oggOpus` has been verified on macOS
    ///      `afinfo` ("2 ch, 48000 Hz, opus", 3522 packets, 64000 bps),
    ///      but not yet played through `AVAudioFile` / `AudioConverter` on a real device;
    ///   3. **Wi‑Fi fast transfer not run by Nomily itself** — protocol (§17) and credentials (§18: `SSID = "TicNote-" + last 4 digits of SN`,
    ///      password = last 8 digits of SN) are set, code is wired, only the device run remains.
    ///
    /// These three items do not involve cryptography, but **should not be released to users before real‑device evidence**.
    static var isVerified: Bool { false }

    /// ★ **Bluetooth read path verified on real device** (2026-10-09, iPhone 15 Pro Max / iOS 27.0.1):
    /// Connect → `0x1A` list → **all 17 entries displayed correctly** (including the new recording from 2026-10-09).
    /// This round also fixed a pagination bug exposed only on the device: the `0x1A` response is
    /// `<u32 flag><u16 total><u16 offset>` **maximum 7 entries per page**,
    /// the old implementation read `total+offset` as a single u32 count, causing all 3 frames of the 17 recordings to be silently dropped.
    /// （`protocol-notes.md` §19.10）。
    ///
    /// Division of labor with `isVerified`: this item only answers the "read path",
    /// fast transfer (the main gap of `isVerified`) and the iOS playback chain are still not on device, so `isVerified` remains `false`.
    static var isReadingVerified: Bool { true }

    /// ★ **`.beta`** — appears in the scan list, but the UI must label it as "experimental".
    ///
    /// Why it is safe to show users: **the read path has an end‑to‑end evidence that can be rerun in CI**.
    /// Self‑check §18 replays the 70.44 s recording from a real‑device capture (353 `0x1C` requests / 7044 data frames /
    /// 353 sentinels / 353 card acknowledgments) to `TicNoteSession`, asserting:
    ///   · the state machine’s **353 requests are all byte‑by‑byte identical to those emitted by the real device**;
    ///   · the assembled **563,520 bytes match the file independently rebuilt in Python byte‑by‑byte**;
    ///   · the packaged Ogg matches the **gold‑standard Ogg built independently in Python byte‑by‑byte** (576,664 B).
    /// This is stronger than “ran on a real device once, nobody saw” — it is reproducible, byte‑level, and cross‑implementation.
    ///
    /// Why it remains `.beta` instead of `.general`: `exposure` only determines "visibility",
    /// `isVerified` answers whether the evidence is sufficient.
    /// None of the three real‑device finishers above (broadcast cross‑check / on‑device playback / Wi‑Fi fast transfer) are covered by §18, so it cannot move to `.general`.
    static var exposure: RecorderExposure { .beta }
}

// MARK: - Text payload truncation rules (new confirmation this round)

/// Length rules for returned text (`0x40` transcription / `0x42` meeting summary).
///
/// **The official implementation does not segment, but truncates.** This is the hard fact uncovered from the Dart snapshot this round:
///
/// ```dart
/// // watch_audio_service.dart  WatchAudioService._truncateToMaxUtf8Bytes
/// //   blutter disassembly address 0x137d1c0, sole call site 0x137c130
/// final b = utf8.encode(text);
/// if (b.length <= 230) return b;         // 0xE6
/// var i = 230;
/// while (i > 0 && (b[i] & 0xC0) == 0x80) i--;   // retreat to the start byte of a UTF‑8 character
/// return Uint8List.sublistView(b, 0, i);
/// ```
///
/// There is an even coarser gate at the call site (same file `0x137c108`):
/// If the total length `> 0xFFFF` (65535) it **rejects sending outright**, log string
/// `[WatchAudioService] [Meeting Summary] Length{n} exceeds limit`, returns `false`.
///
/// Consistent with the "no segmentation" conclusion: if the SDK originally had segmentation capability, cutting packets here would suffice,
/// no need to design a "truncate at UTF‑8 boundaries" logic.
enum TicNoteTextPayload {

    /// Maximum UTF‑8 byte count for text payload.
    static let maxUTF8Bytes = 230

    /// Upstream safety gate: exceeding this byte count causes the official implementation to reject sending outright (no truncation, no segmentation).
    static let hardRejectByteCount = 0xFFFF

    /// Encode the text into UTF‑8 bytes ≤ `maxUTF8Bytes` according to official semantics,
    /// **the truncation point backs up to a character boundary**, never splitting a multi‑byte character.
    static func truncateToMaxUTF8Bytes(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count > maxUTF8Bytes else { return Data(bytes) }
        var i = maxUTF8Bytes
        // UTF‑8 continuation bytes have the high two bits as 10 — backtrack until the start byte is reached.
        while i > 0 && (bytes[i] & 0xC0) == 0x80 { i -= 1 }
        return Data(bytes[0..<i])
    }
}

// MARK: - Frame encoding/decoding

/// TicNote frame format — **confirmed**, two independent evidence chains corroborate each other:
///
/// 1. **Send side**: the 20 constructors of `WatchAudioCommand` all start with a literal
///    `[0x02, cmd, 0x00, …]` (extracted byte‑by‑byte from blutter disassembly).
///    and `WatchAudioService._sendCommand()` **does no wrapping** — it converts the constructor’s
///    returned `List<int>` directly into a `Uint8List` for `sendPlugin`.
/// 2. **Receive side**: `WatchAudioParser.parse()` first rejects when `data.length < 3`,
///    then `_readShort()` (**little‑endian** uint16) reads the command code.
///
/// So the on‑line format is:
/// ```
/// [type u8][cmd u16 LE][payload …]
/// ```
/// **No length prefix, no CRC** — because **a single GATT notify is exactly one whole frame**,
/// frame boundary = notify boundary (evidence: in `_handleClipDeviceData()`
/// `extractBytes(event) → parse(bytes)`, `parse` is called only once, with no loop outside).
///
/// ⚠️ This is the part of the protocol most prone to mistakes: **do not** implement "circular buffer + length‑based framing".
/// Treat each received notify as a single frame passed to `decode()`.
/// The only fallback scenario: if a frame exceeds the payload of a single notify (e.g., large audio chunk and MTU not negotiated),
/// then accumulate to the "expected byte count" to complete it — the official App does not do this.
struct TicNoteFrameCodec: RecorderFrameCodec {

    // MARK: Encoding (App → Card)

    /// Frame assembly: `[0x01][cmd low][cmd high] + payload`.
    ///
    /// ⚠️ `type` is always **`0x01`** (control frame) — verified on real device 371/371 outbound, see statistics in `TicNotePacketType`.
    /// The early version using `0x02` was wrong (treating the "voice payload" as the direction bit).
    ///
    /// ⚠️ Command codes use `cmd.wireValue` (= static reverse value ÷ 2), not `cmd.rawValue`.
    static func frame(_ cmd: TicNoteCommand, payload: Data = Data()) -> Data {
        frame(rawCmd: cmd.wireValue, payload: payload)
    }

    /// Assemble frames directly with the **on‑line command code**. Tested commands use this, bypassing the static reverse conversion.
    static func frame(rawCmd: UInt16, payload: Data = Data()) -> Data {
        var out = Data(capacity: 3 + payload.count)
        out.append(TicNotePacketType.commandResponse.rawValue)
        out.append(UInt8(rawCmd & 0xFF))
        out.append(UInt8((rawCmd >> 8) & 0xFF))
        out.append(payload)
        return out
    }

    /// Use `TicNoteObservedCommand` (real‑device verified code, no ÷2 needed) for frame assembly.
    static func frame(observed cmd: TicNoteObservedCommand, payload: Data = Data()) -> Data {
        frame(rawCmd: cmd.rawValue, payload: payload)
    }

    /// Obtain the full frame for fixed‑payload commands; parameterized commands use the dedicated method below.
    static func frame(_ cmd: TicNoteCommand) -> Data? {
        guard let p = cmd.fixedPayload else { return nil }
        return frame(cmd, payload: p)
    }

    /// **Start‑recording frame** — `01 14 00 01 <scene> 00 00 00 00`.
    ///
    /// ## Byte‑by‑byte source
    /// `WriteCmd::recordStart(dynamic scene)` disassembly (`writeBle.dart` 0x13b2990…)
    /// sequentially appends 9 elements; blutter emits **Smi tag words**, the true value must be `>> 1`:
    /// ```
    ///   Tag   True value   Description
    ///   0x02    0x01   type (control frame)
    ///   0x28    0x14   cmd low byte
    ///   0x00    0x00   cmd high byte
    ///   0x02    0x01   ★ payload[0], **constant 0x01**
    ///   <arg>   scene  payload[1] = recording scene (retrieved by the caller from `0x08` rec_scene)
    ///   0x00…   0x00   payload[2..5]
    /// ```
    ///
    /// ⚠️ **`payload[0]` is `0x01`, not `0x02`** — early versions mistakenly wrote `0x02`
    /// (treating the tag word as a byte value, while the same line’s `0x28` was correctly converted to `0x14`). This is the **only** actual byte error found in this review, and the primary suspect for the "record button unresponsive" issue.
    /// It is the **only** actual byte error discovered in this itemized review, and the main suspect for the "record button not responding" problem.
    ///
    /// ⚠️ Do not infer on‑line bytes from the AOT switch table: the value `0x14` has **disassembly + calibration table** dual evidence
    /// (the table in `TicNoteCommand` documentation: all 10 known commands match captured packets after `>>1`).
    static func recordStartFrame(scene: UInt8) -> Data {
        Data([0x01, 0x14, 0x00, 0x01, scene, 0x00, 0x00, 0x00, 0x00])
    }

    /// **Stop‑recording frame** — `01 17 00`, used paired with the start‑recording frame.
    ///
    /// Source is also byte‑by‑byte disassembly: `WriteCmd::recordEnd` appends `[0x02, 0x2E, 0x00]` (tag word)
    /// → `>>1` → `[0x01, 0x17, 0x00]`, matching the real‑device capture.
    static var recordStopFrame: Data { Data([0x01, 0x17, 0x00]) }

    // MARK: Parameterized commands (payload always little‑endian)

    /// `02 10 00 <u8>` — generic setting.
    static func generalSetting(_ value: UInt8) -> Data {
        frame(.generalSetting, payload: Data([value]))
    }

    /// `02 2A 00 <u32 LE>` (pause) / `02 2C 00 <u32 LE> 02` (resume).
    ///
    /// ⚠️ **Resume has an extra trailing byte `0x02` compared to pause** — this is the result of byte‑by‑byte extraction
    /// (`buildRecordPause` 7 bytes vs `buildRecordResume` 8 bytes), easy to miss.
    /// The meaning of the trailing byte is undefined (possibly "whether to auto‑restart timing after resume").
    static func recording(_ cmd: TicNoteCommand, sessionId: UInt32) -> Data? {
        switch cmd {
        case .recordPause:
            return frame(cmd, payload: u32le(sessionId))
        case .recordResume:
            return frame(cmd, payload: u32le(sessionId) + Data([0x02]))
        default:
            return nil
        }
    }

    /// `02 34 00 <u32 LE> <u32 LE> <u8>` — retrieve session list.
    /// ⚠️ The semantics of the last two fields are pending confirmation (speculated as pagination offset / items per page / filter).
    static func getSessionList(a: UInt32 = 0, b: UInt32 = 0, flags: UInt8 = 0) -> Data {
        var p = Data()
        p.append(u32le(a)); p.append(u32le(b)); p.append(flags)
        return frame(.getSessionList, payload: p)
    }

    /// `02 38 00 <sessionId u32> <start u32> <end u32> <u8>` — **read recording fragment** (16 bytes).
    ///
    /// Byte‑by‑byte extraction confirmed: `buildSyncFile()` is exactly 16 bytes = 3‑byte frame header + 3×u32 + 1‑byte tail flag.
    /// Field semantics corroborated by a sister implementation in the same SDK:
    /// `com.yc.nadalsdk.bean.recorder.RequestSyncAudioRecordFileInfo` fields are
    /// `{sessionId, start, end, fileType}`, and its frame‑building method
    /// (`utejxint/utejxdo.java` lines 295–307) expands them in little‑endian order as `sessionId → start → end → fileType`.
    /// Thus it is **more likely a byte range [start, end) rather than offset + length**.
    /// Another piece of evidence: the Dart side handling of the `0x38` response prints `fileSize`,
    /// and has an `ℹ️ CMD=38 SESSION_NOT_FOUND` branch — indicating the first u32 is indeed the sessionId.
    ///
    /// ⚠️ The `start/end` naming remains **inferred** (order and width are confirmed byte‑by‑byte).
    /// Cross‑check method: capture a real `0x38` round‑trip and see whether the 2nd and 3rd u32 form a continuous interval, and whether the third minus the second equals the size of a single fragment.
    /// 
    static func syncFile(sessionId: UInt32, start: UInt32, end: UInt32, flags: UInt8 = 0) -> Data {
        var p = Data()
        p.append(u32le(sessionId)); p.append(u32le(start)); p.append(u32le(end)); p.append(flags)
        return frame(.syncFile, payload: p)
    }

    /// 02 3C 00 <sessionId u32> <u8> -- Delete recording.
    static func deleteRecord(sessionId: UInt32, flags: UInt8 = 0) -> Data {
        var p = Data()
        p.append(u32le(sessionId)); p.append(flags)
        return frame(.deleteRecord, payload: p)
    }

    /// 02 4C 00 <u32 LE> -- Bookmark sync.
    static func bookmarkSync(_ value: UInt32) -> Data {
        frame(.bookmarkSync, payload: u32le(value))
    }

    /// 02 44 00 <u8> <u8> -- Realtime transcription toggle.
    static func setRealtimeTranscription(enable: Bool, mode: UInt8 = 0) -> Data {
        frame(.setRealtimeTranscriptionEnable, payload: Data([enable ? 0x01 : 0x00, mode]))
    }

    /// 02 40 00 <u32> <u32> <u8> <utf8…> <u8> / 02 42 00 … -- Return text.
    ///
    /// Source: these two constructors internally call `utf8Encode` + `_GrowableList.addAll`,
    /// Thus the payload is the concatenation of `[u32][u32][u8][…utf8 bytes…][u8]`.
    /// The semantics of the two u32 and the leading/trailing u8 are pending confirmation.
    ///
    /// ⚠️ **The official implementation does not segment packets, but truncates** (new confirmation in this round).
    /// Dart side `WatchAudioService._truncateToMaxUtf8Bytes()` (blutter disassembly address
    /// `0x137d1c0`, call site `0x137c130`) behavior is:
    /// ```
    /// b = utf8.encode(text)
    /// if (b.length <= 230) return b
    /// // Otherwise backtrack from index 230 until (b[i] & 0xC0) != 0x80
    /// // (i.e., backtrack to the start byte of a UTF-8 character, never split a multibyte character)
    /// return Uint8List.sublistView(b, 0, i)
    /// ```
    /// In other words, **230 bytes** is the hard limit for the text payload; exceeding it will be silently truncated.
    /// The call site also has a rejection gate `> 0xFFFF(65535)` and the log string is
    /// `[WatchAudioService] [Meeting summary] total length {n} exceeds limit` (the method returns false).
    ///
    /// → Therefore this method **must not** give the caller the impression of "slice resume": overlong text should simply be truncated according to the official semantics.
    static func sendText(
        _ cmd: TicNoteCommand,
        id: UInt32,
        subID: UInt32,
        kind: UInt8 = 0,
        text: String,
        trailer: UInt8 = 0
    ) -> Data? {
        guard cmd == .sendTranscription || cmd == .sendMeetingSummary else { return nil }
        var p = Data()
        p.append(u32le(id)); p.append(u32le(subID)); p.append(kind)
        p.append(TicNoteTextPayload.truncateToMaxUTF8Bytes(text))
        p.append(trailer)
        return frame(cmd, payload: p)
    }

    /// 01 04 00 <u32 timestamp LE> <u8 timezone hour> -- **Time sync**.
    ///
    /// Real device example `01 04 00 45 3A C7 6A 08`: timestamp `0x6AC73A45` = 2026-10-08 14:37:57 +08,
    /// trailing byte `0x08`.
    ///
    /// ⚠️ The meaning of the trailing byte is **inferred**: the real device's phone was at UTC+8 that day, and the value is `8`,
    /// so the most natural explanation is "**whole hours relative to GMT**" (UTC+8 = 8).
    /// Reverse evidence: `-5` (New York) is written as `0xFB`, which falls within the same signed byte range, consistent.
    /// But this **has no second timezone sample**, so:
    ///   · Scenarios requiring precise time sync (relying on the card's RTC for timestamps) should capture once in each timezone;
    ///   · This function only frames according to **this assumption**; time sync failure must not block any main flow.
    static func syncTime(_ date: Date, timeZoneHours: Int? = nil) -> Data {
        let hours = timeZoneHours
            ?? (TimeZone.current.secondsFromGMT(for: date) / 3600)
        var p = Data()
        p.append(u32le(UInt32(bitPattern: Int32(date.timeIntervalSince1970))))
        p.append(UInt8(bitPattern: Int8(clamping: hours)))
        return frame(observed: .syncTime, payload: p)
    }

    /// 01 04 00 <u32 LE> -- Direct timestamp (for playback/testing).
    static func syncTime(timestamp: UInt32, timeZoneHours: Int8) -> Data {
        var p = Data()
        p.append(u32le(timestamp))
        p.append(UInt8(bitPattern: timeZoneHours))
        return frame(observed: .syncTime, payload: p)
    }

    // MARK: RecorderFrameCodec

    func encode(cmd: UInt8, payload: Data) -> Data? {
        guard let c = TicNoteCommand(rawValue: UInt16(cmd)) else { return nil }
        return Self.frame(c, payload: payload)
    }

    /// Parse a **complete** inbound frame.
    ///
    /// ⚠️ Precondition: `data` is already a complete frame. Because the frame **lacks a length field**,
    /// frame slicing must be handled by the upper layer (FIFO circular buffer); this method only performs structural validation.
    func decode(_ data: Data) -> RecorderFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return nil }          // Align with parse()'s `len < 3`.
        guard let type = TicNotePacketType(rawValue: bytes[0]) else { return nil }
        let cmd = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8) // Little-endian, align _readShort().
        return RecorderFrame(type: type.rawValue,
                             cmd: cmd,
                             length: nil,
                             payload: Data(bytes[3...]))
    }

    func encodeJSON(cmd: UInt8, _ object: [String: Any]) -> Data? {
        // TicNote's payload consists of binary little-endian fields, not JSON.
        // To send back "text", use `sendText(_:id:subID:kind:text:trailer:)`.
        return nil
    }

    // MARK: Structured parsing

    /// Parse **voice/recording data frames** → `TicNoteVoiceChunk`.
    ///
    /// ⚠️ Must pass the **original full frame**, not `RecorderFrame.payload`: in voice frames
    /// **there is no command code field**, `[1..2]` is the low 16 bits of `sessionId`.
    /// Thus for voice frames, the `cmd` extracted by `decode()` is meaningless (it is part of the sessionId) —
    /// This is why `parse()` uses `(data[1] | data[2] << 8) == 0x26` to distinguish
    /// "bookmark sync frames" from "voice data".
    ///
    /// Layout (confirmed byte-by-byte on real device in round 5):
    /// `[0x02][sessionId u32][offset u32][len u8][len byte data]`
    /// → Minimum length is **10**, not the earlier note's 9 (the length byte `[9]` was omitted then).
    static func voiceChunk(from raw: Data) -> TicNoteVoiceChunk? {
        let p = [UInt8](raw)
        guard p.count >= 10 else { return nil }
        guard p[0] == TicNotePacketType.voiceData.rawValue else { return nil }
        let sessionId = u32le(p, 1)
        let offset = u32le(p, 5)
        return TicNoteVoiceChunk(sessionId: sessionId,
                                 offset: offset,
                                 declaredLength: p[9],
                                 audio: Data(p.dropFirst(10)))
    }

    /// Parse **fragment request acknowledgment**: `01 1C 00 <sessionId u32> <status u8>` (**always 8 bytes**).
    ///
    /// ## Why this should be rescued from "ignore"
    /// The card **will** explicitly reject a fragment request. Real device sample
    /// (`captures/bleprobe-rec-2026-10-10.log`, probe sent `0x1C` with sid set to 0):
    /// ```
    /// → 01 1c 00 00 00 00 00 00 00 00 00 40 06 00 00 00
    /// ← 01 1c 00 00 00 00 00 02          ← Acknowledgment: sid=0, status=0x02
    /// ```
    /// When sid is correct (`captures/hci-all/bug2-20261008.att.txt` lines 14831/14837, official session
    /// `0x6AC738F1`) the response is `01 1c 00 f1 38 c7 6a 00` → **status `0x00`**,
    /// and immediately the card starts pushing `0x02` data frames.
    ///
    /// Thus `status != 0` is an **immediately actionable** failure signal. Previously it was in `TicNoteSession.ingest`
    /// fell into "other → ignore", so the card explicitly said "I don't recognize this session ID", and the app still had to wait for timeout based on size
    /// resulting in a 49‑minute recording becoming a **few‑minute** false wait,
    /// finally reporting "device did not respond in time". That is neither the real cause nor provides any next step.
    static func syncFileReceipt(from raw: Data) -> TicNoteSyncReceipt? {
        let p = [UInt8](raw)
        // ⚠️ Requires **exactly 8 bytes**, not "at least 8".
        //    Real device samples and official captures are 8; using `>= 8` would, if firmware later sends additional data on `0x1C`,
        //    `0x1C` sends extra content, the 7% byte would be misinterpreted as status, falsely reporting failure ——
        //    Better to not recognize (revert to "ignore", i.e., the pre‑change behavior) than to misjudge.
        guard p.count == 8 else { return nil }
        guard p[0] == TicNotePacketType.commandResponse.rawValue else { return nil }
        guard (UInt16(p[1]) | (UInt16(p[2]) << 8)) == TicNoteObservedCommand.syncFile.rawValue else {
            return nil
        }
        return TicNoteSyncReceipt(sessionId: u32le(p, 3), status: p[7])
    }

    /// Parse **card→App "this fragment finished" notification**: `01 1d 00 <sessionId u32> ff ff` (**always 9 bytes**).
    ///
    /// ## Why this one was pulled out of the "ignore" bucket (2026-10-12)
    /// It is not a preliminary handshake but a **byproduct of the chunk ring**: in the official capture, `0x1C` was requested 355 times,
    /// the card sent this `0x1D` **354 times** —— the same order of magnitude as "once per chunk" (`TicNoteObservedCommand.getSessionState`
    /// 's docs have a complete comparison). So it is the **secondary signal** for "end of the current chunk".
    ///
    /// Why a second channel is needed: the primary signal is `0x02` fragment end (`offset == 0xFFFFFFFF`, see
    /// `TicNoteVoiceChunk.isEnd`), it **arrives first**. However, losing a frame in real‑time streaming over BLE is normal ——
    /// In the real device session at `18:43:03`: the first 17 fragments were normal (27200 B all received), the 17th fragment's end was lost,
    /// the pump's `phase` stayed forever at `.awaitingChunk`,
    /// `nextRequest()` thereafter always returns `nil`, **no further fragment was requested for 20 seconds**, while the UI still showed "recording". This notification serves as a fallback for that situation.
    ///
    /// ⚠️ Ordering prerequisite — only when **confirmed to appear after the fragment end** can it be treated as "completion":
    /// Official per‑fragment order is `0x1C` request → `0x1C` acknowledgment → `0x02`×20 → `0x02` fragment end → **`0x1D`**.
    /// It has a fixed length of 9 bytes plus `ff ff` suffix double‑check; any mismatch returns nil (reverts to "ignore"),
    /// because a single sample cannot support the inference that "different lengths also mean completion".
    ///
    /// ⚠️ `0x1D` **outgoing direction** is the official `syncFileStop` prelude (2 bytes, no payload) —
    /// distinguished by `p.count == 9` and the `ff ff` suffix from the outgoing direction; do not merge the two into a single parser.
    static func chunkCompleteNotice(from raw: Data) -> UInt32? {
        let p = [UInt8](raw)
        guard p.count == 9 else { return nil }
        guard p[0] == TicNotePacketType.commandResponse.rawValue else { return nil }
        guard (UInt16(p[1]) | (UInt16(p[2]) << 8)) == TicNoteObservedCommand.getSessionState.rawValue
        else { return nil }
        guard p[7] == 0xFF, p[8] == 0xFF else { return nil }
        return u32le(p, 3)
    }

    /// Parse **0x26 bookmark sync frame**.
    ///
    /// Authoritative reference `parseBookmarkSyncResponse()`: verify `data[1] | data[2] << 8 == 0x26`,
    /// read header according to `data[3..6]` (u32 LE) / `data[7]` (status) / `data[8]` (count),
    /// and `count <= 0x64`, total length satisfies `>= 9 + count * 4`; then starting at 9, step by 4 to read u32.
    ///
    /// ⚠️ The name of the second u8 (`status`) comes from the key name in the official return map; early reading recorded it as
    /// `total` ("total entries"). The semantic difference does not affect parsing (both are "read one byte and skip"),
    /// but it affects how you use it — capture a real 0x26 frame once to determine.
    static func bookmarkFrame(from data: Data) -> TicNoteBookmarkFrame? {
        let b = [UInt8](data)
        guard b.count >= 9 else { return nil }
        guard (UInt16(b[1]) | (UInt16(b[2]) << 8)) == TicNoteInboundCommand.bookmarkSyncResponse.wireValue else {
            return nil
        }
        let sessionId = u32le(b, 3)
        let status = b[7]
        let count = b[8]
        guard count <= 0x64, b.count >= 9 + Int(count) * 4 else { return nil }

        var offsets: [UInt32] = []
        offsets.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            offsets.append(u32le(b, 9 + i * 4))
        }
        return TicNoteBookmarkFrame(sessionId: sessionId,
                                    status: status,
                                    count: count,
                                    offsetSecList: offsets)
    }

    // MARK: Utility

    /// Little-endian uint32. **Do not** use `withUnsafeBytes(of: x.littleEndian)` casually,
    /// explicit byte assembly is required to ensure byte‑by‑byte consistency with Dart's `_readInt()`.
    static func u32le(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF),
              UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF),
              UInt8((v >> 24) & 0xFF)])
    }

    private static func u32le(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
