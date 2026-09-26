import Observation
import SwiftUI
import UIKit

/// Local privacy signal only. It is not proof of every screenshot and is not sent to a peer.
struct PrivacyEvent: Codable, Identifiable {
    enum Kind: String, Codable { case screenshotDetected }
    let id: UUID
    let kind: Kind
    let timestamp: Date
    let conversationID: UUID?
}

struct ScreenshotMonitor {
    func event(enabled: Bool, conversationID: UUID?) -> PrivacyEvent? {
        guard enabled else { return nil }
        return PrivacyEvent(id: UUID(), kind: .screenshotDetected, timestamp: .now,
                            conversationID: conversationID)
    }
}

struct ScreenCaptureMonitor {
    /// iOS reports screen recording, mirroring and AirPlay capture through this signal.
    func isCaptured() -> Bool { UIScreen.main.isCaptured }
}

struct BackgroundPrivacyManager {
    func shouldHide(scenePhase: ScenePhase, enabled: Bool, sensitiveConversationVisible: Bool) -> Bool {
        scenePhase != .active && (enabled || sensitiveConversationVisible)
    }
}

@MainActor @Observable
final class PrivacyShieldManager {
    private(set) var isCaptured = false
    private(set) var screenshotCount = 0
    private(set) var latestEvent: PrivacyEvent?
    private(set) var scenePhase: ScenePhase = .active
    private(set) var visibleSensitiveConversationID: UUID?
    private let screenshots = ScreenshotMonitor()
    private let capture = ScreenCaptureMonitor()
    private let background = BackgroundPrivacyManager()

    func screenshotObserved(enabled: Bool) {
        screenshotCount += 1
        latestEvent = screenshots.event(enabled: enabled, conversationID: visibleSensitiveConversationID)
    }

    func refreshCaptureState() { isCaptured = capture.isCaptured() }
    func setScenePhase(_ phase: ScenePhase) { scenePhase = phase; if phase == .active { refreshCaptureState() } }
    func setVisibleConversation(_ id: UUID?, protected: Bool) {
        visibleSensitiveConversationID = protected ? id : nil
    }

    func shouldMask(captureProtection: Bool, backgroundEnabled: Bool) -> Bool {
        (captureProtection && isCaptured) || background.shouldHide(scenePhase: scenePhase,
            enabled: backgroundEnabled, sensitiveConversationVisible: visibleSensitiveConversationID != nil)
    }

    func allowsNotificationPreview(for conversation: Conversation, preferences: PrivacyPreferences) -> Bool {
        conversation.requiresPrivacyShield != true && conversation.requiresUnlock != true &&
        preferences.effectiveMessagePreviews
    }
}
