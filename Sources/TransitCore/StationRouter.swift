import Foundation

public struct StationCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let lat: Double?
    public let lon: Double?
    public let kind: String?
    public var coordinate: Coordinate? {
        guard let lat, let lon else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
}

public protocol StationRoutingAPI: Sendable {
    func nearbyStations(at coordinate: Coordinate) async throws -> [StationCandidate]
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

/// Holds only the current origin/destination station and walking data, never a location history.
public actor StationRouter {
    private let api: any StationRoutingAPI
    private let walking: any WalkingProviding
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
    public init(api: any StationRoutingAPI, walking: any WalkingProviding) {
        self.api = api
        self.walking = walking
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
        // Reuse nearby station discovery, but recalculate walking after any coordinate change.
        let valid =
            cached.map { $0.anchor.distance(to: coordinate) <= 100 && Date().timeIntervalSince($0.fetchedAt) < 3600 } ?? false
        do {
            let stations: [StationCandidate]
            if valid, let cached { stations = cached.stations } else { stations = try await api.nearbyStations(at: coordinate) }
            guard !stations.isEmpty, stations.count <= 30 else { return [] }
            var walks = valid && cached?.walkAnchor == coordinate ? (cached?.walks ?? [:]) : [:]
            var result: [StationAccess] = []
            // Feed-specific station IDs can share coordinates: calculate that walk only once.
            var missing: [String: Coordinate] = [:]
            for station in stations {
                if let point = station.coordinate, point.isValid, walks[point.endpoint] == nil { missing[point.endpoint] = point }
            }
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
            for station in stations {
                guard let point = station.coordinate else { continue }
                let key = point.endpoint
                guard let seconds = walks[key], seconds.isFinite, seconds >= 0, seconds <= 1800 else { continue }
                // Round up to a whole minute and allow another minute to reach the platform.
                let padded = ceil(seconds / 60) * 60 + (isOrigin ? 60 : 0)
                result.append(StationAccess(station: station, seconds: padded))
            }
            let saved = EndCache(
                anchor: valid ? (cached?.anchor ?? coordinate) : coordinate, walkAnchor: coordinate,
                fetchedAt: valid ? (cached?.fetchedAt ?? Date()) : Date(), stations: stations, walks: walks)
            if isOrigin { originCache = saved } else { destinationCache = saved }
            return result
        } catch { return [] }
    }

    public func plan(origin: Coordinate, destination: Coordinate, context: StationSearchContext?, now: Date, last: Bool)
        async throws -> [Trip]
    {
        guard origin.isWithinJapanSearchBounds, destination.isWithinJapanSearchBounds else {
            throw TransitError.outsideServiceArea
        }
        if last, let cached = lastCache, cached.origin == origin, cached.destination == destination,
            now.timeIntervalSince(cached.fetchedAt) >= 0, now.timeIntervalSince(cached.fetchedAt) < 600,
            ServiceClock.calendar.isDate(cached.fetchedAt, inSameDayAs: now)
        {
            return cached.trips
        }
        var trips: [Trip] = []
        if let context, context.origin == origin, context.destination == destination {
            trips = await stationTrips(context, now: now, last: last)
        }
        if trips.isEmpty || (!last && RouteParser.recommended(trips, now: Date()) == nil) {
            trips = try await api.plan(origin: origin, destination: destination, now: last ? now : max(now, Date()), last: last)
            if let context { rememberPairs(trips, context: context, now: now, last: last) }
        }
        if last, !trips.isEmpty { lastCache = LastCache(origin: origin, destination: destination, fetchedAt: now, trips: trips) }
        return trips
    }

    private func stationTrips(_ context: StationSearchContext, now: Date, last: Bool) async -> [Trip] {
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
        let result: [Trip] = await withTaskGroup(of: [Trip]?.self) { group in
            // A slow pair must not turn 36 bounded requests into a multi-minute wait.
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(8))
                    return nil
                } catch { return [] }
            }
            var next = 0
            func enqueue(_ index: Int) {
                let (from, to) = pairs[index]
                group.addTask {
                    guard from.station.id != to.station.id else { return [] }
                    do {
                        let queryTime = max(now, Date()).addingTimeInterval(from.seconds)
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
        if preferred.isEmpty { rememberPairs(result, context: context, now: now, last: last) }
        return result
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
