#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_SCRIPT="$REPO_ROOT/scripts/build-node-musl.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/build-node-musl.yml"
MAIN_WORKFLOW="$REPO_ROOT/.github/workflows/build.yml"
MAKEFILE="$REPO_ROOT/Makefile"
BUILD_IPK="$REPO_ROOT/scripts/build_ipk.sh"
BUILD_RUN="$REPO_ROOT/scripts/build_run.sh"
BUILD_APK="$REPO_ROOT/scripts/build_apk.sh"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"
CONTROLLER_SCRIPT="$REPO_ROOT/luasrc/controller/openclaw.lua"
BASIC_LUA="$REPO_ROOT/luasrc/model/cbi/openclaw/basic.lua"
PROFILE_SCRIPT="$REPO_ROOT/root/etc/profile.d/openclaw.sh"
UCI_DEFAULTS_SCRIPT="$REPO_ROOT/root/etc/uci-defaults/99-openclaw"
INIT_SCRIPT="$REPO_ROOT/root/etc/init.d/openclaw"
PATHS_HELPER="$REPO_ROOT/root/usr/libexec/openclaw-paths.sh"
NODE_HELPER="$REPO_ROOT/root/usr/libexec/openclaw-node.sh"
WEB_PTY_SCRIPT="$REPO_ROOT/root/usr/share/openclaw/web-pty.js"
VERSION_FILE="$REPO_ROOT/VERSION"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq 'patchelf --set-interpreter "/lib/ld-musl-aarch64.so.1"' "$BUILD_SCRIPT" || fail "build script should use system musl loader"
grep -Fq '$ORIGIN/../lib' "$BUILD_SCRIPT" || fail "build script should use relative rpath"
if grep -Fq 'patchelf --set-interpreter "${INSTALL_PREFIX}/lib/ld-musl-aarch64.so.1"' "$BUILD_SCRIPT"; then
	fail "build script should not hardcode interpreter to install prefix"
fi

grep -Fq 'verify_prefix /opt/openclaw/node' "$WORKFLOW" || fail "workflow should verify default install path"
grep -Fq 'verify_prefix /tmp/custom-openclaw-root/openclaw/node' "$WORKFLOW" || fail "workflow should verify custom install path"

