import AppIntents
import Foundation

public enum VoiceRecordingLaunchRequest {
    public static let notificationName = Notification.Name("QuagmireExtrasVoiceRecordingLaunchRequest")
    private static let pendingStartKey = "quagmireExtras.pendingVoiceRecordingStart"

    @MainActor
    public static func requestStart() {
        UserDefaults.standard.set(true, forKey: pendingStartKey)
        NotificationCenter.default.post(name: notificationName, object: nil)
    }

    @MainActor
    public static func consumePendingStart() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingStartKey) else { return false }
        UserDefaults.standard.set(false, forKey: pendingStartKey)
        return true
    }
}

public struct StartVoiceRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Voice Recording"
    public static let description = IntentDescription("Open the app and start recording a voice note.")
    public static let supportedModes: IntentModes = .foreground(.immediate)
    public static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    public static let openAppWhenRun = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        await VoiceRecordingLaunchRequest.requestStart()
        return .result()
    }
}

public struct QuagmireExtrasAppIntents: AppIntentsPackage {
    public init() {}
}
