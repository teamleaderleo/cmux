# CmuxForeignWindows

Hosts another app's window inside a cmux pane. The first client is Claude
Desktop: each pane shows one Claude profile (an Electron `--user-data-dir`), and
cmux keeps that app's main window glued over the pane rect through the macOS
Accessibility API.

The package builds and tests on its own, so the feature iterates without a full
cmux app build:

```bash
cd Packages/macOS/CmuxForeignWindows
swift build
swift test
```

## Layout

- `Core/`: the pure parts. `ForeignWindowLeaseBook` decides which host presents
  a profile, `ForeignWindowProfileRegistry` owns one session per profile,
  `ForeignWindowYieldCoordinator` hides hosted windows while cmux floats UI,
  and `ForeignWindowProcessLedger` records launched process ids.
- `Session/`: `ForeignWindowSession` launches the app and moves its window with
  AX calls; `ForeignWindowAccessibility` is the trust gate.
- `Host/`: `ForeignWindowHostView` (AppKit) and `ForeignWindowSurface`
  (SwiftUI) mark the pane rect and show the placeholder and Accessibility prompt.
  Their strings live in `Resources/Localizable.xcstrings`.
- `Claude/`: profile naming and paths, the `claude://` link router, and
  `ClaudeDesktopHosting`, which assembles the graph.
- `Diagnostics/`: a headless snapshot of Accessibility trust, the `claude://`
  handler, and running Claude instances with the profile each one uses.

## Composition

The app builds one `ClaudeDesktopHosting` at its composition root and passes
its pieces down. Nothing in the package is a singleton.

```swift
let hosting = ClaudeDesktopHosting(
    store: ClaudeDesktopProfileStore(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        environment: ProcessInfo.processInfo.environment
    ),
    linkHandlerApplicationURL: Bundle.main.bundleURL,
    logger: ForeignWindowLogger { cmuxDebugLog($0) }
)
```

## Tests

Registry tests inject a fake session factory and fake hosts, so nothing
launches:

```swift
let registry = ForeignWindowProfileRegistry(observesApplicationTermination: false) { profile in
    FakeForeignWindowSession(profile: profile)
}
```

`ClaudeDesktopProfileStore(rootURL:)` takes a temporary directory for on-disk
profile tests.

## Lab

`ForeignWindowLab` opens one window split into panes, one Claude profile each,
using the same library code the app uses:

```bash
swift run ForeignWindowLab --profiles work,personal --verbose
swift run ForeignWindowLab --diagnose          # headless, opens no window
swift run ForeignWindowLab --diagnose --json
```

Run unbundled, the lab does not claim the `claude://` handler and inherits
Accessibility trust from the terminal that starts it. To exercise sign-in link
routing, build the app bundle (ad-hoc signed unless `--sign` names an identity):

```bash
scripts/build-lab-app.sh --sign "SmolRunner Local Release Signing"
open -n .build/ForeignWindowLab.app --args --profiles work,personal --verbose
```

From the bundle the lab claims `claude://` while its Claude processes run,
logs whether Launch Services now names it as the handler, and restores Claude
on quit. `--no-claim` skips the claim. Launched with `open`, the app needs its
own Accessibility grant.

## Signing in

Google sign-in finishes in the system browser with a
`claude://login/google-auth?code=…&hop_nonce=…` link, which macOS may hand to
the wrong Claude copy. Each presented pane has a bar under the Claude window:
copy the link from the browser (right-click "Open Claude", Copy Link) and click
"Paste Claude sign-in link", or focus the bar and press Cmd-V. The link is
checked by `ClaudeDesktopSignInLink` (only `claude://login/…` and
`claude://claude.ai/magic-link…` or `/login…`) and sent to that pane's process
only.
Menu: Lab > Toggle Yield (Cmd-Y) exercises hide and restore; Lab > Focus Next
Pane (Cmd-]) moves focus. Quitting terminates the Claude processes it started.

## Claude Profiles menu-bar app

`ClaudeProfiles` is a personal menu-bar launcher: one Claude Desktop instance
per profile directory under `~/Library/Application Support/cmux/external-apps/claude`,
the same layout the `claude-profile` CLI uses. It finds running instances by
their `--user-data-dir` launch argument, so it tracks ones the CLI started
too, and never starts a second process on one profile. While any profile
instance runs it claims `claude://` through `ClaudeDesktopLinkRouter`, so
Google sign-in callbacks reach the instance that started them; it hands the
scheme back to Claude.app when none remain and on quit.

```bash
scripts/build-profiles-app.sh             # .build/Claude Profiles.app
scripts/build-profiles-app.sh --install   # also replaces ~/Applications/Claude Profiles.app
open ~/Applications/"Claude Profiles.app"
```

"Open on Login" profiles live in
`~/Library/Application Support/cmux/external-apps/claude-profiles.json`
(`{"autoOpen": ["work", "personal"]}`) and open when the app starts. Logs go to
the unified log under subsystem `com.cmuxterm.claudeprofiles`.
