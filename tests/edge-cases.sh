#!/usr/bin/env bash
# Edge-case test suite for the Bifrost proxy gateway.
#
#   ./tests/edge-cases.sh              # static config checks + live checks that cost no tokens
#   ./tests/edge-cases.sh --static     # config.json / .env consistency only (no network)
#   ./tests/edge-cases.sh --full       # also runs billed inference, streaming, cache and payload tests
#
# Exit code is 0 only when every check passes. Requires: bash, curl, python3.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${BIFROST_BASE_URL:-http://localhost:4000}"
MODE="live"
case "${1:-}" in
  --static) MODE="static" ;;
  --full)   MODE="full" ;;
  -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
  "")       ;;
  *) echo "unknown flag: $1 (use --static or --full)"; exit 2 ;;
esac

PASS=0
FAIL=0
failures=()

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); failures+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
skip() { printf '  \033[90mSKIP\033[0m %s\n' "$1"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

expect() { # expect <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (expected $2, got $3)"; fi
}
expect_in() { # expect_in <label> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing '$2')" ;; esac
}

if [ ! -f "$ROOT/.env" ]; then
  echo "missing $ROOT/.env"; exit 2
fi
set -a
# shellcheck disable=SC1091
. "$ROOT/.env"
set +a
: "${BIFROST_VIRTUAL_KEY:?BIFROST_VIRTUAL_KEY not set in .env}"
AUTH="Authorization: Bearer $BIFROST_VIRTUAL_KEY"
JSON="content-type: application/json"
BODY="$(mktemp)"; HDRS="$(mktemp)"; COOKIE="$(mktemp)"
trap 'rm -f "$BODY" "$BODY.large" "$HDRS" "$COOKIE"' EXIT

# POST/GET helper: sets $CODE, writes body to $BODY and response headers to $HDRS.
req() {
  local method="$1"; shift
  CODE=$(curl -s -o "$BODY" -D "$HDRS" -w '%{http_code}' -X "$method" "$@" 2>/dev/null)
  CODE=${CODE:-000}
}
hdr() { grep -i "^$1:" "$HDRS" 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r'; }

##############################################################################
section "1. Static config validation (config.json vs .env)"
##############################################################################
python3 - "$ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
cfg = json.load(open(os.path.join(root, 'bifrost/config.json')))
env = {}
for line in open(os.path.join(root, '.env')):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        k, v = line.split('=', 1)
        env[k.strip()] = v.strip()
errors, notes = [], []

# Every env.X reference must be defined and non-placeholder.
refs = set(re.findall(r'env\.([A-Z0-9_]+)', json.dumps(cfg)))
for name in sorted(refs):
    if name not in env:
        errors.append(f"config references env.{name} but .env has no such key")
    elif env[name] in ('', 'replace-me', 'changeme'):
        errors.append(f"env.{name} is empty or still a placeholder")

providers = cfg.get('providers', {})
gov = cfg.get('governance', {})
limits = {l['id'] for l in gov.get('rate_limits', [])}
vk = (gov.get('virtual_keys') or [{}])[0]

# Rate limit ids referenced by virtual keys must exist.
for pc in vk.get('provider_configs', []):
    rl = pc.get('rate_limit_id')
    if rl and rl not in limits:
        errors.append(f"provider_config {pc.get('provider')} uses undefined rate_limit_id '{rl}'")
    if not pc.get('key_ids'):
        errors.append(f"provider_config {pc.get('provider')} has no key_ids (requests will fail with 'no keys found')")

# Routing rules: weights sum to 1, targets exist and are allowed by the virtual key.
def provider_models(p):
    models = set()
    for k in providers.get(p, {}).get('keys', []):
        models.update(k.get('models') or [])
    return models

rules = gov.get('routing_rules', [])
for r in rules:
    targets = r.get('targets') or []
    total = sum(float(t.get('weight', 0)) for t in targets)
    if abs(total - 1.0) > 1e-6:
        errors.append(f"routing rule '{r['id']}' target weights sum to {total}, expected 1.0")
    for t in targets:
        p, m = t.get('provider'), t.get('model')
        if p not in providers:
            errors.append(f"routing rule '{r['id']}' targets unknown provider '{p}'")
        elif m not in provider_models(p):
            errors.append(f"routing rule '{r['id']}' targets {p}/{m}, which is not in that provider's model list")
    for fb in r.get('fallbacks') or []:
        if '/' not in fb:
            errors.append(f"routing rule '{r['id']}' fallback '{fb}' is not <provider>/<model>")
            continue
        p, m = fb.split('/', 1)
        if p not in providers:
            errors.append(f"routing rule '{r['id']}' fallback provider '{p}' not configured")
        elif m not in provider_models(p):
            errors.append(f"routing rule '{r['id']}' fallback {p}/{m} is not in that provider's model list")
        vk_models = {pc['provider']: set(pc.get('allowed_models') or [])
                     for pc in vk.get('provider_configs', [])}
        if p in vk_models and m not in vk_models[p]:
            errors.append(f"routing rule '{r['id']}' fallback {p}/{m} is blocked by the virtual key allowlist")
    if not r.get('enabled', True):
        notes.append(f"routing rule '{r['id']}' is disabled")

# Providers must have network config with retries; note missing key_ids on the key objects.
for name, p in providers.items():
    net = p.get('network_config') or {}
    if 'default_request_timeout_in_seconds' not in net:
        notes.append(f"provider '{name}' has no default_request_timeout_in_seconds")
    if p.get('custom_provider_config') and not net.get('base_url'):
        errors.append(f"custom provider '{name}' has no base_url")

# Cache plugin needs dimension; direct mode is dimension 1.
for plugin in cfg.get('plugins', []):
    if plugin.get('name') == 'semantic_cache' and plugin.get('enabled'):
        c = plugin.get('config') or {}
        if 'dimension' not in c:
            errors.append("semantic_cache enabled without config.dimension")
        if c.get('dimension') == 1 and (c.get('provider') or c.get('embedding_model')):
            errors.append("semantic_cache: dimension=1 (direct mode) must not set provider/embedding_model")
        if c.get('dimension', 1) > 1 and not c.get('provider'):
            errors.append("semantic_cache: semantic mode requires config.provider")
        if not c.get('default_cache_key'):
            notes.append("semantic_cache: no default_cache_key, so only requests that send "
                         "the x-bf-cache-key header are ever cached")
        if int(c.get('conversation_history_threshold', 3)) <= 3:
            notes.append("semantic_cache: conversation_history_threshold<=3 disables caching for "
                         "any multi-turn agent traffic")
        if cfg.get('vector_store', {}).get('enabled') is not True:
            errors.append("semantic_cache enabled but vector_store is not enabled")

print("  resolved env refs:", len(refs))
for n in notes:
    print(f"  \033[33mNOTE\033[0m {n}")
if errors:
    for e in errors:
        print(f"  \033[31mFAIL\033[0m {e}")
    print(f"  {len(errors)} static error(s)")
    sys.exit(1)
print("  \033[32mPASS\033[0m config.json is internally consistent")
PY
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); failures+=("static config validation"); else PASS=$((PASS+1)); fi

[ "$MODE" = "static" ] && { printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit $?; }

##############################################################################
section "2. Reachability and auth boundaries"
##############################################################################
req GET "$BASE/"
expect "GET / (dashboard shell)" 200 "$CODE"

req GET "$BASE/v1/models"
expect "GET /v1/models without credentials" 401 "$CODE"

req GET "$BASE/v1/models" -H "Authorization: Bearer definitely-not-the-key"
expect "GET /v1/models with wrong key" 401 "$CODE"

req GET "$BASE/v1/models" -H "$AUTH"
expect "GET /v1/models with virtual key" 200 "$CODE"

req POST "$BASE/anthropic/v1/messages" -H "$JSON" \
  -d '{"model":"claude-haiku-5-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
expect "POST /anthropic/v1/messages without credentials" 401 "$CODE"

req POST "$BASE/v1/chat/completions" -H "Authorization: Bearer $NVIDIA_API_KEY_1" -H "$JSON" \
  -d '{"model":"nvidia/nvidia/nemotron-3.5-lightning-30b-a3b","messages":[{"role":"user","content":"hi"}]}'
expect "provider API key used as inference auth (must be rejected)" 401 "$CODE"

req GET "$BASE/api/providers"
expect "dashboard API without session" 401 "$CODE"

req POST "$BASE/api/session/login" -H "$JSON" \
  -d "{\"username\":\"$BIFROST_ADMIN_USERNAME\",\"password\":\"wrong-password\"}"
expect "dashboard login with wrong password" 401 "$CODE"

req POST "$BASE/api/session/login" -c "$COOKIE" -H "$JSON" \
  -d "{\"username\":\"$BIFROST_ADMIN_USERNAME\",\"password\":\"$BIFROST_ADMIN_PASSWORD\"}"
expect "dashboard login with admin credentials" 200 "$CODE"

req GET "$BASE/api/providers" -b "$COOKIE"
expect "dashboard API with session" 200 "$CODE"

##############################################################################
section "3. Request validation (no upstream calls)"
##############################################################################
req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" -d ''
expect "empty body" 400 "$CODE"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" -d '{"model":'
expect "malformed JSON" 400 "$CODE"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" \
  -d '{"messages":[{"role":"user","content":"hi"}]}'
expect "missing model" 400 "$CODE"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" -d '{"model":"agnes/agnes-2.5-flash"}'
expect "missing messages" 400 "$CODE"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" \
  -d '{"model":"agnes/agnes-2.5-flash","messages":[]}'
expect "empty messages array" 400 "$CODE"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" \
  -d '{"model":"nope/nope-model","messages":[{"role":"user","content":"hi"}]}'
expect "unknown provider" 400 "$CODE"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" \
  -d '{"model":"agnes/not-a-real-model","messages":[{"role":"user","content":"hi"}]}'
expect "model not allowlisted for the virtual key" 403 "$CODE"

req POST "$BASE/anthropic/v1/messages" -H "$AUTH" -H "$JSON" \
  -d '{"model":"gpt-4o","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
expect "anthropic path with unresolvable model" 400 "$CODE"

# Known quirk: the dashboard SPA answers unknown paths with HTML and status 200.
req GET "$BASE/v1/does-not-exist" -H "$AUTH"
if [ "$CODE" = "200" ] && grep -qi '<!doctype html' "$BODY"; then
  printf '  \033[33mNOTE\033[0m unknown routes return the dashboard HTML with 200 (SPA fallback)\n'
  PASS=$((PASS+1))
else
  bad "unknown route handling changed (status $CODE)"
fi

##############################################################################
section "4. Anthropic compatibility"
##############################################################################
req POST "$BASE/anthropic/v1/messages/count_tokens" -H "$AUTH" -H "$JSON" \
  -d '{"model":"claude-haiku-5-5","messages":[{"role":"user","content":"count these tokens"}]}'
expect "count_tokens" 200 "$CODE"

request_id=$(hdr "X-Bifrost-Request-Id")
if [ -n "$request_id" ]; then ok "response carries X-Bifrost-Request-Id"; else bad "missing X-Bifrost-Request-Id"; fi

if [ "$MODE" != "full" ]; then
  skip "inference, streaming, cache and payload checks (run with --full)"
else
##############################################################################
section "5. Routing aliases ($MODE)"
##############################################################################
for alias in claude-sonnet-5 claude-opus-5-5 claude-haiku-5-5 claude-fable-5-1; do
  req POST "$BASE/anthropic/v1/messages" -H "$AUTH" -H "$JSON" \
    -d "{\"model\":\"$alias\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}]}"
  if [ "$CODE" = "200" ]; then
    ok "$alias -> $(hdr X-Bifrost-Provider) ($(hdr X-Bifrost-Resolved-Model))"
  else
    bad "$alias returned $CODE: $(head -c 160 "$BODY")"
  fi
done

##############################################################################
section "6. Streaming"
##############################################################################
CODE=$(curl -s -N -o "$BODY" -D "$HDRS" -w '%{http_code}' -m 120 -X POST \
  -H "$AUTH" -H "$JSON" -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-haiku-5-5","max_tokens":24,"stream":true,"messages":[{"role":"user","content":"Count to 3"}]}' \
  "$BASE/anthropic/v1/messages")
expect "anthropic SSE status" 200 "$CODE"
expect_in "anthropic SSE content-type" "text/event-stream" "$(hdr Content-Type)"
expect_in "anthropic SSE emits message_start" "event: message_start" "$(cat "$BODY")"

CODE=$(curl -s -N -o "$BODY" -D "$HDRS" -w '%{http_code}' -m 120 -X POST \
  -H "$AUTH" -H "$JSON" \
  -d '{"model":"agnes/agnes-2.5-flash","stream":true,"messages":[{"role":"user","content":"Count to 3"}]}' \
  "$BASE/v1/chat/completions")
expect "openai SSE status" 200 "$CODE"
expect_in "openai SSE content-type" "text/event-stream" "$(hdr Content-Type)"

##############################################################################
section "7. Caching"
##############################################################################
CACHE_KEY="edge-$RANDOM-$RANDOM"
CACHE_MODEL="nvidia/nvidia/nemotron-3.5-lightning-30b-a3b"
CACHE_BODY="{\"model\":\"$CACHE_MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"cache probe $CACHE_KEY\"}]}"
req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" -H "x-bf-cache-key: $CACHE_KEY" -d "$CACHE_BODY"
expect "cache probe (miss)" 200 "$CODE"
expect "first request is a cache miss" "false" "$(hdr X-Bifrost-Cache-Hit)"
req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" -H "x-bf-cache-key: $CACHE_KEY" -d "$CACHE_BODY"
expect "identical request is a cache hit" "true" "$(hdr X-Bifrost-Cache-Hit)"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" -H "x-bf-cache-key: $CACHE_KEY" \
  -d "{\"model\":\"$CACHE_MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"different $CACHE_KEY\"}]}"
expect "different prompt with same cache key misses" "false" "$(hdr X-Bifrost-Cache-Hit)"

##############################################################################
section "8. Payload and encoding edge cases"
##############################################################################
python3 -c "import json;print(json.dumps({'model':'$CACHE_MODEL','max_tokens':8,'messages':[{'role':'user','content':'x'*200000+' reply OK'}]}))" > "$BODY.large" 2>/dev/null || true
req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" --data-binary @"$BODY.large"
expect "200KB prompt" 200 "$CODE"

req POST "$BASE/v1/chat/completions" -H "$AUTH" -H "$JSON" \
  -d "{\"model\":\"$CACHE_MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"日本語 🎌 emoji, reply OK\"}]}"
expect "unicode/emoji prompt" 200 "$CODE"
fi

##############################################################################
printf '\n\033[1mSummary:\033[0m %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed checks:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
