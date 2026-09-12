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
    private let planner = RoutePlanner(api: TransitAPI(), walking: MapWalkingProvider())
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
            loadingMessage = "駅と徒歩ルートを確認中"
            loadingStep = 1
            let context = await planner.prepare(origin: origin, destination: destination.coordinate)
            guard requestID == activeRefreshID, destinationGeneration == generation else { return }
            loadingMessage = "経路を検索中"
            loadingStep = 2
            let normal = await result {
                try await self.planner.currentRoute(
                    origin: origin, destination: destination, context: context, previous: self.summary, now: now)
            }
            guard requestID == activeRefreshID, destinationGeneration == generation else { return }
            loadingStep = 3
            var plan: CurrentRoutePlan?
            switch normal {
            case .success(let value):
                plan = value
                if value.summary.trip == nil { message = TransitError.noRoute.localizedDescription }
            case .failure(let error): message = summary?.trip(at: Date()) == nil ? error.localizedDescription : nil
            }
            guard let plan else { return }
            // The normal route is the time-critical result. Publish it as soon as
            // the three main stages finish, then resolve the last train separately.
            try publish(plan.summary)
            guard plan.needsLastTrain else { return }
            startLastTrainSearch(
                summary: plan.summary, context: plan.context, now: now, requestID: requestID,
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
        summary: RouteSummary, context: StationSearchContext?, now: Date, requestID: UUID, destinationGeneration: UUID
    ) {
        isLoadingLastTrain = true
        lastTrainTask = Task { [weak self] in
            guard let self else { return }
            let updated = await self.planner.addingLastTrain(to: summary, context: context, now: now)
            guard !Task.isCancelled, requestID == self.activeRefreshID, destinationGeneration == self.generation else { return }
            defer { self.isLoadingLastTrain = false }
            guard let current = self.summary, current.destination.id == updated.destination.id,
                current.origin.distance(to: updated.origin) <= 150
            else { return }
            try? self.publish(updated)
        }
    }
    private func publish(_ value: RouteSummary) throws {
        try SharedStore().save(summary: value)
        summary = value
        WidgetCenter.shared.reloadAllTimelines()
        WatchSync.shared.publish()
    }
    private func result<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}
