#!/usr/bin/env bash
# Launch Apple's Foundation Models Chat Completions server and expose the
# on-device (system) and Private Cloud Compute (pcc) models as an
# OpenAI-compatible endpoint that racecontrol can use as backend tiers.
#
#   ./fm-serve.sh                 # 127.0.0.1:8898
#   FM_PORT=9000 ./fm-serve.sh
#
# Then point a racecontrol [[backends]] entry at it with model_id = "system"
# (on-device) or "pcc" (cloud) -- see router.fm.example.toml. No racecontrol
# code changes: it's just another OpenAI upstream.
set -euo pipefail

HOST="${FM_HOST:-127.0.0.1}"
PORT="${FM_PORT:-8898}"

if ! command -v fm >/dev/null 2>&1; then
    echo "error: the 'fm' CLI was not found. It ships with macOS 26+/27 Apple Intelligence." >&2
    exit 1
fi

echo "[fm-serve] model availability on this machine:"
fm available || true
echo "[fm-serve] starting on ${HOST}:${PORT}"
echo "[fm-serve]   system = on-device (ANE, free, private)"
echo "[fm-serve]   pcc    = Private Cloud Compute (needs the private-cloud-compute entitlement/eligibility)"
exec fm serve --host "$HOST" --port "$PORT"
