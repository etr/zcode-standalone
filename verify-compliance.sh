#!/bin/zsh
# verify-compliance.sh — re-verify the compliance fingerprint at every build.
#
# Usage: verify-compliance.sh <src-dir> <tag> <baseline-json> [--update]
#
# Checks:
#   1. Our patches must NOT modify any fingerprint file (git diff vs tag must be empty
#      for those paths). This is the hard guarantee: we never touch client identity.
#   2. If the tag is in the baseline, fingerprint file hashes must match the recorded
#      ones; a mismatch means UPSTREAM changed identity/fingerprint code since the
#      baseline was recorded — build stops for human review (review the upstream diff,
#      then re-run with --update after consciously accepting it).
#   3. If the tag is new, its hashes are recorded (first-seen).
#
# Exit codes: 0 = verified, 1 = violation (patch touched fingerprint files),
#            2 = upstream drift (human review required).

set -euo pipefail

SRC_DIR="${1:?src dir required}"
TAG="${2:?tag required}"
BASELINE="${3:?baseline json required}"
UPDATE="${4:-}"

# Files that construct the client identity / fingerprint / account request auth.
# We promise never to patch these; upstream changes to them must be human-reviewed.
FINGERPRINT_FILES=(
  "apps/zcode-cli/packages/bootstrap/src/provider-endpoint-routing-source-headers.ts"
  "packages/shared/src/zcode-source-headers.ts"
  "apps/zcode-cli/packages/adapters/src/model/anthropic-request-metadata.ts"
  "apps/zcode-cli/packages/adapters/src/model/official-coding-plan-gateway.ts"
  "apps/zcode-cli/packages/adapters/src/model/provider-endpoint-routing-fetch.ts"
  "packages/services/src/session/offPeakServerClient.ts"
  "packages/services/src/session/offPeakRuntimeModel.ts"
  "packages/services/src/model-provider/zaiStartPlanBilling.ts"
  "apps/zcode-cli/packages/adapters/src/auth/shared-credentials.ts"
)

cd "$SRC_DIR"

violations=0
echo "==> [compliance] checking patches do not touch fingerprint files"
for f in "${FINGERPRINT_FILES[@]}"; do
  if ! git diff "$TAG" -- "$f" | grep -q '^[+-][^+-]'; then
    continue
  fi
  echo "VIOLATION: patch modifies fingerprint file: $f"
  violations=$((violations+1))
done
if (( violations > 0 )); then
  echo "==> [compliance] FAILED: $violations fingerprint file(s) modified by our patches."
  exit 1
fi
echo "    OK: no fingerprint file modified."

echo "==> [compliance] comparing fingerprint hashes against baseline"
python3 - "$BASELINE" "$TAG" "$UPDATE" "${FINGERPRINT_FILES[@]}" <<'PY'
import hashlib, json, os, sys

baseline_path, tag, update, *files = sys.argv[1:]
baseline_path = os.path.expanduser(baseline_path)
baseline = {}
if os.path.exists(baseline_path):
    baseline = json.load(open(baseline_path))

def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()

current = {f: sha(f) for f in files if os.path.exists(f)}
missing = [f for f in files if not os.path.exists(f)]
for f in missing:
    print(f"WARNING: fingerprint file missing at this tag: {f}")

recorded = baseline.get(tag)
if recorded is None:
    baseline[tag] = current
    json.dump(baseline, open(baseline_path, "w"), indent=2, sort_keys=True)
    print(f"    NEW TAG recorded ({len(current)} files). Subsequent builds will verify against it.")
else:
    drift = {f: (recorded.get(f), h) for f, h in current.items() if recorded.get(f) != h}
    if drift:
        print("    UPSTREAM DRIFT detected in fingerprint files:")
        for f, (old, new) in drift.items():
            print(f"      {f}\n        baseline: {old}\n        current:  {new}")
        if update == "--update":
            baseline[tag] = current
            json.dump(baseline, open(baseline_path, "w"), indent=2, sort_keys=True)
            print("    Baseline UPDATED after explicit human review (--update).")
        else:
            print("    Build stopped. Review the upstream diff of these files, then re-run with --update.")
            sys.exit(2)
    else:
        print(f"    OK: all {len(current)} hashes match baseline for {tag}.")
PY

echo "==> [compliance] effective fingerprint summary (informational)"
grep -h 'sourceTitle' apps/zcode-cli/packages/bootstrap/src/provider-endpoint-routing-source-headers.ts | head -1 || true
grep -h 'ultra' apps/zcode-cli/packages/adapters/src/model/official-coding-plan-gateway.ts | head -2 || true
echo "    (sourceTitle must remain 'cli'; deviceMid read-only from telemetry-state.json)"
