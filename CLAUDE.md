# CLAUDE.md — beta-app-perch

## Repository

- **This folder → GitHub repo:** `Useperch/perch-app` (**primary clone**, branch **`main`**)
- **Role:** Canonical checkout of the macOS "notch" app — **this folder owns the real
  `.git` object store**. Tracks `main` (the beta/release line). The `dev` development
  line is a **linked worktree** at `../dev-perch/app`.
- **Org:** all Perch code lives under the **`Useperch`** GitHub org:
  - `Useperch/perch-app` — this app (Swift notch client)
  - `Useperch/perch-backend` — backend / gateway / worker
  - `Useperch/perch-site` — marketing website
  - `Useperch/perch-monorepo-archive` — **archived** original monorepo (read-only, history only)

## Secrets — this repo is PUBLIC

- **Never commit secrets, keys, or signing material.** The committed
  `perch/notch/Info.plist` carries only placeholders (e.g.
  `YOUR_WORKFLOW_SHARE_SECRET`); `scripts/package-release.sh` injects real
  values at package time from the gitignored `.env` at the repo root.
- Real secrets live outside version control only: `.env` (workflow-share
  client secret), `~/.perch-release/sparkle_ed25519_key` (Sparkle update
  signing), `~/Library/Keychains/perchdev.keychain-db` (code-signing cert).
  `.gitignore` blocks the common key/cert file types defensively.
- **Only `main` is ever pushed to `origin`.** Internal branches (`dev`,
  experiments) stay local — `dev` lives in the `../dev-perch/app` worktree
  and must never be pushed to the public remote.
- Before any commit, check the diff for credentials, tokens, personal data,
  or internal URLs that don't belong in a client-facing repo.
