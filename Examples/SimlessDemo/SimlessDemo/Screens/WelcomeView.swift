// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// Content centered, primary button pinned to the bottom safe area.
struct WelcomeView: View {
    var onContinue: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to the demo")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Each screen in this app is rendered twice: once in the iOS Simulator and once by simless.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: onContinue) {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("welcome.start")
        }
        .padding(.bottom, 8)
    }
}
