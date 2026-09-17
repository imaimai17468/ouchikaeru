import SwiftUI

private enum LegalURL {
    static let privacy = URL(string: "https://imaimai17468.github.io/ouchikaeru/privacy.html")
    static let terms = URL(string: "https://imaimai17468.github.io/ouchikaeru/terms.html")
}

struct HomeView: View {
    @ObservedObject var model: AppModel
    @State private var editing = false
    @State private var renaming = false
    @State private var showingSettings = false
    @State private var destinationName = ""
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let destination = model.destination {
                        HStack(alignment: .top, spacing: 14) {
                            OuchiMark().frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(destination.name).font(.title.bold()).accessibilityAddTraits(.isHeader)
                                if let address = destination.address, address != destination.name {
                                    Text(address).font(.subheadline).foregroundStyle(.secondary).fixedSize(
                                        horizontal: false, vertical: true)
                                }
                                HStack(spacing: 18) {
                                    Button("名前を変更") {
                                        destinationName = destination.name
                                        renaming = true
                                    }
                                    Button("住所を変更") { editing = true }
                                }.buttonStyle(.plain).foregroundStyle(Color.ouchiGreen).font(.subheadline.weight(.medium)).frame(
                                    minHeight: 44)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 0) {
                                Button("再読み込み", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.frame(
                                    width: 44, height: 44
                                ).contentShape(Rectangle()).disabled(model.isLoading)
                                Button("情報・規約", systemImage: "doc.text") { showingSettings = true }.frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Color.ouchiGreen).font(.title3)
                        }
                        if let summary = model.summary {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                if summary.isAtDestination {
                                    AtDestinationCard(destinationName: summary.destination.name)
                                } else {
                                    VStack(alignment: .leading, spacing: 24) {
                                        if let trip = summary.trip(at: context.date) {
                                            JourneyCard(
                                                trip: trip, destinationName: summary.destination.name, now: context.date,
                                                isStale: summary.isStale(at: context.date))
                                        } else {
                                            Text("現在利用できる経路がありません。").foregroundStyle(.secondary)
                                        }
                                        if model.isLoadingLastTrain {
                                            LastTrainLoadingCard()
                                        } else if let last = summary.usableLastTrain() {
                                            JourneyCard(
                                                trip: last, destinationName: summary.destination.name, now: context.date,
                                                isStale: summary.isStale(at: context.date), isLastTrain: true)
                                        } else {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Label("終電", systemImage: "moon.stars.fill").font(.headline)
                                                Text(summary.lastTrainText(at: context.date)).font(.subheadline)
                                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).flatCard()
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 24) {
                            OuchiMark().frame(width: 88, height: 88)
                            Text("いつもの場所へ、\nひと目でカエル。").font(.largeTitle.bold()).multilineTextAlignment(.center)
                            Text("目的地をひとつ登録すると、現在地からの発車・到着・終電がすぐにわかります。").foregroundStyle(.secondary).multilineTextAlignment(
                                .center)
                            CoverageNoticeCard()
                            Button("目的地を登録") { editing = true }.buttonStyle(OuchiPrimaryButtonStyle())
                            VStack(spacing: 6) {
                                Text("経路検索時に現在地と目的地の座標をTransit APIへ送信します。移動履歴は保存しません。").font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                if let privacyURL = LegalURL.privacy {
                                    Link("プライバシーポリシー", destination: privacyURL).font(.caption.weight(.medium))
                                }
                            }.padding(.top, 4)
                        }.frame(maxWidth: .infinity).padding(.vertical, 48)
                    }
                }.padding(24)
            }.background(Color.appCanvas).overlay {
                if model.isLoading { RouteLoadingPanel(message: model.loadingMessage, completedSteps: model.loadingStep) }
            }.safeAreaInset(edge: .top, spacing: 0) { if model.message != nil { errorPanel } }.fullScreenCover(
                isPresented: $editing
            ) { DestinationEditor(existing: model.destination, onSave: model.save).tint(Color.ouchiGreen) }.sheet(
                isPresented: $showingSettings
            ) { InformationView() }.alert("目的地の名前を変更", isPresented: $renaming) {
                TextField("自宅・会社など", text: $destinationName)
                Button("キャンセル", role: .cancel) {}
                Button("保存", action: saveDestinationName).disabled(
                    destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("住所はそのままで、表示する名前を変更します。")
            }.refreshable { await model.refresh() }.onReceive(refreshTimer) { date in
                if model.summary?.needsRefresh(at: date) == true, model.message == nil { Task { await model.refresh() } }
            }
        }
    }

    private func saveDestinationName() {
        guard var destination = model.destination else { return }
        destination.name = destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
        destination.updatedAt = Date()
        model.save(destination)
    }

    @ViewBuilder private var errorPanel: some View {
        if let message = model.message {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("更新できませんでした", systemImage: "exclamationmark.triangle.fill").font(.subheadline.bold()).foregroundStyle(
                        .red)
                    Text(message).font(.callout).accessibilityIdentifier("route-error-message")
                    if model.needsPermission {
                        Button("設定を開く") {
                            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(settingsURL)
                            }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                    Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }.padding(.horizontal, 24).padding(.vertical, 12).background(Color.appSurface).overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

}

private enum CoverageGuide {
    static let supported = "日本国内の鉄道・地下鉄・路面電車・モノレールのうち、Transit APIに交通データが収録されている路線"
    static let unavailable = "バスだけの地域、フェリー・航空の経路、交通データが未収録の路線では利用できません"
    static let slow = "駅から遠い場所、交通データが少ない地域、終電検索では、最大約1分かかる、または経路を取得できない場合があります"
}

private struct CoverageNoticeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("対応地域と制限", systemImage: "map.fill").font(.headline).foregroundStyle(Color.ouchiGreen)
            CoverageNoticeRow(title: "利用できる場所", detail: CoverageGuide.supported, symbol: "checkmark.circle.fill")
            Divider()
            CoverageNoticeRow(title: "利用できない経路", detail: CoverageGuide.unavailable, symbol: "xmark.circle.fill")
            CoverageNoticeRow(title: "時間がかかる場合", detail: CoverageGuide.slow, symbol: "clock.fill")
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).flatCard().multilineTextAlignment(.leading)
            .accessibilityElement(children: .combine).accessibilityIdentifier("coverage-notice-card")
    }
}

