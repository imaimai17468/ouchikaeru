import XCTest

@testable import TransitCore

final class RoutePlannerTests: XCTestCase {
    func testCurrentRouteSelectsCatchableTrip() async throws {
        let fixture = fixture()

        let plan = try await fixture.planner.currentRoute(
            origin: fixture.origin, destination: fixture.destination, context: nil, previous: nil, now: fixture.now)

        XCTAssertEqual(plan.summary.trip, fixture.currentTrip)
    }

    func testCurrentRouteWithoutRetainedLastTrainRequestsLookup() async throws {
        let fixture = fixture()

        let plan = try await fixture.planner.currentRoute(
            origin: fixture.origin, destination: fixture.destination, context: nil, previous: nil, now: fixture.now)

        XCTAssertTrue(plan.needsLastTrain)
    }

    func testTimedOutCurrentRouteRetriesOnce() async throws {
        let fixture = fixture(timesOutOnce: true)

        _ = try await fixture.planner.currentRoute(
            origin: fixture.origin, destination: fixture.destination, context: nil, previous: nil, now: fixture.now)
        let requestCount = await fixture.api.currentRequestCount

        XCTAssertEqual(requestCount, 2)
    }

    func testCurrentRouteReusesStationPairFromSavedSummary() async throws {
        let fixture = fixture()
        var savedTrip = fixture.currentTrip
        savedTrip.departure.stationID = "feed:b"
        savedTrip.arrival.stationID = "feed:c"
        let previous = RouteSummary(
            destination: fixture.destination, origin: fixture.origin, trip: savedTrip, lastTrain: nil,
            lastTrainStatus: .unavailable, fetchedAt: fixture.now.addingTimeInterval(-600))
        let context = StationSearchContext(
            origin: fixture.origin, destination: fixture.destination.coordinate,
            departures: [
                StationAccess(station: station(id: "feed:a"), seconds: 0),
                StationAccess(station: station(id: "feed:b"), seconds: 0),
            ], arrivals: [StationAccess(station: station(id: "feed:c"), seconds: 0)])

        _ = try await fixture.planner.currentRoute(
            origin: fixture.origin, destination: fixture.destination, context: context, previous: previous, now: fixture.now)

        let requests = await fixture.api.stationRequests
        XCTAssertEqual(requests.map(\.from), ["feed:b"])
        XCTAssertEqual(requests.map(\.to), ["feed:c"])
        let coordinateRequests = await fixture.api.currentRequestCount
        XCTAssertEqual(coordinateRequests, 0)
    }

    func testAddingLastTrainUsesLatestResult() async throws {
        let fixture = fixture()
        let plan = try await fixture.planner.currentRoute(
            origin: fixture.origin, destination: fixture.destination, context: nil, previous: nil, now: fixture.now)

        let completed = await fixture.planner.addingLastTrain(to: plan.summary, context: nil, now: fixture.now)

        XCTAssertEqual(completed.lastTrain, fixture.lastTrain)
    }

    func testAddingLastTrainUsesStationsObservedInCurrentRoute() async throws {
        let fixture = fixture()
        var current = fixture.currentTrip
        current.departure.stationID = "feed:actual-from"
        current.arrival.stationID = "feed:actual-to"
        let summary = RouteSummary(
            destination: fixture.destination, origin: fixture.origin, trip: current, lastTrain: nil,
            lastTrainStatus: .unavailable, fetchedAt: fixture.now)
        let context = StationSearchContext(
            origin: fixture.origin, destination: fixture.destination.coordinate,
            departures: [StationAccess(station: station(id: "feed:representative-from"), seconds: 0)],
            arrivals: [StationAccess(station: station(id: "feed:representative-to"), seconds: 0)])

        let completed = await fixture.planner.addingLastTrain(to: summary, context: context, now: fixture.now)

        let requests = await fixture.api.stationRequests
        XCTAssertEqual(requests.map(\.from), ["feed:actual-from"])
        XCTAssertEqual(requests.map(\.to), ["feed:actual-to"])
        XCTAssertEqual(completed.lastTrain, fixture.lastTrain)
    }

