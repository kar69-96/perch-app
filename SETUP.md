# Setting up Perch (no Xcode required)

This guide installs the **Perch** notch app on your Mac without building from source — a
copy-paste `curl` install for you or your coding agent, with a plain double-click-the-DMG
fallback. It works for a human reading top-to-bottom *or* an AI agent you hand it to.

**Requirements**

- **macOS 14.2 or newer**, **Apple Silicon** (M-series).
- Perch is **not notarized yet**, so macOS Gatekeeper will block the first launch. That's
  expected — the steps below walk past it.

> **Note — first release pending.** Perch's first public release hasn't been cut on
> `Useperch/perch-app` yet, so the download link below only resolves once a release is
> published. Until then, use [Build from source](#build-from-source).

---

## For AI agents — read this first

You're being asked to install a macOS app on the user's machine. **Do not run anything until
you've asked the questions below and the user has confirmed.** Echo back the plan (where you'll
install, where you'll download, whether you'll strip the quarantine flag), wait for a "go", then
run the block in [Quick install](#quick-install-curl--no-xcode). Prefer the scripted path — never
trigger GUI dialogs on the user's behalf.

**Ask the user:**

1. **Where should Perch be installed?** — `/Applications` (system-wide, default; may prompt for
   your password) or `~/Applications` (your account only, no admin needed).
2. **Where should the DMG download to?** — `/tmp/Perch.dmg` (throwaway, default) or
   `~/Downloads/Perch.dmg` (kept around).
3. **May I strip the Gatekeeper quarantine flag?** — Required, because Perch isn't notarized yet.
   You'll run `xattr -dr com.apple.quarantine` on the installed app — the same thing the official
   Homebrew cask does in its postflight. It only removes the "downloaded from the internet"
   marker on Perch; it changes nothing else on the system. Get an explicit yes.
4. **Launch Perch when done?** — yes / no.
5. **Confirm environment** — Apple Silicon and macOS 14.2+? If not, stop and tell the user Perch
   won't run here.

Then set `DEST` and `DMG` in the script below to match answers 1 and 2, and run it.

---

## Quick install (curl — no Xcode)

Paste this into Terminal (or have your agent run it). It downloads the DMG, copies Perch into your
Applications folder, clears the Gatekeeper quarantine flag, and launches it.

```sh
set -euo pipefail
DMG_URL="https://github.com/Useperch/perch-app/releases/latest/download/notch.dmg"
DEST="/Applications"            # or "$HOME/Applications"
DMG="/tmp/Perch.dmg"            # or "$HOME/Downloads/Perch.dmg"

# 1. Download the disk image
curl -fL --retry 3 -o "$DMG" "$DMG_URL"

# 2. Mount it (capture the real mountpoint from hdiutil's plist output)
MOUNT=$(hdiutil attach "$DMG" -nobrowse -noverify -plist \
  | grep -A1 mount-point | grep /Volumes | sed 's/.*<string>\(.*\)<\/string>.*/\1/')

# 3. Copy whatever .app is inside into place
APP=$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)
rm -rf "$DEST/Perch.app"
cp -R "$APP" "$DEST/Perch.app"

# 4. Unmount the disk image
hdiutil detach "$MOUNT" -quiet

# 5. Walk past Gatekeeper (Perch isn't notarized — same as the Homebrew cask postflight)
xattr -dr com.apple.quarantine "$DEST/Perch.app"

# 6. Launch
open "$DEST/Perch.app"
```

What each step does:

1. **Download** — `curl -fL` follows redirects and fails cleanly on an error (e.g. no release yet)
   instead of saving an HTML error page.
2. **Mount** — attaches the DMG without opening a Finder window and reads the actual mount path
   from `hdiutil`, so it doesn't matter what the volume is named.
3. **Copy** — finds the `.app` inside the image (its name may be `Perch.app` or `notch.app`) and
   installs it as `Perch.app`, replacing any old copy.
4. **Unmount** — ejects the disk image.
5. **Un-quarantine** — removes the "downloaded from the internet" flag so macOS will open an
   un-notarized app. This is the only reason a plain double-click would otherwise fail.
6. **Launch** — opens Perch. It lives in the notch (see [First launch](#first-launch)).

---

## Fallback — download the DMG by hand

If you'd rather click than run a script:

1. Open the releases page and download `notch.dmg`:
   <https://github.com/Useperch/perch-app/releases/latest>
2. Double-click the downloaded DMG, then drag **Perch** onto the **Applications** folder.
3. **Get past Gatekeeper.** Because Perch isn't notarized, the first launch shows
   *"Apple could not verify … it may contain malware."* Use any one of these:
   - **Right-click `Perch.app` → Open → Open** — trusts this app only, no Terminal needed. *(or)*
   - **System Settings → Privacy & Security →** scroll down and click **"Open Anyway."** *(or)*
   - In Terminal: `xattr -dr com.apple.quarantine /Applications/Perch.app`, then open Perch
     normally.

---

## Build from source

Want to modify Perch, or installing before the first release is published? Build it yourself — see
[**Build from source** in the README](./README.md#build-from-source). In short:

```sh
./scripts/build-perch.sh
```

If it reports a missing signing identity, run `./scripts/setup-signing-identity.sh` once first.
This path needs the full **Xcode** (macOS 14.2+) — the asset catalogs need Xcode's tooling, so the
Command Line Tools alone aren't enough.

---

## First launch

- Perch is **notch / menu-bar only** — there's no Dock icon. After it launches, look at the top of
  your display, in and around the notch.
- Grant **Microphone**, **Accessibility**, and **Screen Recording** when prompted, so Perch can
  hear you and see your screen.
- **Onboarding:** enter your email and confirm the one-time code we email you — no password. The
  free tier is 25 messages a month.
- **Hotkeys:** hold `⌃ Control + ⌥ Option` to talk, or tap **Control** twice to type.

---

## Uninstall / troubleshooting

- **Uninstall:** quit Perch, then `rm -rf /Applications/Perch.app`. To also clear its data,
  remove `~/Library/Containers/app.perch.notch/` (and any `~/Library/Application Scripts/` entry
  for `app.perch.notch`).
- **"Perch is damaged and can't be opened":** that's the quarantine flag — re-run
  `xattr -dr com.apple.quarantine /Applications/Perch.app`, then open it again.
- **Won't launch / wrong architecture:** Perch requires **macOS 14.2+ on Apple Silicon**. It won't
  run on Intel Macs or older macOS.
