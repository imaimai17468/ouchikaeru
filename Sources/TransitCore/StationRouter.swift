import Foundation

public struct StationCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let lat: Double?
    public let lon: Double?
    public let kind: String?
    public let weight: Double?

    public init(id: String, name: String, lat: Double?, lon: Double?, kind: String?, weight: Double? = nil) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.kind = kind
        self.weight = weight
    }

    public var coordinate: Coordinate? {
        guard let lat, let lon else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
}

public protocol StationDiscovering: Sendable { func nearbyStations(at coordinate: Coordinate) async throws -> [StationCandidate] }

public protocol StationRoutingAPI: StationDiscovering {
    func stationPlan(from: String, to: String, boardingAfter: Date, serviceDate: Date, last: Bool) async throws -> [Trip]
    func plan(origin: Coordinate, destination: Coordinate, now: Date, last: Bool) async throws -> [Trip]
}

public protocol WalkingProviding: Sendable { func seconds(from: Coordinate, to: Coordinate) async throws -> TimeInterval }

public struct StationAccess: Sendable {
    public let station: StationCandidate
    public let seconds: TimeInterval
}

public struct StationSearchContext: Sendable {
    public let origin: Coordinate
    public let destination: Coordinate
    public let departures: [StationAccess]
    public let arrivals: [StationAccess]
}

private struct LocatedStation {
    let station: StationCandidate
    let coordinate: Coordinate
    let name: String
}

