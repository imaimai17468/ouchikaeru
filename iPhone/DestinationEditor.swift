import MapKit
import SwiftUI

struct DestinationEditor: View {
    let existing: Destination?
    let onSave: (Destination) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedName: String?
    @State private var address: String?
    @State private var coordinate: Coordinate?
    @State private var places: [Place] = []
    @State private var message: String?
    @State private var searching = false
    @State private var resolving = false
    @State private var selectionID = UUID()
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767),
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)))

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    if let coordinate {
                        Marker(
                            address ?? "選択した場所",
                            coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        ).tint(Color.ouchiGreen)
                    }
                }.mapStyle(.standard(emphasis: .muted)).onTapGesture { point in
                    guard let selected = proxy.convert(point, from: .local) else { return }
                    searchFocused = false
                    query = ""
                    coordinate = Coordinate(latitude: selected.latitude, longitude: selected.longitude)
                    selectedName = nil
                    address = nil
                    message = nil
                    selectionID = UUID()
                }.overlay(alignment: .top) { searchPanel.padding(16) }.safeAreaInset(edge: .bottom, spacing: 0) { selectionPanel }
                    .task(id: selectionID) {
                        guard let coordinate, address == nil else { return }
                        let requestID = selectionID
                        resolving = true
                        defer { if requestID == selectionID { resolving = false } }
                        do {
                            let results = try await TransitAPI().reverse(coordinate: coordinate)
                            try Task.checkCancellation()
                            if let place = results.first {
                                selectedName = place.displayName
                                address = place.displayAddress
                            }
                            if address == nil { address = await geocodedAddress(for: coordinate) }
                            if address == nil { address = coordinateFallback(for: coordinate) }
                            if selectedName == nil { selectedName = address }
                        } catch {
                            guard !Task.isCancelled else { return }
                            address = await geocodedAddress(for: coordinate)
                            if address == nil { address = coordinateFallback(for: coordinate) }
                            selectedName = address
                        }
                    }
            }.navigationTitle(existing == nil ? "帰る場所を登録" : "住所を変更").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("閉じる", systemImage: "xmark") { dismiss() } }
            }.onAppear {
                if let existing {
                    selectedName = existing.name
                    address = existing.address ?? existing.name
                    coordinate = existing.coordinate
                    moveCamera(to: existing.coordinate)
                }
            }.task(id: query) {
                places = []
                message = nil
                searching = false
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    searching = true
                    var results = try await TransitAPI().places(query: text)
                    try Task.checkCancellation()
                    if results.isEmpty { results = try await mapPlaces(query: text) }
                    places = results
                    searching = false
                    if results.isEmpty { message = "住所が見つかりませんでした。別の住所でお試しください。" }
                } catch {
                    guard !Task.isCancelled else { return }
                    do {
                        let fallback = try await mapPlaces(query: text)
                        guard !Task.isCancelled else { return }
                        places = fallback
                        searching = false
                        if fallback.isEmpty { message = "住所が見つかりませんでした。別の住所でお試しください。" }
                    } catch {
                        guard !Task.isCancelled else { return }
                        searching = false
                        message = "検索できませんでした。もう一度お試しください。"
                    }
                }
            }
        }
    }

    private func geocodedAddress(for coordinate: Coordinate) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let marks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let mark = marks.first else { return nil }
            let addressParts = [
                mark.administrativeArea, mark.locality, mark.subLocality, mark.thoroughfare, mark.subThoroughfare,
            ]
            return addressParts.compactMap { $0 }.joined(separator: " ")
        } catch { return nil }
    }

    private func coordinateFallback(for coordinate: Coordinate) -> String {
        let lat = coordinate.latitude.formatted(.number.precision(.fractionLength(4)))
        let lon = coordinate.longitude.formatted(.number.precision(.fractionLength(4)))
        return "選択した地点（\(lat), \(lon)）"
    }

    private func mapPlaces(query: String) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767),
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8))
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            guard let location = item.placemark.location else { return nil }
            let name = item.name ?? item.placemark.name ?? query
            let detail = [
                item.placemark.postalCode, item.placemark.administrativeArea, item.placemark.locality,
                item.placemark.thoroughfare, item.placemark.subThoroughfare,
            ].compactMap { $0 }.joined(separator: " ")
            return Place(
                id: "map-\(location.coordinate.latitude)-\(location.coordinate.longitude)-\(name)", name: name,
                description: detail.isEmpty ? nil : detail, lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                kind: "address", feedName: "Apple Maps")
        }
    }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("目的地の住所を入力", text: $query).focused($searchFocused).submitLabel(.search).onSubmit {
                    searchFocused = false
                }.autocorrectionDisabled()
                if searching { ProgressView() }
                if !query.isEmpty {
                    Button("検索をクリア", systemImage: "xmark.circle.fill") { query = "" }.foregroundStyle(.secondary).labelStyle(
                        .iconOnly)
                }
            }.padding(16)
            if !places.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(places) { place in
                            Button {
                                selectionID = UUID()
                                coordinate = place.coordinate
                                selectedName = place.displayName
                                address = place.displayAddress
                                resolving = false
                                query = ""
                                places = []
                                searchFocused = false
                                moveCamera(to: place.coordinate)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "mappin.circle.fill").foregroundStyle(Color.ouchiGreen)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(place.displayName).foregroundStyle(.primary)
                                        Text(place.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("place-result-\(place.id)")
                            Divider().padding(.leading, 48)
                        }
                    }
                }.frame(maxHeight: 240).scrollDismissesKeyboard(.interactively)
            }
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).shadow(
            color: .black.opacity(0.1), radius: 16, y: 6)
    }

    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if resolving {
                ProgressView("この場所の住所を確認中")
            } else if let address {
                Label("目的地の住所", systemImage: "mappin.and.ellipse").font(.caption.bold()).foregroundStyle(.secondary)
                Text(address).font(.headline).lineLimit(3)
                Text("名前は登録後に「自宅」などに変更できます。").font(.caption).foregroundStyle(.secondary)
                Button {
                    guard let coordinate else { return }
                    let sameLocation = existing?.coordinate == coordinate
                    let name = sameLocation ? (existing?.name ?? selectedName ?? address) : (selectedName ?? address)
                    onSave(
                        Destination(
                            id: existing?.id ?? UUID(), name: name, address: address, coordinate: coordinate,
                            createdAt: existing?.createdAt ?? Date()))
                    dismiss()
                } label: {
                    Text("この住所を登録").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(OuchiPrimaryButtonStyle()).disabled(coordinate?.isValid != true)
            } else {
                Label("帰る場所はどこですか？", systemImage: "house.fill").font(.headline)
                Text("住所を検索すると、地図で場所を確認できます。地図をタップして選ぶこともできます。").font(.subheadline).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(
            .regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
    }

    private func moveCamera(to coordinate: Coordinate) {
        withAnimation {
            camera = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)))
        }
    }
}
