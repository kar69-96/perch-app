# Setting up Perch 

This guide installs the **Perch** notch app on your Mac without building from source — a
copy-paste `curl` install for you or your coding agent, with a fallback as a double-click-the-DMG
fallback. 

**Requirements**

- **macOS 14.2 or newer**, **Apple Silicon** (M-series).
- Perch is **not notarized yet**, so macOS Gatekeeper will block the first launch. That's
  expected — the steps below walk past it.

---

## For AI agents — read this first

You're being asked to install a macOS app on the user's machine. **Do not run anything until
you've asked the questions below and the user has confirmed.** Echo back the plan (where you'll
install, where you'll download, whether you'll strip the quarantine flag), wait for a "go", then
run the block in [Quick install](#quick-install-curl--no-xcode). Prefer the scripted path — never
trigger GUI dialogs on the user's behalf.

First: confirm that the machine is Apple Silicon and macOS 14.2+ If not, stop and tell the user Perch
   won't run here.

---

## Quick install 

Paste this into Terminal (or have your agent run it). It downloads the DMG, copies Perch into your
Applications folder, clears the Gatekeeper quarantine flag, and launches it.

```sh
set -euo pipefail
DMG_URL="https://github.com/Useperch/perch-app/releases/latest/download/perch.dmg"
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

---

## Fallback — download the DMG by hand

If you'd rather click than run a script:

1. Open the releases page and download `perch.dmg`:
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

Want to modify Perch? Build it yourself!
In short:

```sh
./scripts/build-perch.sh
```

If it reports a missing signing identity, run `./scripts/setup-signing-identity.sh` once first.
This path needs the full **Xcode** (macOS 14.2+) — the asset catalogs need Xcode's tooling, so the
Command Line Tools alone aren't enough.

**What works in a source build:** everything you see in the official app — chat, voice,
onboarding, the dashboard — talks to the same hosted backend out of the box (the gateway
URL is committed). Two features are only in the official DMG:

- **The autonomous browser agent** — its sidecar lives in a separate (closed) repo and is
  bundled into official builds; a source build simply won't offer agent runs.
- **Workflow sharing** — the committed `Info.plist` carries a placeholder client secret
  (`YOUR_WORKFLOW_SHARE_SECRET`); the real one is injected at release-packaging time, so
  share uploads from a source build get a 401.

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
