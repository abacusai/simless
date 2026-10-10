# simless demo app

A small SwiftUI app whose screens cover common UI patterns: a welcome screen pinned to the safe areas, a long `List`, wrapping text, a grouped `Form` with platform controls, text fields, and a profile with a `Menu`. It's used to show how simless renders compare with the iOS Simulator; see [docs/fidelity.md](../../docs/fidelity.md).

It's also a minimal example of a project set up for simless:

- `SimlessDemoApp.swift` calls `SimlessHost.startIfRequested()` in `init()`.
- `SimlessDemo/Simless/SimlessFixtures.swift` registers each screen with fixed sample data (`DemoData.swift`).
- `SimlessDemo/Simless/SimlessKit.swift` is the kit from `Templates/`, kept identical by CI.
- `SimlessDemoTests` is the app-hosted unit-test target simless installs hosts through (Swift Testing).
- `.simless.json` is the config `simless init` would write.

## Try it

```sh
cd Examples/SimlessDemo
simless up                      # build and start the hidden host (~1 min the first time)
simless render all --matrix     # every screen, light and dark, three device sizes
simless calibrate --dark        # compare every screen with an iOS Simulator
simless test                    # the unit tests, on the Mac
```

The project sets no signing team. simless uses the only Apple Development identity in your keychain; if you have several, set `SIMLESS_TEAM=<team id>`. You also need the team's wildcard development profile that includes your Mac (see the main README's requirements).
