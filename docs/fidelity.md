# How simless renders compare to the iOS Simulator

The [demo app](../Examples/SimlessDemo) has seven screens built from common SwiftUI patterns. Each one was rendered twice, in light and dark mode:

- **iOS Simulator:** an iPhone 17 Pro running iOS 27.0, which is what the legacy workflow screenshots;
- **simless:** the same app running natively on the Mac as a hidden host (macOS 27.0.1, Xcode 27.0).

`simless calibrate` then compared the two accessibility trees element by element.

**8 of 14 renders match** within 2 pt. The other six show three real differences, all listed below with the images. The [full report](fidelity/report.md) has every pair and every difference.

## Summary

| Screen | Pattern | Result | What differs on the Mac |
|---|---|---|---|
| Welcome | Centered content, button pinned to the bottom safe area | ✓ light, ✓ dark | Text renders ~4% wider (same lines) |
| Article | Long wrapping paragraphs in a scroll view | ✓ light, ✓ dark | Text renders ~2% wider (same lines) |
| Login | Text fields, a toggle, a button | ✓ light, ✓ dark | None |
| Login.error | The same with an inline error | ✓ light, ✓ dark | Text renders ~4% wider (same lines) |
| Feed | Long `List` with sections in a `NavigationStack` | ✗ | Each row is 2 pt taller, accumulating down the list |
| Settings | Grouped `Form` with toggles, a picker, a stepper | ✗ | Toggle rows are 6 pt taller; "on" toggles use the Mac's accent color |
| Profile | Wrapped bio, equal-width stats, wrapping tags, `Menu` | ✗ | The bio wraps onto a third line; the `Menu` exposes no label |

## Matching screens

| Welcome: iOS Simulator | Welcome: simless |
|:-:|:-:|
| <img src="fidelity/Welcome-light-simulator.png" width="300"> | <img src="fidelity/Welcome-light-simless.png" width="300"> |

| Article: iOS Simulator | Article: simless |
|:-:|:-:|
| <img src="fidelity/Article-light-simulator.png" width="300"> | <img src="fidelity/Article-light-simless.png" width="300"> |

| Login with error, dark: iOS Simulator | Login with error, dark: simless |
|:-:|:-:|
| <img src="fidelity/Login.error-dark-simulator.png" width="300"> | <img src="fidelity/Login.error-dark-simless.png" width="300"> |

## Screens that differ

### Feed: list rows are 2 pt taller

Each row is 72 pt tall in simless and 70 pt in the simulator, so the offset grows down the list: 3 pt by the 4th row, 8 pt by the 9th. Content and order are identical.

| iOS Simulator | simless |
|:-:|:-:|
| <img src="fidelity/Feed-light-simulator.png" width="300"> | <img src="fidelity/Feed-light-simless.png" width="300"> |

### Settings: form rows are taller, and toggles use the Mac's accent color

Rows containing a toggle are 58 pt tall in simless and 52 pt in the simulator, so everything below them moves down, by up to 34 pt at the bottom of the form. Controls also pick up the Mac's accent color from System Settings: the "on" toggle above is gray, not green. An accessibility tree can't see colors, which is one reason this page shows images too.

| iOS Simulator | simless |
|:-:|:-:|
| <img src="fidelity/Settings-light-simulator.png" width="300"> | <img src="fidelity/Settings-light-simless.png" width="300"> |

### Profile: wider text changes a line break, and a Menu loses its label

Text renders a few percent wider on the Mac. Usually that changes nothing, but this centered bio needs a third line in simless, which pushes everything below it down by ~22 pt. The `Menu` with a custom label is exposed as an unlabeled button on the Mac, but as a "More" button on iOS. That's a simless-only accessibility issue, not a bug in the app.

| iOS Simulator | simless |
|:-:|:-:|
| <img src="fidelity/Profile-light-simulator.png" width="300"> | <img src="fidelity/Profile-light-simless.png" width="300"> |

## What this means when you use simless

- **Trust:** what's on the screen, its order, labels and identifiers, and layout built from stacks, padding and fixed sizes. Those matched across every screen.
- **Treat as approximate:**
  - exact line breaks in long or centered text;
  - heights of platform-styled rows (`List`, `Form`);
  - anything positioned below such rows.
- **Not visible in a tree:** colors that come from the system accent color. Check those in the simulator.
- **Accessibility flags on `Menu` and other platform-backed controls:** confirm them with `simless calibrate` before fixing.
- **Run `simless calibrate --png <dir>` on your own app.** It produces this same comparison for your screens, so you know which renders you can rely on.

## Reproducing this page

```sh
cd Examples/SimlessDemo
simless up
simless calibrate --dark --png ../../docs/fidelity
for f in ../../docs/fidelity/*.png; do sips -Z 874 "$f" >/dev/null; done   # halve the image size for the repo
```

`simless up` needs a signing team. The demo project doesn't set one, so simless uses the only Apple Development identity in your keychain. Set `SIMLESS_TEAM=<team id>` if you have several.
