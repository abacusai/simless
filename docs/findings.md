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
- **Dynamic Type is ignored.** Five strategies all had no effect: `.environment(\.dynamicTypeSize)`, the legacy `\.sizeCategory`, a parent trait override, window `traitOverrides`, and swizzling `preferredContentSizeCategory` on `UIApplication`/`UITraitCollection`. Text styles resolve to fixed sizes.
- **Display scale follows the hidden window's display.** On a 1× external display, layout rounds differently (whole points instead of half points). Pin `traitOverrides.displayScale = 2`.
- **Headless:** without `LSUIElement` in the Info.plist, a Dock icon flashes for ~1.5–3 s at launch. `INFOPLIST_KEY_LSUIElement` doesn't reach Designed-for-iPad builds, so set it in the built Info.plist and re-sign.
- **Windows still flash in install and test runs.** Launches by `xcodebuild test` don't carry simless's arguments. In those runs the app's main window was on screen for ~290 ms. Hiding the app early in `App.init` cut that to ~40 ms, and `LSBackgroundOnly` to ~20 ms. Only making `NSWindow` ordering (`orderWindow:relativeTo:`, `orderFront:`, `makeKeyAndOrderFront:`, `orderFrontRegardless`) a no-op removed it completely; rendering is unaffected.
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
