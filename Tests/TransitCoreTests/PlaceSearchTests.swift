import XCTest

@testable import TransitCore

final class PlaceSearchTests: XCTestCase {
    private func place(
        _ id: String, name: String = "東金", kind: String = "station", lat: Double = 35.5602766, lon: Double = 140.3636144,
        feed: String? = nil
    ) throws -> Place {
        var value: [String: Any] = ["id": id, "name": name, "kind": kind, "lat": lat, "lon": lon]
        if let feed { value["feedName"] = feed }
        return try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testToganeAcrossThreeSourcesBecomesOneResultWithLineName() throws {
        let values = try [place("aggregate"), place("osm"), place("rail", feed: "東金線")]
        let result = PlaceSearch.unique(values)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.subtitle, "駅 · 東金線")
    }
    func testNearbyStationCoordinatesMergeWithoutChangingRanking() throws {
        let values = try [place("first"), place("other", name: "東金市役所", kind: "place"), place("rail", lat: 35.5604, feed: "東金線")]
        XCTAssertEqual(PlaceSearch.unique(values).map(\.id), ["rail", "other"])
    }
    func testDifferentLocationsAndKindsStaySeparate() throws {
        let values = try [
            place("station"), place("distant", lat: 36.56), place("address", kind: "address"), place("stop", kind: "stop"),
        ]
        XCTAssertEqual(PlaceSearch.unique(values).count, 4)
    }
    func testStationDisplayRemovesDuplicateSuffixAndAggregateCount() {
        let place = Place(id: "u", name: "宇都宮駅駅", description: "駅 2地点", lat: 36.559, lon: 139.898, kind: "station")
        XCTAssertEqual(place.displayName, "宇都宮駅")
        XCTAssertEqual(place.displayAddress, "宇都宮駅")
        XCTAssertEqual(place.subtitle, "駅")
    }
    func testStationOperatorIsNotConcatenatedIntoAddress() {
        let place = Place(id: "chiba", name: "千葉駅", description: "駅 / 東日本旅客鉄道", lat: 35.613, lon: 140.113, kind: "station")
        XCTAssertEqual(place.displayName, "千葉駅")
        XCTAssertEqual(place.displayAddress, "千葉駅")
        XCTAssertEqual(place.subtitle, "東日本旅客鉄道")
    }
    func testStationDisplayRemovesAppendedRomanization() {
        let place = Place(id: "nagahara", name: "長原Nagahara", lat: 35.602, lon: 139.697, kind: "station")
        XCTAssertEqual(place.displayName, "長原")
    }
    func testJapaneseAndRomanizedStationResultsMerge() throws {
        let result = PlaceSearch.unique([
            try place("romanized", name: "長原Nagahara"), try place("japanese", name: "長原", lat: 35.5604, feed: "池上線"),
        ])
        XCTAssertEqual(result.map(\.id), ["japanese"])
    }
    func testFacilityDisplayKeepsLatinSuffix() {
        let place = Place(id: "facility", name: "長原Nagahara", lat: 35.602, lon: 139.697, kind: "place")
        XCTAssertEqual(place.displayName, "長原Nagahara")
    }
    func testLegacySavedStationMetadataIsRemoved() {
        let destination = Destination(
            name: "千葉駅 駅 / 東日本旅客鉄道", address: "千葉駅 駅 / 東日本旅客鉄道", coordinate: .init(latitude: 35.613, longitude: 140.113)
        ).removingLegacyPlaceMetadata()
        XCTAssertEqual(destination.name, "千葉駅")
        XCTAssertEqual(destination.address, "千葉駅")
    }
}
