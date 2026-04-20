#!/bin/sh
set -eu

UPSTREAM_REPO="${1:-${OPENCLAW_UPSTREAM_REPO:-openclaw/openclaw}}"
API_URL="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"

PYTHON_BIN="${PYTHON_BIN:-}"
if [ -z "$PYTHON_BIN" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN=python
  else
    echo "错误: 未找到 python3 或 python" >&2
    exit 1
  fi
fi

"$PYTHON_BIN" - "$API_URL" <<'PY'
import json
import sys
from urllib.request import Request, urlopen

url = sys.argv[1]

try:
    req = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "codex-openclaw-version-resolver",
        },
    )
    with urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))

    tag = (payload.get("tag_name") or "").strip()
    if not tag:
        raise RuntimeError("tag_name is empty")

    print(tag[1:] if tag.startswith("v") else tag)
except Exception as exc:  # noqa: BLE001 - CI helper script
    print(f"错误: 无法从上游 release 解析版本: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
