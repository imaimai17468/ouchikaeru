import SwiftUI
import WidgetKit

struct RouteEntry: TimelineEntry {
    let date: Date
    let summary: RouteSummary?
}

struct RouteProvider: TimelineProvider {
    func placeholder(in context: Context) -> RouteEntry { RouteEntry(date: .now, summary: nil) }
    func getSnapshot(in context: Context, completion: @escaping (RouteEntry) -> Void) {
        completion(RouteEntry(date: .now, summary: SharedStore().summary))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RouteEntry>) -> Void) {
        let now = Date(), summary = SharedStore().summary
        var dates = [now, now.addingTimeInterval(301)]
        if let summary {
            dates.append(summary.fetchedAt.addingTimeInterval(301))
            for trip in summary.upcomingTrips ?? summary.trip.map({ [$0] }) ?? [] {
                dates.append(trip.leaveBy.addingTimeInterval(1))
            }
            if let last = summary.usableLastTrain() { dates.append(last.leaveBy.addingTimeInterval(1)) }
        }
        let entries = Set(dates.filter { $0 >= now }).sorted().map { RouteEntry(date: $0, summary: summary) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }
}

struct RouteWidgetView: View {
    let entry: RouteEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let summary = entry.summary {
                switch family {
                case .systemSmall: SmallRouteWidget(summary: summary, now: entry.date)
                case .systemLarge: LargeRouteWidget(summary: summary, now: entry.date)
                default: MediumRouteWidget(summary: summary, now: entry.date)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        OuchiMark().frame(width: 22, height: 22)
                        Text("オウチカエル").font(.headline)
                    }
                    Text("iPhoneで目的地を登録して\n経路を取得してください。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.widgetURL(URL(string: "ouchikaeru://home")).containerBackground(Color.widgetSurface, for: .widget)
    }
}

private struct SmallRouteWidget: View {
    let summary: RouteSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            destinationLabel(summary.destination.name, markSize: 16, font: .caption.bold())
            if summary.isAtDestination {
                DestinationReachedWidget(compact: true)
            } else {
                if let trip = summary.trip(at: now) {
                    CompactJourney(title: "今出る", trip: trip, now: now)
                } else {
                    CompactUnavailableJourney(title: "今出る", text: "経路なし")
                }
                Divider()
                if let last = summary.usableLastTrain() {
                    CompactJourney(title: "終電", trip: last, now: now, isLast: true)
                } else {
                    CompactUnavailableJourney(title: "終電", text: summary.lastTrainText(at: now))
                }
            }
        }
    }
}

private struct MediumRouteWidget: View {
    let summary: RouteSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            destinationLabel(summary.destination.name, markSize: 20, font: .headline)
            if summary.isAtDestination {
                DestinationReachedWidget()
            } else {
                HStack(alignment: .top, spacing: 16) {
                    if let trip = summary.trip(at: now) {
                        DetailedJourney(title: "今出ると", trip: trip, now: now)
                    } else {
                        WidgetUnavailableJourney(title: "今出ると", text: "経路を取得できませんでした")
                    }
                    Divider()
                    if let last = summary.usableLastTrain() {
                        DetailedJourney(title: "終電", trip: last, now: now, isLast: true)
                    } else {
                        WidgetUnavailableJourney(title: "終電", text: summary.lastTrainText(at: now))
                    }
                }
            }
        }
    }
}

private struct LargeRouteWidget: View {
    let summary: RouteSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            destinationLabel(summary.destination.name, markSize: 24, font: .title3.bold())
            if summary.isAtDestination {
                DestinationReachedWidget()
            } else {
                if let trip = summary.trip(at: now) {
                    FullJourney(title: "今出ると", trip: trip, now: now)
                } else {
                    WidgetUnavailableJourney(title: "今出ると", text: "経路を取得できませんでした")
                }
                Divider()
                if let last = summary.usableLastTrain() {
                    FullJourney(title: "終電", trip: last, now: now, isLast: true)
                } else {
                    WidgetUnavailableJourney(title: "終電", text: summary.lastTrainText(at: now))
                }
            }
        }
    }
}

private struct DestinationReachedWidget: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            Label("目的地付近です", systemImage: "house.fill").font(compact ? .caption.bold() : .headline).foregroundStyle(
                Color.ouchiGreen)
            Text("経路案内は必要ありません").font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct CompactJourney: View {
    let title: String
    let trip: Trip
    let now: Date
    var isLast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                compactTime(isLast ? trip.leaveBy : now)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
                compactTime(trip.finalArrivalTime)
            }
            CompactRouteLine(trip: trip)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactTime(_ value: Date) -> some View {
        Text(ServiceClock.time(value, relativeTo: now).replacingOccurrences(of: "翌 ", with: "翌")).font(.subheadline.bold())
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).frame(
                maxWidth: .infinity, alignment: .center)
    }
}

