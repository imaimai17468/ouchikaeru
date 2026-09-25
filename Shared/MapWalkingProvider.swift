import Foundation
import MapKit

struct MapWalkingProvider: WalkingProviding {
    func seconds(from: Coordinate, to: Coordinate) async throws -> TimeInterval {
        if from == to { return 0 }
        let request = MKDirections.Request()
        request.source = MKMapItem(
            placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)))
        request.destination = MKMapItem(
            placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)))
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        return try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    let response = try await directions.calculate()
                    guard let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
                        throw TransitError.noRoute
                    }
                    return route.expectedTravelTime
                } onCancel: {
                    directions.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(6))
                throw TransitError.timedOut
            }
            defer { group.cancelAll() }
            guard let seconds = try await group.next() else { throw TransitError.noRoute }
            return seconds
        }
    }
}

struct MapStationProvider: StationDiscovering {
    private let api = TransitAPI()

    func nearbyStations(at coordinate: Coordinate) async throws -> [StationCandidate] {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalSearch.Request(
            naturalLanguageQuery: "駅",
            region: MKCoordinateRegion(center: center, latitudinalMeters: 6_000, longitudinalMeters: 6_000))
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler {
            try await search.start()
        } onCancel: {
            search.cancel()
        }
        let stations = response.mapItems.compactMap { item -> (String, Coordinate)? in
            guard let name = item.name else { return nil }
            let point = item.placemark.coordinate
            let station = Coordinate(latitude: point.latitude, longitude: point.longitude)
            guard station.isValid, station.distance(to: coordinate) <= 3_000 else { return nil }
            return (name, station)
        }.sorted { $0.1.distance(to: coordinate) < $1.1.distance(to: coordinate) }
        return await withTaskGroup(of: [StationCandidate].self) { group in
            for (name, station) in stations.prefix(5) {
                group.addTask { (try? await api.stationCandidates(named: name, near: station)) ?? [] }
            }
            var result: [StationCandidate] = []
            for await candidates in group { result += candidates }
            var ids = Set<String>()
            return result.filter { ids.insert($0.id).inserted }
        }
    }
}
