import XCTest

@testable import TransitCore

final class StationRouterTests: XCTestCase {
    private let origin = Coordinate(latitude: 35, longitude: 139)
    private let destination = Coordinate(latitude: 36, longitude: 140)

    func testStationSearchIncludesWalkAndComparesMultipleFeedIDs() async throws {
        let api = StationAPIStub(), walks = WalkingStub()
        let router = StationRouter(api: api, walking: walks)
        let context = await router.prepare(origin: origin, destination: destination)
        XCTAssertEqual(context?.departures.count, 2)
        let start = Date()
        let trips = try await router.plan(origin: origin, destination: destination, context: context, now: start, last: false)
        let calls = await api.requests
        XCTAssertEqual(Set(calls.map(\.from)), ["feed:a", "feed:b"])
        XCTAssertTrue(calls.allSatisfy { $0.boardingAfter.timeIntervalSince(start) >= 180 })
        XCTAssertEqual(trips.count, 2)
        XCTAssertTrue(trips.allSatisfy { $0.walkToStationMinutes == 3 && $0.walkToDestinationMinutes == 2 })
        let fallback = await api.fallbackCount
        XCTAssertEqual(fallback, 0)
        let best = try XCTUnwrap(RouteParser.recommended(trips, now: start))
        XCTAssertEqual(best.lineName, "feed:b")
    }

    func testWalkingCacheToleratesGPSDriftButRecalculatesAfterMovement() async throws {
        let api = StationAPIStub(), walks = WalkingStub()
        let router = StationRouter(api: api, walking: walks)
        _ = await router.prepare(origin: origin, destination: destination)
        _ = await router.prepare(origin: origin, destination: destination)
        let firstCount = await walks.count
        let firstDiscoveries = await api.discoveryCount
        XCTAssertEqual(firstCount, 2)  // Two departure feed IDs share the same physical coordinate.
        XCTAssertEqual(firstDiscoveries, 2)
        _ = await router.prepare(origin: .init(latitude: 35.0001, longitude: 139), destination: destination)
        let nextWalks = await walks.count
        let nextDiscoveries = await api.discoveryCount
        XCTAssertEqual(nextWalks, 2)
        XCTAssertEqual(nextDiscoveries, 2)
        _ = await router.prepare(origin: .init(latitude: 35.0006, longitude: 139), destination: destination)
        let movedWalks = await walks.count
        let reusedDiscoveries = await api.discoveryCount
        XCTAssertEqual(movedWalks, 3)
        XCTAssertEqual(reusedDiscoveries, 2)
        _ = await router.prepare(origin: .init(latitude: 35.01, longitude: 139), destination: destination)
        let movedDiscoveries = await api.discoveryCount
        XCTAssertEqual(movedDiscoveries, 3)
    }

    func testMissingStationsUsesCoordinateFallback() async throws {
        let api = StationAPIStub(emptyStations: true)
        let router = StationRouter(api: api, walking: WalkingStub())
        let context = await router.prepare(origin: origin, destination: destination)
        XCTAssertNil(context)
        let trips = try await router.plan(origin: origin, destination: destination, context: context, now: Date(), last: false)
        XCTAssertEqual(trips.count, 1)
        let count = await api.fallbackCount
        XCTAssertEqual(count, 1)
    }

    func testLastTrainCacheExpiresAndDoesNotCrossServiceDate() async throws {
        let api = StationAPIStub(emptyStations: true)
        let router = StationRouter(api: api, walking: WalkingStub())
        let now = Date()
        _ = try await router.plan(origin: origin, destination: destination, context: nil, now: now, last: true)
        _ = try await router.plan(
            origin: origin, destination: destination, context: nil, now: now.addingTimeInterval(60), last: true)
        let reused = await api.fallbackCount
        XCTAssertEqual(reused, 1)
        _ = try await router.plan(
            origin: origin, destination: destination, context: nil, now: now.addingTimeInterval(601), last: true)
        let expired = await api.fallbackCount
        XCTAssertEqual(expired, 2)
        let nextDay = try XCTUnwrap(ServiceClock.calendar.date(byAdding: .day, value: 1, to: now))
        _ = try await router.plan(origin: origin, destination: destination, context: nil, now: nextDay, last: true)
        let changedDay = await api.fallbackCount
        XCTAssertEqual(changedDay, 3)
    }