grep -Fq 'oc_node_version_ge "$installed_ver" "$node_ver"' "$ENV_SCRIPT" || fail "installer should enforce minimum node version after extraction"
grep -Fq 'NODE_VERSION_V2="24.14.1"' "$ENV_SCRIPT" || fail "installer should default V2 to Node.js 24.14.1"
APP_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
[ "$APP_VERSION" = "2026.6.10" ] || fail "package VERSION should track hotwa OpenClaw release naming"
grep -Fq "## [${APP_VERSION}]" "$REPO_ROOT/CHANGELOG.md" || fail "changelog should include the hotwa release version used by VERSION"
grep -Fq "OC_TESTED_VERSION=\"$APP_VERSION\"" "$ENV_SCRIPT" || fail "stable OpenClaw runtime target should match package VERSION"
grep -Fq 'OC_NODE_MIN_VERSION="${OC_NODE_MIN_VERSION:-22.19.0}"' "$ENV_SCRIPT" || fail "installer should pin OpenClaw 2026.6.x minimum Node.js version"
grep -Fq 'OC_VERSION  — 指定 OpenClaw 版本 (如 2026.6.10)，不设置则安装已测试稳定版' "$ENV_SCRIPT" || fail "installer usage should describe pinned stable installs"
grep -Fq 'oc_pkg="openclaw@${OC_TESTED_VERSION}"' "$ENV_SCRIPT" || fail "fresh setup should install the tested stable OpenClaw version by default"
grep -Fq 'target_pkg="openclaw@${OC_TESTED_VERSION}"' "$ENV_SCRIPT" || fail "runtime upgrade should target the tested stable OpenClaw version by default"
grep -Fq 'assert_node_runtime "$node_ver"' "$ENV_SCRIPT" || fail "installer should validate Node.js against OpenClaw runtime minimums"
grep -Fq '. /usr/libexec/openclaw-node.sh' "$INIT_SCRIPT" || fail "init script should load Node.js version helpers"
grep -Fq 'OC_NODE_MIN_VERSION="${OC_NODE_MIN_VERSION:-22.19.0}"' "$INIT_SCRIPT" || fail "init script should pin OpenClaw 2026.6.x minimum Node.js version"
grep -Fq 'oc_assert_node_min_version "$NODE_BIN" "$OC_NODE_MIN_VERSION"' "$INIT_SCRIPT" || fail "service start should reject Node.js below OpenClaw runtime minimum"
grep -Fq "description: 'Build V2 (24.14.1) - Current LTS version'" "$WORKFLOW" || fail "workflow should describe V2 as Node.js 24.14.1 LTS"
grep -Fq 'NODE_VER="24.14.1"' "$WORKFLOW" || fail "workflow should request Node.js 24.14.1 for V2"
grep -Fq 'Build Node.js V2 ARM64 musl (apk lts mode)' "$WORKFLOW" || fail "workflow should build V2 in apk lts mode"
grep -Fq 'PKG_TYPE=lts' "$WORKFLOW" || fail "workflow should use Alpine nodejs LTS package for V2"
grep -Fq 'alpine:edge sh /build-node-musl.sh' "$WORKFLOW" || fail "workflow should build V2 from Alpine edge to get the latest Node.js 24 LTS package"
grep -Fq 'EXPECTED_ARTIFACT="node-v24.14.1-linux-arm64-musl.tar.xz"' "$WORKFLOW" || fail "workflow should require the exact Node.js 24.14.1 V2 artifact name"
grep -Fq '`node-v24.14.1-linux-arm64-musl.tar.xz`' "$WORKFLOW" || fail "release notes should mention the Node.js 24.14.1 ARM64 musl tarball"
if grep -Fq 'mirror_list="$mirror_list ${NODE_SELF_HOST}/${v1_tarball}"' "$ENV_SCRIPT"; then
	fail "installer should not auto-fallback from V2 to V1 tarball"
fi
grep -Fq 'OPENCLAW_GITHUB_REPO="${OPENCLAW_GITHUB_REPO:-hotwa/luci-app-openclaw}"' "$ENV_SCRIPT" || fail "installer should default app repo to hotwa"
grep -Fq 'OPENCLAW_NODE_BINS_REPO="${OPENCLAW_NODE_BINS_REPO:-hotwa/luci-app-openclaw}"' "$ENV_SCRIPT" || fail "installer should default ARM64 musl node-bins to hotwa"
grep -Fq 'NODE_SELF_HOST="${NODE_SELF_HOST:-https://github.com/${OPENCLAW_NODE_BINS_REPO}/releases/download/node-bins}"' "$ENV_SCRIPT" || fail "installer should derive node-bins release URL from hotwa repo"
grep -Fq 'OPENCLAW_GITEA_REPO="${OPENCLAW_GITEA_REPO:-group/luci-app-openclaw}"' "$ENV_SCRIPT" || fail "installer should default Gitea mirror repo to group"
grep -Fq 'NODE_SELF_HOST_FALLBACK="${NODE_SELF_HOST_FALLBACK:-https://gitea.jmsu.top/${OPENCLAW_GITEA_REPO}/releases/download/node-bins}"' "$ENV_SCRIPT" || fail "installer should use Gitea as node-bins fallback"
grep -Fq 'NODE_RELEASE_API="${NODE_RELEASE_API:-https://api.github.com/repos/${OPENCLAW_NODE_BINS_REPO}/releases/tags/node-bins}"' "$ENV_SCRIPT" || fail "installer should derive node-bins release API from hotwa repo"
grep -Fq 'NODE_RELEASE_API_FALLBACK="${NODE_RELEASE_API_FALLBACK:-https://gitea.jmsu.top/api/v1/repos/${OPENCLAW_GITEA_REPO}/releases/tags/node-bins}"' "$ENV_SCRIPT" || fail "installer should use Gitea release API fallback"
grep -Fq 'NODE_RELEASE_PAGE_FALLBACK="${NODE_RELEASE_PAGE_FALLBACK:-https://gitea.jmsu.top/${OPENCLAW_GITEA_REPO}/releases/tag/node-bins}"' "$ENV_SCRIPT" || fail "installer should expose Gitea release page fallback"
grep -Fq 'for release_api in "$NODE_RELEASE_API" "$NODE_RELEASE_API_FALLBACK"; do' "$ENV_SCRIPT" || fail "installer should try GitHub release API before Gitea fallback API"
grep -Fq 'oc_select_node_release_asset_url' "$ENV_SCRIPT" || fail "installer should dynamically select ARM64 musl asset"
grep -Fq 'oc_node_requires_opt_compat "$NODE_BIN"' "$ENV_SCRIPT" || fail "installer should detect legacy opt-bound ARM64 musl node assets"
grep -Fq 'oc_ensure_opt_compat_link "$OC_ROOT"' "$ENV_SCRIPT" || fail "installer should create /opt compatibility symlink for legacy assets"
grep -Fq 'mirror_list="${NODE_SELF_HOST}/${musl_tarball} ${NODE_SELF_HOST_FALLBACK}/${musl_tarball}"' "$ENV_SCRIPT" || fail "installer should try GitHub node-bins URL before Gitea mirror URL"
grep -Fq 'arm64_musl_url=$(resolve_arm64_musl_node_url "$node_ver" 2>/dev/null || true)' "$ENV_SCRIPT" || fail "installer should keep API-based ARM64 musl asset discovery as fallback"
grep -Fq 'while IFS= read -r d; do' "$ENV_SCRIPT" || fail "installer should traverse OpenClaw entry candidates without a pipeline subshell"
if grep -Fq 'echo "$search_dirs" | while read -r d; do' "$ENV_SCRIPT"; then
	fail "installer should not rely on a pipeline subshell for OpenClaw entry lookup"
