import Foundation

struct SharedStore {
    // Must match the App Group entitlement on iPhone and Widget.
    static let group = "group.jp.ouchikaeru.app"
    private let defaults: UserDefaults
    init() {
        #if os(watchOS)
            defaults = .standard
        #else
            guard let sharedDefaults = UserDefaults(suiteName: Self.group) else {
                preconditionFailure("App Group UserDefaults could not be created")
            }
            defaults = sharedDefaults
        #endif
    }
    var destination: Destination? {
        guard let stored = read(Destination.self, key: "destination") else { return nil }
        let cleaned = stored.removingLegacyPlaceMetadata()
        if cleaned != stored, let data = try? JSONEncoder().encode(cleaned) { defaults.set(data, forKey: "destination") }
        return cleaned
    }
    var summary: RouteSummary? {
        guard var stored = read(RouteSummary.self, key: "summary") else { return nil }
        var changed = false
        let cleaned = stored.destination.removingLegacyPlaceMetadata()
        if cleaned != stored.destination {
            stored.destination = cleaned
            changed = true
        }
        if stored.lastTrain != nil, stored.usableLastTrain() == nil {
            stored.lastTrain = nil
            stored.lastTrainStatus = .unavailable
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: "summary") }
        return stored
    }
    func save(destination: Destination?) throws {
        guard let destination else {
            defaults.removeObject(forKey: "destination")
            defaults.removeObject(forKey: "summary")
            return
        }
        if var retained = summary, retained.destination.id == destination.id,
            retained.destination.coordinate == destination.coordinate
        {
            retained.destination = destination
            try save(summary: retained)
        } else {
            defaults.removeObject(forKey: "summary")
        }
        defaults.set(try JSONEncoder().encode(destination), forKey: "destination")
    }
    func save(summary: RouteSummary?) throws {
        if let summary {
            defaults.set(try JSONEncoder().encode(summary), forKey: "summary")
        } else {
            defaults.removeObject(forKey: "summary")
        }
    }
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
