# AppSwitcher

Menu-bar app that replaces the built-in ⌘⇥ switcher with one that lists only apps that have at least one window.

An app counts as having a window if it has one on any Space (including other desktops and full-screen Spaces), a minimized window, or windows hidden with ⌘H. Apps whose windows are all closed are left out, even while they keep running.

## Build / install

```sh
./build.sh            # builds build/AppSwitcher.app
./build.sh --install  # also copies it to /Applications and launches it
```

Grant Accessibility access when asked (System Settings › Privacy & Security › Accessibility). Until then, ⌘⇥ keeps opening the built-in switcher. Launch at Login is in the menu-bar menu, or from the command line: `/Applications/AppSwitcher.app/Contents/MacOS/AppSwitcher --launch-at-login on|off`.

## Keys

Same as the built-in switcher:

- ⌘⇥ / ⌘⇧⇥: next / previous app; release ⌘ to switch
- while ⌘ is held: `` ` `` or ← / →  to move, Esc to cancel, Return to switch, Q to quit the selected app, H to hide it
- switching to an app whose windows are all minimized restores all of them and brings them to the front; hold ⌥ when releasing ⌘ to do this for any app
- hovering selects, clicking switches

## Apps without windows

With Show Apps Without Windows (menu-bar menu) on, they are listed too, faded and smaller, in the same most-recently-used order. Switching to one opens a new window, as clicking its Dock icon does.

## Limitations

- Event taps get no keystrokes while a password field has secure input on, so ⌘⇥ opens the built-in switcher then.
- Windows on other Spaces are found through private SkyLight calls (`CGSCopyWindowsWithOptionsAndTags`); a macOS update could change them.

Logs: `log stream --predicate 'subsystem == "com.morrishoresh.AppSwitcher"'`
