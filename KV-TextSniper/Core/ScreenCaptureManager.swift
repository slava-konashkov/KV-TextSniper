//
//  ScreenCaptureManager.swift
//  KV-TextSniper
//
//  Captures a region of the screen as a CGImage.
//
//  We use `CGWindowListCreateImage` because it is available on all
//  supported macOS versions and works fine for sandboxed apps that
//  hold the Screen Recording TCC permission (granted by the user the
//  first time the app captures the screen).
//
//  `CGWindowListCreateImage` is deprecated in macOS 15, but still
//  functional — the modern replacement is `ScreenCaptureKit`. Switching
//  to SCKit is a future enhancement; see README.
//

import AppKit
import CoreGraphics

enum ScreenCaptureManager {
    /// Captures a rectangle of the screen in global Core Graphics coordinates
    /// (top-left origin, Y grows downward).
    static func captureScreenRegion(_ rect: CGRect) -> CGImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        // Exclude the desktop-picture window so we always get pixels from real
        // windows (matters when the selection crosses an empty desktop area).
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

        let image = CGWindowListCreateImage(
            rect,
            options,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
        return image
    }
}
