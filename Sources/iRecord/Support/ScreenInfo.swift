import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Lightweight description of a capturable display.
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    /// Frame in global Cocoa coordinates (bottom-left origin).
    let frame: CGRect
}

/// Lightweight description of a capturable window.
struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
}

enum ScreenInfo {
    /// Lists capturable on-screen windows via ScreenCaptureKit, filtered to real
    /// application windows (visible, reasonably sized, titled or named) and sorted
    /// by app then title. Requires Screen Recording permission.
    static func windows() async -> [WindowInfo] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let result: [WindowInfo] = content.windows.compactMap { win in
            guard win.isOnScreen else { return nil }
            // Skip tiny windows (menus, tooltips) and our own windows.
            guard win.frame.width >= 80, win.frame.height >= 80 else { return nil }
            if let app = win.owningApplication, app.processID == ownPID { return nil }
            let appName = win.owningApplication?.applicationName ?? "Unknown"
            guard !appName.isEmpty else { return nil }
            let title = (win.title?.isEmpty == false ? win.title! : appName)
            return WindowInfo(id: win.windowID, title: title, appName: appName)
        }
        return result.sorted {
            $0.appName == $1.appName ? $0.title < $1.title : $0.appName < $1.appName
        }
    }

    /// Maps each NSScreen to a DisplayInfo using its CGDirectDisplayID.
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            let name = screen.localizedName
            return DisplayInfo(id: id, name: name, frame: screen.frame)
        }
    }

    /// The CGDirectDisplayID of the screen that contains the given global point,
    /// or the main display if none match.
    static func displayID(containing point: CGPoint) -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            if screen.frame.contains(point),
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return CGDirectDisplayID(number.uint32Value)
            }
        }
        return CGMainDisplayID()
    }

    static func nsScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// Converts a rectangle in global Cocoa coordinates (bottom-left origin) to a
    /// display-local rectangle in top-left-origin points, which is what
    /// `SCStreamConfiguration.sourceRect` expects.
    static func sourceRect(forGlobalRect globalRect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        guard let screen = nsScreen(for: displayID) else { return globalRect }
        let displayFrame = screen.frame
        // Local origin within the display, bottom-left.
        let localX = globalRect.origin.x - displayFrame.origin.x
        let localYBottom = globalRect.origin.y - displayFrame.origin.y
        // Flip Y to top-left origin.
        let localYTop = displayFrame.height - (localYBottom + globalRect.height)
        return CGRect(x: localX, y: localYTop, width: globalRect.width, height: globalRect.height)
    }
}