    func testWalkingChangesDoorArrivalOrderAndLastDepartureDeadline() {
        let now = Date()
        let earlierTrain = fixture(departure: now, duration: 600, line: "A")
        let laterTrain = fixture(departure: now, duration: 660, line: "B")
        let earlierJourney = StationRouter.addWalking(to: earlierTrain, access: 180, egress: 600)
        let laterJourney = StationRouter.addWalking(to: laterTrain, access: 180, egress: 60)
        XCTAssertLessThan(laterJourney.finalArrivalTime, earlierJourney.finalArrivalTime)
        XCTAssertEqual(earlierJourney.leaveBy, now.addingTimeInterval(-180))
        XCTAssertEqual(earlierJourney.walkToDestinationMinutes, 10)
    }

    func testActualBoardingIDsAreReusedThenRecomparedAfterFiveMinutes() async throws {
        let api = StationAPIStub()
        let router = StationRouter(api: api, walking: WalkingStub())
        let context = await router.prepare(origin: origin, destination: destination)
        let now = Date()
        _ = try await router.plan(origin: origin, destination: destination, context: context, now: now, last: false)
        _ = try await router.plan(
            origin: origin, destination: destination, context: context, now: now.addingTimeInterval(1), last: false)
        let reused = await api.requests
        XCTAssertEqual(reused.count, 3)
        XCTAssertEqual(reused.last?.from, "feed:b")
        _ = try await router.plan(
            origin: origin, destination: destination, context: context, now: now.addingTimeInterval(301), last: false)
        let expanded = await api.requests
        XCTAssertEqual(expanded.count, 5)
    }

    func testLastTrainReusesPairSelectedByNormalRoute() async throws {
        let api = StationAPIStub()
        let router = StationRouter(api: api, walking: WalkingStub())
        let context = await router.prepare(origin: origin, destination: destination)
        let now = Date()
        _ = try await router.plan(origin: origin, destination: destination, context: context, now: now, last: false)
        let normalRequestCount = await api.requests.count
        _ = try await router.plan(origin: origin, destination: destination, context: context, now: now, last: true)
        let requests = await api.requests
        XCTAssertEqual(requests.count, normalRequestCount + 1)
        XCTAssertEqual(requests.last?.from, "feed:b")
        XCTAssertEqual(requests.last?.last, true)
    }

    func testPersistedPairAvoidsComparingEveryFeedAfterRelaunch() async throws {
        let api = StationAPIStub()
        let router = StationRouter(api: api, walking: WalkingStub())
        let context = await router.prepare(origin: origin, destination: destination)
        let now = Date()

        let trips = try await router.plan(
            origin: origin, destination: destination, context: context, now: now, last: false,
            preferredPair: StationPair(from: "feed:b", to: "feed:c"))

        let requests = await api.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.from, "feed:b")
        XCTAssertEqual(trips.first?.lineName, "feed:b")
    }

    func testCoordinateFallbackOverlapsSlowStationComparison() async throws {
        let api = StationAPIStub(stationDelay: .seconds(2))
        let router = StationRouter(api: api, walking: WalkingStub())
        let context = await router.prepare(origin: origin, destination: destination)
        let start = ContinuousClock.now

        let trips = try await router.plan(origin: origin, destination: destination, context: context, now: Date(), last: false)

        XCTAssertEqual(trips.first?.lineName, "coordinate")
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testBoardingAfterMidnightUsesNextServiceDate() async throws {
        let api = StationAPIStub()
        let router = StationRouter(api: api, walking: WalkingStub())
        let context = await router.prepare(origin: origin, destination: destination)
        let tomorrow = try XCTUnwrap(ServiceClock.calendar.date(byAdding: .day, value: 1, to: Date()))
        let now = try XCTUnwrap(ServiceClock.calendar.date(bySettingHour: 23, minute: 59, second: 30, of: tomorrow))
        _ = try await router.plan(origin: origin, destination: destination, context: context, now: now, last: false)
        let requests = await api.requests
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { !ServiceClock.calendar.isDate($0.serviceDate, inSameDayAs: now) })
        XCTAssertTrue(requests.allSatisfy { ServiceClock.calendar.isDate($0.serviceDate, inSameDayAs: $0.boardingAfter) })
    }

    func testPartialStationFailureFallsBackAndReusesValidatedBoardingPair() async throws {
        let api = StationAPIStub(failingStation: "feed:a")
        let router = StationRouter(api: api, walking: WalkingStub())
        let context = await router.prepare(origin: origin, destination: destination)
        let now = Date()
        let first = try await router.plan(origin: origin, destination: destination, context: context, now: now, last: false)
        XCTAssertEqual(first.first?.lineName, "coordinate")
        let fallbackCount = await api.fallbackCount
        XCTAssertEqual(fallbackCount, 1)
        _ = try await router.plan(
            origin: origin, destination: destination, context: context, now: now.addingTimeInterval(1), last: false)
        let requests = await api.requests
        XCTAssertEqual(requests.last?.from, "feed:b")
        let nextFallbackCount = await api.fallbackCount
        XCTAssertEqual(nextFallbackCount, 1)
    }
}

