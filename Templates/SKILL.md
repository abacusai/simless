---
name: simless
description: Fast, headless, simulator-free verification of SwiftUI iOS apps with the `simless` CLI. Use it whenever you build or change SwiftUI views and need to check that screens render correctly (layout, text, accessibility labels, dark mode, iPad/small iPhone), when the user says to test or verify UI with simless, or instead of booting the iOS Simulator for screen checks or unit tests.
---

# SwiftUI verification with `simless`

`simless` runs the app natively on the Mac as an invisible render host: no simulator, no windows. A screen render returns its accessibility tree in milliseconds. An edited view hot-reloads in about 2 s. Many agents can work in parallel, one host per git worktree.

**Do not boot the iOS Simulator for screen checks or unit tests.** Use `simless`. Use the simulator only for what `simless` can't do (see Limits).

## 1. Is the repo set up?

```sh
simless status        # fails with "no .simless.json" if the repo isn't set up
```

If it isn't set up, do it yourself:

1. Run `simless init` at the repo root. It writes `.simless.json` and `<App>/Simless/SimlessKit.swift` (generated, never edit), creates `SimlessFixtures.swift`, and adds the hook to the `@main` App's `init()`. Check the hook compiles. If the project doesn't use synchronized folders, add both Simless files to the app target.
2. If app startup has side effects that a background render host shouldn't trigger (analytics, sync, network), guard them: `if !SimlessHost.isActive { ... }` (DEBUG only).
3. Register fixtures (below), then run `simless up`. The first build takes a few minutes; later ones are incremental.

`simless init` needs an Xcode project (not a workspace) with an app-hosted unit-test target. If either is missing, tell the user instead of improvising.

## 2. Fixtures: the screens simless can render

`SimlessFixtures.swift` is normal app code:

```swift
#if DEBUG && os(iOS)
import SwiftUI

@MainActor
func simlessFixtures(_ r: SimlessRegistry) {
    r.add("Settings") { SettingsView().environmentObject(SettingsStore.preview) }
    r.add("Paywall.trialEnded") { PaywallView(state: .trialEnded, products: .fixture) }
    r.add("NoteList.empty") { NoteListView(notes: []) }
    r.add("NoteList.long") { NoteListView(notes: .fixture(count: 50, longTitles: true)) }
}
#endif
```

- **One fixture per meaningful state:** normal, empty, loading, error, long content.
- **Deterministic data only.** Use fixed dates, in-memory stores, preview/fixture objects. No network, no real user data. Reuse existing preview data or test seeds when the project has them.
- **Inject whatever the view expects** (`.environmentObject`, `.environment`, model containers).
- **Name them `Screen.state`.** When you add or change a screen, add or update its fixtures in the same change.

## 3. The loop

```sh
simless up                                   # once per worktree, and after big changes
simless reload --render <Fixture>            # after editing views: hot reload (~2 s) + render
simless render all                           # every fixture
simless render <Fixture> --dark --device ipad          # devices: iphone, iphone-small, iphone-max, ipad
simless render all --matrix                  # every fixture × light/dark × iphone, iphone-small, ipad
simless render <Fixture> --png /tmp/shots/   # only when you need to see pixels
simless test MyAppTests/SomeTests            # unit tests on the Mac, no simulator
```

Reading a render:

```
NoteList.empty · light · iphone 402×874 · 31 ms · patch 2
  header  "No Notes"  @140,300 122×26
  button  "New Note" #notes.new  @48,360 306×50
  issues (1):
    ⚠ button without accessibility label @48,420 306×50
```

- **Lines:** each is role, label, `#identifier`, and frame in points (`@x,y w×h`) on the device canvas.
- **Check the tree first.** Is the expected text there? Are elements where they should be, not overlapping and not off-screen? Fix every listed issue: unlabeled controls, text VoiceOver reads twice, off-screen elements, tap targets under 44 pt, overlapping controls. The checks don't cover everything, so also read the frames yourself.
- **Check variants:** `--matrix` for layout changes.
- **Look at a `--png`** when the change is visual: colors, images, clipping. Read the image file.

`simless reload` hot-patches only the edited files plus the fixtures file. If a patch can't express a change (stored properties, function signatures, new types used elsewhere), it falls back to a full build automatically. Compiler errors point at your real `file:line`: fix them and re-run. `simless reload` with no arguments picks up every file edited since the last `simless up`.

## 4. Limits: when the simulator is still needed

`simless` can't verify:
- Dynamic Type sizes,
- gestures and swipe actions,
- the software keyboard,
- system UI (permissions, share sheets, StoreKit sheets),
- navigation flows across screens,
- pixel-exact iPhone rendering (no notch or home indicator).

Leave those for a final simulator or XCUITest pass, and say so in your summary. Don't claim `simless` verified them.

## 5. Housekeeping

- **Don't clean up manually.** Hosts exit after 30 idle minutes (`simless down` stops one now; it relaunches on next use). When a worktree is deleted, `simless` removes its host, slot and caches automatically.
- `simless clean` removes this worktree's build cache. `simless status` lists hosts and whether live reload is on.
- Live reload uses SimlessAgent, which needs Full Disk Access granted once by the user. Without it, reloads still work in about 10 s. Mention it to the user if `simless status` shows live reload off; don't try to grant it yourself.

In your summary, report what you verified with `simless` (which fixtures, devices and modes) and what still needs a simulator.
