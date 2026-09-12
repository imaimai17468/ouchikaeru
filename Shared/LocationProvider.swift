import CoreLocation

@MainActor final class LocationProvider: NSObject, @MainActor CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<Coordinate, Error>?
    private var timeout: Task<Void, Never>?
    private var simulatorFallback: Coordinate?
    enum Failure: LocalizedError {
        case denied, unavailable
        var errorDescription: String? { self == .denied ? "現在地から経路を検索するため、位置情報を許可してください。" : "現在地を取得できませんでした。もう一度お試しください。" }
    }
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    func locate(fallback: Coordinate? = nil) async throws -> Coordinate {
        #if targetEnvironment(simulator)
            if let location = manager.location {
                let coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                if coordinate.isWithinJapanSearchBounds { return coordinate }
            }
            simulatorFallback = fallback?.isWithinJapanSearchBounds == true ? fallback : nil
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            if let old = pending { old.resume(throwing: Failure.unavailable) }
            pending = continuation
            timeout?.cancel()
            timeout = Task { [weak self] in
                #if targetEnvironment(simulator)
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if let fallback = self?.simulatorFallback {
                        self?.finish(.success(fallback))
                    } else {
                        self?.finish(.failure(Failure.unavailable))
                    }
                #else
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.finish(.failure(Failure.unavailable))
                #endif
            }
            authorize()
        }
    }
    private func authorize() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: if pending != nil { manager.startUpdatingLocation() }
        case .denied, .restricted: finish(.failure(Failure.denied))
        @unknown default: finish(.failure(Failure.unavailable))
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorize() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        #if !targetEnvironment(simulator)
            guard abs(location.timestamp.timeIntervalSinceNow) < 120 else { return }
        #endif
        let coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        #if targetEnvironment(simulator)
            guard coordinate.isWithinJapanSearchBounds else { return }
        #endif
        finish(.success(coordinate))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        finish(.failure(manager.authorizationStatus == .denied ? Failure.denied : Failure.unavailable))
    }
    private func finish(_ result: Result<Coordinate, Error>) {
        timeout?.cancel()
        timeout = nil
        simulatorFallback = nil
        manager.stopUpdatingLocation()
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
