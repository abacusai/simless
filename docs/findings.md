# Findings

These are the platform facts behind simless's design, found by building it against a large production SwiftUI app on Xcode 27 / macOS 27 (Apple Silicon, 32 GB). Each one cost time to discover; they are recorded so nobody has to rediscover them.

## Why not the simulator

- **Memory:** a booted iOS 27 simulator running a real app holds about **2.2 GB of private memory across ~210 processes** (5 simulators: 11.2 GB, 1,071 processes; see [benchmarks](benchmarks.md)). One `xcodebuild` UI-test run with parallel testing clones and boots several of them. During development we observed **one agent's single UI-test run with 3 cloned simulators running**, and 556 simulator processes on the machine in total.
- **Compilation:** each agent also runs its own full `xcodebuild`, and each one wants every core.
- **Why it breaks down:** with 4–5 agents, a 32 GB Mac starts swapping. The bottleneck is "N × (build + simulator)", not any single tool.

## Rendering approaches that don't work

- **`ImageRenderer`:** it only rasterizes SwiftUI primitives. Complex controls, `ScrollView` content, `List`, `Picker`, `Map` and UIKit-backed views render as placeholders or blank, so it can't render real screens.
- **Single-file renderers** (render a `View` from one `.swift` file) can't load a real app's modules and dependencies.
- **Xcode's `RenderPreview` (MCP)** renders real previews, but needs the Xcode GUI per project and uses a simulator runtime underneath.
- **Mac Catalyst** needs `ios-macabi` slices from every SDK, and many closed-source SDKs don't ship them. Designed-for-iPad runs the iOS slice unchanged.

## Designed for iPad: the details

- **Hidden destination:** Xcode hides the "Designed for iPad" destination for targets with `macosx` in `SUPPORTED_PLATFORMS`. Command-line build-setting overrides don't bring it back; the project file itself must change, so simless uses a generated copy.
- **Destination string:** `xcodebuild` can't parse `variant=Designed for [iPad,iPhone]` (the comma breaks the destination parser). `variant=Designed for iPad` works.
- **Launching:** `open` on the built `.app` fails ("incorrect executable format"), and so do a hand-made wrapper bundle and running the binary directly. **The only supported installer is `xcodebuild test`**, which goes through `installcoordinationd`. A zero-test run (`-only-testing:<Target>/NonExistent`) installs, launches, runs nothing and exits 0.
- **Installed copies are read-only.** They live under `/var/folders/.../d/Wrapper/` on a read-only filesystem.
- **Stale registrations:** LaunchServices can hold several registrations for one bundle id, and `open -b` may pick a stale one. Launching the slot's `.XCInstall/<App>.app` wrapper by path is reliable.
- **Startup race:** `open` right after the install run can be swallowed while the install's test process is still exiting. Wait until no instance of the bundle id is running, then launch.
- **Builds under `/tmp` are killed by Gatekeeper** ("Gatekeeper policy blocked execution"). The same build under `~/Library/Caches` runs.
- **One instance per bundle id:** launching a second host of the same app kills the first. Concurrent installs of the same bundle id fail ("Coordinator found for …"). Hence one bundle id per slot, and serialized installs.
- **Signing without the developer account:** the team's wildcard development profile (`TEAM.*`), which already lists the Mac's provisioning UDID, is enough once capabilities are stripped. Nothing gets registered.
- **Supervisor cost:** a host running *inside* an XCTest (the first prototype) keeps an `xcodebuild` alive at about **500 MB RSS**, and killing it kills the host. Moving the server into the app and launching with `open` removed it. The host's own footprint is **~30–35 MB**.
- **Scheme containers are relative to the project's directory.** A scheme in `ios/App.xcodeproj` says `container:App.xcodeproj`, not `container:ios/App.xcodeproj`. If a copied scheme isn't rewritten to match, it silently builds the original project's targets.
- **Reading build settings:** `xcodebuild -showBuildSettings -scheme X -sdk iphoneos` fails for some schemes ("Found no destinations"). Querying with the actual destination (`-destination 'platform=macOS,arch=arm64,variant=Designed for iPad'`) works, and `-target` works as a fallback, but `-target` can't take `-derivedDataPath`.
- **Swift 6 data-race errors don't appear with `-typecheck`.** Region-based isolation is checked later in compilation, so code that typechecks can still fail to build in Swift 6. Check templates by compiling them, in every language mode they must support.
- **Test plans** reference targets as `container:<Project>.xcodeproj`. Building from a renamed project copy yields an empty `.xctestrun` unless the plan is copied and rewritten too.

