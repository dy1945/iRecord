import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import AppKit

/// Centralizes the two privacy permissions the app needs: Screen Recording and
/// (optionally) Microphone. macOS gates `SCStream` behind the Screen Recording
/// TCC entry; we probe it via `SCShareableContent` and, if denied, deep-link the
/// user into System Settings.
enum PermissionsManager {

    // MARK: Screen Recording

    /// Returns true if we currently have screen-recording access.
    static func hasScreenRecordingPermission() -> Bool {
        // CGPreflightScreenCaptureAccess reflects the live TCC decision.
        return CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system permission prompt for screen recording (first run only).
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        return CGRequestScreenCaptureAccess()
    }

    /// Authoritative async check: actually ask ScreenCaptureKit for content.
    static func verifyScreenRecordingPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: Microphone

    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophonePermission() async -> Bool {
        switch microphoneAuthorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: Deep links

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
