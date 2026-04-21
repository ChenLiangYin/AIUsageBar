import Foundation

struct UsageBar: Equatable {
    let label: String
    // When percent is provided, it is the authoritative display value on the
    // 0–100 scale (matches the API's `utilization` field). used/limit are kept
    // for the offline fallback path that still shows raw token counts.
    let percent: Double?
    let used: Double
    let limit: Double?
    let unit: String
    let resetsAt: Date?
}

enum ProviderStatus: String, Equatable {
    case ok
    case error
    case unavailable
}

struct ProviderUsage: Equatable {
    enum ID: String { case claude, codex }
    let id: ID
    let name: String
    let status: ProviderStatus
    let message: String?
    let bars: [UsageBar]
    let meta: [(String, String)]

    static func == (lhs: ProviderUsage, rhs: ProviderUsage) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.status == rhs.status
            && lhs.message == rhs.message && lhs.bars == rhs.bars
            && lhs.meta.map { $0.0 + "=" + $0.1 } == rhs.meta.map { $0.0 + "=" + $0.1 }
    }
}

struct UsageSnapshot: Equatable {
    let fetchedAt: Date
    let providers: [ProviderUsage]
}
