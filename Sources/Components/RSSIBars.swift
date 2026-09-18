import SwiftUI

/// 4-bar Wi-Fi-style indicator from an RSSI dBm value.
///   −30..−50 → 4 bars  (excellent)
///   −51..−65 → 3 bars  (good)
///   −66..−75 → 2 bars  (fair)
///   −76..−85 → 1 bar   (weak)
///   <−85     → 0 bars  (unusable)
struct RSSIBars: View {
    let rssi: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i < bars ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
        .accessibilityLabel("Signal strength: \(bars) of 4")
    }

    private var bars: Int {
        switch rssi {
        case ...(-86): return 0
        case -85 ... -76: return 1
        case -75 ... -66: return 2
        case -65 ... -51: return 3
        default: return 4
        }
    }
}
