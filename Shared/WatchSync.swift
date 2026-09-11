import Combine
import Foundation
import WatchConnectivity

typealias WatchMessageReply = ([String: Any]) -> Void

final class WatchSync: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = WatchSync()
    @Published private(set) var summary = SharedStore().summary
    @Published private(set) var error: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isRequestingRefresh = false
    private var lastAutomaticRefreshRequest: Date?
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
            do {
                let data = try JSONEncoder().encode(SharedStore().summary)
                try session.updateApplicationContext(["summary": data])
                error = nil
            } catch { self.error = "Apple Watchへの同期を再試行します。" }
        #endif
    }
    func refreshIfNeeded(at now: Date = Date()) {
        #if os(watchOS)
            guard summary?.needsRefresh(at: now) != false, !isRequestingRefresh else { return }
            if let lastAutomaticRefreshRequest, now.timeIntervalSince(lastAutomaticRefreshRequest) < 60 { return }
            lastAutomaticRefreshRequest = now
            requestRefresh(announceQueuedRequest: false)
        #endif
    }
    func requestRefresh(announceQueuedRequest: Bool = true) {
        #if os(watchOS)
            let session = WCSession.default
            guard session.activationState == .activated else {
                error = "iPhoneとの接続を準備中です。"
                return
            }
            error = nil
            isRequestingRefresh = true
            let request = ["action": "refresh"]
            if session.isReachable {
                session.sendMessage(request) { _ in
                    DispatchQueue.main.async {
                        self.isRequestingRefresh = false
                        self.statusMessage = nil
                    }
                } errorHandler: { _ in
                    DispatchQueue.main.async { self.queueRefresh(request, session: session, announce: announceQueuedRequest) }
                }
            } else {
                queueRefresh(request, session: session, announce: announceQueuedRequest)
            }
        #endif
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            #if os(iOS)
                self.publish()
            #else
                self.receive(session.receivedApplicationContext)
            #endif
        }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.receive(applicationContext) }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping WatchMessageReply) {
        #if os(iOS)
            guard message["action"] as? String == "refresh" else {
                replyHandler(["accepted": false])
                return
            }
            Task { @MainActor in
                await self.refreshHandler?()
                replyHandler(["completed": true])
            }
        #endif
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        #if os(iOS)
            guard userInfo["action"] as? String == "refresh" else { return }
            Task { @MainActor in await self.refreshHandler?() }
        #endif
    }
    private func receive(_ context: [String: Any]) {
        #if os(watchOS)
            guard let data = context["summary"] as? Data else { return }
            do {
                let value = try JSONDecoder().decode(RouteSummary?.self, from: data)
                try SharedStore().save(summary: value)
                summary = value
                isRequestingRefresh = false
                statusMessage = nil
            } catch { self.error = "同期情報を読み取れませんでした。" }
        #endif
    }
    #if os(watchOS)
        private func queueRefresh(_ request: [String: Any], session: WCSession, announce: Bool) {
            session.transferUserInfo(request)
            isRequestingRefresh = false
            statusMessage = announce ? "更新を依頼しました" : nil
        }
    #endif
    #if os(iOS)
        func sessionDidBecomeInactive(_ session: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) { session.activate() }
        func sessionWatchStateDidChange(_ session: WCSession) { DispatchQueue.main.async { self.publish() } }
    #endif
}
