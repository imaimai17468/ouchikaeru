import Foundation

public enum TransitError: LocalizedError {
    case invalidResponse, http(Int), noRoute, invalidLocation, timedOut, outsideServiceArea
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "交通情報を読み取れませんでした。"
        case .http: return "交通情報サービスに接続できませんでした。"
        case .noRoute: return "利用できる鉄道経路が見つかりませんでした。"
        case .invalidLocation: return "地点の座標を確認してください。"
        case .timedOut: return "交通情報サービスの応答に時間がかかっています。少し待ってから再読み込みしてください。"
        case .outsideServiceArea: return "現在地または目的地が交通情報の対応エリア外です。日本国内の地点を指定してください。"
        }
    }
}

public struct PlanResponse: Decodable {
    public let date: String
    public let timezone: String
    public let journeys: [Journey]
    public struct Journey: Decodable {
        let departureSecs: Double
        let arrivalSecs: Double
        let accessWalkSecs: Double?
        let egressWalkSecs: Double?
        let legs: [Leg]
    }
    public struct Leg: Decodable {
        let kind: String
        let routeName: String?
        let mode: String?
        let from: Stop
        let to: Stop
        let departureSecs: Double
        let arrivalSecs: Double
    }
    public struct Stop: Decodable {
        let name: String
        let id: String?
    }
}

public enum RouteParser {
    private static let maximumEndpointWalkMinutes = 180

    public static func trips(from response: PlanResponse) throws -> [Trip] {
        guard let zone = TimeZone(identifier: response.timezone) else { throw TransitError.invalidResponse }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = response.date.contains("-") ? "yyyy-MM-dd" : "yyyyMMdd"
        f.isLenient = false
        guard let midnight = f.date(from: response.date) else { throw TransitError.invalidResponse }
        func time(_ seconds: Double) -> Date { midnight.addingTimeInterval(seconds) }
        return response.journeys.compactMap { journey in
            let legs = journey.legs.filter { $0.kind == "transit" }
            guard let first = legs.first, let last = legs.last, journey.arrivalSecs.isFinite, journey.departureSecs.isFinite,
                journey.arrivalSecs >= journey.departureSecs,
                legs.allSatisfy({ $0.departureSecs.isFinite && $0.arrivalSecs.isFinite && $0.arrivalSecs >= $0.departureSecs })
            else { return nil }
            // The API can include station-to-station walks before/after the rail legs.
            // accessWalkSecs/egressWalkSecs describe only the geographic endpoint walks.
            let leadingWalk = journey.legs.prefix(while: { $0.kind != "transit" }).reduce(0) {
                $0 + max(0, $1.arrivalSecs - $1.departureSecs)
            }
            let trailingWalk = journey.legs.reversed().prefix(while: { $0.kind != "transit" }).reduce(0) {
                $0 + max(0, $1.arrivalSecs - $1.departureSecs)
            }
            let access = (journey.accessWalkSecs ?? 0) + leadingWalk
            let egress = (journey.egressWalkSecs ?? 0) + trailingWalk
            guard access.isFinite, egress.isFinite, access >= 0, egress >= 0, access < 86400, egress < 86400 else { return nil }
            let transfers = zip(legs, legs.dropFirst()).map { previous, next in
                Transfer(
                    arrival: RouteStop(stationName: previous.to.name, time: time(previous.arrivalSecs)),
                    departure: RouteStop(stationName: next.from.name, time: time(next.departureSecs)),
                    lineName: next.routeName ?? "")
            }
            return Trip(
                walkToStationMinutes: Int(ceil(access / 60)),
                departure: RouteStop(stationName: first.from.name, time: time(first.departureSecs), stationID: first.from.id),
                transfers: transfers,
                arrival: RouteStop(stationName: last.to.name, time: time(last.arrivalSecs), stationID: last.to.id),
                walkToDestinationMinutes: Int(ceil(egress / 60)),
                finalArrivalTime: time(max(journey.arrivalSecs, last.arrivalSecs + egress)),
                leaveBy: time(first.departureSecs - access), lineName: first.routeName ?? "",
                transitModes: Array(Set(legs.compactMap(\.mode))).sorted())
        }
    }
    public static func recommended(_ trips: [Trip], now: Date) -> Trip? {
        trips.filter { $0.leaveBy >= now && hasPracticalEndpointWalks($0) }.min { $0.finalArrivalTime < $1.finalArrivalTime }
    }
    public static func lastTrain(in trips: [Trip], serviceDate: Date) -> Trip? {
        trips.filter { isValidLastTrain($0, serviceDate: serviceDate) }.max { $0.leaveBy < $1.leaveBy }
    }
    public static func isValidLastTrain(_ trip: Trip, serviceDate: Date) -> Bool {
        let serviceStart = ServiceClock.calendar.startOfDay(for: serviceDate)
        guard let nextDay = ServiceClock.calendar.date(byAdding: .day, value: 1, to: serviceStart) else { return false }
        let latestBoarding = nextDay.addingTimeInterval(2 * 60 * 60)
        let latestArrival = nextDay.addingTimeInterval(4 * 60 * 60)
        let transferWaitsAreContinuous = trip.transfers.allSatisfy {
            let wait = $0.departure.time.timeIntervalSince($0.arrival.time)
            return wait >= 0 && wait <= 90 * 60
        }
        return hasPracticalEndpointWalks(trip) && trip.leaveBy >= serviceStart && trip.departure.time >= serviceStart
            && trip.departure.time <= latestBoarding && trip.finalArrivalTime >= trip.arrival.time
            && trip.finalArrivalTime <= latestArrival && transferWaitsAreContinuous
    }

