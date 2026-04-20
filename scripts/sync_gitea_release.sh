#!/bin/bash
set -euo pipefail

VER="${1:-}"
TAG="${2:-}"
ASSET_DIR="${3:-}"
BODY_FILE="${4:-}"

if [ -z "$VER" ] || [ -z "$TAG" ] || [ -z "$ASSET_DIR" ] || [ -z "$BODY_FILE" ]; then
  echo "用法: $0 <version> <tag> <asset_dir> <body_file>" >&2
  exit 1
fi

: "${GITEA_TOKEN:?请设置 GITEA_TOKEN}"
: "${GITEA_API_BASE:?请设置 GITEA_API_BASE}"
: "${GITEA_REPO:?请设置 GITEA_REPO}"

OWNER="${GITEA_REPO%%/*}"
REPO="${GITEA_REPO#*/}"
AUTH_HEADER="Authorization: token ${GITEA_TOKEN}"

api_url() {
  printf '%s/repos/%s/%s%s' "$GITEA_API_BASE" "$OWNER" "$REPO" "$1"
}

json_escape_file() {
  python - "$1" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(json.dumps(path.read_text(encoding="utf-8")))
PY
}

json_get() {
  python - "$1" "$2" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
value = payload
for key in sys.argv[2].split('.'):
    if not key:
        continue
    if isinstance(value, dict):
        value = value.get(key)
    else:
        value = None
        break

if value is None:
    sys.exit(1)

if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

urlencode() {
  python - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1]))
PY
}

wait_for_tag() {
  local encoded_tag attempts delay
  encoded_tag=$(urlencode "$TAG")
  attempts="${GITEA_TAG_WAIT_ATTEMPTS:-12}"
  delay="${GITEA_TAG_WAIT_DELAY:-5}"

  echo "==> 等待 Gitea tag 同步: ${TAG}"
  while [ "$attempts" -gt 0 ]; do
    if curl -fsS -H "$AUTH_HEADER" "$(api_url "/tags/${encoded_tag}")" >/dev/null 2>&1; then
      echo "==> 已确认 Gitea tag 存在: ${TAG}"
      return 0
    fi

    attempts=$((attempts - 1))
    if [ "$attempts" -le 0 ]; then
      break
    fi

    sleep "$delay"
  done

  echo "错误: 等待 Gitea tag 同步超时: ${TAG}" >&2
  return 1
}

echo "==> 尝试同步 Gitea 镜像"
curl -fsS -X POST \
  -H "$AUTH_HEADER" \
  "$(api_url "/mirror-sync")" >/dev/null || echo "警告: mirror-sync 调用失败，继续尝试发布 release" >&2
wait_for_tag

BODY_JSON=$(json_escape_file "$BODY_FILE")
PAYLOAD=$(
  python - "$VER" "$TAG" "$BODY_JSON" <<'PY'
import json
import sys

version = sys.argv[1]
tag = sys.argv[2]
body = json.loads(sys.argv[3])

payload = {
    "tag_name": tag,
    "target_commitish": tag,
    "name": version,
    "body": body,
    "draft": False,
    "prerelease": False,
}
print(json.dumps(payload))
PY
)

echo "==> 查找 Gitea release: ${TAG}"
EXISTING_JSON=$(curl -fsS -H "$AUTH_HEADER" "$(api_url "/releases/tags/${TAG}")" 2>/dev/null || true)

if [ -n "$EXISTING_JSON" ]; then
  RELEASE_ID=$(json_get "$EXISTING_JSON" "id")
  echo "==> 更新已有 Gitea release #${RELEASE_ID}"
  RELEASE_JSON=$(curl -fsS -X PATCH \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$(api_url "/releases/${RELEASE_ID}")")
else
  echo "==> 创建新的 Gitea release ${TAG}"
  RELEASE_JSON=$(curl -fsS -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$(api_url "/releases")")
  RELEASE_ID=$(json_get "$RELEASE_JSON" "id")
fi

echo "==> Gitea release id: ${RELEASE_ID}"
EXISTING_ASSETS=$(curl -fsS -H "$AUTH_HEADER" "$(api_url "/releases/${RELEASE_ID}/assets")" 2>/dev/null || echo "[]")

shopt -s nullglob
for asset in "$ASSET_DIR"/*; do
  [ -f "$asset" ] || continue
  name=$(basename "$asset")
  echo "==> 同步 Gitea 资产: ${name}"

  ATTACHMENT_ID=$(python - "$EXISTING_ASSETS" "$name" <<'PY'
import json
import sys

assets = json.loads(sys.argv[1])
target = sys.argv[2]
for item in assets:
    if item.get("name") == target:
        print(item.get("id"))
        break
PY
)

  if [ -n "${ATTACHMENT_ID:-}" ]; then
    curl -fsS -X DELETE \
      -H "$AUTH_HEADER" \
      "$(api_url "/releases/${RELEASE_ID}/assets/${ATTACHMENT_ID}")" >/dev/null
  fi

  curl -fsS -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$asset" \
    "$(api_url "/releases/${RELEASE_ID}/assets?name=$(urlencode "$name")")" >/dev/null
done

echo "==> Gitea release 同步完成: ${TAG}"