fi
grep -Fq 'NPM_CONFIG_PREFIX="${OC_GLOBAL}"' "$ENV_SCRIPT" || fail "installer should force npm global prefix into custom install root"
grep -Fq 'NPM_CONFIG_CACHE="${OC_DATA}/.npm"' "$ENV_SCRIPT" || fail "installer should force npm cache into custom data root"
grep -Fq 'XDG_CACHE_HOME="${OC_DATA}/.cache"' "$ENV_SCRIPT" || fail "installer should force generic caches into custom data root"
grep -Fq 'COREPACK_HOME="${OC_DATA}/.cache/corepack"' "$ENV_SCRIPT" || fail "installer should force corepack cache into custom data root"
grep -Fq 'TMPDIR="${OC_DATA}/tmp"' "$ENV_SCRIPT" || fail "installer should force temp files into custom data root"

grep -Fq 'openclaw-paths.sh' "$MAKEFILE" || fail "package makefile should install path helper"
grep -Fq 'openclaw-node.sh' "$MAKEFILE" || fail "package makefile should install node helper"
grep -Fq 'openclaw/paths.lua' "$MAKEFILE" || fail "package makefile should install Lua path helper"
grep -Fq 'PKG_RELEASE:=2' "$MAKEFILE" || fail "package release should bump after changing embedded download defaults"
grep -Fq '+libstdcpp' "$MAKEFILE" || fail "package makefile should depend on libstdcpp"
if grep -Fq 'libstdcpp6' "$MAKEFILE" "$BUILD_IPK" "$BUILD_RUN"; then
	fail "packaging metadata should not reference libstdcpp6"
