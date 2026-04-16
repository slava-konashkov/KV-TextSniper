//
//  ScreenSelectionController.swift
//  KV-TextSniper
//
//  Puts a semi-transparent overlay across every screen, lets the user
//  drag a rectangle, then reports the selected rect back in global
//  screen coordinates (Core Graphics "flipped" coordinates — origin
//  at top-left of the primary display, Y grows downward).
//

import AppKit
import os

/// Tiny UserDefaults-backed preferences store shared with the Settings UI.
enum Preferences {
    private static let dimBackgroundKey = "KVTS.dimBackground"

    /// Whether the selection overlay should dim the rest of the screen
    /// while the user drags a rectangle. Defaults to `true`.
    static var dimBackground: Bool {
        get {
            if UserDefaults.standard.object(forKey: dimBackgroundKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: dimBackgroundKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: dimBackgroundKey)
        }
    }
}

final class ScreenSelectionController {

    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [SelectionWindow] = []
    /// Prevents `finish(with:cancelled:)` from running twice — mouseUp from
    /// two overlays (rare, but possible on multi-display setups), or an Escape
    /// keyDown arriving while a mouseUp is still being processed, can both
    /// trigger the callback. We don't want to tear down a second time.
    private var hasFinished = false

    func begin() {
        // Create one overlay window per screen so the selection covers
        // every display including external monitors.
        windows = NSScreen.screens.map { screen in
            let window = SelectionWindow(screen: screen)
            window.onFinish = { [weak self] globalRect, cancelled in
                self?.finish(with: globalRect, cancelled: cancelled)
            }
            return window
        }
        Log.selection.notice("begin: \(self.windows.count) overlay window(s)")

        // Ensure the app is focused so key events reach us.
        NSApp.activate(ignoringOtherApps: true)

        // Push the crosshair onto the global cursor stack. Unlike NSCursor.set(),
        // push applies immediately even if our .accessory app hasn't been brought
        // fully to front yet — otherwise the cursor wouldn't switch to crosshair
        // until the user clicked inside the overlay. Paired with pop() in finish().
        NSCursor.crosshair.push()

        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(with globalRect: CGRect?, cancelled: Bool) {
        guard !hasFinished else {
            Log.selection.notice("finish: ignored — already finished")
            return
        }
        hasFinished = true
        Log.selection.notice("finish: cancelled=\(cancelled, privacy: .public) rect=\(globalRect?.debugDescription ?? "nil", privacy: .public) windows=\(self.windows.count)")

        // Neutralise every overlay window: pop the crosshair we pushed in
        // begin() and drop the windows from the window list. We deliberately
        // keep this simple — no `close()`, no `ignoresMouseEvents` toggles —
        // because layering extra teardown steps on `.screenSaver`-level
        // windows has caused WindowServer hangs.
        NSCursor.pop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        // Wait a couple of display frames so WindowServer has fully drained
        // the overlay teardown before the screenshot is taken — a single
        // runloop hop (`async`) has proven insufficient in practice; without
        // this delay CGWindowListCreateImage sometimes still composites the
        // dimmed layer into the returned image.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            if cancelled {
                self.onCancel?()
            } else if let rect = globalRect {
                self.onSelection?(rect)
            } else {
                self.onCancel?()
            }
        }
    }
}

// MARK: - Selection window

/// One of these per display. The visible content is the `SelectionView`.
private final class SelectionWindow: NSWindow {

    var onFinish: ((CGRect?, Bool) -> Void)?
    private let displayScreen: NSScreen

    init(screen: NSScreen) {
        self.displayScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        isMovable = false
        acceptsMouseMovedEvents = true
        // Display on every Space and over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] localRect, cancelled in
            guard let self = self else { return }
            let global = localRect.map { self.convertToGlobalCG(localRect: $0) }
            self.onFinish?(global, cancelled)
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Convert a rect in this window's AppKit coordinates (origin bottom-left
    /// of the current screen) to the top-left-origin coordinate system used
    /// by CoreGraphics screen captures.
    private func convertToGlobalCG(localRect: NSRect) -> CGRect {
        // Offset by the screen's origin (already in AppKit global coords).
        let screenRect = NSRect(
            x: displayScreen.frame.origin.x + localRect.origin.x,
            y: displayScreen.frame.origin.y + localRect.origin.y,
            width: localRect.width,
            height: localRect.height
        )
        // Flip Y: CG origin is top-left of primary display's full coordinate space.
        guard let primary = NSScreen.screens.first else { return screenRect }
        let totalHeight = primary.frame.height
        let cgY = totalHeight - screenRect.origin.y - screenRect.height
        return CGRect(x: screenRect.origin.x, y: cgY, width: screenRect.width, height: screenRect.height)
    }
}

// MARK: - Selection view

private final class SelectionView: NSView {

    var onFinish: ((NSRect?, Bool) -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Crosshair is pushed onto the cursor stack by ScreenSelectionController
        // in begin(); cursorUpdate(with:) below keeps it fresh as the pointer
        // moves across the overlay.
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shouldDim = Preferences.dimBackground

        if shouldDim {
            NSColor.black.withAlphaComponent(0.28).setFill()
            bounds.fill()
        }

        guard let rect = currentRect else { return }
        let clearRect = rect.integral

        if shouldDim, let ctx = NSGraphicsContext.current?.cgContext {
            // Punch a hole in the dimmed layer so the pixels under the
            // selection stay true to life.
            ctx.clear(clearRect)
        }

        // Draw a thin border around the selection. When dim is disabled we
        // brighten the border so it still reads against arbitrary content.
        let border = NSBezierPath(rect: clearRect)
        border.lineWidth = shouldDim ? 1 : 1.5
        (shouldDim ? NSColor.white : NSColor.systemBlue).setStroke()
        border.stroke()

        // Print the size in the bottom-right corner of the selection.
        let sizeString = "\(Int(rect.width)) × \(Int(rect.height))"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let size = (sizeString as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let textRect = NSRect(
            x: clearRect.maxX - size.width - padding,
            y: max(clearRect.minY - size.height - 4, 4),
            width: size.width + padding,
            height: size.height
        )
        // Tiny shadow for contrast.
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: textRect.insetBy(dx: -4, dy: -2), xRadius: 3, yRadius: 3).fill()
        (sizeString as NSString).draw(in: textRect, withAttributes: attributes)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(origin: startPoint!, size: .zero)
        Log.selection.debug("mouseDown at \(String(format: "(%.0f,%.0f)", self.startPoint!.x, self.startPoint!.y), privacy: .public)")
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width:  abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        guard let rect = currentRect, rect.width > 0, rect.height > 0 else {
            Log.selection.notice("mouseUp with empty selection — cancelling")
            onFinish?(nil, true)
            return
        }
        Log.selection.notice("mouseUp committing rect=\(rect.debugDescription, privacy: .public)")
        // Hand the result upstream — ScreenSelectionController.finish() handles
        // cursor restoration, hiding the overlay, and the runloop hop before
        // the screen is captured.
        onFinish?(rect, false)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Escape cancels.
        if event.keyCode == 53 {
            Log.selection.notice("keyDown: Escape — cancelling")
            onFinish?(nil, true)
            return
        }
        super.keyDown(with: event)
    }
}