private struct CoverageNoticeRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.ouchiGreen).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AtDestinationCard: View {
    let destinationName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("目的地に到着しています", systemImage: "house.fill").font(.title3.bold()).foregroundStyle(Color.ouchiGreen)
            Text("現在地は「\(destinationName)」の近くです。経路案内は必要ありません。").font(.subheadline).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).flatCard().accessibilityElement(children: .combine)
            .accessibilityIdentifier("at-destination-card")
    }
}

private struct RouteLoadingPanel: View {
    let message: String
    let completedSteps: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.06).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(message).font(.subheadline.bold())
                    Spacer(minLength: 16)
                    Text("\(completedSteps) / 3").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: Double(completedSteps), total: 3).progressViewStyle(.linear).accessibilityIdentifier(
                    "route-loading-progress"
                ).accessibilityLabel("経路更新の進行状況").accessibilityValue(message)
            }.padding(16).frame(maxWidth: 270).flatCard(cornerRadius: 16)
        }.animation(.easeInOut(duration: 0.2), value: completedSteps)
    }
}

private struct LastTrainLoadingCard: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("終電", systemImage: "moon.stars.fill").font(.headline)
            Spacer(minLength: 12)
            Text("確認中").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).flatCard().accessibilityElement(children: .combine)
            .accessibilityLabel("終電を確認中").accessibilityIdentifier("last-train-loading-card")
    }
}

