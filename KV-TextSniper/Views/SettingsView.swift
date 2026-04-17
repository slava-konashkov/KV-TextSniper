//
//  SettingsView.swift
//  KV-TextSniper
//

import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var hotkeyManager: HotkeyManager
    @AppStorage("KVTS.dimBackground") private var dimBackground: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            HStack(spacing: 12) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KV-TextSniper")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Capture text from any part of the screen")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Keyboard shortcut")
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 12) {
                    ShortcutRecorderView(
                        shortcut: hotkeyManager.shortcut,
                        onShortcutCaptured: { newValue in
                            hotkeyManager.update(to: newValue)
                        }
                    )
                    .frame(width: 200, height: 28)

                    Button("Reset") {
                        hotkeyManager.update(to: .default)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Click the field and press the key combination you want.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                // Surface the exact reason Carbon refused to register the
                // shortcut so the user knows they need to either free it
                // up in System Settings or pick a different one.
                if let error = hotkeyManager.registrationError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.12))
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Selection")
                    .font(.system(size: 13, weight: .medium))
                Toggle(isOn: $dimBackground) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dim background while selecting")
                            .font(.system(size: 12))
                        Text("Darkens the rest of the screen to highlight the selection area.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Startup")
                    .font(.system(size: 13, weight: .medium))
                if #available(macOS 13.0, *) {
                    LaunchAtLoginToggle()
                } else {
                    Text("Launch-at-login requires macOS 13 or later.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("OCR works for any language — Latin, Cyrillic, Chinese, Japanese, Korean and more.", systemImage: "globe")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Label("The app needs Screen Recording permission to capture the selected area.", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

// MARK: - Launch at login

@available(macOS 13.0, *)
private struct LaunchAtLoginToggle: View {
    @State private var isEnabled: Bool = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(.system(size: 12))
                    Text("Start KV-TextSniper automatically when you log in to your Mac.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .onChange(of: isEnabled) { newValue in
                apply(newValue)
            }

            if let message = errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                }
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.12))
                )
            }
        }
        // Re-sync when the view appears in case the state was changed by
        // the user in System Settings → General → Login Items behind our
        // back.
        .onAppear {
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            // Flip the toggle back so the UI reflects the actual state.
            errorMessage = "Couldn't \(enabled ? "enable" : "disable") launch-at-login: \(error.localizedDescription). Try from System Settings → General → Login Items."
            DispatchQueue.main.async {
                isEnabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

// MARK: - Shortcut recorder

/// AppKit-backed shortcut recorder. When focused it captures the next
/// key press (with modifiers) and reports it upwards.
struct ShortcutRecorderView: NSViewRepresentable {
    let shortcut: Shortcut
    let onShortcutCaptured: (Shortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.onShortcutCaptured = onShortcutCaptured
        field.display(shortcut: shortcut)
        return field
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {
        nsView.onShortcutCaptured = onShortcutCaptured
        nsView.display(shortcut: shortcut)
    }
}

final class ShortcutRecorderField: NSView {

    var onShortcutCaptured: ((Shortcut) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet { needsDisplay = true; updateLabel() }
    }
    private var currentShortcut: Shortcut = .default

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(activate))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    func display(shortcut: Shortcut) {
        currentShortcut = shortcut
        updateLabel()
    }

    private func updateLabel() {
        if isRecording {
            label.stringValue = "Press keys…"
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = currentShortcut.displayString
            label.textColor = .labelColor
        }
    }

    @objc private func activate() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    // Capture the first keyDown that includes at least one modifier.
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording.
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let usedModifiers = modifierFlags.intersection(allowedModifiers)

        // Require at least one modifier to avoid trapping plain keystrokes.
        guard !usedModifiers.isEmpty else {
            NSSound.beep()
            return
        }

        let newShortcut = Shortcut(
            keyCode: UInt32(event.keyCode),
            modifierFlagsRaw: usedModifiers.rawValue
        )
        currentShortcut = newShortcut
        onShortcutCaptured?(newShortcut)
        isRecording = false
        window?.makeFirstResponder(nil)
    }
}
