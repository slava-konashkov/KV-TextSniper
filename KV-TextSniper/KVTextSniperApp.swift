//
//  KVTextSniperApp.swift
//  KV-TextSniper
//
//  Menu-bar OCR utility: capture a region of the screen and copy the
//  recognised text straight to the clipboard.
//

import SwiftUI
import AppKit

@main
struct KVTextSniperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings window opened via the menu-bar icon or ⌘, from the
        // app being focused.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.hotkeyManager)
                .frame(width: 460, height: 400)
        }
    }
}
