import SwiftUI

/// ★ 2026-10-29（饭耳移植 · 规格 #10 隐私话术系统化）
///
/// One source of truth for the "数据去哪了" sentences, reused across the pages
/// where a user might reasonably ask. Before this the privacy wording lived in
/// scattered hand-written footers; the spec asks for it to be **systematic** —
/// same claims, same tone, everywhere.
///
/// Rule for what a page may claim (from the codebase's actual behaviour, not
/// marketing): audio + transcripts live only on-device (`StorageLocations`,
/// app group); cloud flows are user-configured opt-ins (ASR/LLM providers);
/// backup destinations are the user's own server/folder. Never promise
/// "end-to-end encryption" — the local layer is ChaCha20-encrypted at rest
/// (see the passphrase flow), which is what `storageNote` may say.
struct PrivacyNote: View {
    enum Flavor {
        /// Where recordings and transcripts live.
        case storage
        /// Cloud ASR/LLM — what leaves the device and when.
        case cloud
        /// Backup/export destinations.
        case backup

        var text: String {
            switch self {
            case .storage: return L10n.Privacy.storageNote
            case .cloud: return L10n.Privacy.cloudNote
            case .backup: return L10n.Privacy.backupNote
            }
        }
    }

    let flavor: Flavor

    var body: some View {
        Label {
            Text(flavor.text)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
