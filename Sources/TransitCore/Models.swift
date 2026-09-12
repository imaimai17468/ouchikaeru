import Foundation

public struct Coordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
    public var endpoint: String { "geo:\(latitude),\(longitude)" }
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    /// A broad envelope including Japan's islands, not a guarantee of transit coverage.
    public var isWithinJapanSearchBounds: Bool { isValid && (20...46).contains(latitude) && (122...154).contains(longitude) }
    public func distance(to other: Coordinate) -> Double {
        let r = Double.pi / 180
        let h =
            pow(sin((other.latitude - latitude) * r / 2), 2) + cos(latitude * r) * cos(other.latitude * r)
            * pow(sin((other.longitude - longitude) * r / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}

public struct Destination: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String?
    public var coordinate: Coordinate
    public var createdAt: Date
    public var updatedAt: Date
    public init(
        id: UUID = UUID(), name: String, address: String? = nil, coordinate: Coordinate, createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Removes search-provider metadata that older app versions appended to
    /// the saved destination label (for example "千葉駅 駅 / 東日本旅客鉄道").
    public func removingLegacyPlaceMetadata() -> Destination {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: #"\s+(?:駅|停留所)(?:\s*[/／・]\s*.*|\s+\d+地点)?$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"駅(?:\s*駅)+$"#, with: "駅", options: .regularExpression).trimmingCharacters(
                    in: .whitespacesAndNewlines)
        }
        var value = self
        let cleanedName = clean(name)
        if !cleanedName.isEmpty { value.name = cleanedName }
        if let address {
            let cleanedAddress = clean(address)
            value.address = cleanedAddress.isEmpty ? value.name : cleanedAddress
        }
        return value
    }
}

public struct RouteStop: Codable, Equatable, Sendable {
    public var stationName: String
    public var time: Date
    public var stationID: String?
}

public struct Transfer: Codable, Equatable, Sendable {
    public var arrival: RouteStop
    public var departure: RouteStop
    public var lineName: String
}

public struct Trip: Codable, Equatable, Sendable {
    public var walkToStationMinutes: Int
    public var departure: RouteStop
    public var transfers: [Transfer]
    public var arrival: RouteStop
    public var walkToDestinationMinutes: Int
    public var finalArrivalTime: Date
    public var leaveBy: Date
    public var lineName: String
    public var transitModes: [String]?
}

public enum LastTrainStatus: String, Codable, Sendable { case available, ended, unavailable }

public struct RouteSummary: Codable, Equatable, Sendable {
    public var destination: Destination
    public var origin: Coordinate
    public var trip: Trip?
    public var upcomingTrips: [Trip]?
    public var lastTrain: Trip?
    public var lastTrainStatus: LastTrainStatus
    public var fetchedAt: Date
    public init(
        destination: Destination, origin: Coordinate, trip: Trip?, upcomingTrips: [Trip]? = nil, lastTrain: Trip?,
        lastTrainStatus: LastTrainStatus, fetchedAt: Date
    ) {
        self.destination = destination
        self.origin = origin
        self.trip = trip
        self.upcomingTrips = upcomingTrips
        self.lastTrain = lastTrain
        self.lastTrainStatus = lastTrainStatus
        self.fetchedAt = fetchedAt
    }
    public func trip(at now: Date = Date()) -> Trip? {
        RouteParser.recommended(upcomingTrips ?? trip.map { [$0] } ?? [], now: now)
    }
    public func needsRefresh(at now: Date = Date()) -> Bool { now.timeIntervalSince(fetchedAt) > 300 || trip(at: now) == nil }
    public func isStale(at now: Date = Date()) -> Bool { trip(at: now) == nil }
    public func usableLastTrain() -> Trip? {
        guard let lastTrain, RouteParser.isValidLastTrain(lastTrain, serviceDate: fetchedAt) else { return nil }
        return lastTrain
    }
    public func lastTrainText(at now: Date = Date()) -> String {
        let usableLastTrain = usableLastTrain()
        if !ServiceClock.calendar.isDate(fetchedAt, inSameDayAs: now), usableLastTrain.map({ $0.leaveBy < now }) ?? true {
            return "終電情報を更新してください。"
        }
        if let lastTrain = usableLastTrain {
            if now > lastTrain.leaveBy { return "本日の終電は終了しました。" }
            return "終電 \(ServiceClock.time(lastTrain.departure.time, relativeTo: now)) \(lastTrain.departure.stationName) 発"
        }
        return lastTrainStatus == .ended ? "本日の終電は終了しました。" : "終電情報を取得できませんでした。"
    }
}

public enum RouteLoadingPhase: Equatable, Sendable {
    case locating
    case preparing
    case searching
    case lastTrain
}

public enum RouteLoadState: Equatable, Sendable {
    case loading(previous: RouteSummary?, phase: RouteLoadingPhase)
    case available(RouteSummary)
    case unavailable(previous: RouteSummary?, message: String)
    case failure(previous: RouteSummary?, message: String)

    public var summary: RouteSummary? {
        switch self {
        case .loading(let previous, _), .unavailable(let previous, _), .failure(let previous, _): return previous
        case .available(let summary): return summary
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

public enum ServiceClock {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "Asia/Tokyo") else { preconditionFailure("Asia/Tokyo must be available") }
        calendar.timeZone = timeZone
        return calendar
    }
    public static func date(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f.string(from: date)
    }
    public static func time(_ value: Date, relativeTo reference: Date = Date()) -> String {
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: value)).day
            ?? 0
        let prefix = days == 1 ? "翌 " : days == 0 ? "" : date(value, format: "M/d ")
        return prefix + date(value, format: "H:mm")
    }
    public static func updated(_ value: Date) -> String { date(value, format: "M/d H:mm") + " 更新" }
}
