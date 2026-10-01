# SoftLock

A tiny macOS menu bar app that "soft locks" your Mac while you step away. It blocks the keyboard and clicks so kids (or cats) can't interrupt a long render or an agent session, without sleeping or locking the machine.

It is **not** a security feature. Anyone can unlock it from the menu bar icon.

## Features

- **Lock / Unlock**: blocks all keyboard input (including media/volume/brightness keys), clicks, scrolling and trackpad gestures. The pointer still moves. Clicks on the SoftLock menu bar icon and its menu still work, so you unlock by clicking the icon and choosing **Unlock**.
- **Blur Screen While Locked** (on by default): lightly blurs every screen while locked, except the SoftLock icon, so it's obvious the Mac is locked when you sit back down.
- **Keep Awake**: stops the display and system from idle-sleeping (like `caffeinate -d`).
- **Keep Awake While Locked** (on by default): keeps the Mac awake only while it's locked, so the screensaver or a real lock doesn't start while you're away.
- **Open at Login**
- **Accessibility Settings…**: opens System Settings → Privacy & Security → Accessibility, where you allow or remove SoftLock. Reads **Allow Accessibility Access…** when SoftLock doesn't have permission yet.

While locked, the icon becomes a filled padlock, and **Quit** and **Accessibility Settings…** are disabled.

## Build & install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh           # builds build/SoftLock.app
./build.sh install   # builds, copies to /Applications, and launches it
```

The first time you choose **Lock**, macOS asks you to allow SoftLock in **System Settings → Privacy & Security → Accessibility**. Turn it on, then choose **Lock** again.

> The build is ad-hoc signed, so macOS ties the Accessibility permission to that exact build. After a rebuild, remove SoftLock from the Accessibility list (–) and add it again. You can avoid this by signing with a real identity: `SIGN_IDENTITY="Apple Development: …" ./build.sh`.

Each push also builds the app on GitHub Actions and uploads it as a `SoftLock` artifact. Downloaded builds are quarantined, so after unzipping run `xattr -dr com.apple.quarantine SoftLock.app`.

## How it works

SoftLock installs a `CGEventTap` at the HID level. The tap drops key, click, scroll and gesture events unless the pointer is over one of SoftLock's own windows: the status item or its open menu. The blur uses click-through overlay windows with the private `CGSSetWindowBackgroundBlurRadius` call (as iTerm2 does) to set a light radius. If that call is ever unavailable, it falls back to a standard, stronger `NSVisualEffectView` blur. Keep Awake holds an IOKit `PreventUserIdleDisplaySleep` power assertion.

## Limitations

- Some input can't be intercepted: the power button, Touch ID, closing the lid, and the hardware force-restart.
- When an app turns on Secure Keyboard Entry (for example, a focused password field or Terminal's "Secure Keyboard Entry"), macOS hides keystrokes from event taps, so those keystrokes reach that app.
