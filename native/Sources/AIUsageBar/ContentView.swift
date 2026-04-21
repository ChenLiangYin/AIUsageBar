import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            ScrollView {
                VStack(spacing: 8) {
                    if let snap = store.snapshot {
                        ForEach(snap.providers, id: \.id.rawValue) { provider in
                            ProviderCard(provider: provider)
                        }
                        HStack {
                            Spacer()
                            Text("Updated \(formatTime(snap.fetchedAt))")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.3))
                            Spacer()
                        }
                        .padding(.top, 2)
                    } else {
                        HStack {
                            Spacer()
                            Text("Loading usage…")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                        }
                        .frame(height: 120)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 360, height: 500)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .foregroundColor(.white)
    }
}

private struct TitleBar: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.55, blue: 0.3).opacity(0.8),
                            Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.8),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 18, height: 18)
                Text("AIUsageBar")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(store.refreshing ? 0.5 : 1)
            Button {
                // Close the popover (not quit). To quit, right-click the
                // menu-bar icon → Quit AIUsageBar.
                for window in NSApp.windows where window.className.contains("Popover") {
                    window.orderOut(nil)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close popup — right-click menu bar icon to quit")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct ProviderCard: View {
    let provider: ProviderUsage

    private var accent: Color {
        provider.id == .claude
            ? Color(red: 0.98, green: 0.55, blue: 0.3)
            : Color(red: 0.4, green: 0.7, blue: 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(provider.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                StatusChip(status: provider.status)
            }
            .padding(.bottom, 10)

            if provider.status == .ok {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(provider.bars, id: \.label) { bar in
                        BarView(bar: bar, accent: accent)
                    }
                    if !provider.meta.isEmpty {
                        MetaRow(meta: provider.meta)
                            .padding(.top, 6)
                    }
                    if let msg = provider.message {
                        Text(msg)
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(2)
                    }
                }
            } else {
                Text(provider.message ?? "No data.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(accent.opacity(0.4), lineWidth: 1)
                )
        )
    }
}

private struct StatusChip: View {
    let status: ProviderStatus

    var body: some View {
        let (bg, fg, label): (Color, Color, String) = {
            switch status {
            case .ok:
                return (Color.green.opacity(0.15), Color(red: 0.5, green: 0.9, blue: 0.6), "live")
            case .error:
                return (Color.red.opacity(0.15), Color(red: 0.95, green: 0.5, blue: 0.5), "error")
            case .unavailable:
                return (Color.white.opacity(0.1), Color.white.opacity(0.5), "offline")
            }
        }()
        return Text(label.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .foregroundColor(fg)
    }
}

private struct BarView: View {
    let bar: UsageBar
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.label)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                if let reset = bar.resetsAt {
                    Text("· resets \(formatReset(reset))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                Spacer()
                Text(displayValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * widthFraction)
                }
            }
            .frame(height: 6)
        }
    }

    private var displayValue: String {
        if let p = bar.percent {
            // Percent is on a 0–100 scale and may slightly exceed 100 during
            // grace windows, so clamp for display but keep sign honest.
            let shown = max(0, min(100, p))
            return shown == floor(shown)
                ? String(format: "%.0f%%", shown)
                : String(format: "%.1f%%", shown)
        }
        return formatUsed(bar.used, unit: bar.unit)
    }

    private var widthFraction: CGFloat {
        if let p = bar.percent {
            return max(0.02, min(1, CGFloat(p / 100)))
        }
        if let limit = bar.limit, limit > 0 {
            return min(1, CGFloat(bar.used / limit))
        }
        let n = max(0, bar.used)
        let logged = log10(n + 1) * 22 / 100
        return max(0.04, min(1, CGFloat(logged)))
    }

    // Tint the bar red/yellow/accent based on % used when that signal exists.
    private var barColor: Color {
        guard let p = bar.percent else { return accent }
        if p >= 90 { return Color(red: 0.95, green: 0.4, blue: 0.45) }
        if p >= 70 { return Color(red: 0.98, green: 0.75, blue: 0.25) }
        return accent
    }
}

private func formatReset(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds < 60 { return "now" }
    if seconds < 60 * 60 {
        let m = seconds / 60
        return "in \(m)m"
    }
    if seconds < 24 * 60 * 60 {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
    }
    let d = seconds / 86400
    let h = (seconds % 86400) / 3600
    return h == 0 ? "in \(d)d" : "in \(d)d \(h)h"
}

private struct MetaRow: View {
    let meta: [(String, String)]

    var body: some View {
        FlowLayout(spacing: 10) {
            ForEach(0..<meta.count, id: \.self) { idx in
                let entry = meta[idx]
                HStack(spacing: 4) {
                    Text(entry.0)
                        .foregroundColor(.white.opacity(0.4))
                    Text(entry.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
                .font(.system(size: 11))
            }
        }
        .padding(.top, 6)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)
                .padding(.top, -1),
            alignment: .top
        )
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                totalHeight += rowHeight + 4
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + 4
                x = bounds.minX
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private func formatUsed(_ n: Double, unit: String) -> String {
    if unit == "tokens" {
        if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
        return String(format: "%.0f", n)
    }
    if unit == "sessions" { return String(format: "%.0f", n) }
    return "\(Int(n)) \(unit)"
}

private func formatTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}
