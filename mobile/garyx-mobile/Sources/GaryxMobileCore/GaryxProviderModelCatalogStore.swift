import Combine
import Foundation

public enum GaryxProviderModelCatalogRefreshOutcome: Equatable, Sendable {
    case updated
    case failed
    case superseded
}

/// Stale-while-refresh owner for provider model catalogs.
///
/// Existing snapshots remain readable while a refresh runs. Requests are
/// single-flight per provider, failures leave the last snapshot untouched, and
/// `reset()` fences every response from the previous gateway generation.
@MainActor
public final class GaryxProviderModelCatalogStore: ObservableObject {
    public typealias Loader = @MainActor () async throws -> GaryxProviderModels
    public typealias CommitGuard = @MainActor () -> Bool

    @Published public private(set) var modelsByProvider: [String: GaryxProviderModels] = [:]

    private enum FetchResult: Sendable {
        case success(GaryxProviderModels)
        case failure
    }

    private struct InFlight {
        var id: UInt64
        var epoch: UInt64
        var task: Task<FetchResult, Never>
    }

    private var epoch: UInt64 = 0
    private var nextRequestID: UInt64 = 1
    private var inFlightByProvider: [String: InFlight] = [:]
    private var latestRequestIDByProvider: [String: UInt64] = [:]
    private var committedRequestIDByProvider: [String: UInt64] = [:]

    public init() {}

    public func isRefreshing(providerType: String) -> Bool {
        let provider = Self.normalizedProviderType(providerType)
        return provider.map { inFlightByProvider[$0] != nil } ?? false
    }

    @discardableResult
    public func refresh(
        providerType: String,
        canCommit: @escaping CommitGuard = { true },
        load: @escaping Loader
    ) async -> GaryxProviderModelCatalogRefreshOutcome {
        guard let provider = Self.normalizedProviderType(providerType) else {
            return .superseded
        }

        let flight: InFlight
        if let existing = inFlightByProvider[provider], existing.epoch == epoch {
            flight = existing
        } else {
            let id = nextRequestID
            nextRequestID &+= 1
            let task = Task { @MainActor in
                do {
                    return FetchResult.success(try await load())
                } catch {
                    return FetchResult.failure
                }
            }
            flight = InFlight(id: id, epoch: epoch, task: task)
            inFlightByProvider[provider] = flight
            latestRequestIDByProvider[provider] = id
        }

        let result = await flight.task.value
        if inFlightByProvider[provider]?.id == flight.id {
            inFlightByProvider.removeValue(forKey: provider)
        }

        guard flight.epoch == epoch,
              latestRequestIDByProvider[provider] == flight.id else {
            return .superseded
        }

        switch result {
        case .failure:
            return .failed
        case .success(let models):
            if committedRequestIDByProvider[provider] == flight.id {
                return .updated
            }
            guard canCommit() else {
                return .superseded
            }
            modelsByProvider[provider] = models
            committedRequestIDByProvider[provider] = flight.id
            return .updated
        }
    }

    /// Starts a new gateway domain. Late completions are structurally unable to
    /// repopulate the cleared cache, even if their transport ignores cancellation.
    public func reset() {
        epoch &+= 1
        for flight in inFlightByProvider.values {
            flight.task.cancel()
        }
        inFlightByProvider.removeAll()
        latestRequestIDByProvider.removeAll()
        committedRequestIDByProvider.removeAll()
        modelsByProvider.removeAll()
    }

    private static func normalizedProviderType(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
