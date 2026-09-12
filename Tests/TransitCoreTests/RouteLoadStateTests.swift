import XCTest

@testable import TransitCore

final class RouteLoadStateTests: XCTestCase {
    func testLoadingRetainsPreviousSummary() {
        let summary = makeSummary()
        XCTAssertEqual(RouteLoadState.loading(previous: summary, phase: .locating).summary, summary)
    }

    func testAvailableExposesSummary() {
        let summary = makeSummary()
        XCTAssertEqual(RouteLoadState.available(summary).summary, summary)
    }

    func testUnavailableRetainsPreviousSummary() {
        let summary = makeSummary()
        XCTAssertEqual(RouteLoadState.unavailable(previous: summary, message: "unavailable").summary, summary)
    }

    func testFailureRetainsPreviousSummary() {
        let summary = makeSummary()
        XCTAssertEqual(RouteLoadState.failure(previous: summary, message: "failure").summary, summary)
    }

    func testLoadingStateIsLoading() { XCTAssertTrue(RouteLoadState.loading(previous: nil, phase: .searching).isLoading) }

    func testUnavailableStateIsNotLoading() {
        XCTAssertFalse(RouteLoadState.unavailable(previous: nil, message: "unavailable").isLoading)
    }

    private func makeSummary() -> RouteSummary {
        RouteSummary(
            destination: Destination(name: "自宅", coordinate: Coordinate(latitude: 35.0, longitude: 139.0)),
            origin: Coordinate(latitude: 35.1, longitude: 139.1), trip: nil, lastTrain: nil, lastTrainStatus: .unavailable,
            fetchedAt: Date(timeIntervalSince1970: 1_000))
    }
}