private struct CompactRouteLine: View {
    let trip: Trip

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            compactStation(trip.departure.stationName, suffix: "発")
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
            WidgetTransferSummary(transfers: trip.transfers)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
            compactStation(trip.arrival.stationName, suffix: "着")
        }
    }

    private func compactStation(_ station: String, suffix: String) -> some View {
        Text("\(station) \(suffix)").font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.7)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }
}

private struct CompactUnavailableJourney: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.caption2).lineLimit(2).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailedJourney: View {
    let title: String
    let trip: Trip
    let now: Date
    var isLast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.bold())
            HStack(spacing: 5) {
                Text(ServiceClock.time(isLast ? trip.leaveBy : now, relativeTo: now)).font(.title3.bold()).monospacedDigit()
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(ServiceClock.time(trip.finalArrivalTime, relativeTo: now)).font(.title3.bold()).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .center)
            Text("徒歩\(trip.walkToStationMinutes)分").font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 6) {
                WidgetRailEndpoint(time: trip.departure.time, station: trip.departure.stationName, suffix: "発", now: now)
                WidgetTransferSummary(transfers: trip.transfers)
                WidgetRailEndpoint(time: trip.arrival.time, station: trip.arrival.stationName, suffix: "着", now: now)
            }
            Text("徒歩\(trip.walkToDestinationMinutes)分 → 到着").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FullJourney: View {
    let title: String
    let trip: Trip
    let now: Date
    var isLast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(ServiceClock.time(isLast ? trip.leaveBy : now, relativeTo: now)).font(.title2.bold()).monospacedDigit()
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(ServiceClock.time(trip.finalArrivalTime, relativeTo: now)).font(.title2.bold()).monospacedDigit()
            }
            HStack(spacing: 8) {
                WalkLeg(minutes: trip.walkToStationMinutes)
                WidgetRailEndpoint(time: trip.departure.time, station: trip.departure.stationName, suffix: "発", now: now)
                WidgetTransferSummary(transfers: trip.transfers)
                WidgetRailEndpoint(time: trip.arrival.time, station: trip.arrival.stationName, suffix: "着", now: now)
                WalkLeg(minutes: trip.walkToDestinationMinutes)
            }
            ForEach(Array(trip.transfers.enumerated()), id: \.offset) { _, transfer in
                Text(transferDescription(transfer)).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }

    private func transferDescription(_ transfer: Transfer) -> String {
        let arrival = "\(ServiceClock.time(transfer.arrival.time, relativeTo: now)) \(transfer.arrival.stationName) 着"
        let departure = "\(ServiceClock.time(transfer.departure.time, relativeTo: now)) 発"
        return "乗換  \(arrival) → \(departure)  ·  \(transfer.lineName)"
    }
}

private struct WalkLeg: View {
    let minutes: Int

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "figure.walk")
            Text("\(minutes)分").monospacedDigit()
        }.font(.caption2).foregroundStyle(.secondary).fixedSize()
    }
}

private struct WidgetUnavailableJourney: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Color {
    static var widgetSurface: Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.09, green: 0.12, blue: 0.095, alpha: 1)
                    : UIColor(red: 0.97, green: 0.98, blue: 0.94, alpha: 1)
            })
    }
}

private func destinationLabel(_ name: String, markSize: CGFloat, font: Font) -> some View {
    HStack(spacing: 6) {
        OuchiMark().frame(width: markSize, height: markSize)
        Text(name).font(font).lineLimit(1).minimumScaleFactor(0.8)
    }
}

private struct WidgetRailEndpoint: View {
    let time: Date
    let station: String
    let suffix: String
    let now: Date
    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(ServiceClock.time(time, relativeTo: now)).font(.caption.bold()).monospacedDigit()
            Text("\(station) \(suffix)").font(.caption2).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct WidgetTransferSummary: View {
    let transfers: [Transfer]

    var body: some View {
        Group {
            if transfers.isEmpty {
                Text("直通")
            } else if transfers.count == 1, let transfer = transfers.first {
                VStack(spacing: 1) {
                    Text(transfer.arrival.stationName).lineLimit(2)
                    Text("乗換").font(.caption2)
                }
            } else {
                Text("乗換\(transfers.count)件")
            }
        }.font(.caption2.bold()).foregroundStyle(.secondary).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}

@main struct OuchikaeruWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OuchikaeruRoute", provider: RouteProvider()) { RouteWidgetView(entry: $0) }
            .configurationDisplayName("オウチカエル").description("いつもの目的地への発車・到着・終電を確認します。").supportedFamilies([
                .systemSmall, .systemMedium, .systemLarge,
            ])
    }
}
