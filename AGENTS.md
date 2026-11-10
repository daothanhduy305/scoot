# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this is

Scoot is a macOS menu-bar utility (AppKit + some SwiftUI, Swift, macOS 12+ deployment target) that moves/clicks/drags/scrolls the mouse cursor from the keyboard. Two jump modes plus one no-UI mode: **element** (AX-discovered UI elements in the frontmost app's focused window), **grid** (every screen split into equal cells), and **freestyle** (no overlay, just keyboard movement). Requires Accessibility permission at runtime.

Swift Package dependencies (resolved by Xcode): `KeyboardShortcuts` (global hotkeys + settings UI) and `AXSwift` (Accessibility API wrapper).

## Build & test

Single Xcode project, single shared scheme `Scoot`. CI (`.github/workflows/main_test.yml`) runs:

```sh
xcodebuild -resolvePackageDependencies
xcodebuild -scheme Scoot test CODE_SIGN_IDENTITY=-
```

Run one test class / method:

```sh
xcodebuild -scheme Scoot test CODE_SIGN_IDENTITY=- -only-testing:ScootTests/TreeTests
xcodebuild -scheme Scoot test CODE_SIGN_IDENTITY=- -only-testing:ScootTests/GridTests/testIndexing
```

Unit tests (`ScootTests/`) cover only pure logic: `Tree`, `Grid`, geometry extensions, and `Positionable` crowding reduction. Anything touching AX, windows, or mouse events is untested and must be checked by running the app. No linter is configured.

Debug vs. release behavior differs in `AppDelegate.applicationDidFinishLaunching`: DEBUG builds skip startup entirely when running under tests/SwiftUI previews, only *warn* if AX trust is missing, and auto-activate element mode on launch. Release builds prompt for AX trust and terminate if not granted.

## Architecture

**Windows.** Two kinds, both subclasses of `TransparentWindow` (borderless, click-through, `.canJoinAllSpaces`):
- One `KeyboardInputWindow` (from the storyboard, found via `NSApp.orderedWindows`) — invisible, becomes key, receives *all* keyboard input, and owns the navigation state. Its logic is split across `KeyboardInputWindow+*.swift` extensions (Keyboard, StandardKeyBinds, Actions, UI, EventMonitor, Delegate).
- One `JumpWindow` per `NSScreen`, each managed by a `JumpWindowController` → `JumpViewController` hosting `GridView` and `ElementView` (the drawn overlays). `AppDelegate` spawns these on launch and rebuilds them all on `didChangeScreenParametersNotification` (also exposed as a Debug menu item — multi-monitor window placement is a recurring bug area, see issue #18).

**Navigation data flow.**
1. Global hotkey (`GlobalKeybindings.swift`) → `AppDelegate.bringToForeground(using:)` sets `inputWindow.activeJumpMode`, records the previously frontmost app (`currentApp`; Scoot itself is never stored), and activates Scoot.
2. Grid trees are built at launch/screen change (`initializeCoreDataStructuresForGridBasedMovement`); element trees are built *only* on element-mode invocation (`initializeCoreDataStructuresForElementBasedMovement`) because AX traversal is slow (issue #26).
3. Both produce a `Tree<CGRect>` — an avy-style char decision tree where each leaf is a target rect in global screen coordinates. Element rects are first thinned with `reducingCrowding` (`Positionable+Crowding.swift`).
4. `keyDown` (`KeyboardInputWindow+Keyboard.swift`) walks `currentNode` one char at a time; on reaching a leaf, `Mouse` moves to the rect's center. `currentNode`'s `didSet` redraws the jump views.

**Key handling.** `keyDown` first handles cancel, then tree-walking chars (unmodified, not reserved, not special to the active `KeybindingMode`), then explicit bindings (Return = click, `=` = hold, `[`/`]`, vi keys, etc.), and finally falls through to `interpretKeyEvents`, so system/Emacs text-movement bindings arrive as `NSStandardKeyBindingResponding` overrides in `+StandardKeyBinds.swift` (moveLeft, moveWordRight, …) mapped onto 2D cursor movement. When adding a key, check `isReserved` and `KeybindingMode.isCharacterSpecial` so it doesn't get swallowed as a label char.

**Clicking** always calls `appDelegate.bringToBackground()` *before* posting the mouse event so the target app regains focus first (issue #28) — preserve this ordering.

**Coordinates.** AX/CoreGraphics use top-left origin; Cocoa uses bottom-left. Conversions live in `Extensions/` (`CGRect.convertToCocoa`, `NSScreen` landmark helpers). Multi-display offsets are a common source of bugs.

**Settings.** Persisted via `@AppStorage` declared in `SettingsView`; `UserSettings.shared` deliberately reads those same properties rather than redeclaring them (see the FIXME in `UserSettings.swift` for why — don't "fix" this by duplicating `@AppStorage`).

**Accessibility.** `Accessibility.swift` traverses the focused window's AX tree via AXSwift, and sets `AXEnhancedUserInterface` on all running apps at launch, and clears it on terminate. Some apps only expose their AX tree when an assistive client like VoiceOver is active. It's set up front rather than just before traversal because apps need time to enable their AX APIs (issue #11).

**Logging** uses `OSLog.main` (`Log.swift`); view with Console.app filtered on the Scoot subsystem.
