# AppSwitcher

Menu-bar app that replaces the built-in ⌘⇥ switcher with one that lists only apps that have at least one window.

An app counts as having a window if it has one on any Space (including other desktops and full-screen Spaces), a minimized window, or windows hidden with ⌘H. Apps whose windows are all closed are left out, even while they keep running.

## Build / install

```sh
./build.sh            # builds build/AppSwitcher.app
./build.sh --install  # also copies it to /Applications and launches it
```

Grant Accessibility access when asked (System Settings › Privacy & Security › Accessibility). Until then, ⌘⇥ keeps opening the built-in switcher. The menu-bar menu turns ⌘⇥ Switcher and Dock Previews on and off separately. Launch at Login is there too, or from the command line: `/Applications/AppSwitcher.app/Contents/MacOS/AppSwitcher --launch-at-login on|off`.

## Keys

Same as the built-in switcher:

- ⌘⇥ / ⌘⇧⇥: next / previous app; release ⌘ to switch
- while ⌘ is held: `` ` `` or ← / →  to move, ↑ / ↓ to move between rows, Esc to cancel, Return to switch, Q to quit the selected app, H to hide it
- switching to an app whose windows are all minimized restores all of them and brings them to the front; hold ⌥ when releasing ⌘ to do this for any app
- hovering selects, clicking switches

## Apps without windows

With Show Apps Without Windows (menu-bar menu) on, they are listed too, faded, in the same most-recently-used order. Switching to one opens a new window, as clicking its Dock icon does.

## Window previews

With Show Window Previews (menu-bar menu, under ⌘⇥ Switcher) on, each app is shown as a snapshot of its front window with its icon in the corner, and the selected app is larger than the rest. Selected Preview Size and Other Previews Size (same menu) set their sizes. Snapshots need Screen Recording access. Apps whose windows are all minimized or hidden show their last snapshot, or their icon if none was taken yet.

Icons are the size of the built-in switcher's icons (128 pt), and previews of apps that are not selected are never shorter than that; apps wrap onto more rows instead, and also past the number set in Apps per Row (same menu).

## Dock previews

With Dock Previews (menu-bar menu, on by default) on, resting the pointer on a running app's Dock icon shows its windows next to the icon: a snapshot of each, its title, and the tabs of windows that have a tab bar (Finder, Terminal, Safari, Firefox, and other apps with standard tabs). Clicking a window brings it to the front, switching Space if needed; clicking a tab selects it first. Resting the pointer on a tab title selects that tab in the app and shows its snapshot, since apps draw only the selected tab; when the preview closes without a click, each window goes back to the tab it had. Minimized windows are listed after the others and are restored when clicked. Preview Size (under Dock Previews) sets the snapshot size.

Snapshots need Screen Recording access (System Settings › Privacy & Security › Screen Recording), asked for when previews are first turned on; without it, previews show the app icon in place of each snapshot. Minimized windows and windows of a hidden app show their last snapshot, or the app icon if none was taken yet.

## Limitations

- Event taps get no keystrokes while a password field has secure input on, so ⌘⇥ opens the built-in switcher then.
- Windows on other Spaces are found through private SkyLight calls (`CGSCopyWindowsWithOptionsAndTags`); a macOS update could change them. Dock previews also use private calls to focus a window (`_SLPSSetFrontProcessWithOptions`, `_AXUIElementGetWindow`) and to capture windows on full-screen Spaces, which ScreenCaptureKit cannot (`CGSHWCaptureWindowList`).
- Accessibility lists only the current Space's windows; Dock previews find windows on other Spaces by trying Accessibility element IDs through a private call (`_AXUIElementCreateWithRemoteToken`), as AltTab does.
- Firefox exposes its tab bar only to assistive apps, so on the first preview AppSwitcher turns on Firefox's accessibility support (`AXEnhancedUserInterface`, as VoiceOver does). It stays on until Firefox quits, which can make Firefox slightly slower and window managers animate its windows.

Logs: `log stream --predicate 'subsystem == "com.morrishoresh.AppSwitcher"'`
