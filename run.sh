#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="/home/w568w/.claude-code-router/config.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "config not found: $CONFIG_PATH" >&2
  exit 1
fi

eval "$(python3 - <<'PY'
import json
from shlex import quote

path = "/home/w568w/.claude-code-router/config.json"
cfg = json.load(open(path, encoding="utf-8"))
providers = cfg.get("Providers", [])
if not providers:
    raise SystemExit("no providers found in config")
p = providers[0]
base = p.get("api_base_url", "")
key = p.get("api_key", "")
models = p.get("models", [])
model = models[0] if models else ""

if not base or not key or not model:
    raise SystemExit("provider missing api_base_url/api_key/models[0]")

print(f"export OPENAI_API_BASE={quote(base)}")
print(f"export OPENAI_API_KEY={quote(key)}")
print(f"export OPENAI_MODEL={quote(model)}")
PY
)"

exec zig build run -Doptimize=ReleaseSmall -- "$@"
