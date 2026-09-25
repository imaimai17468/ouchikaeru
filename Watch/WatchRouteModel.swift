import Combine
import Foundation

@MainActor final class WatchRouteModel: ObservableObject {
    @Published private(set) var state: RouteLoadState

    private let location: any DeviceLocationProviding
    private let planner: any RoutePlanning
    private let store: any RouteSnapshotStoring
    private let connectivity: any WatchContextCommunicating
    private let clock: WallClock
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var lastAutomaticRefreshRequest: Date?

    convenience init() {
        self.init(
            location: LocationProvider(),
            planner: RoutePlanner(api: TransitAPI(), walking: MapWalkingProvider(), stationDiscovery: MapStationProvider()),
            store: SharedStore(), connectivity: WatchSync.shared, clock: .system)
    }

    init(
        location: any DeviceLocationProviding, planner: any RoutePlanning, store: any RouteSnapshotStoring,
        connectivity: any WatchContextCommunicating, clock: WallClock
    ) {
        self.location = location
        self.planner = planner
        self.store = store
        self.connectivity = connectivity
        self.clock = clock
        if let summary = store.summary {
            state = Self.state(for: summary, at: clock.now())
        } else {
            state = .unavailable(previous: nil, message: "iPhoneで目的地を設定してください。")
        }
        connectivity.contextHandler = { [weak self] payload in self?.receive(payload) }
    }

    func refreshIfNeeded(at date: Date? = nil) {
        let now = date ?? clock.now()
        guard !state.isLoading, state.summary?.needsRefresh(at: now) != false else { return }
        requestAutomaticRefresh(at: now)
    }

    func refreshOnActivation(at date: Date? = nil) {
        guard !state.isLoading else { return }
        requestAutomaticRefresh(at: date ?? clock.now())
    }

    private func requestAutomaticRefresh(at now: Date) {
        if let lastAutomaticRefreshRequest, now.timeIntervalSince(lastAutomaticRefreshRequest) < 60 { return }
        lastAutomaticRefreshRequest = now
        refresh()
    }

    func refresh() {
        let previous = state.summary
        guard let destination = store.destination ?? previous?.destination else {
            let request = connectivity.requestCompanionRefresh()
            switch request {
            case .sent: state = .unavailable(previous: previous, message: "iPhoneから目的地を取得しています。")
            case .queued: state = .unavailable(previous: previous, message: "iPhoneへ目的地の更新を依頼しました。")
            case .unavailable: state = .failure(previous: previous, message: "iPhoneとの接続を準備できませんでした。")
            }
            return
        }
        refreshID = UUID()
        let requestID = refreshID
        refreshTask?.cancel()
        state = .loading(previous: previous, phase: .locating)
        refreshTask = Task { [weak self] in await self?.loadRoute(to: destination, requestID: requestID) }
    }

    private func loadRoute(to destination: Destination, requestID: UUID) async {
        do {
            let previous = state.summary
            let origin = try await location.locate(fallback: previous?.origin)
            guard accepts(requestID) else { return }
            state = .loading(previous: previous, phase: .preparing)
            let context = await planner.prepare(origin: origin, destination: destination.coordinate)
            guard accepts(requestID) else { return }
            state = .loading(previous: previous, phase: .searching)
            let now = clock.now()
            let plan = try await planner.currentRoute(
                origin: origin, destination: destination, context: context, previous: previous, now: now)
            guard accepts(requestID) else { return }
            try store.save(summary: plan.summary)
            state = Self.state(for: plan.summary, at: clock.now())
            guard plan.needsLastTrain else { return }
            state = .loading(previous: plan.summary, phase: .lastTrain)
            let completed = await planner.addingLastTrain(to: plan.summary, context: plan.context, now: now)
            guard accepts(requestID) else { return }
            try store.save(summary: completed)
            state = Self.state(for: completed, at: clock.now())
        } catch {
            guard accepts(requestID) else { return }
            state = .failure(previous: state.summary, message: error.localizedDescription)
        }
    }

    private func receive(_ payload: WatchContextPayload) {
        do {
            let destinationChanged = payload.destination != store.destination
            if destinationChanged {
                refreshID = UUID()
                refreshTask?.cancel()
            }
            try store.save(destination: payload.destination)
            guard let incoming = payload.summary else {
                state = .unavailable(previous: nil, message: "iPhoneで目的地を設定してください。")
                return
            }
            if let current = state.summary, current.destination.id == incoming.destination.id,
                current.fetchedAt > incoming.fetchedAt
            {
                return
            }
            try store.save(summary: incoming)
            state = Self.state(for: incoming, at: clock.now())
        } catch { state = .failure(previous: state.summary, message: "同期情報を保存できませんでした。") }
    }

    private func accepts(_ requestID: UUID) -> Bool { !Task.isCancelled && requestID == refreshID }

    private static func state(for summary: RouteSummary, at now: Date) -> RouteLoadState {
        if summary.isAtDestination { return .available(summary) }
        if summary.trip(at: now) == nil { return .unavailable(previous: summary, message: "利用できる経路がありません。") }
        return .available(summary)
    }
}
