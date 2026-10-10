// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// A grouped Form with platform controls: toggles, a menu picker, a stepper.
struct SettingsView: View {
    @State private var notifications = true
    @State private var weeklySummary = false
    @State private var theme = "System"
    @State private var fontSize = 3

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle("Push notifications", isOn: $notifications)
                    Toggle("Weekly summary", isOn: $weeklySummary)
                }
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
                    }
                    Stepper("Text size: \(fontSize)", value: $fontSize, in: 1...5)
                }
                Section {
                    Button("Sign out", role: .destructive) {}
                } footer: {
                    Text("Version 1.0 (demo)")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
