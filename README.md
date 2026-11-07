# zcode-standalone

> **Personal tooling, not affiliated with or endorsed by Z.ai.** This repo
> distributes patches to the Apache-2.0 [zai-org/ZCode](https://github.com/zai-org/ZCode)
> source and builds a self-hosted engine for personal use. It authenticates
> with the user's own official credentials, self-identifies honestly
> (`sourceTitle: cli`, real device id), and treats every server-side gate
> (quotas, eligibility, version checks) as authoritative — refusals are
> surfaced, never bypassed. Users are responsible for complying with the
> vendor's terms. No Z.ai source code is contained here; only patches.

Our own build of the ZCode engine + TUI, living outside the ZCode.app bundle.
Replaces the desktop app as the primary entrypoint.

## Layout

- `build.sh` — build engine from an upstream tag + our patches → `~/.zcode/local/engine`
- `patches/*.patch` — our only source modifications, applied on top of clean tags
- `verify-compliance.sh` — refuses to build if patches touch client-identity files;
  detects upstream drift in those files (human review via `--update`)
- `fingerprint-baseline.json` — per-tag sha256 of identity/fingerprint files
- `docs/upstream-feedback.md` — engineering findings offered to the ZCode team
- `src/` — the ZCode clone (gitignored)
- `tui-deploy/` — self-contained @zcode/tui node_modules closure (gitignored)

## Login architecture (IMPORTANT — do not isolate the data root)

The TUI and the desktop app **share one login store** (the default
`~/.zcode/v2/credentials.json`). Do NOT set `ZCODE_DATA_BASE_DIR` on the
TUI wrapper — an isolated root was an early design that was abandoned after
the real interop root cause was found (the desktop persists a *business*
token in `oauth:zai:access_token` while stock CLI logins persist a raw
1-hour OAuth token; patches 0005/0006 make both surfaces produce and consume
the business token, so one login serves both).

Rules:

- Log in from **either surface** whenever convenient — `/login` is always
  allowed and simply writes a fresh business token both surfaces ride.
- A desktop-only login does not carry the terminal keys: the TUI shows your
  models but the first turn asks you to `/login` once (clear error, one click,
  desktop app unaffected).
- An isolated data root silently breaks start-plan entitlement (patch 0007's
  balance probe needs `telemetry-state.json`'s deviceMid, which lives in the
  shared root) — keep the root shared.
  ride the shared business token. Neither needs to be kept running.
- Never `/login` (or `zcode login`/`logout`) from the TUI while a login
  exists — patch 0004's guards refuse it; `ZCODE_STANDALONE_ALLOW_LOGIN=1` overrides
  for deliberate re-logins.
- Also, an isolated data root silently breaks start-plan entitlement
  (patch 0007's balance probe needs `telemetry-state.json`'s deviceMid, which
  lives in the shared root) — another reason to keep the root shared.

Wrapper (`~/.local/bin/zcode-tui`) is exactly:

```zsh
#!/bin/zsh
exec node "$HOME/.zcode/local/engine/zcode.cjs" tui "$@"
```

## Compliance contract

We never patch the files in `FINGERPRINT_FILES` (verify-compliance.sh enforces):
client identity stays the vendor's own — `sourceTitle: "cli"`, real deviceMid,
official OAuth credentials, the vendor's endpoint routing. Any feature gated
server-side (off-peak tickets, start-plan entitlement) is *requested honestly*
and accepted as unavailable if refused.

Deliberate exception (user-approved): the engine reports the **product
version** of the tag it was built from (`__OWN_PRODUCT_VERSION__`, patch 0008)
rather than the CLI subpackage version — both are true of the build; endpoints
that version-gate accept product versions only.

## Version bumps

1. `./build.sh` (defaults to the installed app's tag — but our engine does NOT
   need to match the app; any tag works since the TUI runs standalone). The
   baked product version tracks the tag automatically.
2. If a patch conflicts: rebase it on the new tag, verify it still does what it
   says, commit, rebuild.
3. If compliance fails with UPSTREAM DRIFT: review the upstream diff of the
   listed files, then re-run verify-compliance.sh with --update only if the
   identity semantics are still acceptable.

## Engine runtime layout (~/.zcode/local/engine)

zcode.cjs, provider/zcode-builtin.json (adjacent, so no env-var workaround),
packages/* (official plugins + bundled skills), node-runtime/ (npm shim),
node_modules/ (@zcode/tui closure + @zcode/services ESM bundle).

## Feature flags

- `ZCODE_STANDALONE_OFFPEAK=1` — in-TUI off-peak host (idle tasks; queue proven live,
  full dispatch loop pending live verification)
- `ZCODE_STANDALONE_STARTPLAN=1` — start-plan models in `/model` (zai family only;
  balance-gated entitlement)
