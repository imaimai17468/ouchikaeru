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