private struct JourneyCard: View {
    let trip: Trip
    let destinationName: String
    let now: Date
    let isStale: Bool
    var isLastTrain = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JourneyOverview(trip: trip, destinationName: destinationName, now: now, isStale: isStale, isLastTrain: isLastTrain)
            ZStack {
                Divider()
                Button(action: toggleDetails) {
                    HStack(spacing: 5) {
                        Text("経路詳細")
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                    }.padding(.horizontal, 10).background(Color.appSurface)
                }.buttonStyle(.plain).accessibilityValue(expanded ? "開いています" : "閉じています")
            }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
            RouteDetail(trip: trip, destinationName: destinationName, now: now, expanded: expanded).padding(
                .top, expanded ? 8 : 0)
        }.padding(18).flatCard()
    }

    private func toggleDetails() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.28)) { expanded.toggle() }
    }
}

private struct RouteDetail: View {
    let trip: Trip
    let destinationName: String
    let now: Date
    let expanded: Bool
    @State private var detailHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WalkingLabel(minutes: trip.walkToStationMinutes)
            StopRow(stop: trip.departure, label: "発", now: now)
            TransitBorder { Label(trip.lineName, systemImage: "tram.fill").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array(trip.transfers.enumerated()), id: \.offset) { _, transfer in
                TransferCard(transfer: transfer, now: now)
                TransitBorder {
                    Label(transfer.lineName, systemImage: "tram.fill").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            StopRow(stop: trip.arrival, label: "着", now: now)
            WalkingLabel(minutes: trip.walkToDestinationMinutes)
            HStack(alignment: .firstTextBaseline) {
                Text(ServiceClock.time(trip.finalArrivalTime, relativeTo: now)).font(.title2.bold()).monospacedDigit()
                Text(destinationName).font(.headline)
                Spacer(minLength: 0)
                Text("到着").foregroundStyle(.secondary)
            }
        }.background { GeometryReader { proxy in Color.clear.preference(key: DetailHeightKey.self, value: proxy.size.height) } }
            .frame(height: expanded ? detailHeight : 0, alignment: .top).clipped().onPreferenceChange(
                DetailHeightKey.self, perform: updateDetailHeight)
    }

    private func updateDetailHeight(_ height: CGFloat) { detailHeight = height }
}

private struct DetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TransferCard: View {
    let transfer: Transfer
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(transfer.arrival.stationName)で乗り換え", systemImage: "arrow.left.arrow.right").font(.subheadline.bold())
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ServiceClock.time(transfer.arrival.time, relativeTo: now)).font(.headline).monospacedDigit()
                Text("着").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Text(ServiceClock.time(transfer.departure.time, relativeTo: now)).font(.headline).monospacedDigit()
                Text("発").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.appCanvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TransitBorder<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }.padding(.leading, 14).padding(.vertical, 4).overlay(
            alignment: .leading
        ) { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 3) }
    }
}

