import SwiftUI
import WidgetKit

@MainActor final class AppModel: ObservableObject {
    @Published var destination = SharedStore().destination
    @Published var summary = SharedStore().summary
    @Published var isLoading = false
    @Published var message: String?
    @Published var needsPermission = false
    @Published var loadingMessage = "経路を更新中"
    @Published var loadingStep = 0
    @Published var isLoadingLastTrain = false
    private let location = LocationProvider()
    private let router = StationRouter(api: TransitAPI(), walking: MapWalkingProvider())
    private var generation = UUID()
    private var activeRefreshID = UUID()
    private var lastTrainTask: Task<Void, Never>?

    func save(_ value: Destination) {
        do {
            try SharedStore().save(destination: value)
            generation = UUID()
            activeRefreshID = UUID()
            lastTrainTask?.cancel()
            destination = value
            summary = SharedStore().summary
            message = nil
            isLoadingLastTrain = false
            WidgetCenter.shared.reloadAllTimelines()
            WatchSync.shared.publish()
            // An in-flight request sees a different generation and refreshes the new destination.
            Task { await refresh() }
        } catch { message = "目的地を保存できませんでした。" }
    }

    func refresh() async {
        guard !isLoading, let destination else { return }
        let destinationGeneration = generation
        let requestID = UUID()
        activeRefreshID = requestID
        lastTrainTask?.cancel()
        isLoadingLastTrain = false
        isLoading = true
        message = nil
        needsPermission = false
        loadingMessage = "現在地を取得中"
        loadingStep = 0
        defer {
            isLoading = false
            if generation != destinationGeneration { Task { await refresh() } }
        }
        do {
            let origin = try await location.locate(fallback: summary?.origin)
            guard origin.isWithinJapanSearchBounds, destination.coordinate.isWithinJapanSearchBounds else {
                throw TransitError.outsideServiceArea
            }
            let now = Date()
            let savedLastTrain = reusableLastTrain(origin: origin, destination: destination, now: now)
            loadingMessage = "駅と徒歩ルートを確認中"
            loadingStep = 1
            let context = await router.prepare(origin: origin, destination: destination.coordinate)
            guard requestID == activeRefreshID, destinationGeneration == generation else { return }
            loadingMessage = "経路を検索中"
            loadingStep = 2
            let normal = await result {
                try await self.planWithRetry(
                    origin: origin, destination: destination.coordinate, context: context, now: now, last: false)
            }
            guard requestID == activeRefreshID, destinationGeneration == generation else { return }
            loadingStep = 3
            var fresh: RouteSummary?
            switch normal {
            case .success(let trips):
                let fetchedAt = Date()
                let selected = RouteParser.recommended(trips, now: fetchedAt)
                fresh = RouteSummary(
                    destination: destination, origin: origin, trip: selected, upcomingTrips: selected == nil ? nil : trips,
                    lastTrain: savedLastTrain,
                    lastTrainStatus: savedLastTrain.map { $0.leaveBy < fetchedAt ? .ended : .available } ?? .unavailable,
                    fetchedAt: fetchedAt)
                if fresh?.trip == nil { message = TransitError.noRoute.localizedDescription }
            case .failure(let error): message = summary?.trip(at: Date()) == nil ? error.localizedDescription : nil
            }
            guard let fresh else { return }
            // The normal route is the time-critical result. Publish it as soon as
            // the three main stages finish, then resolve the last train separately.
            try publish(fresh)
            guard savedLastTrain == nil, fresh.trip(at: now) != nil else { return }
            startLastTrainSearch(
                origin: origin, destination: destination, context: context, now: now, requestID: requestID,
                destinationGeneration: destinationGeneration)
        } catch {
            guard requestID == activeRefreshID, destinationGeneration == generation else { return }
            needsPermission = (error as? LocationProvider.Failure) == .denied
            message = summary?.trip(at: Date()) == nil ? error.localizedDescription : nil
            #if targetEnvironment(simulator)
                if case TransitError.outsideServiceArea = error {
                    message =
                        error.localizedDescription
                        + "\nSimulatorの Features → Location → Custom Location で、日本国内の現在地を設定してください。東京駅: 緯度35.681、経度139.767。"
                }
            #endif
        }
    }

    private func startLastTrainSearch(
        origin: Coordinate, destination: Destination, context: StationSearchContext?, now: Date, requestID: UUID,
        destinationGeneration: UUID
    ) {
        isLoadingLastTrain = true
        lastTrainTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.result {
                try await self.router.plan(
                    origin: origin, destination: destination.coordinate, context: context, now: now, last: true)
            }
            guard !Task.isCancelled, requestID == self.activeRefreshID, destinationGeneration == self.generation else { return }
            defer { self.isLoadingLastTrain = false }
            guard var current = self.summary, current.destination.id == destination.id, current.origin.distance(to: origin) <= 150
            else { return }
            switch result {
            case .success(let results):
                if let final = RouteParser.lastTrain(in: results, serviceDate: now) {
                    current.lastTrain = final
                    current.lastTrainStatus = final.leaveBy < Date() ? .ended : .available
                } else {
                    current.lastTrain = nil
                    current.lastTrainStatus = .ended
                }
            case .failure:
                current.lastTrain = nil
                current.lastTrainStatus = .unavailable
            }
            try? self.publish(current)
        }
    }
    private func publish(_ value: RouteSummary) throws {
        try SharedStore().save(summary: value)
        summary = value
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.publish()
    }
    private func reusableLastTrain(origin: Coordinate, destination: Destination, now: Date) -> Trip? {
        guard let summary, summary.destination.coordinate == destination.coordinate, summary.origin.distance(to: origin) <= 150,
            ServiceClock.calendar.isDate(summary.fetchedAt, inSameDayAs: now), let lastTrain = summary.usableLastTrain()
        else { return nil }
        return lastTrain
    }
    private func planWithRetry(origin: Coordinate, destination: Coordinate, context: StationSearchContext?, now: Date, last: Bool)
        async throws -> [Trip]
    {
        do {
            return try await router.plan(origin: origin, destination: destination, context: context, now: now, last: last)
        } catch let error as TransitError {
            guard case .timedOut = error else { throw error }
            try await Task.sleep(for: .milliseconds(250))
            return try await router.plan(origin: origin, destination: destination, context: context, now: now, last: last)
        }
    }
    private func result<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}
