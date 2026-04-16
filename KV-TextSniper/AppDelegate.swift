//
//  AppDelegate.swift
//  KV-TextSniper
//

import AppKit
import SwiftUI
import os

/// Shared logger factories. Every important step in the capture/OCR pipeline
/// emits a log line so issues in the field are diagnosable via Console.app
/// (filter by subsystem `com.viacheslav.KV-TextSniper`) or via Terminal:
///
///     log stream --predicate 'subsystem == "com.viacheslav.KV-TextSniper"' --level debug
///
enum Log {
    private static let subsystem = "com.viacheslav.KV-TextSniper"
    static let app       = Logger(subsystem: subsystem, category: "app")
    static let hotkey    = Logger(subsystem: subsystem, category: "hotkey")
    static let selection = Logger(subsystem: subsystem, category: "selection")
    static let capture   = Logger(subsystem: subsystem, category: "capture")
    static let ocr       = Logger(subsystem: subsystem, category: "ocr")
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Singletons wired together at launch.
    let hotkeyManager  = HotkeyManager()
    let bannerManager  = BannerManager()
    let ocrService     = OCRService()

    private var statusItem: NSStatusItem?
    private var selectionController: ScreenSelectionController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("applicationDidFinishLaunching")

        // Single-instance guard. A second copy would register the same global
        // hotkey and spawn a competing overlay when it fires, so bail before
        // any side effects. exit(0) is safe — nothing has been acquired yet.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.viacheslav.KV-TextSniper"
        let currentPID = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        if let first = others.first {
            Log.app.notice("another instance already running (pid=\(first.processIdentifier, privacy: .public)) — terminating self")
            exit(0)
        }

        // The app lives in the menu bar only — it is not a regular Dock app.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        hotkeyManager.onTrigger = { [weak self] in
            self?.startCapture()
        }
        hotkeyManager.registerStoredShortcut()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("applicationWillTerminate")
        hotkeyManager.unregister()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // "text.viewfinder" is a crisp SF Symbol that reads well at menu-bar size.
            let image = NSImage(systemSymbolName: "text.viewfinder",
                                accessibilityDescription: "KV-TextSniper")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "KV-TextSniper"
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Capture Text…",
            action: #selector(captureFromMenu),
            keyEquivalent: ""
        ).target = self

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: "Quit KV-TextSniper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        statusItem = item
    }

    @objc private func captureFromMenu() {
        startCapture()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // macOS 14+ uses a different selector name than earlier versions.
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    // MARK: - Capture flow

    func startCapture() {
        // Guard against entering the flow twice.
        guard selectionController == nil else {
            Log.app.notice("startCapture: ignored — selection already in progress")
            return
        }

        Log.app.notice("startCapture: begin")

        let controller = ScreenSelectionController()
        selectionController = controller

        controller.onSelection = { [weak self] rect in
            Log.app.notice("startCapture: selection finished rect=\(rect.debugDescription, privacy: .public)")
            self?.selectionController = nil
            self?.handleSelection(rect)
        }
        controller.onCancel = { [weak self] in
            Log.app.notice("startCapture: selection cancelled")
            self?.selectionController = nil
        }

        controller.begin()
    }

    private static func dumpCapture(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.capture.error("dumpCapture: PNG representation failed")
            return
        }
        let url = URL(fileURLWithPath: "/tmp/kvts-capture.png")
        do {
            try data.write(to: url)
            Log.capture.notice("dumpCapture: wrote \(url.path, privacy: .public) (\(data.count) bytes)")
        } catch {
            Log.capture.error("dumpCapture: write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleSelection(_ rect: CGRect) {
        // Empty / zero-sized selection → user essentially cancelled.
        guard rect.width >= 4, rect.height >= 4 else {
            Log.app.notice("handleSelection: rect too small \(rect.debugDescription, privacy: .public) — ignoring")
            return
        }

        let captureStart = CFAbsoluteTimeGetCurrent()
        guard let image = ScreenCaptureManager.captureScreenRegion(rect) else {
            Log.capture.error("captureScreenRegion returned nil for rect=\(rect.debugDescription, privacy: .public)")
            bannerManager.showError()
            return
        }
        let captureElapsed = CFAbsoluteTimeGetCurrent() - captureStart
        Log.capture.notice("captured \(image.width)x\(image.height) in \(String(format: "%.3f", captureElapsed), privacy: .public)s")

        // Diagnostic: dump exactly what went into Vision so we can verify the
        // capture isn't our own dimmed overlay. File is overwritten each run.
        Self.dumpCapture(image)

        let ocrStart = CFAbsoluteTimeGetCurrent()
        ocrService.recognizeText(in: image) { [weak self] text in
            let ocrElapsed = CFAbsoluteTimeGetCurrent() - ocrStart
            Log.ocr.notice("recognizeText: \(text == nil ? "nil" : "\(text!.count) chars", privacy: .public) in \(String(format: "%.3f", ocrElapsed), privacy: .public)s")
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let text = text, !text.isEmpty {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    self.bannerManager.showSuccess()
                } else {
                    self.bannerManager.showError()
                }
            }
        }
    }
}