    private static func hasPracticalEndpointWalks(_ trip: Trip) -> Bool {
        (0...maximumEndpointWalkMinutes).contains(trip.walkToStationMinutes)
            && (0...maximumEndpointWalkMinutes).contains(trip.walkToDestinationMinutes)
    }
}

public struct Place: Decodable, Identifiable, Sendable {
    public init(
        id: String, name: String, description: String? = nil, lat: Double, lon: Double, kind: String? = nil,
        feedName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.lat = lat
        self.lon = lon
        self.kind = kind
        self.feedName = feedName
    }
    public let id: String
    public let name: String
    public let description: String?
    public let lat: Double
    public let lon: Double
    public let kind: String?
    public let feedName: String?
    public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    public var displayName: String {
        let value = kind == "station" || kind == "stop" ? StationNameFormatter.displayName(name) : name
        return value.replacingOccurrences(of: #"駅(?:\s*駅)+$"#, with: "駅", options: .regularExpression)
    }
    public var displayAddress: String {
        // Station metadata such as "駅 / 東日本旅客鉄道" is a search-result
        // description, not part of the destination address.
        if kind == "station" || kind == "stop" { return displayName }
        return cleanedDescription ?? displayName
    }
    public var subtitle: String {
        let category: String
        switch kind {
        case "station": category = "駅"
        case "stop": category = "停留所"
        case "address": category = "住所"
        default: category = "施設"
        }
        if let feedName, !feedName.isEmpty { return "\(category) · \(feedName)" }
        if let cleanedDescription { return cleanedDescription }
        return category
    }
    private var cleanedDescription: String? {
        guard let description, !description.isEmpty else { return nil }
        let cleaned = description.replacingOccurrences(of: #"\s*\d+地点"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(駅|停留所)\s*(?:[/／・]\s*)?"#, with: "", options: .regularExpression).trimmingCharacters(
                in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

public enum PlaceSearch {
    public static func unique(_ places: [Place]) -> [Place] {
        var result: [Place] = []
        for place in places where place.coordinate.isValid {
            if let index = result.firstIndex(where: { samePlace($0, place) }) {
                // Keep the API ranking, but use the candidate with a useful line name.
                if detailRank(place) > detailRank(result[index]) { result[index] = place }
            } else {
                result.append(place)
            }
        }
        return result
    }
    private static func samePlace(_ first: Place, _ second: Place) -> Bool {
        guard normalized(first.displayName) == normalized(second.displayName), first.kind == second.kind else { return false }
        let radians = Double.pi / 180
        let lat = (second.lat - first.lat) * radians
        let lon = (second.lon - first.lon) * radians
        let h = pow(sin(lat / 2), 2) + cos(first.lat * radians) * cos(second.lat * radians) * pow(sin(lon / 2), 2)
        let meters = 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
        // Station feeds often put the same station at different platform/entrance points.
        return meters <= (first.kind == "station" ? 100 : 20)
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP")).components(
            separatedBy: .whitespacesAndNewlines
        ).joined()
    }
    private static func detailRank(_ place: Place) -> Int {
        if let name = place.feedName, !name.isEmpty { return 2 }
        return place.description?.contains("/") == true ? 1 : 0
    }
}

public struct TransitAPI: StationRoutingAPI {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func plan(origin: Coordinate, destination: Coordinate, now: Date, last: Bool = false) async throws -> [Trip] {
        try await plan(
            origin: origin, destination: destination, now: now, last: last, allowedModes: ["rail", "subway", "tram", "monorail"])
    }
    public func plan(origin: Coordinate, destination: Coordinate, now: Date, last: Bool, allowedModes: [String]) async throws
        -> [Trip]
    {
        guard origin.isValid, destination.isValid else { throw TransitError.invalidLocation }
        guard origin.isWithinJapanSearchBounds, destination.isWithinJapanSearchBounds else {
            throw TransitError.outsideServiceArea
        }
        let queryTime = last ? "23:59:59" : ServiceClock.date(now, format: "HH:mm:ss")
        let response: PlanResponse = try await get(
            path: "plan",
            query: [
                "from": origin.endpoint, "to": destination.endpoint, "type": last ? "arrival" : "departure",
                "date": ServiceClock.date(now, format: "yyyyMMdd"), "time": queryTime,
                "allowModes": allowedModes.joined(separator: ","), "numItineraries": last ? "1" : "3",
            ], timeout: last ? 15 : nil)
        return try RouteParser.trips(from: response)
    }
    public func places(query: String) async throws -> [Place] {
        struct Response: Decodable { let places: [Place] }
        let response: Response = try await get(path: "places/suggest", query: ["q": query, "limit": "10"])
        return PlaceSearch.unique(response.places)
    }
    public func reverse(coordinate: Coordinate) async throws -> [Place] {
        struct Response: Decodable { let places: [Place] }
        let response: Response = try await get(
            path: "places/reverse",
            query: ["lat": String(coordinate.latitude), "lon": String(coordinate.longitude), "limit": "1"])
        return response.places
    }
    public func nearbyStations(at coordinate: Coordinate) async throws -> [StationCandidate] {
        struct Nearby: Decodable { let places: [Place] }
        struct Matches: Decodable { let stations: [StationCandidate] }
        let nearby: Nearby = try await get(
            path: "places/reverse",
            query: [
                "lat": String(coordinate.latitude), "lon": String(coordinate.longitude), "limit": "10", "radiusMeters": "500",
            ], timeout: 8)
        var seenNames = Set<String>()
        let names = nearby.places.compactMap { place -> String? in
            guard place.kind == "station", seenNames.insert(place.displayName).inserted else { return nil }
            return place.displayName
        }.prefix(3)
        return await withTaskGroup(of: [StationCandidate].self) { group in
            for name in names {
                group.addTask {
                    do {
                        let matches: Matches = try await self.get(
                            path: "locations/suggest", query: ["q": name, "limit": "30"], timeout: 8)
                        return matches.stations.filter {
                            $0.kind == "station" && StationNameFormatter.displayName($0.name) == name
                                && $0.coordinate.map { $0.isValid && $0.distance(to: coordinate) <= 750 } == true
                        }
                    } catch { return [] }
                }
            }
            var found: [StationCandidate] = []
            for await stations in group { found += stations }
            var ids = Set<String>()
            return found.filter { ids.insert($0.id).inserted }.sorted { lhs, rhs in
                let leftWeight = lhs.weight ?? 0
                let rightWeight = rhs.weight ?? 0
                if leftWeight != rightWeight { return leftWeight > rightWeight }
                return lhs.id < rhs.id
            }
        }
    }
    public func stationPlan(from: String, to: String, boardingAfter: Date, serviceDate: Date, last: Bool) async throws -> [Trip] {
        let queryTime = last ? "23:59:59" : ServiceClock.date(boardingAfter, format: "HH:mm:ss")
        let response: PlanResponse = try await get(
            path: "plan",
            query: [
                "from": from, "to": to, "type": last ? "arrival" : "departure",
                "date": ServiceClock.date(serviceDate, format: "yyyyMMdd"), "time": queryTime,
                "allowModes": "rail,subway,tram,monorail", "numItineraries": last ? "1" : "3",
            ], timeout: 8)
        return try RouteParser.trips(from: response)
    }
    private func get<T: Decodable>(path: String, query: [String: String], timeout: TimeInterval? = nil) async throws -> T {
        guard var url = URLComponents(string: "https://api.transit.ls8h.com/api/v1/\(path)") else {
            throw TransitError.invalidResponse
        }
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let requestURL = url.url else { throw TransitError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout ?? (path == "plan" ? 60 : 30)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch let error as URLError {
            guard error.code != .timedOut else { throw TransitError.timedOut }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw TransitError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TransitError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