private func fixture(departure: Date, duration: Double = 600, line: String = "test") -> Trip {
    Trip(
        walkToStationMinutes: 0, departure: .init(stationName: "出発", time: departure), transfers: [],
        arrival: .init(stationName: "到着", time: departure.addingTimeInterval(duration)), walkToDestinationMinutes: 0,
        finalArrivalTime: departure.addingTimeInterval(duration), leaveBy: departure, lineName: line)
}

private actor WalkingStub: WalkingProviding {
    var count = 0
    func seconds(from: Coordinate, to: Coordinate) async throws -> TimeInterval {
        count += 1
        return 91
    }
}

private actor StationAPIStub: StationRoutingAPI {
    struct Request {
        let from: String
        let boardingAfter: Date
        let serviceDate: Date
        let last: Bool
    }
    var requests: [Request] = []
    var fallbackCount = 0
    var discoveryCount = 0
    let emptyStations: Bool
    let failingStation: String?
    let stationDelay: Duration?
    init(emptyStations: Bool = false, failingStation: String? = nil, stationDelay: Duration? = nil) {
        self.emptyStations = emptyStations
        self.failingStation = failingStation
        self.stationDelay = stationDelay
    }
    func nearbyStations(at coordinate: Coordinate) async throws -> [StationCandidate] {
        discoveryCount += 1
        if emptyStations { return [] }
        if coordinate.latitude < 35.5 {
            return ["feed:a", "feed:b"].map { StationCandidate(id: $0, name: "東京", lat: 35.001, lon: 139, kind: "station") }
        }
        return [StationCandidate(id: "feed:c", name: "東金", lat: 36.001, lon: 140, kind: "station")]
    }
    func stationPlan(from: String, to: String, boardingAfter: Date, serviceDate: Date, last: Bool) async throws -> [Trip] {
        requests.append(Request(from: from, boardingAfter: boardingAfter, serviceDate: serviceDate, last: last))
        if let stationDelay { try await Task.sleep(for: stationDelay) }
        if from == failingStation { throw TransitError.timedOut }
        var trip = fixture(departure: boardingAfter.addingTimeInterval(120), duration: from == "feed:a" ? 900 : 600, line: from)
        trip.departure.stationID = "feed:b"
        trip.arrival.stationID = "feed:c"
        return [trip]
    }
    func plan(origin: Coordinate, destination: Coordinate, now: Date, last: Bool) async throws -> [Trip] {
        fallbackCount += 1
        var trip = fixture(departure: now.addingTimeInterval(600), line: "coordinate")
        trip.departure.stationID = "feed:b"
        trip.arrival.stationID = "feed:c"
        return [trip]
    }
}
