# Patch index

One paragraph per patch: what it does, what it touches, and the design
decision it encodes. Read this *and* the diff before acting on a patch.

## 0001 — standalone registry: derived off-peak providers

`bootstrap/src/app/standalone-account-provider-runtime.ts`
The standalone (terminal) provider registry only ever entitled
individual-coding-plan providers. This adds `account:{family}-offpeak-idle-plan`
as a *derived* entitlement: entitled exactly when the same family's coding plan
is entitled (mirrors the desktop's `isCodingPlanDerivedMode`). The off-peak
provider is hidden (`visibility: hidden`) — it exists for the dispatcher, not
for `/model`.

## 0002 — in-TUI off-peak host

`cli/src/standalone-offpeak-host.ts` (new), `cli/src/tui-prompt-handler.ts`,
`cli/package.json`, `cli/scripts/build.mjs`, `pnpm-lock.yaml`
Runs the vendor's own queue (`OffPeakTaskService`/`Repo`/`ServerClient` from
`@zcode/services` — host-agnostic by construction) inside the TUI process:
`OffPeakPort` over the service, a 20s `claimDue` scheduler, dispatch into a
dedicated session whose configured default model is the off-peak provider.
Also externalizes `@zcode/services` from the CLI bundle (its TS source uses
`import.meta`, unusable in the CJS bundle) — build-services.mjs ships it as an
ESM module in the engine's node_modules. Always on.
Note: the off-peak tasks DB is shared with the desktop by upstream path
resolution — co-claiming is safe by design (BEGIN IMMEDIATE + stale reclaim).

## 0003 — off-peak quota errors carry the reset time

`services/src/session/offPeakTaskService.ts`,
`core/src/tool/handlers/off-peak.ts`
`OffPeakServerError` already carried `next_take_at`; the classifier dropped it.
Now threaded through `errorCode` and rendered in the model-facing text
("quota resets at …"). Pure UX; no behavior change.

## 0005 — business-token passthrough

`adapters/src/auth/zai-business-token-cache.ts`
The desktop persists a *business* token in `oauth:zai:access_token`; the stock
CLI persists a raw 1h OAuth token and re-runs it through `z/login`, which
rejects business tokens ("user information is invalid" →
`project_token_login_failed`). The cache now recognizes already-business
tokens (JWT without an `iat` claim, or opaque) and passes them straight to
project-key resolution. This is what lets the TUI ride a desktop login.

## 0006 — CLI login persists the business token

`bootstrap/src/auth-login.ts`
The CLI login flow performs the same `z/login` conversion the desktop adapter
does, persisting the long-lived business token (fallback to the raw token if
conversion fails — never blocks login). With 0005, every login from either
surface produces and consumes the universal token type. Verified: a TUI login
and the desktop app coexist on the shared store.

## 0007 — standalone start-plan provider (zai only)

`bootstrap/src/app/standalone-account-provider-runtime.ts`
Adds `account:zai-start-plan` entitlement via the account's real balance
(`GET zcode.z.ai/api/v1/zcode-plan/billing/balance`, Bearer `zcodejwttoken`,
mandatory `X-Device-Mid` from `telemetry-state.json` — which lives in the
SHARED root; an isolated data root breaks this silently). Models from balance
`capabilities`, normalized to official GLM ids. Request auth: Bearer JWT
(desktop parity). **Family-gated to zai** after a bug where the bigmodel
start-plan entry appeared entitled off zai credentials → deterministic
server blocks. Fail-closed everywhere. Always on.

## 0008 — report the product version

`cli/scripts/build.mjs`, `bootstrap/src/model-config.ts`,
`bootstrap/src/provider-endpoint-routing.ts`
Bakes `__OWN_PRODUCT_VERSION__` from the monorepo root package.json (i.e. the
tag `build.sh` builds from — auto-tracks version bumps). Platform headers
(`ZCode/<v>`, `x-zcode-app-version`) default to it when `ZCODE_APP_VERSION`
is unset. Rationale (user-approved): the engine IS built from that tag; the
CLI subpackage version (0.x) is also true but is rejected by version-gating
endpoints (verified byte-level: identical requests differing only in the
declared version flip block/pass). Env var still wins for desktop-hosted
children. This is the one deliberate deviation from "patch nothing
identity-adjacent" — the policy change lives in the header *callers*; the
fingerprint files themselves remain untouched.

## 0009 — desktop-login visibility + one-time terminal provisioning

`bootstrap/src/app/standalone-account-provider-runtime.ts`
Registry entitlement falls back to the shared desktop `user_info` when the
CLI identity keys are absent, so a desktop-only machine sees its models
immediately. Request time derives nothing: missing terminal keys produce a
clear "run /login once in this TUI" error; that login writes the keys
alongside the shared business token (desktop unaffected). This replaced an
earlier request-time identity-derivation design that fought the upstream
scope/fingerprint guards on every turn.

(Numbering note: 0004 — the login guard — was removed. It blocked exactly
this bootstrap flow, and with 0006-era business tokens a re-login is
harmless.)
