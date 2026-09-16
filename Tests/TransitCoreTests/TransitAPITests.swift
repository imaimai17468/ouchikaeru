import XCTest

@testable import TransitCore

final class TransitAPITests: XCTestCase {
    private func client() -> TransitAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransitStub.self]
        return TransitAPI(session: URLSession(configuration: config))
    }
    override func tearDown() {
        TransitStub.handler = nil
        super.tearDown()
    }

    func testRouteRequestBudgetAndCandidateLimits() async throws {
        TransitStub.handler = { request in
            let query = try queryParameters(from: request)
            XCTAssertEqual(query["from"], "geo:35.681,139.767")
            XCTAssertEqual(query["to"], "geo:35.56,140.36")
            if query["type"] == "arrival" {
                XCTAssertEqual(request.timeoutInterval, 15)
                XCTAssertEqual(query["numItineraries"], "1")
                XCTAssertEqual(query["time"], "23:59:59")
            } else {
                XCTAssertEqual(request.timeoutInterval, 60)
                XCTAssertEqual(query["numItineraries"], "3")
            }
            return Data(#"{"date":"20260910","timezone":"Asia/Tokyo","journeys":[]}"#.utf8)
        }
        let api = client()
        for last in [false, true] {
            _ = try await api.plan(
                origin: .init(latitude: 35.681, longitude: 139.767), destination: .init(latitude: 35.56, longitude: 140.36),
                now: Date(), last: last)
        }
    }
    func testTimeoutHasActionableJapaneseMessage() async throws {
        TransitStub.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await client().plan(
                origin: .init(latitude: 35, longitude: 139), destination: .init(latitude: 36, longitude: 140), now: Date())
            XCTFail("Expected timeout")
        } catch {
            guard case TransitError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("再読み込み"))
        }
    }
    func testLastTrainCanRestrictSearchToObservedModes() async throws {
        TransitStub.handler = { request in
            let query = try queryParameters(from: request)
            XCTAssertEqual(query["allowModes"], "rail")
            XCTAssertEqual(query["numItineraries"], "1")
            return Data(#"{"date":"20260910","timezone":"Asia/Tokyo","journeys":[]}"#.utf8)
        }
        _ = try await client().plan(
            origin: .init(latitude: 35.681, longitude: 139.767), destination: .init(latitude: 35.56, longitude: 140.36),
            now: Date(), last: true, allowedModes: ["rail"])
    }
    func testSimulatorDefaultLocationIsRejectedBeforeNetworkRequest() async throws {
        TransitStub.handler = { _ in
            XCTFail("Must not search US to Japan")
            return Data()
        }
        let outside = Coordinate(latitude: 37.785834, longitude: -122.406417)
        let japan = Coordinate(latitude: 35.5602766, longitude: 140.3636144)
        for (origin, destination) in [(outside, japan), (japan, outside)] {
            do {
                _ = try await client().plan(origin: origin, destination: destination, now: Date())
                XCTFail("Expected unsupported location")
            } catch { guard case TransitError.outsideServiceArea = error else { return XCTFail("Unexpected error: \(error)") } }
        }
    }
    func testNearbyStationSearchUsesJapaneseDisplayName() async throws {
        TransitStub.handler = { request in
            if request.url?.path.contains("places/reverse") == true {
                return Data(#"{"places":[{"id":"nearby","name":"長原Nagahara","kind":"station","lat":35.602,"lon":139.697}]}"#.utf8)
            }
            XCTAssertEqual(try queryParameters(from: request)["q"], "長原")
            return Data(
                #"{"stations":[{"id":"feed:nagahara","name":"長原Nagahara","kind":"station","lat":35.602,"lon":139.697,"weight":42}]}"#
                    .utf8)
        }
        let stations = try await client().nearbyStations(at: .init(latitude: 35.602, longitude: 139.697))
        XCTAssertEqual(stations.map(\.id), ["feed:nagahara"])
        XCTAssertEqual(stations.first?.weight, 42)
    }
}

private class TransitStub: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let requestURL = request.url else { throw TransitAPITestError.invalidRequest }
            let data = try handler(request)
            guard let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw TransitAPITestError.invalidResponse
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private enum TransitAPITestError: Error {
    case invalidRequest
    case invalidResponse
}

private func queryParameters(from request: URLRequest) throws -> [String: String] {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let queryItems = components.queryItems
    else { throw TransitAPITestError.invalidRequest }
    return try Dictionary(
        uniqueKeysWithValues: queryItems.map { item in
            guard let value = item.value else { throw TransitAPITestError.invalidRequest }
            return (item.name, value)
        })
}