## Rendering on the Mac

- **Accessibility tree:** SwiftUI's accessibility tree is empty in-process until accessibility automation is enabled (`_AXSSetAutomationEnabled` from `libAccessibility`). Frames are in Mac screen space; take them relative to the hosting view's own accessibility frame.
- **Identifiers:** `accessibilityIdentifier` on SwiftUI elements is read through KVC; the elements don't conform to `UIAccessibilityIdentification`.
- **Dynamic Type doesn't scale text.** Five strategies all had no effect: `.environment(\.dynamicTypeSize)`, the legacy `\.sizeCategory`, a parent trait override, window `traitOverrides`, and swizzling `preferredContentSizeCategory` on `UIApplication`/`UITraitCollection`. Text styles resolve to fixed sizes. It's below SwiftUI: `UIFont.preferredFont(forTextStyle:compatibleWith:)` and `UIFontMetrics.scaledValue(for:compatibleWith:)` return the default size for every category, and the `-UIPreferredContentSizeCategoryName` launch argument changes nothing. Layout that reads `dynamicTypeSize` does follow the override, and so does control padding.
- **Display scale follows the hidden window's display.** On a 1× external display, layout rounds differently (whole points instead of half points). Pin `traitOverrides.displayScale = 2`.
- **Headless:** without `LSUIElement` in the Info.plist, a Dock icon flashes for ~1.5–3 s at launch. `INFOPLIST_KEY_LSUIElement` doesn't reach Designed-for-iPad builds, so set it in the built Info.plist and re-sign.
- **Windows still flash in install and test runs.** Launches by `xcodebuild test` don't carry simless's arguments. In those runs the app's main window was on screen for ~290 ms. Hiding the app early in `App.init` cut that to ~40 ms, and `LSBackgroundOnly` to ~20 ms. Only making `NSWindow` ordering (`orderWindow:relativeTo:`, `orderFront:`, `makeKeyAndOrderFront:`, `orderFrontRegardless`) a no-op removed it completely; rendering is unaffected.
- **Overriding the idiom crashes `Stepper`.** On the Mac, `traitOverrides.userInterfaceIdiom = .phone` crashes SwiftUI's `Stepper` with `EXC_BAD_ACCESS` at the stack guard. Tested one control at a time on macOS 27, `Toggle`, `Picker`, `Form`, `List` and `Form { Toggle }` render fine under it, so the crash first blamed on `Form`/`Toggle`/`Picker` came from a `Stepper` on the same screen. Size-class overrides are safe. It isn't deep recursion: the crashing thread is only 90 to 180 frames deep, frames barely repeat, and a 64 MB main-thread stack (patched into `LC_MAIN`) only moves the fault. One frame in the Swift runtime's tuple-metadata lookup asks for a huge stack allocation, which points at a SwiftUI bug. It has also been reported under the iPad idiom in a larger app, though Steppers in forms, lists, navigation stacks and with formats, sizes and locales all rendered fine under it here.
- **The phone idiom doesn't close the fidelity gap.** Against an iOS 26.5 simulator, the demo app matched in 11 of 17 renders with `.phone` and 10 of 17 with `.pad`. It fixed a split view's navigation bar, but text stayed 2–4% wider, pill buttons and `Form` toggle rows kept their Mac sizes, and `List` rows got 2 pt taller.
- **The sandbox can be opened from outside, but not by entitlement.** A slot signed with `com.apple.security.temporary-exception.files.absolute-path.read-only` fails to install ("A valid provisioning profile for this executable was not found"). A read-only sandbox extension issued by an unsandboxed process (`sandbox_extension_issue_file`, class `com.apple.app-sandbox.read`) and consumed by the app works, for both `/tmp` and `/private/tmp` spellings, and writes stay denied. Creating another app's group container from a shell fails (`Operation not permitted`), so app groups are redirected instead.
- **Several test bundles can share one launch.** `dlopen` of another `.xctest` bundle's binary from the host app at launch makes both XCTest (its default suite includes the loaded bundle's `XCTestCase` classes) and Swift Testing run its tests. Each extra launch costs the app's startup: about 1.3 s on the demo app, about 40 s on a larger app. If a test crashes in such a launch, xcodebuild restarts it without end, since it can't count the loaded bundles' tests as done.
- **Test output interleaves.** XCTest, Swift Testing and the app's own logging share one stream. Lines can start mid-line, and invisible U+200B characters show up in them, including in front of `Fatal error` and inside test names. A test's "passed" line that isn't recognized makes a finished test look hung. A parameterized test finishes as `Test name(_:) with 3 test cases passed`.
- **Hostless test bundles are dropped for Designed for iPad.** A local package's test target in the app's scheme isn't built for that destination at all, without a warning, and `-only-testing` then says it isn't in the scheme. Built for `generic/platform=iOS` and copied into the host app's `PlugIns`, the same bundle runs fine as an app-hosted bundle (XCTest and Swift Testing), including code that imports `WatchConnectivity`.
- **Extensions and watch apps install** when their ids are moved under the slot's id and each extension carries the wildcard profile and its own `application-identifier`. macOS then registers the extensions (`pluginkit -m` lists them), and `pluginkit -e ignore` hides them.
- **Measured rendering differences, from the demo app against an iPhone 17 Pro / iOS 27 simulator** (see [fidelity.md](fidelity.md)):
  - text renders 2–4% wider, which usually keeps the same line breaks;
  - `List` rows are 2 pt taller;
  - `Form` toggle rows are 6 pt taller;
  - controls use the macOS accent color.
