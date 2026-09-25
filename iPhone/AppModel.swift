import SwiftUI
import WidgetKit

private enum AppRouteLoadingPhase: Equatable {
    case locating
    case preparing
    case searching

    var message: String {
        switch self {
        case .locating: return "現在地を取得中"
        case .preparing: return "駅と徒歩ルートを確認中"
        case .searching: return "経路を検索中"
        }
    }

    var completedSteps: Int {
        switch self {
        case .locating: return 0
        case .preparing: return 1
        case .searching: return 2
        }
    }
}

private enum AppRouteState: Equatable {
    case loading(previous: RouteSummary?, phase: AppRouteLoadingPhase)
    case available(RouteSummary, isLoadingLastTrain: Bool)
    case unavailable(summary: RouteSummary?, message: String?, isLoadingLastTrain: Bool)
    case failure(previous: RouteSummary?, message: String, needsPermission: Bool)

    var summary: RouteSummary? {
        switch self {
        case .loading(let previous, _), .failure(let previous, _, _): return previous
        case .available(let summary, _): return summary
        case .unavailable(let summary, _, _): return summary
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var destination: Destination?
    @Published private var routeState: AppRouteState

    var summary: RouteSummary? { routeState.summary }
    var isLoading: Bool {
        if case .loading = routeState { return true }
        return false
    }
    var message: String? {
        switch routeState {
        case .unavailable(_, let message, _): return message
        case .failure(_, let message, _): return message
        case .loading, .available: return nil
        }
    }
    var needsPermission: Bool {
        if case .failure(_, _, let needsPermission) = routeState { return needsPermission }
        return false
    }
    var loadingMessage: String {
        if case .loading(_, let phase) = routeState { return phase.message }
        return "経路を更新中"
    }
    var loadingStep: Int {
        if case .loading(_, let phase) = routeState { return phase.completedSteps }
        return 0
    }
    var isLoadingLastTrain: Bool {
        switch routeState {
        case .available(_, let isLoading), .unavailable(_, _, let isLoading): return isLoading
        case .loading, .failure: return false
        }
    }

    private let location: any DeviceLocationProviding
    private let planner: any RoutePlanning
    private let store: any RouteSnapshotStoring
    private let clock: WallClock
    private let notifySharedDataChanged: @MainActor () -> Void
    private var generation = UUID()
    private var activeRefreshID = UUID()
    private var lastTrainTask: Task<Void, Never>?

    convenience init() {
        self.init(
            location: LocationProvider(),
            planner: RoutePlanner(api: TransitAPI(), walking: MapWalkingProvider(), stationDiscovery: MapStationProvider()),
            store: SharedStore(), clock: .system
        ) {
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.publish()
        }
    }

    init(
        location: any DeviceLocationProviding, planner: any RoutePlanning, store: any RouteSnapshotStoring, clock: WallClock,
        notifySharedDataChanged: @escaping @MainActor () -> Void
    ) {
        self.location = location
        self.planner = planner
        self.store = store
        self.clock = clock
        self.notifySharedDataChanged = notifySharedDataChanged
        destination = store.destination
        routeState = Self.restingState(summary: store.summary, at: clock.now())
    }

    func save(_ value: Destination) {
        do {
            try store.save(destination: value)
            generation = UUID()
            activeRefreshID = UUID()
            lastTrainTask?.cancel()
            destination = value
            routeState = Self.restingState(summary: store.summary, at: clock.now())
            notifySharedDataChanged()
            // An in-flight request sees a different generation and refreshes the new destination.
            Task { await refresh() }
        } catch { routeState = .failure(previous: summary, message: "目的地を保存できませんでした。", needsPermission: false) }
    }

    func refresh() async {
        guard !isLoading, let destination else { return }
        let previous = summary
        let destinationGeneration = generation
        let requestID = UUID()
        activeRefreshID = requestID
        lastTrainTask?.cancel()
        routeState = .loading(previous: previous, phase: .locating)
        defer { if generation != destinationGeneration { Task { await refresh() } } }
        do {
            let origin = try await location.locate(fallback: previous?.origin)
            guard origin.isWithinJapanSearchBounds, destination.coordinate.isWithinJapanSearchBounds else {
                throw TransitError.outsideServiceArea
            }
            let now = clock.now()
            routeState = .loading(previous: previous, phase: .preparing)
            let context = await planner.prepare(origin: origin, destination: destination.coordinate)
            guard accepts(requestID, generation: destinationGeneration) else { return }
            routeState = .loading(previous: previous, phase: .searching)
            let normal = await result {
                try await self.planner.currentRoute(
                    origin: origin, destination: destination, context: context, previous: previous, now: now)
            }
            guard accepts(requestID, generation: destinationGeneration) else { return }
            switch normal {
            case .success(let plan):
                try persist(plan.summary)
                routeState = Self.loadedState(summary: plan.summary, isLoadingLastTrain: plan.needsLastTrain, at: clock.now())
                guard plan.needsLastTrain else { return }
                startLastTrainSearch(
                    summary: plan.summary, context: plan.context, now: now, requestID: requestID,
                    destinationGeneration: destinationGeneration)
            case .failure(let error): setFailure(error, previous: previous)
            }
        } catch {
            guard accepts(requestID, generation: destinationGeneration) else { return }
            setFailure(error, previous: previous)
        }
    }

    private func startLastTrainSearch(
        summary: RouteSummary, context: StationSearchContext?, now: Date, requestID: UUID, destinationGeneration: UUID
    ) {
        lastTrainTask = Task { [weak self] in
            guard let self else { return }
            let updated = await self.planner.addingLastTrain(to: summary, context: context, now: now)
            guard !Task.isCancelled, self.accepts(requestID, generation: destinationGeneration) else { return }
            guard let current = self.summary, current.destination.id == updated.destination.id,
                current.origin.distance(to: updated.origin) <= 150
            else { return }
            do {
                try self.persist(updated)
                self.routeState = Self.loadedState(summary: updated, isLoadingLastTrain: false, at: self.clock.now())
            } catch { self.routeState = Self.loadedState(summary: current, isLoadingLastTrain: false, at: self.clock.now()) }
        }
    }

    private func persist(_ value: RouteSummary) throws {
        try store.save(summary: value)
        notifySharedDataChanged()
    }

    private func setFailure(_ error: Error, previous: RouteSummary?) {
        if let previous, previous.trip(at: clock.now()) != nil {
            routeState = .available(previous, isLoadingLastTrain: false)
            return
        }
        var message = error.localizedDescription
        #if targetEnvironment(simulator)
            if case TransitError.outsideServiceArea = error {
                message += "\nSimulatorの Features → Location → Custom Location で、日本国内の現在地を設定してください。東京駅: 緯度35.681、経度139.767。"
            }
        #endif
        routeState = .failure(
            previous: previous, message: message, needsPermission: (error as? LocationProvider.Failure) == .denied)
    }

    private func accepts(_ requestID: UUID, generation expectedGeneration: UUID) -> Bool {
        requestID == activeRefreshID && expectedGeneration == generation
    }

    private static func restingState(summary: RouteSummary?, at now: Date) -> AppRouteState {
        guard let summary else { return .unavailable(summary: nil, message: nil, isLoadingLastTrain: false) }
        guard summary.trip(at: now) != nil else { return .unavailable(summary: summary, message: nil, isLoadingLastTrain: false) }
        return .available(summary, isLoadingLastTrain: false)
    }

    private static func loadedState(summary: RouteSummary, isLoadingLastTrain: Bool, at now: Date) -> AppRouteState {
        if summary.isAtDestination { return .available(summary, isLoadingLastTrain: false) }
        guard summary.trip(at: now) != nil else {
            return .unavailable(
                summary: summary, message: TransitError.noRoute.localizedDescription, isLoadingLastTrain: isLoadingLastTrain)
        }
        return .available(summary, isLoadingLastTrain: isLoadingLastTrain)
    }

    private func result<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}
