//
//  BannerWindow.swift
//  KV-TextSniper
//
//  A floating, borderless window that briefly appears at the bottom-center
//  of the active screen to confirm success ("✅ скопировано в буфер") or
//  report failure ("❌ ошибка распознавания").
//

import AppKit
import SwiftUI

final class BannerManager {

    private var window: BannerWindow?
    private var dismissWorkItem: DispatchWorkItem?

    func showSuccess() {
        show(emoji: "✅", message: "Copied to clipboard", tint: .systemGreen)
    }

    func showError() {
        show(emoji: "❌", message: "Recognition failed", tint: .systemRed)
    }

    private func show(emoji: String, message: String, tint: NSColor) {
        dismissWorkItem?.cancel()

        if window == nil {
            window = BannerWindow()
        }
        guard let window = window else { return }

        window.update(emoji: emoji, message: message, tint: tint)
        window.present()

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func dismiss() {
        window?.dismiss()
    }
}

// MARK: - BannerWindow

final class BannerWindow: NSWindow {

    private let hosting: NSHostingView<BannerContent>
    private let rootState: BannerState

    init() {
        let state = BannerState()
        self.rootState = state
        self.hosting = NSHostingView(rootView: BannerContent(state: state))

        let size = NSSize(width: 260, height: 260)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(emoji: String, message: String, tint: NSColor) {
        rootState.emoji   = emoji
        rootState.message = message
        rootState.tint    = Color(nsColor: tint)
    }

    func present() {
        positionOnActiveScreen()
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let visible   = screen.visibleFrame
        let size      = frame.size
        let originX   = visible.midX - size.width / 2
        // 48pt above the Dock / bottom edge so it doesn't feel cramped.
        let originY   = visible.minY + 48
        setFrameOrigin(NSPoint(x: originX.rounded(), y: originY.rounded()))
    }
}

// MARK: - SwiftUI content

private final class BannerState: ObservableObject {
    @Published var emoji:   String = "✅"
    @Published var message: String = ""
    @Published var tint:    Color  = .green
}

private struct BannerContent: View {
    @ObservedObject var state: BannerState

    var body: some View {
        VStack(spacing: 16) {
            Text(state.emoji)
                .font(.system(size: 96))
            Text(state.message)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(state.tint.opacity(0.45), lineWidth: 2)
        )
        .padding(6)
    }
}
