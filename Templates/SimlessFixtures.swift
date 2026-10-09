// Fixtures for `simless render`: each one builds a screen in a deterministic state.
// Created by `simless init`. This file is yours; edit it freely.
//
// Hot reload recompiles this file together with the edited view files, so
// fixtures always render the latest code. Keep it to view construction:
// seed data, environment objects, fixed dates, no network.
#if DEBUG && os(iOS)
import SwiftUI

@MainActor
func simlessFixtures(_ r: SimlessRegistry) {
    // r.add("Settings") { SettingsView() }
    // r.add("Paywall.trialEnded") { PaywallView(state: .trialEnded).environmentObject(Store.preview) }
}
#endif
