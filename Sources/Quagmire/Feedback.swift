import AudioToolbox
import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
enum SoundFX {
    enum Effect: String {
        case pinchOpen = "pinch-open"
        case drop
        case delete
    }

    static func play(_ effect: Effect, enabled: Bool) {
        guard enabled, let id = soundID(for: effect) else { return }
        AudioServicesPlaySystemSound(id)
    }

    static func resourceURL(for effect: Effect) -> URL? {
        Bundle.module.url(forResource: effect.rawValue, withExtension: "caf")
    }

    private static var cache: [Effect: SystemSoundID] = [:]

    private static func soundID(for effect: Effect) -> SystemSoundID? {
        if let cached = cache[effect] { return cached }
        guard let url = resourceURL(for: effect) else { return nil }
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        cache[effect] = id
        return id
    }
}

private enum ImpactStyle: Hashable {
    case light
    case medium
    case heavy
}

#if os(iOS)
private extension ImpactStyle {
    var feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: .light
        case .medium: .medium
        case .heavy: .heavy
        }
    }
}
#endif

@MainActor
enum Haptics {
    #if os(iOS)
    private static var preparedImpactGenerators: [ImpactStyle: UIImpactFeedbackGenerator] = [:]
    #endif

    static func prepareLight(enabled: Bool) {
        prepare(.light, enabled: enabled)
    }

    static func light(enabled: Bool) {
        impact(.light, enabled: enabled)
    }

    static func medium(enabled: Bool) {
        impact(.medium, enabled: enabled)
    }

    static func heavy(enabled: Bool) {
        impact(.heavy, enabled: enabled)
    }

    private static func prepare(_ style: ImpactStyle, enabled: Bool) {
        #if os(iOS)
        guard enabled else {
            preparedImpactGenerators[style] = nil
            return
        }
        let generator = preparedImpactGenerators[style]
            ?? UIImpactFeedbackGenerator(style: style.feedbackStyle)
        preparedImpactGenerators[style] = generator
        generator.prepare()
        #endif
    }

    private static func impact(_ style: ImpactStyle, enabled: Bool) {
        guard enabled else { return }
        #if os(iOS)
        let generator = preparedImpactGenerators.removeValue(forKey: style)
            ?? UIImpactFeedbackGenerator(style: style.feedbackStyle)
        generator.impactOccurred()
        #endif
    }
}
