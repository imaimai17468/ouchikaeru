import SwiftUI

@main struct OuchikaeruWatchApp: App {
    @StateObject private var model = WatchRouteModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WatchHomeView(model: model).task { model.refreshOnActivation() }.onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshOnActivation() }
            }
        }
    }
}

private struct WatchHomeView: View {
    @ObservedObject var model: WatchRouteModel
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView { WatchRouteContent(state: model.state, now: context.date, refresh: model.refresh) }
        }.onReceive(refreshTimer) { date in model.refreshIfNeeded(at: date) }
    }
}

private struct WatchRouteContent: View {
    let state: RouteLoadState
    let now: Date
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .available(let summary): summaryContent(summary)
            case .loading(let previous, let phase):
                if let previous {
                    summaryContent(previous, notice: phase.message, noticeColor: Color.ouchiGreen)
                } else {
                    emptyContent(message: phase.message, isLoading: true)
                }
            case .unavailable(let previous, let message):
                if let previous {
                    summaryContent(previous, notice: message, noticeColor: .orange)
                } else {
                    emptyContent(message: message, isLoading: false)
                }
            case .failure(let previous, let message):
                if let previous {
                    summaryContent(previous, notice: message, noticeColor: .orange)
                } else {
                    emptyContent(message: message, isLoading: false)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }

    @ViewBuilder private func summaryContent(_ summary: RouteSummary, notice: String? = nil, noticeColor: Color = .secondary)
        -> some View
    {
        WatchDestinationHeader(name: summary.destination.name, isRefreshing: state.isLoading, refresh: refresh)
        if let notice { Text(notice).font(.caption2).foregroundStyle(noticeColor) }
        if summary.isStale(at: now) { Text("情報が古くなっています").font(.caption2).foregroundStyle(.orange) }
        if let trip = summary.trip(at: now) {
            WatchArrivalHero(trip: trip, destinationName: summary.destination.name, now: now)
            WatchRouteDetail(trip: trip, now: now)
        }
        WatchLastTrainSummary(summary: summary, now: now)
        Text(ServiceClock.updated(summary.fetchedAt)).font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private func emptyContent(message: String, isLoading: Bool) -> some View {
        OuchiMark().frame(width: 50, height: 50)
        Text("経路情報がありません").font(.headline)
        Button(action: refresh) { if isLoading { ProgressView() } else { Label("経路を取得", systemImage: "arrow.clockwise") } }
            .buttonStyle(.borderedProminent).tint(Color.ouchiGreen).disabled(isLoading)
        Text(message).font(.caption2).foregroundStyle(isLoading ? Color.secondary : Color.orange)
    }
}

private extension RouteLoadingPhase {
    var message: String {
        switch self {
        case .locating: return "現在地を取得中"
        case .preparing: return "駅と徒歩ルートを確認中"
        case .searching: return "経路を検索中"
        case .lastTrain: return "終電を確認中"
        }
    }
}

private struct WatchArrivalHero: View {
    let trip: Trip
    let destinationName: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("今出ると").font(.caption.weight(.semibold)).foregroundStyle(Color.ouchiGreen)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(ServiceClock.time(trip.finalArrivalTime, relativeTo: now)).font(
                    .system(size: 38, weight: .bold, design: .rounded)
                ).monospacedDigit().lineLimit(1).minimumScaleFactor(0.62)
                Text("到着").font(.caption.bold())
            }
            Text(destinationName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

private struct WatchRouteDetail: View {
    let trip: Trip
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("経路詳細").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 9) {
                Rectangle().fill(Color.ouchiGreen).frame(width: 2)
                VStack(alignment: .leading, spacing: 9) {
                    WatchWalkStep(label: "駅まで", minutes: trip.walkToStationMinutes)
                    WatchStopStep(stop: trip.departure, label: "発", now: now, emphasized: true)
                    ForEach(Array(trip.transfers.enumerated()), id: \.offset) { _, transfer in
                        WatchTransferStep(transfer: transfer, now: now)
                    }
                    WatchStopStep(stop: trip.arrival, label: "着", now: now, emphasized: true)
                    WatchWalkStep(label: "目的地まで", minutes: trip.walkToDestinationMinutes)
                }.padding(.vertical, 2)
            }
        }.padding(.top, 2)
    }
}

private struct WatchStopStep: View {
    let stop: RouteStop
    let label: String
    let now: Date
    let emphasized: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "tram.fill").font(.caption2).foregroundStyle(Color.ouchiGreen)
            Text(ServiceClock.time(stop.time, relativeTo: now)).font(.caption.weight(emphasized ? .bold : .regular))
                .monospacedDigit()
            Text("\(stop.stationName) \(label)").font(.caption.weight(emphasized ? .semibold : .regular)).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

private struct WatchWalkStep: View {
    let label: String
    let minutes: Int

    var body: some View {
        Label("\(label) 徒歩\(minutes)分", systemImage: "figure.walk").font(.caption2).foregroundStyle(.secondary)
    }
}

private struct WatchTransferStep: View {
    let transfer: Transfer
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(transfer.arrival.stationName)で乗換").font(.caption2.weight(.semibold)).foregroundStyle(Color.ouchiGreen)
            Text(
                "\(ServiceClock.time(transfer.arrival.time, relativeTo: now)) 着  →  \(ServiceClock.time(transfer.departure.time, relativeTo: now)) 発"
            ).font(.caption2).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

private struct WatchLastTrainSummary: View {
    let summary: RouteSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("終電").font(.caption2.weight(.semibold)).foregroundStyle(Color.ouchiGreen)
            if let last = summary.usableLastTrain(), last.leaveBy >= now {
                HStack(spacing: 5) {
                    Text(ServiceClock.time(last.departure.time, relativeTo: now)).font(.caption.bold()).monospacedDigit()
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(ServiceClock.time(last.finalArrivalTime, relativeTo: now)).font(.caption.bold()).monospacedDigit()
                }
                Text("\(last.departure.stationName) 発  ·  \(summary.destination.name) 到着").font(.caption2).foregroundStyle(
                    .secondary
                ).lineLimit(1)
            } else {
                Text(summary.lastTrainText(at: now)).font(.caption2).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct WatchDestinationHeader: View {
    let name: String
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            OuchiMark().frame(width: 22, height: 22)
            Text(name).font(.headline).lineLimit(1)
            Spacer(minLength: 2)
            Button(action: refresh) { if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") } }
                .buttonStyle(.plain).foregroundStyle(Color.ouchiGreen).frame(width: 34, height: 34).contentShape(Rectangle())
                .disabled(isRefreshing).accessibilityLabel("経路を更新")
        }
    }
}
