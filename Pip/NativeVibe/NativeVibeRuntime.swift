import Foundation

/// Distinguishes Pip-embedded vs standalone NativeVibe.app runtime behavior.
enum NativeVibeRuntime {
    private static let standaloneKey = "nativevibe.standalone"

    static var isStandalone: Bool {
        get { UserDefaults.standard.bool(forKey: standaloneKey) }
        set { UserDefaults.standard.set(newValue, forKey: standaloneKey) }
    }

    static func markStandalone() {
        isStandalone = true
    }
}