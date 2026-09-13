#!/bin/bash
# Smoke test per SPEC.md R8. Run inside the instance (or against a reachable host).
# Usage: ./smoke_test.sh [base_url] [api_key]
set -uo pipefail

BASE="${1:-http://127.0.0.1:7862}"
KEY="${2:-${MUSIC_API_KEY:-}}"
AUTH=()
[ -n "$KEY" ] && AUTH=(-H "Authorization: Bearer $KEY")

fail() { echo "FAIL: $*"; exit 1; }

echo "== /health (waiting up to 20 min for model load) =="
for i in $(seq 1 240); do
    code=$(curl -s -o /tmp/health.json -w '%{http_code}' "$BASE/health")
    [ "$code" = "200" ] && break
    sleep 5
done
[ "$code" = "200" ] || fail "/health never became ready (last=$code: $(cat /tmp/health.json 2>/dev/null))"
cat /tmp/health.json; echo

echo "== /v1/models =="
curl -fsS "${AUTH[@]}" "$BASE/v1/models" | grep -q minimax_ttm || fail "model not listed"
echo "ok"

echo "== auth check (expect 401 without key) =="
if [ -n "$KEY" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/audio/speech" \
        -H 'Content-Type: application/json' \
        -d '{"model":"minimax_ttm","input":"[Instrumental]","instructions":"test","max_new_tokens":25}')
    [ "$code" = "401" ] || fail "expected 401 without key, got $code"
    echo "ok"
fi

echo "== generate 10s clip =="
curl -fsS "${AUTH[@]}" -X POST "$BASE/v1/audio/speech" \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "minimax_ttm",
      "input": "[Instrumental]\n(none)",
      "instructions": "A short ambient test tone, warm analog pad, 70 BPM, no vocals",
      "seed": 1,
      "max_new_tokens": 250,
      "response_format": "wav",
      "stream": false
    }' --output /tmp/smoke.wav || fail "generation request failed"

python3 - <<'EOF' || exit 1
import wave, sys
f = wave.open("/tmp/smoke.wav")
info = {"channels": f.getnchannels(), "rate": f.getframerate(),
        "width": f.getsampwidth(), "sec": round(f.getnframes()/f.getframerate(), 2)}
print(info)
assert info["channels"] == 2 and info["width"] == 2 and info["sec"] > 0, "bad WAV"
EOF
[ $? -eq 0 ] || fail "WAV validation failed"

echo "ALL CHECKS PASSED"