    func testFailedLastTrainLookupIsUnavailable() async throws {
        let fixture = fixture(lastFails: true)
        let plan = try await fixture.planner.currentRoute(
            origin: fixture.origin, destination: fixture.destination, context: nil, previous: nil, now: fixture.now)

        let completed = await fixture.planner.addingLastTrain(to: plan.summary, context: nil, now: fixture.now)

        XCTAssertEqual(completed.lastTrainStatus, .unavailable)
    }

    func testEmptyLastTrainLookupIsEnded() async throws {
        let fixture = fixture(lastTrips: [])
        let plan = try await fixture.planner.currentRoute(
            origin: fixture.origin, destination: fixture.destination, context: nil, previous: nil, now: fixture.now)

        let completed = await fixture.planner.addingLastTrain(to: plan.summary, context: nil, now: fixture.now)

        XCTAssertEqual(completed.lastTrainStatus, .ended)
    }

    private func fixture(timesOutOnce: Bool = false, lastFails: Bool = false, lastTrips: [Trip]? = nil) -> PlannerFixture {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = trip(departure: now.addingTimeInterval(600), arrival: now.addingTimeInterval(1_800))
        let last = trip(departure: now.addingTimeInterval(10_000), arrival: now.addingTimeInterval(11_200))
        let api = PlannerAPI(current: [current], last: lastTrips ?? [last], timesOutOnce: timesOutOnce, lastFails: lastFails)
        let planner = RoutePlanner(api: api, walking: PlannerWalking(), clock: WallClock { now })
        return PlannerFixture(
            now: now, origin: Coordinate(latitude: 35.7, longitude: 139.8),
            destination: Destination(name: "自宅", coordinate: Coordinate(latitude: 35.6, longitude: 139.7)), currentTrip: current,
            lastTrain: last, api: api, planner: planner)
    }

    private func trip(departure: Date, arrival: Date) -> Trip {
        Trip(
            walkToStationMinutes: 5, departure: RouteStop(stationName: "出発", time: departure), transfers: [],
            arrival: RouteStop(stationName: "到着", time: arrival), walkToDestinationMinutes: 5,
            finalArrivalTime: arrival.addingTimeInterval(300), leaveBy: departure.addingTimeInterval(-300), lineName: "路線")
    }

    private func station(id: String) -> StationCandidate {
        StationCandidate(id: id, name: id, lat: 35.65, lon: 139.75, kind: "station")
    }
}

private struct PlannerFixture {
    let now: Date
    let origin: Coordinate
    let destination: Destination
    let currentTrip: Trip
    let lastTrain: Trip
    let api: PlannerAPI
    let planner: RoutePlanner
}

private actor PlannerAPI: StationRoutingAPI {
    struct StationRequest: Sendable {
        let from: String
        let to: String
    }

    let current: [Trip]
    let last: [Trip]
    let timesOutOnce: Bool
    let lastFails: Bool
    private(set) var currentRequestCount = 0
    private(set) var stationRequests: [StationRequest] = []

    init(current: [Trip], last: [Trip], timesOutOnce: Bool = false, lastFails: Bool = false) {
        self.current = current
        self.last = last
        self.timesOutOnce = timesOutOnce
        self.lastFails = lastFails
    }

    func nearbyStations(at coordinate: Coordinate) async throws -> [StationCandidate] { [] }
    func stationPlan(from: String, to: String, boardingAfter: Date, serviceDate: Date, last: Bool) async throws -> [Trip] {
        stationRequests.append(StationRequest(from: from, to: to))
        return last ? self.last : current
    }
    func plan(origin: Coordinate, destination: Coordinate, now: Date, last: Bool) async throws -> [Trip] {
        if last {
            if lastFails { throw PlannerFailure.failed }
            return self.last
        }
        currentRequestCount += 1
        if timesOutOnce, currentRequestCount == 1 { throw TransitError.timedOut }
        return current
    }
}

private enum PlannerFailure: Error { case failed }

private struct PlannerWalking: WalkingProviding {
    func seconds(from: Coordinate, to: Coordinate) async throws -> TimeInterval { 0 }
}