fi
grep -Fq 'openclaw-paths.sh' "$BUILD_IPK" || fail "ipk builder should package path helper"
grep -Fq 'openclaw-node.sh' "$BUILD_IPK" || fail "ipk builder should package node helper"
grep -Fq 'openclaw-compat.sh' "$BUILD_IPK" || fail "ipk builder should package compat helper"
grep -Fq 'openclaw-wechat.sh' "$BUILD_IPK" || fail "ipk builder should package wechat helper"
grep -Fq 'openclaw/paths.lua' "$BUILD_IPK" || fail "ipk builder should package Lua path helper"
grep -Fq 'apk mkpkg' "$BUILD_APK" || fail "apk builder should use apk mkpkg"
grep -Fq 'openclaw-compat.sh' "$BUILD_APK" || fail "apk builder should package compat helper"
grep -Fq 'openclaw-wechat.sh' "$BUILD_APK" || fail "apk builder should package wechat helper"
grep -Fq 'luci-app-openclaw_${VER}-r1_all.apk' "$REPO_ROOT/scripts/gen-release-body.sh" || fail "release body should include apk install command"
grep -Fq 'openclaw-paths.sh' "$BUILD_RUN" || fail "run builder should package path helper"
grep -Fq 'openclaw-node.sh' "$BUILD_RUN" || fail "run builder should package node helper"
grep -Fq 'openclaw-compat.sh' "$BUILD_RUN" || fail "run builder should package compat helper"
grep -Fq 'openclaw-wechat.sh' "$BUILD_RUN" || fail "run builder should package wechat helper"
grep -Fq 'openclaw/paths.lua' "$BUILD_RUN" || fail "run builder should package Lua path helper"
grep -Fq 'Build .apk package' "$MAIN_WORKFLOW" || fail "main workflow should build apk package"
grep -Fq 'dist/*.apk' "$MAIN_WORKFLOW" || fail "main workflow should publish apk artifact"

PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "python3 is required for line ending checks"
"$PYTHON_BIN" - "$ENV_SCRIPT" "$PROFILE_SCRIPT" "$UCI_DEFAULTS_SCRIPT" "$INIT_SCRIPT" "$PATHS_HELPER" "$NODE_HELPER" "$BUILD_IPK" "$BUILD_RUN" "$BUILD_APK" "$BUILD_SCRIPT" <<'PY' || fail "shell-oriented source files must use LF line endings"
from pathlib import Path
import sys

bad = []
for arg in sys.argv[1:]:
    data = Path(arg).read_bytes()
    if b"\r\n" in data:
        bad.append(arg)

if bad:
    print("CRLF detected in:", file=sys.stderr)
    for path in bad:
        print(path, file=sys.stderr)
    raise SystemExit(1)
PY

