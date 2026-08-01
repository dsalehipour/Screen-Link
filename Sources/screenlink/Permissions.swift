import ApplicationServices
import CoreGraphics
import Foundation

enum Permissions {
    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Both permissions are granted per-binary by cdhash. An ad-hoc signed build gets a new
    /// identity every rebuild, so a previously granted approval will not carry over.
    ///
    /// Screen recording is deliberately not preflighted here. CGPreflightScreenCaptureAccess
    /// reports false even when ScreenCaptureKit is capturing happily, so acting on it would prompt
    /// the user on every launch. Capture attempts the real API and requests access only if it fails.
    static func report() {
        let ax = hasAccessibility(prompt: false)
        Log.info("accessibility: \(ax ? "granted" : "DENIED")")
        if !ax {
            Log.warn("Requesting accessibility access; approve in System Settings > Privacy & Security > Accessibility.")
            _ = hasAccessibility(prompt: true)
        }
    }
}
