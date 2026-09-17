import XCTest

@testable import TransitCore

final class RouteParserTests: XCTestCase {
    private func response(_ journeys: String, date: String = "20260910") throws -> PlanResponse {
        try JSONDecoder().decode(
            PlanResponse.self,
            from: Data(
                """
                {"date":"\(date)","timezone":"Asia/Tokyo","journeys":[\(journeys)]}
                """.utf8))
    }
    private func journey(departure: Int = 81660, arrival: Int = 86580, access: Int = 360, egress: Int = 480) -> String {
        """
        {"departureSecs":\(departure - access),"arrivalSecs":\(arrival + egress),"accessWalkSecs":\(access),"egressWalkSecs":\(egress),"legs":[
        {"kind":"transit","mode":"rail","routeName":"総武線","from":{"name":"東京"},"to":{"name":"東金"},"departureSecs":\(departure),"arrivalSecs":\(arrival)}]}
        """
    }
    func testAfterMidnightAndWalkingNotDoubleCounted() throws {
        let trip = try XCTUnwrap(RouteParser.trips(from: response(journey())).first)
        XCTAssertEqual(ServiceClock.date(trip.arrival.time, format: "yyyyMMdd HH:mm"), "20260911 00:03")
        XCTAssertEqual(ServiceClock.date(trip.finalArrivalTime, format: "yyyyMMdd HH:mm"), "20260911 00:11")
        XCTAssertEqual(trip.walkToStationMinutes, 6)
        XCTAssertEqual(trip.walkToDestinationMinutes, 8)
        XCTAssertEqual(ServiceClock.time(trip.finalArrivalTime, relativeTo: trip.departure.time), "翌 0:11")
        XCTAssertEqual(trip.departure.time.timeIntervalSince(trip.leaveBy), 360)
        XCTAssertEqual(trip.transitModes, ["rail"])
    }
    func testUnreachableDepartureIsExcludedAndEarliestArrivalWins() throws {
        let trips = try RouteParser.trips(
            from: response(
                [
                    journey(departure: 36000, arrival: 40000), journey(departure: 36600, arrival: 40500),
                    journey(departure: 36700, arrival: 40100),
                ].joined(separator: ",")))
        let now = trips[0].departure.time.addingTimeInterval(-60)
        XCTAssertEqual(RouteParser.recommended(trips, now: now), trips[2])
    }
    func testNegativeSecondsAndISOServiceDate() throws {
        let trip = try XCTUnwrap(
            RouteParser.trips(from: response(journey(departure: -600, arrival: 120), date: "2026-09-10")).first)
        XCTAssertEqual(ServiceClock.date(trip.departure.time, format: "yyyyMMdd HH:mm"), "20260909 23:50")
    }
    func testTransferBetweenDifferentStations() throws {
        let json = """
            {"departureSecs":36000,"arrivalSecs":40000,"legs":[
            {"kind":"transit","routeName":"A線","from":{"name":"出発"},"to":{"name":"乗換A"},"departureSecs":36000,"arrivalSecs":37000},
            {"kind":"walk","from":{"name":"乗換A"},"to":{"name":"乗換B"},"departureSecs":37000,"arrivalSecs":37300},
            {"kind":"transit","routeName":"B線","from":{"name":"乗換B"},"to":{"name":"到着"},"departureSecs":37500,"arrivalSecs":40000}]}
            """
        let trip = try XCTUnwrap(RouteParser.trips(from: response(json)).first)
        XCTAssertEqual(trip.transfers.count, 1)
        XCTAssertEqual(trip.transfers[0].arrival.stationName, "乗換A")
        XCTAssertEqual(trip.transfers[0].departure.stationName, "乗換B")
    }
    func testRouteStopsRemoveAppendedRomanization() throws {
        let trip = try XCTUnwrap(
            RouteParser.trips(
                from: response(
                    journey().replacingOccurrences(of: "東京", with: "長原Nagahara").replacingOccurrences(
                        of: "東金", with: "洗足池Senzoku-ike"))
            ).first)
        XCTAssertEqual([trip.departure.stationName, trip.arrival.stationName], ["長原", "洗足池"])
    }
    func testCachedRouteStopRemovesAppendedRomanization() throws {
        let stop = try JSONDecoder().decode(RouteStop.self, from: Data(#"{"stationName":"長原Nagahara","time":0}"#.utf8))
        XCTAssertEqual(stop.stationName, "長原")
    }
    func testTrailingStationWalkIsIncludedInDestinationWalk() throws {
        let json = """
            {"departureSecs":36000,"arrivalSecs":37400,"accessWalkSecs":60,"egressWalkSecs":100,"legs":[
            {"kind":"transit","routeName":"A線","from":{"name":"出発"},"to":{"name":"到着"},"departureSecs":36000,"arrivalSecs":37000},
            {"kind":"walk","from":{"name":"到着"},"to":{"name":"別の駅出口"},"departureSecs":37000,"arrivalSecs":37300}]}
            """
        let trip = try XCTUnwrap(RouteParser.trips(from: response(json)).first)
        XCTAssertEqual(trip.walkToDestinationMinutes, 7)
        XCTAssertEqual(trip.finalArrivalTime.timeIntervalSince(trip.arrival.time), 400)
    }
    func testEmptyResponseIsNotProofLastTrainEnded() throws {
        XCTAssertTrue(try RouteParser.trips(from: response("")).isEmpty)
        let now = Date()
        let summary = RouteSummary(
            destination: Destination(name: "自宅", coordinate: .init(latitude: 35, longitude: 139)),
            origin: .init(latitude: 35, longitude: 140), trip: nil, lastTrain: nil, lastTrainStatus: .unavailable, fetchedAt: now)
        XCTAssertEqual(summary.lastTrainText(at: now), "終電情報を取得できませんでした。")
    }
    func testSnapshotRoundTripAndExpiryAtWalkingDeadline() throws {
        let trip = try XCTUnwrap(RouteParser.trips(from: response(journey())).first)
        let summary = RouteSummary(
            destination: Destination(name: "自宅", coordinate: .init(latitude: 35, longitude: 139)),
            origin: .init(latitude: 35, longitude: 140), trip: trip, lastTrain: trip, lastTrainStatus: .available,
            fetchedAt: trip.leaveBy.addingTimeInterval(-10))
        let decoded = try JSONDecoder().decode(RouteSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(summary, decoded)
        XCTAssertFalse(summary.isStale(at: trip.leaveBy.addingTimeInterval(-1)))
        XCTAssertTrue(summary.isStale(at: trip.leaveBy.addingTimeInterval(1)))
        XCTAssertEqual(summary.lastTrainText(at: trip.leaveBy.addingTimeInterval(1)), "本日の終電は終了しました。")
    }
    func testSummaryAdvancesToNextCatchableTrip() throws {
        let trips = try RouteParser.trips(
            from: response(
                [journey(departure: 36000, arrival: 40000), journey(departure: 36600, arrival: 40500)].joined(separator: ",")))
        let summary = RouteSummary(
            destination: Destination(name: "自宅", coordinate: .init(latitude: 35, longitude: 139)),
            origin: .init(latitude: 35, longitude: 140), trip: trips[0], upcomingTrips: trips, lastTrain: nil,
            lastTrainStatus: .unavailable, fetchedAt: trips[0].leaveBy)
        let afterFirstDeadline = trips[0].leaveBy.addingTimeInterval(1)

        XCTAssertEqual(summary.trip(at: afterFirstDeadline), trips[1])
        XCTAssertFalse(summary.isStale(at: afterFirstDeadline))
        XCTAssertTrue(summary.needsRefresh(at: afterFirstDeadline.addingTimeInterval(301)))
        XCTAssertNil(summary.trip(at: trips[1].leaveBy.addingTimeInterval(1)))
    }
    func testSummaryDecodesCacheSavedBeforeUpcomingTripsWereAdded() throws {
        let trip = try XCTUnwrap(RouteParser.trips(from: response(journey())).first)
        let summary = RouteSummary(
            destination: Destination(name: "自宅", coordinate: .init(latitude: 35, longitude: 139)),
            origin: .init(latitude: 35, longitude: 140), trip: trip, lastTrain: nil, lastTrainStatus: .unavailable,
            fetchedAt: trip.leaveBy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        object.removeValue(forKey: "upcomingTrips")

        let decoded = try JSONDecoder().decode(
            RouteSummary.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))

        XCTAssertEqual(decoded.trip(at: trip.leaveBy), trip)
    }
    func testSummaryDecodesCacheSavedBeforeLocationStatusWasAdded() throws {
        let summary = RouteSummary(
            destination: Destination(name: "自宅", coordinate: .init(latitude: 35, longitude: 139)),
            origin: .init(latitude: 35, longitude: 140), trip: nil, lastTrain: nil, lastTrainStatus: .unavailable,
            fetchedAt: Date())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        object.removeValue(forKey: "locationStatus")

        let decoded = try JSONDecoder().decode(
            RouteSummary.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))

        XCTAssertFalse(decoded.isAtDestination)
    }
    func testAtDestinationSummaryRefreshesAfterFiveMinutesWithoutBeingStale() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let summary = RouteSummary(
            destination: Destination(name: "自宅", coordinate: .init(latitude: 35, longitude: 139)),
            origin: .init(latitude: 35, longitude: 139), trip: nil, lastTrain: nil, lastTrainStatus: .unavailable,
            fetchedAt: fetchedAt, locationStatus: .atDestination)

        XCTAssertFalse(summary.isStale(at: fetchedAt))
        XCTAssertFalse(summary.needsRefresh(at: fetchedAt.addingTimeInterval(300)))
        XCTAssertTrue(summary.needsRefresh(at: fetchedAt.addingTimeInterval(301)))
    }
    func testLastTrainRejectsNextMorningAndOvernightTransfer() throws {
        let serviceDate = try XCTUnwrap(ServiceClock.calendar.date(from: DateComponents(year: 2026, month: 9, day: 11)))
        let nextDay = try XCTUnwrap(ServiceClock.calendar.date(byAdding: .day, value: 1, to: serviceDate))
        var morning = try XCTUnwrap(RouteParser.trips(from: response(journey())).first)
        morning.leaveBy = nextDay.addingTimeInterval(3 * 60 * 60)
        morning.departure.time = morning.leaveBy
        morning.arrival.time = morning.leaveBy.addingTimeInterval(30 * 60)
        morning.finalArrivalTime = morning.arrival.time
        var overnightWait = morning
        overnightWait.leaveBy = serviceDate.addingTimeInterval(23 * 60 * 60)
        overnightWait.departure.time = overnightWait.leaveBy
        let overnightTransfer = Transfer(
            arrival: RouteStop(stationName: "千葉", time: nextDay),
            departure: RouteStop(stationName: "千葉", time: nextDay.addingTimeInterval(2 * 60 * 60)), lineName: "東金線")
        overnightWait.transfers = [overnightTransfer]

        XCTAssertFalse(RouteParser.isValidLastTrain(morning, serviceDate: serviceDate))
        XCTAssertFalse(RouteParser.isValidLastTrain(overnightWait, serviceDate: serviceDate))
    }
}
