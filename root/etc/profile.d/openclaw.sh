#!/bin/sh
# ============================================================================
# luci-app-openclaw — 全局环境变量
# 仅在 Node.js 已安装时生效，为 SSH 登录用户提供正确的运行环境
# 解决 Issue #42: 统一配置文件路径，避免 /root/.openclaw 与运行目录混乱
# ============================================================================

. /usr/libexec/openclaw-paths.sh
oc_load_paths "$OPENCLAW_INSTALL_ROOT"

# 检查 Node.js 是否已安装
[ -x "${NODE_BASE}/bin/node" ] || return 0

# 添加 Node.js 和 OpenClaw 到 PATH (非侵入式，检查是否已存在)
case ":$PATH:" in
  *":${NODE_BASE}/bin:"*) ;;
  *) export PATH="${NODE_BASE}/bin:${OC_GLOBAL}/bin:$PATH" ;;
esac

# 设置 Node.js ICU 数据路径
export NODE_ICU_DATA="${NODE_BASE}/share/icu"
export NPM_CONFIG_PREFIX="$OC_GLOBAL"
export npm_config_prefix="$OC_GLOBAL"
export NPM_CONFIG_CACHE="${OC_DATA}/.npm"
export npm_config_cache="${OC_DATA}/.npm"
export XDG_CACHE_HOME="${OC_DATA}/.cache"
export COREPACK_HOME="${OC_DATA}/.cache/corepack"
export PNPM_HOME="${OC_GLOBAL}/bin"
export TMPDIR="${OC_DATA}/tmp"
export TMP="${OC_DATA}/tmp"
export TEMP="${OC_DATA}/tmp"

# 设置 OpenClaw 核心环境变量
# 这些变量确保 openclaw 命令使用正确的配置路径
export OPENCLAW_HOME="$OC_DATA"
export OPENCLAW_STATE_DIR="${OC_DATA}/.openclaw"
export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"

# 创建便捷包装器：只给 openclaw 命令单独注入 HOME，避免污染用户 shell。
_oc_cli=""
if [ -x "${OC_GLOBAL}/bin/openclaw" ]; then
	_oc_cli="${OC_GLOBAL}/bin/openclaw"
elif [ -x "${NODE_BASE}/bin/openclaw" ]; then
	_oc_cli="${NODE_BASE}/bin/openclaw"
else
	for _oc_dir in "${OC_GLOBAL}/lib/node_modules/openclaw" "${OC_GLOBAL}/node_modules/openclaw" "${NODE_BASE}/lib/node_modules/openclaw"; do
		if [ -f "${_oc_dir}/openclaw.mjs" ]; then
			_oc_cli="${NODE_BASE}/bin/node ${_oc_dir}/openclaw.mjs"
			break
		elif [ -f "${_oc_dir}/dist/cli.js" ]; then
			_oc_cli="${NODE_BASE}/bin/node ${_oc_dir}/dist/cli.js"
			break
		fi
	done
fi

if [ -n "$_oc_cli" ]; then
	openclaw() {
		HOME="$OC_DATA" \
		OPENCLAW_HOME="$OC_DATA" \
		OPENCLAW_STATE_DIR="${OC_DATA}/.openclaw" \
		OPENCLAW_CONFIG_PATH="$CONFIG_FILE" \
		sh -c 'exec "$@"' openclaw $_oc_cli "$@"
	}
fi