- **VoiceOver container semantics.** An accessibility element is one unit (VoiceOver doesn't descend into it), and a container that lists `accessibilityElements` replaces its subviews. Walking subviews as well finds duplicates (a `Toggle` row's switch, a `Picker`'s value text, navigation titles) that VoiceOver never announces.
- **`.xctestrun` comes in two formats.** Schemes with a test plan produce format 2 (`TestConfigurations[].TestTargets[]`); schemes without one produce format 1, with test targets as top-level keys.
- **Device idiom:** `UIDevice.current.userInterfaceIdiom` reports `.pad` for an iOS app on the Mac, and trait overrides don't change it. `traitOverrides.horizontalSizeClass` and `userInterfaceIdiom` do change what views see through the trait collection.
- **Calibration against the iOS 27 simulator,** on a production app:
  - Simple layouts matched within 1.5 pt.
  - A two-line label wrapped differently: 334 pt wide in simless, 320 pt in the simulator, because of font metrics.
  - A `Menu` with a custom label had no accessibility label on the Mac but did on iOS.

## Hot reload

- **Compiler command lines:** Xcode no longer logs per-file compile commands (since 16.3). Reconstruct the flags from build settings instead.
- **Package checkouts contain symlink cycles.** A recursive glob loops forever; use `find`.
- **Quarantine:** files a sandboxed app writes are quarantined. `dlopen` of quarantined code makes `syspolicyd` show a **user prompt and block** the loading thread. The sandbox forbids `removexattr` of `com.apple.quarantine` (EPERM).
- **Containers:** sandbox containers are **UUID-named**; the owner is in `.com.apple.containermanagerd.metadata.plist`. They're protected as App Data. Access from another process is denied silently, with no prompt, even when it's signed by the same team. Full Disk Access is needed.
- **Occasional slow launch:** a host occasionally took ~30 s to start serving right after a unit-test run, and the cause isn't known. Restarting an instance that runs but doesn't serve (after 10 s, then 20 s, then 30 s) bounds the cost.
- **Writing to a non-existent `~/Library/Containers/<bundle id>/` path** creates a directory that containermanagerd then adopts as a protected stub, and you can't delete it from a shell afterwards.
- **InjectionNext** reports xcodebuild-only workflows broken on recent Xcode, and it targets function-body swaps. simless's approach compiles a separate module whose types shadow the app's, rebuilds fixtures from it, and needs no interposing.
