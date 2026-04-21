import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var refreshing: Bool = false

    private var refreshLoop: Task<Void, Never>?

    func start() {
        guard refreshLoop == nil else { return }
        // 90s keeps us well under any sane rate limit while still feeling live.
        let interval: UInt64 = 90_000_000_000
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func refresh() async {
        refreshing = true
        let snap = await UsageReader.snapshot()
        snapshot = snap
        refreshing = false
    }
}