private struct JourneyOverview: View {
    let trip: Trip
    let destinationName: String
    let now: Date
    let isStale: Bool
    var isLastTrain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                endpoint(
                    label: isLastTrain ? "終電" : "今出ると", time: (isStale || isLastTrain) ? trip.leaveBy : now, place: "現在地",
                    color: .primary, identifier: nil)
                Image(systemName: "arrow.right").font(.title3.bold()).foregroundStyle(.tertiary)
                endpoint(
                    label: "到着", time: trip.finalArrivalTime, place: destinationName, color: .primary,
                    identifier: isLastTrain ? "last-train-arrival-time" : "final-arrival-time")
            }
            HStack(alignment: .center, spacing: 5) {
                railEndpoint(time: trip.departure.time, station: trip.departure.stationName, suffix: "発")
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
                transferNode
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
                railEndpoint(time: trip.arrival.time, station: trip.arrival.stationName, suffix: "着")
            }
            HStack(spacing: 8) {
                Label("駅まで徒歩\(trip.walkToStationMinutes)分", systemImage: "figure.walk")
                Spacer(minLength: 8)
                Label("降車後徒歩\(trip.walkToDestinationMinutes)分", systemImage: "figure.walk")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func endpoint(label: String, time: Date, place: String, color: Color, identifier: String?) -> some View {
        VStack(alignment: .center, spacing: 5) {
            Text(label).font(.caption.bold()).foregroundStyle(Color.ouchiGreen)
            Text(ServiceClock.time(time, relativeTo: now)).font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).accessibilityIdentifier(identifier ?? "")
            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.foregroundStyle(color).frame(maxWidth: .infinity, alignment: .center)
    }

    private func railEndpoint(time: Date, station: String, suffix: String) -> some View {
        VStack(alignment: .center, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "tram.fill").foregroundStyle(Color.ouchiGreen)
                Text(ServiceClock.time(time, relativeTo: now)).monospacedDigit()
            }.font(.subheadline.bold())
            Text("\(station) \(suffix)").font(.caption).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder private var transferNode: some View {
        VStack(spacing: 2) {
            if trip.transfers.isEmpty {
                Text("直通")
            } else if trip.transfers.count == 1, let transfer = trip.transfers.first {
                Text(transfer.arrival.stationName)
                Text("乗換").font(.system(size: 9))
            } else {
                Text("乗換")
                Text("\(trip.transfers.count)件").font(.system(size: 9))
            }
        }.font(.caption2.bold()).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize()
    }

}

private extension Color {
    static var appCanvas: Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.055, green: 0.075, blue: 0.06, alpha: 1)
                    : UIColor(red: 0.94, green: 0.96, blue: 0.91, alpha: 1)
            })
    }
    static var appSurface: Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.09, green: 0.12, blue: 0.095, alpha: 1)
                    : UIColor(red: 0.99, green: 0.99, blue: 0.965, alpha: 1)
            })
    }
    static var appStroke: Color { Color.ouchiGreen.opacity(0.18) }
}

private extension View {
    func flatCard(cornerRadius: CGFloat = 14) -> some View {
        background(Color.appSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)).overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.appStroke, lineWidth: 1)
        }
    }
}

private struct InformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("法的情報") {
                    if let privacyURL = LegalURL.privacy { Link("プライバシーポリシー", destination: privacyURL) }
                    if let termsURL = LegalURL.terms { Link("利用規約", destination: termsURL) }
                }
                Section("位置情報について") {
                    Text(
                        """
                        現在地と目的地の座標をTransit APIへ送信して駅・経路を検索し、Appleの地図サービスで駅までの徒歩ルートを調べます。\
                        目的地と最後に取得した経路は端末に保存し、WidgetとペアリングしたApple Watchで表示します。\
                        移動履歴の保存や常時GPS追跡は行いません。
                        """)
                }
                Section("交通情報") {
                    Text("時刻は予定時刻です。運行状況やデータの収録範囲によって、実際と異なる場合があります。WidgetとWatchでは最後に取得した情報を表示します。")
                    if let apiURL = URL(string: "https://api.transit.ls8h.com/") {
                        Link("Transit API・データ提供元", destination: apiURL)
                    }
                    if let feedsURL = URL(string: "https://api.transit.ls8h.com/api/v1/feeds") {
                        Link("交通データのライセンス・帰属", destination: feedsURL)
                    }
                }
                Section("対応地域と制限") {
                    CoverageNoticeRow(title: "利用できる場所", detail: CoverageGuide.supported, symbol: "checkmark.circle.fill")
                    CoverageNoticeRow(title: "利用できない経路", detail: CoverageGuide.unavailable, symbol: "xmark.circle.fill")
                    CoverageNoticeRow(title: "時間がかかる場合", detail: CoverageGuide.slow, symbol: "clock.fill")
                }
            }.scrollContentBackground(.hidden).background(Color.appCanvas).navigationTitle("情報").navigationBarTitleDisplayMode(
                .inline
            ).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる", systemImage: "xmark") { dismiss() } } }
        }
    }
}
