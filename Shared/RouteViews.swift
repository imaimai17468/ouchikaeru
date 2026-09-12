import SwiftUI

extension Color {
    static let ouchiGreen = Color(red: 0.05, green: 0.52, blue: 0.24)
    static let ouchiInk = Color(red: 0.04, green: 0.11, blue: 0.06)
    static let ouchiCream = Color(red: 0.97, green: 0.96, blue: 0.84)
}

/// A shared "way home" mark that remains legible at app icon, widget, and watch sizes.
struct OuchiMark: View {
    var body: some View {
        Canvas { context, canvasSize in
            let unit = min(canvasSize.width, canvasSize.height)
            let offsetX = (canvasSize.width - unit) / 2
            let offsetY = (canvasSize.height - unit) / 2
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: offsetX + unit * x, y: offsetY + unit * y) }

            var home = Path()
            home.move(to: point(0.08, 0.43))
            home.addQuadCurve(to: point(0.43, 0.11), control: point(0.24, 0.23))
            home.addQuadCurve(to: point(0.57, 0.11), control: point(0.50, 0.04))
            home.addQuadCurve(to: point(0.92, 0.43), control: point(0.76, 0.23))
            home.addLine(to: point(0.92, 0.79))
            home.addQuadCurve(to: point(0.79, 0.92), control: point(0.92, 0.92))
            home.addLine(to: point(0.21, 0.92))
            home.addQuadCurve(to: point(0.08, 0.79), control: point(0.08, 0.92))
            home.closeSubpath()
            context.fill(home, with: .color(.ouchiGreen))

            var route = Path()
            route.move(to: point(0.43, 0.98))
            route.addLine(to: point(0.43, 0.65))
            route.addLine(to: point(0.32, 0.65))
            route.addLine(to: point(0.50, 0.44))
            route.addLine(to: point(0.68, 0.65))
            route.addLine(to: point(0.57, 0.65))
            route.addLine(to: point(0.57, 0.98))
            route.closeSubpath()
            context.fill(route, with: .color(.ouchiCream))
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

struct OuchiPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 11).background(
            Color.ouchiGreen.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct StopRow: View {
    let stop: RouteStop
    let label: String
    let now: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ServiceClock.time(stop.time, relativeTo: now)).font(.title2.bold()).monospacedDigit()
            Text(stop.stationName).font(.headline)
            Spacer(minLength: 0)
            Text(label).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct WalkingLabel: View {
    let minutes: Int
    var body: some View { Label("徒歩 \(minutes)分", systemImage: "figure.walk").font(.subheadline).foregroundStyle(.secondary) }
}

struct LastTrainView: View {
    let summary: RouteSummary
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("終電", systemImage: "moon.stars.fill").font(.headline)
            Text(summary.lastTrainText(at: now)).font(.subheadline)
            if let last = summary.usableLastTrain(), last.leaveBy >= now {
                Text("\(ServiceClock.time(last.leaveBy, relativeTo: now)) までに出発").font(.caption).foregroundStyle(.secondary)
                Text("\(ServiceClock.time(last.arrival.time, relativeTo: now)) \(last.arrival.stationName) 着").font(.caption)
                WalkingLabel(minutes: last.walkToDestinationMinutes)
                Text("\(ServiceClock.time(last.finalArrivalTime, relativeTo: now)) \(summary.destination.name) 到着").font(
                    .subheadline.bold())
            }
        }
    }
}
