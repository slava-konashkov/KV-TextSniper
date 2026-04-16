//
//  HotkeyManager.swift
//  KV-TextSniper
//
//  Registers a global hotkey using the Carbon event system.
//  Carbon is still the supported path for global hotkeys under sandboxed
//  Mac App Store apps — no special entitlement is required.
//

import AppKit
import Carbon.HIToolbox
import Combine
import os

/// Describes a keyboard shortcut in terms of a virtual key code and
/// a set of NSEvent.ModifierFlags. This representation is stable across
/// keyboard layouts because we store virtual key codes (not characters).
struct Shortcut: Codable, Equatable {
    /// Carbon / AppKit virtual key code (e.g. kVK_ANSI_9 == 25).
    let keyCode: UInt32
    /// Raw `NSEvent.ModifierFlags` bitmask (device-independent subset only).
    let modifierFlagsRaw: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
            .intersection(.deviceIndependentFlagsMask)
    }

    /// Default shortcut: ⌘⇧9.
    static let `default` = Shortcut(
        keyCode: UInt32(kVK_ANSI_9),
        modifierFlagsRaw: (NSEvent.ModifierFlags.command.union(.shift)).rawValue
    )

    /// Human-readable string such as "⌘⇧9".
    var displayString: String {
        var result = ""
        if modifierFlags.contains(.control)  { result += "⌃" }
        if modifierFlags.contains(.option)   { result += "⌥" }
        if modifierFlags.contains(.shift)    { result += "⇧" }
        if modifierFlags.contains(.command)  { result += "⌘" }
        result += Self.characterFor(keyCode: keyCode)
        return result
    }

    private static func characterFor(keyCode: UInt32) -> String {
        // Common keys
        switch Int(keyCode) {
        case kVK_Return:           return "↩"
        case kVK_Tab:               return "⇥"
        case kVK_Space:             return "␣"
        case kVK_Delete:            return "⌫"
        case kVK_Escape:            return "⎋"
        case kVK_LeftArrow:         return "←"
        case kVK_RightArrow:        return "→"
        case kVK_UpArrow:           return "↑"
        case kVK_DownArrow:         return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: break
        }

        // Fallback: translate through the current keyboard layout.
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return "?" }
        let keyLayout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

        var deadKeyState: UInt32 = 0
        var chars       = [UniChar](repeating: 0, count: 4)
        var length      = 0
        let status      = UCKeyTranslate(
            keyLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        if status == noErr, length > 0 {
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
        return "?"
    }
}

/// Registers a single global hotkey and invokes `onTrigger` when it fires.
final class HotkeyManager: ObservableObject {

    /// Closure invoked on the main thread when the hotkey is pressed.
    var onTrigger: (() -> Void)?

    /// Published so the UI can redraw when the shortcut changes.
    @Published private(set) var shortcut: Shortcut = HotkeyManager.loadShortcut()

    // MARK: - Carbon plumbing

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let signature: FourCharCode = HotkeyManager.fourCharCode("KVTS")
    private let identifier: UInt32 = 1

    // MARK: - Public API

    func registerStoredShortcut() {
        install(shortcut: shortcut)
    }

    func update(to newShortcut: Shortcut) {
        shortcut = newShortcut
        Self.save(newShortcut)
        install(shortcut: newShortcut)
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: - Internals

    private func install(shortcut: Shortcut) {
        unregister()
        Log.hotkey.notice("installing shortcut \(shortcut.displayString, privacy: .public)")

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )

        // Capture self via an opaque pointer so the C callback can reach back.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr, hkID.signature == manager.signature, hkID.id == manager.identifier {
                    DispatchQueue.main.async {
                        Log.hotkey.notice("pressed \(manager.shortcut.displayString, privacy: .public)")
                        manager.onTrigger?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        let hkID = EventHotKeyID(signature: signature, id: identifier)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifierFlags(from: shortcut.modifierFlags),
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRef = ref
    }

    private static func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if flags.contains(.command)  { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option)   { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control)  { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift)    { carbonFlags |= UInt32(shiftKey) }
        return carbonFlags
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) + FourCharCode(scalar.value & 0xFF)
        }
        return result
    }

    // MARK: - Persistence

    private static let defaultsKey = "KVTS.shortcut"

    private static func loadShortcut() -> Shortcut {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Shortcut.self, from: data) {
            return decoded
        }
        return .default
    }

    private static func save(_ shortcut: Shortcut) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
