import Foundation
import WatchConnectivity

struct WatchContextPayload: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let destination: Destination?
    let summary: RouteSummary?

    init(destination: Destination?, summary: RouteSummary?) {
        version = Self.version
        self.destination = destination
        self.summary = summary
    }
}

enum CompanionRefreshRequest: Equatable {
    case sent
    case queued
    case unavailable
}

@MainActor protocol WatchContextCommunicating: AnyObject {
    var contextHandler: ((WatchContextPayload) -> Void)? { get set }
    func requestCompanionRefresh() -> CompanionRefreshRequest
}

@MainActor final class WatchSync: NSObject, WCSessionDelegate, WatchContextCommunicating {
    static let shared = WatchSync()
    var contextHandler: ((WatchContextPayload) -> Void)?
    #if os(iOS)
        var refreshHandler: (() async -> Void)?
    #endif

    override private init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish() {
        #if os(iOS)
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            let store = SharedStore()
            let payload = WatchContextPayload(destination: store.destination, summary: store.summary)
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? session.updateApplicationContext(["payload": data])
        #endif
    }

    func requestCompanionRefresh() -> CompanionRefreshRequest {
        #if os(watchOS)
            let session = WCSession.default
            guard session.activationState == .activated else { return .unavailable }
            let request = ["action": "refresh"]
            guard session.isReachable else {
                session.transferUserInfo(request)
                return .queued
            }
            session.sendMessage(request, replyHandler: nil) { _ in session.transferUserInfo(request) }
            return .sent
        #else
            return .unavailable
        #endif
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        Task { @MainActor in
            #if os(iOS)
                self.publish()
            #else
                self.receive(session.receivedApplicationContext)
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.receive(applicationContext) }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        #if os(iOS)
            Task { @MainActor in
                guard message["action"] as? String == "refresh" else {
                    replyHandler(["accepted": false])
                    return
                }
                await self.refreshHandler?()
                replyHandler(["completed": true])
            }
        #endif
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        #if os(iOS)
            Task { @MainActor in
                guard userInfo["action"] as? String == "refresh" else { return }
                await self.refreshHandler?()
            }
        #endif
    }

    private func receive(_ context: [String: Any]) {
        #if os(watchOS)
            guard let payload = Self.decode(context) else { return }
            contextHandler?(payload)
        #endif
    }

    private static func decode(_ context: [String: Any]) -> WatchContextPayload? {
        if let data = context["payload"] as? Data, let payload = try? JSONDecoder().decode(WatchContextPayload.self, from: data),
            payload.version == WatchContextPayload.version
        {
            return payload
        }
        guard let summaryData = context["summary"] as? Data else { return nil }
        let summary: RouteSummary?
        do { summary = try JSONDecoder().decode(RouteSummary?.self, from: summaryData) } catch { return nil }
        let destination =
            (context["destination"] as? Data).flatMap { try? JSONDecoder().decode(Destination?.self, from: $0) }
            ?? summary?.destination
        return WatchContextPayload(destination: destination, summary: summary)
    }

    #if os(iOS)
        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
        nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
        nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.publish() } }
    #endif
}
