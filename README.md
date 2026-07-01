# 🦉 Perch

Perch is a little buddy that lives in your MacBook notch and helps organize your life.
It sees your screen, talks back, and can go do things for you — right there at the top
of your display. Hold `⌃ Control + ⌥ Option` to talk, or tap **Control** twice to type.

- **macOS only** — works best on a MacBook with a notch, running **macOS 14.2 or newer**
  (Apple Silicon).
- This repository is the **open-source client** — the Swift app that runs on your Mac.

## Open core — what's here, what isn't

Perch is open-core. The app talks only to the hosted **Perch gateway** (a Cloudflare
Worker) over HTTPS; **no third-party API keys ever ship in the app**.

- **In this repo:** the full notch app — voice answer + point, the daily brief, the
  dashboard, onboarding, and all client-side logic. Built from source, it runs against
  the hosted gateway on the **free tier (25 messages / month)**.
- **Ships in the official download, not in this repo:** the autonomous browser/desktop
  **agent** is a closed binary. Building from source gives you everything except that
  agent target — its absence is expected, not a bug.
- **Not open:** the gateway Worker (which holds the provider keys), the account/billing
  backend, and the agent sidecar.

## Build from source

Requires the full **Xcode** (macOS 14.2+). Asset catalogs need Xcode's tooling, so the
Command Line Tools alone aren't enough.

```sh
./scripts/build-perch.sh
```

If it reports a missing signing identity, run `./scripts/setup-signing-identity.sh` once
first. Perch is menu-bar/notch only (`LSUIElement=true`) — after launch, find it in the
notch. Grant **Microphone**, **Accessibility**, and **Screen Recording** when asked so it
can hear you and see your screen.

## Accounts & pricing

- Enter your email at onboarding — no password, no code.
- **Free:** 25 messages a month (voice or text), metered to your account.
- **Pro ($20/mo):** unlimited messages + the autonomous agent. Upgrade from inside the
  app; it links to your email automatically.

## License

Perch is released under the **GNU General Public License v3.0 (GPL-3.0)** — the same
license as [boring.notch](https://github.com/TheBoredTeam/boring.notch), the project
Perch's notch shell is built on. See [LICENSE](./LICENSE) and [NOTICE.md](./NOTICE.md).
