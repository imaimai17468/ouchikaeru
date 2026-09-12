import Foundation

public struct WallClock: Sendable {
    private let currentDate: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) { currentDate = now }

    public func now() -> Date { currentDate() }

    public static let system = WallClock { Date() }
}

public struct CurrentRoutePlan: Sendable {
    public let summary: RouteSummary
    public let context: StationSearchContext?
    public let needsLastTrain: Bool
}

/// Coordinates the route rules shared by the iPhone and Apple Watch clients.
public actor RoutePlanner {
    private let router: StationRouter
    private let clock: WallClock

    public init(api: any StationRoutingAPI, walking: any WalkingProviding, clock: WallClock = .system) {
        router = StationRouter(api: api, walking: walking, clock: clock)
        self.clock = clock
    }

    public func prepare(origin: Coordinate, destination: Coordinate) async -> StationSearchContext? {
        await router.prepare(origin: origin, destination: destination)
    }

    public func currentRoute(
        origin: Coordinate, destination: Destination, context: StationSearchContext?, previous: RouteSummary?, now: Date
    ) async throws -> CurrentRoutePlan {
        let retainedLastTrain = reusableLastTrain(in: previous, origin: origin, destination: destination, now: now)
        let trips = try await planWithRetry(
            origin: origin, destination: destination.coordinate, context: context, now: now, last: false)
        let fetchedAt = clock.now()
        let selected = RouteParser.recommended(trips, now: fetchedAt)
        let summary = RouteSummary(
            destination: destination, origin: origin, trip: selected, upcomingTrips: selected == nil ? nil : trips,
            lastTrain: retainedLastTrain,
            lastTrainStatus: retainedLastTrain.map { $0.leaveBy < fetchedAt ? .ended : .available } ?? .unavailable,
            fetchedAt: fetchedAt)
        return CurrentRoutePlan(summary: summary, context: context, needsLastTrain: retainedLastTrain == nil && selected != nil)
    }

    public func addingLastTrain(to summary: RouteSummary, context: StationSearchContext?, now: Date) async -> RouteSummary {
        var updated = summary
        do {
            let results = try await router.plan(
                origin: summary.origin, destination: summary.destination.coordinate, context: context, now: now, last: true)
            if let final = RouteParser.lastTrain(in: results, serviceDate: now) {
                updated.lastTrain = final
                updated.lastTrainStatus = final.leaveBy < clock.now() ? .ended : .available
            } else {
                updated.lastTrain = nil
                updated.lastTrainStatus = .ended
            }
        } catch {
            updated.lastTrain = nil
            updated.lastTrainStatus = .unavailable
        }
        return updated
    }

    private func reusableLastTrain(in summary: RouteSummary?, origin: Coordinate, destination: Destination, now: Date) -> Trip? {
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
}
