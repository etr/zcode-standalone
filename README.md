# zcode-own

Our own build of the ZCode engine + TUI, living outside the ZCode.app bundle.
Replaces the desktop app as the primary entrypoint.

## Layout

- `build.sh` — build engine from an upstream tag + our patches → `~/.zcode/local/engine`
- `patches/*.patch` — our only source modifications, applied on top of clean tags
- `verify-compliance.sh` — refuses to build if patches touch client-identity files;
  detects upstream drift in those files (human review via `--update`)
- `fingerprint-baseline.json` — per-tag sha256 of identity/fingerprint files
- `src/` — the ZCode clone (gitignored)
- `tui-deploy/` — self-contained @zcode/tui node_modules closure (gitignored)

## Compliance contract

We never patch the files in `FINGERPRINT_FILES` (verify-compliance.sh enforces):
client identity stays the vendor's own — `sourceTitle: "cli"`, real deviceMid,
official OAuth credentials, the vendor's endpoint routing. Any feature gated
server-side (off-peak tickets, start-plan entitlement) is *requested honestly*
and accepted as unavailable if refused.

## Version bumps

1. `./build.sh` (defaults to the installed app's tag — but our engine does NOT
   need to match the app; any tag works since the TUI runs standalone)
2. If a patch conflicts: rebase it on the new tag, verify it still does what it
   says, commit, rebuild.
3. If compliance fails with UPSTREAM DRIFT: review the upstream diff of the
   listed files, then re-run verify-compliance.sh with --update only if the
   identity semantics are still acceptable.

## Engine runtime layout (~/.zcode/local/engine)

zcode.cjs, provider/zcode-builtin.json (adjacent, so no env-var workaround),
packages/* (official plugins + bundled skills), node-runtime/ (npm shim),
node_modules/ (@zcode/tui closure). Launched via `~/.local/bin/zcode-tui`
which also sets ZCODE_DATA_BASE_DIR=~/.zcode/tui for login isolation from
the desktop app.