grep -Fq 'local GITHUB_REPO = "hotwa/luci-app-openclaw"' "$CONTROLLER_SCRIPT" || fail "controller should default to hotwa repo"
grep -Fq 'local GITHUB_RELEASES_URL = "https://github.com/" .. GITHUB_REPO .. "/releases"' "$CONTROLLER_SCRIPT" || fail "controller should derive release URLs from hotwa repo"
grep -Fq 'local GITHUB_API_RELEASES_URL = "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases"' "$CONTROLLER_SCRIPT" || fail "controller should derive API URLs from hotwa repo"
grep -Fq 'local GITEA_REPO = "group/luci-app-openclaw"' "$CONTROLLER_SCRIPT" || fail "controller should use group Gitea mirror repo"
grep -Fq "URLS='%s %s'; " "$CONTROLLER_SCRIPT" || fail "plugin upgrade should build ordered fallback URL lists"
grep -Fq 'run_url_github, run_url_gitea' "$CONTROLLER_SCRIPT" || fail "plugin upgrade should try GitHub run asset before Gitea mirror"
grep -Fq 'apk_url_github, apk_url_gitea, apk_legacy_url_github, apk_legacy_url_gitea' "$CONTROLLER_SCRIPT" || fail "plugin upgrade should try GitHub apk assets before Gitea mirror"
grep -Fq 'export NPM_CONFIG_PREFIX="$OC_GLOBAL"' "$PROFILE_SCRIPT" || fail "shell profile should export npm prefix into custom install root"
grep -Fq 'export NPM_CONFIG_CACHE="${OC_DATA}/.npm"' "$PROFILE_SCRIPT" || fail "shell profile should export npm cache into custom data root"
grep -Fq 'export XDG_CACHE_HOME="${OC_DATA}/.cache"' "$PROFILE_SCRIPT" || fail "shell profile should export cache home into custom data root"
grep -Fq 'NPM_CONFIG_PREFIX="$OC_GLOBAL" \' "$INIT_SCRIPT" || fail "service environment should pass npm prefix into custom install root"
grep -Fq 'NPM_CONFIG_CACHE="${OC_DATA}/.npm" \' "$INIT_SCRIPT" || fail "service environment should pass npm cache into custom data root"
grep -Fq 'XDG_CACHE_HOME="${OC_DATA}/.cache" \' "$INIT_SCRIPT" || fail "service environment should pass cache home into custom data root"
grep -Fq 'NPM_CONFIG_PREFIX: OC_GLOBAL' "$WEB_PTY_SCRIPT" || fail "web PTY environment should pass npm prefix into custom install root"
grep -Fq 'NPM_CONFIG_CACHE: `${OC_DATA}/.npm`' "$WEB_PTY_SCRIPT" || fail "web PTY environment should pass npm cache into custom data root"
grep -Fq 'COREPACK_HOME: `${OC_DATA}/.cache/corepack`' "$WEB_PTY_SCRIPT" || fail "web PTY environment should pass corepack cache into custom data root"
grep -Fq "https://gitea.jmsu.top/group/luci-app-openclaw/releases/tag/v" "$BASIC_LUA" || fail "UI should link manual download to group gitea release page"
grep -Fq 'runtime_upgrade' "$CONTROLLER_SCRIPT" || fail "controller should expose a runtime OpenClaw upgrade API"
grep -Fq 'runtime_upgrade_log' "$CONTROLLER_SCRIPT" || fail "controller should expose runtime OpenClaw upgrade logs"
grep -Fq 'OPENCLAW_INSTALL_ROOT=' "$CONTROLLER_SCRIPT" || fail "runtime upgrade should pass the derived install root to openclaw-env"
grep -Fq '/usr/bin/openclaw-env upgrade' "$CONTROLLER_SCRIPT" || fail "runtime upgrade should call openclaw-env upgrade"
grep -Fq 'OC_VERSION=' "$CONTROLLER_SCRIPT" || fail "runtime upgrade should target the installed plugin version when available"
grep -Fq '/tmp/openclaw-runtime-upgrade.log' "$CONTROLLER_SCRIPT" || fail "runtime upgrade should write a dedicated log file"
grep -Fq '/etc/init.d/openclaw restart' "$CONTROLLER_SCRIPT" || fail "runtime upgrade should restart OpenClaw after successful upgrade"
grep -Fq 'btn-runtime-upgrade' "$BASIC_LUA" || fail "UI should provide an independent OpenClaw runtime upgrade button"
grep -Fq 'runtime-update-dot' "$BASIC_LUA" || fail "UI should show a red dot on the OpenClaw runtime upgrade button"
grep -Fq 'ocRuntimeNeedsUpgrade' "$BASIC_LUA" || fail "UI should detect runtime/plugin version mismatch"
grep -Fq 'ocRefreshRuntimeUpgradeHint' "$BASIC_LUA" || fail "UI should refresh runtime upgrade red dot from status data"
grep -Fq 'ocRuntimeUpgrade' "$BASIC_LUA" || fail "UI should start runtime upgrade from the independent button"
grep -Fq 'ocPollRuntimeUpgradeLog' "$BASIC_LUA" || fail "UI should poll runtime upgrade logs"
grep -Fq 'cat /tmp/openclaw-runtime-upgrade.log' "$BASIC_LUA" || fail "UI should show how to inspect runtime upgrade logs after failure"
grep -Fq 'openclaw@${target_ver}' "$ENV_SCRIPT" || fail "runtime upgrade should support targeting a specific OpenClaw version"
grep -Fq "ARM64 musl" "$BASIC_LUA" || fail "UI should mention ARM64 musl specific guidance"
grep -Fq "hotwa/luci-app-openclaw" "$BASIC_LUA" || fail "UI should point ARM64 musl guidance at hotwa repo"
if grep -Fq 'NODE_MIRROR=https://npmmirror.com/mirrors/node openclaw-env setup' "$BASIC_LUA"; then
	fail "UI should not recommend NODE_MIRROR for ARM64 musl node download failures"
fi

echo "ok"