public struct StationPair: Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Holds only the current origin/destination station and walking data, never a location history.
public actor StationRouter {
    private let api: any StationRoutingAPI
    private let stationDiscovery: any StationDiscovering
    private let walking: any WalkingProviding
    private let clock: WallClock
    private struct EndCache {
        let anchor: Coordinate
        let walkAnchor: Coordinate
        let fetchedAt: Date
        let stations: [StationCandidate]
        var walks: [String: TimeInterval]
    }
    private var originCache: EndCache?
    private var destinationCache: EndCache?
    private struct LastCache {
        let origin: Coordinate
        let destination: Coordinate
        let fetchedAt: Date
        let trips: [Trip]
    }
    private var lastCache: LastCache?
    private struct PairKey: Hashable {
        let from: String
        let to: String
    }
    private struct PairCache {
        let origin: Coordinate
        let destination: Coordinate
        let fetchedAt: Date
        let pairs: [PairKey]
    }
    private var normalPairs: PairCache?
    private var lastPairs: PairCache?
    public init(
        api: any StationRoutingAPI, walking: any WalkingProviding, stationDiscovery: (any StationDiscovering)? = nil,
        clock: WallClock = .system
    ) {
        self.api = api
        self.stationDiscovery = stationDiscovery ?? api
        self.walking = walking
        self.clock = clock
    }

    public func prepare(origin: Coordinate, destination: Coordinate) async -> StationSearchContext? {
        guard origin.isWithinJapanSearchBounds, destination.isWithinJapanSearchBounds else { return nil }
        async let departures = resolve(at: origin, isOrigin: true)
        async let arrivals = resolve(at: destination, isOrigin: false)
        let (from, to) = await (departures, arrivals)
        guard !from.isEmpty, !to.isEmpty, from.count * to.count <= 36 else { return nil }
        return StationSearchContext(origin: origin, destination: destination, departures: from, arrivals: to)
    }

    private func resolve(at coordinate: Coordinate, isOrigin: Bool) async -> [StationAccess] {
        let cached = isOrigin ? originCache : destinationCache
        let checkedAt = clock.now()
        // GPS readings commonly drift by a few meters while the user is stationary. The
        // rounded walking allowance is stable within this range, so avoid repeating MapKit work.
        let valid =
            cached.map { $0.anchor.distance(to: coordinate) <= 100 && checkedAt.timeIntervalSince($0.fetchedAt) < 3600 } ?? false
        do {
            let stations: [StationCandidate]
            if valid, let cached {
                stations = cached.stations
            } else {
                let apiStations = (try? await api.nearbyStations(at: coordinate)) ?? []
                stations = apiStations.isEmpty ? try await stationDiscovery.nearbyStations(at: coordinate) : apiStations
            }
            guard !stations.isEmpty, stations.count <= 30, let station = nearestRepresentative(in: stations, to: coordinate)
            else { return [] }
            let canReuseWalks = valid && cached.map { $0.walkAnchor.distance(to: coordinate) <= 50 } == true
            var walks = canReuseWalks ? (cached?.walks ?? [:]) : [:]
            var result: [StationAccess] = []
            var missing: [String: Coordinate] = [:]
            if let point = station.coordinate, point.isValid, walks[point.endpoint] == nil { missing[point.endpoint] = point }
            let resolved = await withTaskGroup(of: (String, TimeInterval?).self) { group in
                for (key, point) in missing {
                    group.addTask {
                        let seconds = try? await self.walking.seconds(
                            from: isOrigin ? coordinate : point, to: isOrigin ? point : coordinate)
                        return (key, seconds)
                    }
                }
                var values: [String: TimeInterval] = [:]
                for await (key, seconds) in group { if let seconds { values[key] = seconds } }
                return values
            }
            walks.merge(resolved) { _, new in new }
            if let point = station.coordinate {
                let key = point.endpoint
                if let seconds = walks[key], seconds.isFinite, seconds >= 0, seconds <= 1800 {
                    // Round up to a whole minute and allow another minute to reach the platform.
                    let padded = ceil(seconds / 60) * 60 + (isOrigin ? 60 : 0)
                    result.append(StationAccess(station: station, seconds: padded))
                }
            }
            let saved = EndCache(
                anchor: valid ? (cached?.anchor ?? coordinate) : coordinate, walkAnchor: coordinate,
                fetchedAt: valid ? (cached?.fetchedAt ?? checkedAt) : clock.now(), stations: stations, walks: walks)
            if isOrigin { originCache = saved } else { destinationCache = saved }
            return result
        } catch { return [] }
    }

    public func plan(
        origin: Coordinate, destination: Coordinate, context: StationSearchContext?, now: Date, last: Bool,
        preferredPair: StationPair? = nil
    ) async throws -> [Trip] {
        guard origin.isWithinJapanSearchBounds, destination.isWithinJapanSearchBounds else {
            throw TransitError.outsideServiceArea
        }
        let currentTime = clock.now()
        if last, let cached = lastCache, cached.origin == origin, cached.destination == destination,
            now.timeIntervalSince(cached.fetchedAt) >= 0, now.timeIntervalSince(cached.fetchedAt) < 600,
            ServiceClock.calendar.isDate(cached.fetchedAt, inSameDayAs: now)
        {
            return cached.trips
        }
        var trips: [Trip] = []
        if let context, context.origin == origin, context.destination == destination {
            if let pair = matching(preferredPair, in: context) {
                let preferred = await search(pair, now: now, currentTime: currentTime, last: last, timeout: .seconds(2))
                if hasUsableTrip(preferred, now: currentTime, last: last) {
                    rememberPairs(preferred, context: context, now: now, last: last)
                    trips = preferred
                }
            }
            if trips.isEmpty {
                if last {
                    trips = await stationTrips(context, now: now, last: true)
                } else {
                    trips = try await fastestPlan(origin: origin, destination: destination, context: context, now: now)
                }
            }
        }
        if trips.isEmpty || (!last && RouteParser.recommended(trips, now: currentTime) == nil) {
            trips = try await api.plan(
                origin: origin, destination: destination, now: last ? now : max(now, currentTime), last: last)
            if let context { rememberPairs(trips, context: context, now: now, last: last) }
        }
        if last, !trips.isEmpty { lastCache = LastCache(origin: origin, destination: destination, fetchedAt: now, trips: trips) }
        return trips
    }

    private func matching(_ pair: StationPair?, in context: StationSearchContext) -> [(StationAccess, StationAccess)]? {
        guard let pair else { return nil }
        let matches = context.departures.flatMap { from in
            context.arrivals.compactMap { to in from.station.id == pair.from && to.station.id == pair.to ? (from, to) : nil }
        }
        if !matches.isEmpty { return matches }
        guard context.departures.count == 1, context.arrivals.count == 1, let from = context.departures.first,
            let to = context.arrivals.first
        else { return nil }
        return [(from.replacingStationID(with: pair.from), to.replacingStationID(with: pair.to))]
    }

    private func fastestPlan(origin: Coordinate, destination: Coordinate, context: StationSearchContext, now: Date) async throws
        -> [Trip]
    {
        enum Attempt: Sendable {
            case station([Trip])
            case coordinate(Result<[Trip], Error>)
        }
        let currentTime = clock.now()
        return try await withThrowingTaskGroup(of: Attempt.self) { group in
            group.addTask { .station(await self.stationTrips(context, now: now, last: false)) }
            group.addTask {
                do {
                    // Give the inexpensive station-ID plan a short head start. Slow
                    // comparisons then overlap the coordinate fallback instead of blocking it.
                    try await Task.sleep(for: .milliseconds(400))
                    let trips = try await self.api.plan(
                        origin: origin, destination: destination, now: max(now, currentTime), last: false)
                    return .coordinate(.success(trips))
                } catch { return .coordinate(.failure(error)) }
            }
            var coordinateError: Error?
            for try await attempt in group {
                switch attempt {
                case .station(let trips):
                    guard hasUsableTrip(trips, now: currentTime, last: false) else { continue }
                    group.cancelAll()
                    return trips
                case .coordinate(.success(let trips)):
                    guard hasUsableTrip(trips, now: currentTime, last: false) else { continue }
                    rememberPairs(trips, context: context, now: now, last: false)
                    group.cancelAll()
                    return trips
                case .coordinate(.failure(let error)): coordinateError = error
                }
            }
            if let coordinateError { throw coordinateError }
            return []
        }
    }

    private func stationTrips(_ context: StationSearchContext, now: Date, last: Bool) async -> [Trip] {
        let currentTime = clock.now()
        let allPairs = context.departures.flatMap { from in context.arrivals.map { (from, $0) } }
        func isReusable(_ cache: PairCache?) -> Bool {
            cache.map {
                $0.origin == context.origin && $0.destination == context.destination && now.timeIntervalSince($0.fetchedAt) >= 0
                    && now.timeIntervalSince($0.fetchedAt) < 300 && ServiceClock.calendar.isDate($0.fetchedAt, inSameDayAs: now)
            } ?? false
        }
        // A normal route has already selected a practical station pair. The
        // same pair is the best first choice for the last-train lookup.
        let cache = last && isReusable(lastPairs) ? lastPairs : normalPairs
        let reusable = isReusable(cache)
        let cachedPairs = cache?.pairs ?? []
        let preferred =
            reusable
            ? allPairs.filter { from, to in cachedPairs.contains(PairKey(from: from.station.id, to: to.station.id)) } : []
        let pairs = preferred.isEmpty ? allPairs : preferred
        let result = await search(pairs, now: now, currentTime: currentTime, last: last)
        if preferred.isEmpty { rememberPairs(result, context: context, now: now, last: last) }
        return result
    }

    private func search(
        _ pairs: [(StationAccess, StationAccess)], now: Date, currentTime: Date, last: Bool, timeout: Duration = .seconds(8)
    ) async -> [Trip] {
        await withTaskGroup(of: [Trip]?.self) { group in
            // A slow pair must not turn 36 bounded requests into a multi-minute wait.
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return nil
                } catch { return [] }
            }
            var next = 0
            func enqueue(_ index: Int) {
                let (from, to) = pairs[index]
                group.addTask {
                    guard from.station.id != to.station.id else { return [] }
                    do {
                        let queryTime = max(now, currentTime).addingTimeInterval(from.seconds)
                        // Normal searches crossing midnight must use the boarding service date.
                        let journeys = try await self.api.stationPlan(
                            from: from.station.id, to: to.station.id, boardingAfter: queryTime,
                            serviceDate: last ? now : queryTime, last: last)
                        return journeys.map { Self.addWalking(to: $0, access: from.seconds, egress: to.seconds) }
                    } catch TransitError.http(404) { return [] } catch { return last ? [] : nil }
                }
            }
            // Limit server load even at large stations with several feed-specific IDs.
            while next < min(4, pairs.count) {
                enqueue(next)
                next += 1
            }
            var result: [Trip] = []
            var completed = 0
            for await event in group {
                guard let trips = event else {
                    // A partial search can miss a much faster route (or the true last train).
                    group.cancelAll()
                    // Last-train coordinate searches can produce an overnight walking
                    // itinerary. Keep valid station-to-station results when available.
                    if last, !result.isEmpty { return result }
                    // For normal routes, compare again through the coordinate planner.
                    return []
                }
                result += trips
                completed += 1
                if completed == pairs.count {
                    group.cancelAll()
                    break
                }
                if next < pairs.count {
                    enqueue(next)
                    next += 1
                }
            }
            return result
        }
    }

    private func hasUsableTrip(_ trips: [Trip], now: Date, last: Bool) -> Bool {
        if last { return !trips.isEmpty }
        return RouteParser.recommended(trips, now: now) != nil
    }

    private func rememberPairs(_ trips: [Trip], context: StationSearchContext, now: Date, last: Bool) {
        let ordered = trips.sorted {
            if last { return $0.leaveBy > $1.leaveBy }
            if $0.finalArrivalTime != $1.finalArrivalTime { return $0.finalArrivalTime < $1.finalArrivalTime }
            return $0.walkToStationMinutes + $0.walkToDestinationMinutes < $1.walkToStationMinutes + $1.walkToDestinationMinutes
        }
        var seen = Set<PairKey>()
        let keys = ordered.compactMap { trip -> PairKey? in
            guard let from = trip.departure.stationID, let to = trip.arrival.stationID,
                context.departures.contains(where: { $0.station.id == from }),
                context.arrivals.contains(where: { $0.station.id == to })
            else { return nil }
            let key = PairKey(from: from, to: to)
            return seen.insert(key).inserted ? key : nil
        }
        if !keys.isEmpty {
            let saved = PairCache(
                origin: context.origin, destination: context.destination, fetchedAt: now, pairs: Array(keys.prefix(1)))
            if last { lastPairs = saved } else { normalPairs = saved }
        }
    }

    public static func addWalking(to trip: Trip, access: TimeInterval, egress: TimeInterval) -> Trip {
        var value = trip
        value.walkToStationMinutes += Int(ceil(access / 60))
        value.walkToDestinationMinutes += Int(ceil(egress / 60))
        value.leaveBy = trip.leaveBy.addingTimeInterval(-access)
        value.finalArrivalTime = trip.finalArrivalTime.addingTimeInterval(egress)
        return value
    }
}

private extension StationRouter {
    func nearestRepresentative(in stations: [StationCandidate], to coordinate: Coordinate) -> StationCandidate? {
        let valid = stations.compactMap { station -> LocatedStation? in
            guard let point = station.coordinate, point.isValid else { return nil }
            return LocatedStation(station: station, coordinate: point, name: StationNameFormatter.displayName(station.name))
        }
        guard
            let nearest = valid.min(by: { lhs, rhs in
                let leftDistance = lhs.coordinate.distance(to: coordinate)
                let rightDistance = rhs.coordinate.distance(to: coordinate)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.station.id < rhs.station.id
            })
        else { return nil }
        return valid.filter { $0.name == nearest.name }.map(\.station).min { lhs, rhs in
            let leftWeight = lhs.weight ?? 0
            let rightWeight = rhs.weight ?? 0
            if leftWeight != rightWeight { return leftWeight > rightWeight }
            return lhs.id < rhs.id
        }
    }
}

private extension StationAccess {
    func replacingStationID(with id: String) -> StationAccess {
        StationAccess(
            station: StationCandidate(
                id: id, name: station.name, lat: station.lat, lon: station.lon, kind: station.kind, weight: station.weight),
            seconds: seconds)
    }
}
