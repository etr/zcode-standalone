# Engineering feedback for the ZCode team

Findings from building a standalone (terminal-only) ZCode engine from the
`zai-org/ZCode` source, tag v3.17.2 / CLI 0.17.1. Working fixes for all of
these live in this repository's `patches/` — happy for any of it to be
upstreamed, no attribution needed.

## 1. Desktop ↔ CLI credential interop is broken (highest impact)

`oauth:zai:access_token` carries **different token semantics per client**:

- The desktop's zai adapter persists the **business token** (it converts via
  `/api/auth/z/login` at login — see the contract comment in
  `packages/services/src/oauth/providers/zaiProviderAdapter.ts`).
- The CLI's `loginZCodeCli` persists the **raw OAuth token** (1h JWT) —
  and drops the `refresh_token` the poll response already carries
  (`cli-oauth.ts:221` reads it; only bigmodel persists it, `auth-login.ts:151`).

Consequences on a machine using both surfaces:
- CLI-side requests feed the app's business token into `z/login` →
  `500 "Z.ai user information is invalid"` → `project_token_login_failed`.
- A CLI login mints a 1-hour session (no refresh persisted), and the two
  surfaces' logins disturb each other.
- `z/login` is not a valid oracle for app tokens — worth knowing when debugging.

Working fixes here: `0005-accept-desktop-business-token-passthrough.patch`
(the zai business-token cache recognizes already-business tokens by claim
shape — JWT without `iat`) and `0006-cli-login-persists-business-token.patch`
(CLI login performs the same conversion the desktop adapter does).

## 2. Standalone `zcode tui` is broken in the app distribution

- `resolveBundledZCodeBuiltinProviderConfig` probes
  `entryDir/provider/zcode-builtin.json` and
  `entryDir/../../../../../config/provider/zcode-builtin.json`; in the .app
  layout the 5-level climb lands at the filesystem root, so any standalone
  invocation dies with `无法定位 CLI ZCode Built-in Provider Config`.
- The node-bundle artifact dynamically imports `@zcode/tui`
  (`tui-runtime-loader.ts`), but the bundle ships no `node_modules/@zcode/tui`
  and the package is not on npm — the non-SEA import can never resolve.

Fix sketch: walk up from the entrypoint until `config/provider/zcode-builtin.json`
exists; ship `@zcode/tui` in the bundle (a pnpm deploy closure works) or publish
the package.

## 3. The start-plan endpoint's version gate blocks your own CLI version

`https://zcode.z.ai/api/v1/zcode-plan/anthropic` rejects requests whose
declared client version isn't a known product version: `user-agent:
ZCode/0.17.1` + `x-zcode-app-version: 0.17.1` (the CLI subpackage version)
gets `blocked due to unusual activity`; `3.17.2` passes. Byte-identical
requests otherwise. If a standalone CLI is ever shipped for real, its own
gate will block it. Suggestion: version the CLI as `3.17.2-cli` (or pass the
product version through) and allowlist that shape.

## 4. Quota errors discard the reset time

`classifyOffPeakCreateFailure` drops `OffPeakServerError.nextTakeAt`; the
model-facing text can't say when the daily idle-task quota resets even though
the server sends `next_take_at`. Fix: thread it into `errorCode` and render it
in `throwOffPeakCreateFailure`.

## 5. The off-peak queue is already host-agnostic

`OffPeakTaskService` / `OffPeakTaskRepo` / `OffPeakServerClient`
(`packages/services/src/session/`) have no Electron dependency; we run the
full take-ticket → poll → claimDue → dispatch loop inside a terminal process
(see `0002-standalone-offpeak-host-in-tui.patch`). If a first-party CLI host is on
the roadmap, most of the work is done.

---

Reproduction details, byte-level request captures, and the debug trail are
available on request. This repo also contains a compliance-guarding build
pipeline (fingerprint files whose sha256 must never be modified by patches)
in case that pattern is useful for your own release process.
