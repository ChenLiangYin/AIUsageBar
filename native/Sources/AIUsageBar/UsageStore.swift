import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var refreshing: Bool = false

    private var refreshLoop: Task<Void, Never>?

    func start(refreshIntervalNanoseconds: UInt64 = 600_000_000_000) {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(allowingCredentialPrompts: false)
                try? await Task.sleep(nanoseconds: refreshIntervalNanoseconds)
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func refresh(allowingCredentialPrompts: Bool = true) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let snap = await UsageReader.snapshot(allowingCredentialPrompts: allowingCredentialPrompts)
        snapshot = snap
    }
}
