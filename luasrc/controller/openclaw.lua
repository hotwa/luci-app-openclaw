-- luci-app-openclaw — LuCI Controller
module("luci.controller.openclaw", package.seeall)

local nixio_fs = require "nixio.fs"
local util = require "luci.util"
local jsonc = require "luci.jsonc"
local oc_paths = require "openclaw.paths"
local GITHUB_REPO = "hotwa/luci-app-openclaw"
local GITHUB_RELEASES_URL = "https://github.com/" .. GITHUB_REPO .. "/releases"
local GITHUB_API_RELEASES_URL = "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases"
local GITEA_REPO = "group/luci-app-openclaw"
local GITEA_RELEASES_URL = "https://gitea.jmsu.top/" .. GITEA_REPO .. "/releases"
local GITEA_API_RELEASES_URL = "https://gitea.jmsu.top/api/v1/repos/" .. GITEA_REPO .. "/releases"

local function get_install_root_from_uci()
	return require("luci.model.uci").cursor():get("openclaw", "main", "install_root")
end

local function get_runtime_paths(install_root)
	return oc_paths.derive_paths(install_root or get_install_root_from_uci())
end

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_requested_install_root(value)
	local cleaned = trim(value)
	if cleaned == "" then
		return true, get_runtime_paths().install_root
	end
	if cleaned:sub(1, 1) ~= "/" then
		return false, nil, "安装根目录必须使用绝对路径，例如 /mnt/emmc"
	end
	if cleaned:match("%s") then
		return false, nil, "安装根目录不能包含空白字符"
	end
	return true, oc_paths.normalize_install_root(cleaned)
end

local function get_node_bin(paths)
	return paths.node_base .. "/bin/node"
end

local function get_config_file(paths)
	return paths.oc_data .. "/.openclaw/openclaw.json"
end

local function shell_quote(value)
	return util.shellquote(value or "")
end

local function is_safe_openclaw_root(value)
	if type(value) ~= "string" or value == "" or value == "/" then
		return false
	end
	if value == "/openclaw" or value == "/opt/openclaw" then
		return true
	end
	return value:match("^/mnt/[^/]+/openclaw$") ~= nil
		or value:match("^/media/[^/]+/openclaw$") ~= nil
		or value:match("^/srv/[^/]+/openclaw$") ~= nil
end

local function path_type(path)
	return nixio_fs.stat(path, "type")
end

local function directory_exists(path)
	return path_type(path) == "dir"
end

local function file_exists(path)
	return path_type(path) ~= nil
end

local function ensure_openclaw_user(oc_data)
	local sys = require "luci.sys"
	if sys.call("id -u openclaw >/dev/null 2>&1") == 0 then
		return true
	end
	local create = "OC_UID=1000; while grep -q \"^[^:]*:x:${OC_UID}:\" /etc/passwd; do OC_UID=$((OC_UID+1)); done; " ..
		"OC_GID=$OC_UID; grep -q '^openclaw:' /etc/group || echo \"openclaw:x:${OC_GID}:\" >> /etc/group; " ..
		"grep -q '^openclaw:' /etc/passwd || echo \"openclaw:x:${OC_UID}:${OC_GID}:openclaw:${OC_HOME}:/bin/false\" >> /etc/passwd; " ..
		"grep -q '^openclaw:' /etc/shadow || echo 'openclaw:x:0:0:99999:7:::' >> /etc/shadow"
	sys.exec("OC_HOME=" .. shell_quote(oc_data) .. " sh -c " .. shell_quote(create) .. " >/dev/null 2>&1")
	return sys.call("id -u openclaw >/dev/null 2>&1") == 0
end

local function find_oc_entry(paths)
	local search_dirs = {
		paths.oc_global .. "/lib/node_modules/openclaw",
		paths.oc_global .. "/node_modules/openclaw",
		paths.node_base .. "/lib/node_modules/openclaw",
	}

	for _, dir_path in ipairs(search_dirs) do
		if file_exists(dir_path .. "/openclaw.mjs") then
			return dir_path .. "/openclaw.mjs", dir_path
		elseif file_exists(dir_path .. "/dist/cli.js") then
			return dir_path .. "/dist/cli.js", dir_path
		end
	end

	return "", ""
end

local function runtime_installed(paths)
	local oc_entry = find_oc_entry(paths)
	return file_exists(get_node_bin(paths)) and oc_entry ~= ""
end

local function get_gateway_state()
	local sys = require "luci.sys"
	local raw = sys.exec([[ubus call service list '{"name":"openclaw"}' 2>/dev/null]])
	if not raw or raw == "" then
		return nil
	end

	local data = jsonc.parse(raw)
	local gateway = data and data.openclaw and data.openclaw.instances and data.openclaw.instances.gateway
	if not gateway then
		return nil
	end

	return {
		running = gateway.running == true,
		pid = tostring(gateway.pid or ""),
		exit_code = tonumber(gateway.exit_code),
	}
end

local WECHAT_HELPER = "/usr/libexec/openclaw-wechat.sh"
local WECHAT_INSTALL_LOG = "/tmp/openclaw-wechat-install.log"
local WECHAT_INSTALL_PID = "/tmp/openclaw-wechat-install.pid"
local WECHAT_INSTALL_EXIT = "/tmp/openclaw-wechat-install.exit"
local WECHAT_LOGIN_QR = "/tmp/openclaw-wechat-qrcode.txt"
local WECHAT_LOGIN_PID = "/tmp/openclaw-wechat-login.pid"
local WECHAT_LOGIN_EXIT = "/tmp/openclaw-wechat-login.exit"
local WECHAT_RESTARTED = "/tmp/openclaw-wechat-restarted"
local WECHAT_STATE_FILE = "/tmp/openclaw-wechat.state"

local function read_text_file(path)
	local f = io.open(path, "r")
	if not f then
		return ""
	end

	local content = f:read("*a") or ""
	f:close()
	return content
end

local function get_plugin_version()
	local version = trim(read_text_file("/usr/share/openclaw/VERSION"))
	if not version:match("^[%w%._%-]+$") then
		return ""
	end
	return version
end

local function read_kv_file(path)
	local values = {}

	for line in read_text_file(path):gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key then
			values[key] = value
		end
	end

	return values
end

local function pid_is_running(pid)
	if not pid or pid == "" then
		return false
	end

	local sys = require "luci.sys"
	local status = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
	return status == "yes"
end

local function get_wechat_paths(paths)
	local root = paths.oc_data .. "/.openclaw"

	return {
		plugin_dir = root .. "/extensions/openclaw-weixin",
		plugin_json = root .. "/extensions/openclaw-weixin/openclaw.plugin.json",
		package_json = root .. "/extensions/openclaw-weixin/package.json",
		accounts_json = root .. "/openclaw-weixin/accounts.json",
		config_json = root .. "/openclaw.json",
	}
end

local function wechat_helper_command(action, extra_args)
	local paths = get_runtime_paths()
	local command = string.format(
		"HOME=%s NPM_CONFIG_CACHE=%s start-stop-daemon -S -c openclaw -x %s -- %s",
		shell_quote(paths.oc_data),
		shell_quote(paths.oc_data .. "/.npm"),
		shell_quote(WECHAT_HELPER),
		action
	)

	if extra_args and extra_args ~= "" then
		command = command .. " " .. extra_args
	end

	return command
end

local function wechat_spawn(action, pidfile, extra_args)
	local sys = require "luci.sys"
	local command = string.format("( %s ) >/dev/null 2>&1 & echo $! > %s", wechat_helper_command(action, extra_args), shell_quote(pidfile))
	sys.exec(command)
end

local function wechat_run(action, extra_args)
	local sys = require "luci.sys"
	return sys.exec(wechat_helper_command(action, extra_args))
end

local function compare_plugin_versions(lhs, rhs)
	local function split(version)
		local parts = {}
		local cleaned = trim(version):gsub("^v", "")

		for part in cleaned:gmatch("%d+") do
			parts[#parts + 1] = tonumber(part) or 0
		end

		return parts
	end

	local left = split(lhs)
	local right = split(rhs)
	local max_len = math.max(#left, #right, 3)

	for i = 1, max_len do
		local l = left[i] or 0
		local r = right[i] or 0
		if l ~= r then
			return l - r
		end
	end

	return 0
end

local function normalize_release_tag(tag)
	tag = tostring(tag or ""):gsub("^v", ""):gsub("%s+", "")
	return tag
end

local function decode_release_body(body)
	body = tostring(body or "")
	if body == "" then
		return ""
	end

	return body:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
end

local function fetch_release_metadata_from_api(sys, api_base)
	local payload = sys.exec("curl -fsS --connect-timeout 5 --max-time 10 '" .. api_base .. "/latest' 2>/dev/null")
	if not payload or payload == "" then
		return "", ""
	end

	local data = jsonc.parse(payload)
	if type(data) == "table" then
		local tag = normalize_release_tag(data.tag_name)
		local body = decode_release_body(data.body)
		return tag, body
	end

	local tag = normalize_release_tag(payload:match('"tag_name"%s*:%s*"([^"]+)"'))
	local body = decode_release_body(payload:match('"body"%s*:%s*"(.-)"[,}%]\n ]'))
	return tag, body
end

local function fetch_release_tag_from_redirect(sys, releases_base)
	local effective = sys.exec(
		"curl -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 5 --max-time 10 '" ..
		releases_base .. "/latest' 2>/dev/null"
	)
	effective = tostring(effective or ""):gsub("%s+", "")

	if effective == "" then
		return ""
	end

	local tag = effective:match("/releases/tag/([^/?#]+)$")
		or effective:match("/releases/download/([^/?#]+)/")
	return normalize_release_tag(tag)
end

function index()
	-- 主入口: 服务 → OpenClaw (🧠 作为菜单图标)
	local page = entry({"admin", "services", "openclaw"}, alias("admin", "services", "openclaw", "basic"), _("OpenClaw"), 90)
	page.dependent = false

	-- 基本设置 (CBI)
	entry({"admin", "services", "openclaw", "basic"}, cbi("openclaw/basic"), _("基本设置"), 10).leaf = true

	-- 配置管理 (View — 嵌入 oc-config Web 终端)
	entry({"admin", "services", "openclaw", "advanced"}, template("openclaw/advanced"), _("配置管理"), 20).leaf = true

	-- Web 控制台 (View — 嵌入 OpenClaw Web UI)
	entry({"admin", "services", "openclaw", "console"}, template("openclaw/console"), _("Web 控制台"), 30).leaf = true

	-- 状态 API (AJAX 接口, 供前端 XHR 调用)
	entry({"admin", "services", "openclaw", "status_api"}, call("action_status"), nil).leaf = true

	-- 服务控制 API
	-- 会改状态的端点必须用 post(): LuCI 的 test_post_security() 同时要求
	-- POST 方法与匹配的 CSRF token，call() 允许 GET 触发，
	-- 诱导已登录管理员访问一个链接即可启停服务。
	entry({"admin", "services", "openclaw", "service_ctl"}, post("action_service_ctl"), nil).leaf = true

	-- 安装/升级日志 API (轮询)
	entry({"admin", "services", "openclaw", "setup_log"}, call("action_setup_log"), nil).leaf = true

	-- 版本检查 API (仅检查插件版本)
	entry({"admin", "services", "openclaw", "check_update"}, call("action_check_update"), nil).leaf = true

	-- 卸载运行环境 API (破坏性操作，必须 POST + CSRF)
	entry({"admin", "services", "openclaw", "uninstall"}, post("action_uninstall"), nil).leaf = true

	-- 获取网关 Token API (返回凭据，必须 POST + CSRF 防止被第三方页面读取)
	entry({"admin", "services", "openclaw", "get_token"}, post("action_get_token"), nil).leaf = true

	-- 插件升级 API (会下载并执行 .run，必须 POST + CSRF)
	entry({"admin", "services", "openclaw", "plugin_upgrade"}, post("action_plugin_upgrade"), nil).leaf = true

	-- 插件升级日志 API (轮询)
	entry({"admin", "services", "openclaw", "plugin_upgrade_log"}, call("action_plugin_upgrade_log"), nil).leaf = true

	-- OpenClaw 运行体升级 API
	entry({"admin", "services", "openclaw", "runtime_upgrade"}, call("action_runtime_upgrade"), nil).leaf = true
	entry({"admin", "services", "openclaw", "runtime_upgrade_log"}, call("action_runtime_upgrade_log"), nil).leaf = true

	-- 配置备份 API (v2026.3.8+: openclaw backup create/verify)
	-- 含 create/restore/delete 等破坏性动作，必须 POST + CSRF。
	-- 只读的 list 也走同一入口，一并要求 POST 以保持调用方式统一。
	entry({"admin", "services", "openclaw", "backup"}, post("action_backup"), nil).leaf = true

	-- 系统配置检测 API (安装前检测)
	entry({"admin", "services", "openclaw", "check_system"}, call("action_check_system"), nil).leaf = true

	-- 微信渠道 API
	entry({"admin", "services", "openclaw", "wechat_status"}, call("action_wechat_status"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_install"}, post("action_wechat_install"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_install_log"}, call("action_wechat_install_log"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_login"}, post("action_wechat_login"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_login_status"}, call("action_wechat_login_status"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_check_upgrade"}, call("action_wechat_check_upgrade"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_upgrade_plugin"}, post("action_wechat_upgrade_plugin"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_logout"}, post("action_wechat_logout"), nil).leaf = true
	entry({"admin", "services", "openclaw", "wechat_uninstall"}, post("action_wechat_uninstall"), nil).leaf = true
end

-- ═══════════════════════════════════════════
-- 状态查询 API: 返回 JSON
-- ═══════════════════════════════════════════
function action_status()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()
	local paths = get_runtime_paths()

	local port = uci:get("openclaw", "main", "port") or "18789"
	local pty_port = uci:get("openclaw", "main", "pty_port") or "18793"
	local enabled = uci:get("openclaw", "main", "enabled") or "0"

	-- 验证端口值为纯数字，防止命令注入
	if not port:match("^%d+$") then port = "18789" end
	if not pty_port:match("^%d+$") then pty_port = "18793" end

	local result = {
		enabled = enabled,
		port = port,
		pty_port = pty_port,
		gateway_running = false,
		gateway_starting = false,
		gateway_failed = false,
		gateway_exit_code = "",
		pty_running = false,
		pid = "",
		memory_kb = 0,
		uptime = "",
		node_version = "",
		oc_version = "",
		plugin_version = "",
		install_root = paths.install_root,
		oc_root = paths.oc_root,
	}

	-- 插件版本
	result.plugin_version = get_plugin_version()

	-- 安装方式检测 (离线 / 在线)

	-- 检查 Node.js
	local node_bin = get_node_bin(paths)
	local f = io.open(node_bin, "r")
	if f then
		f:close()
		local node_ver = sys.exec(node_bin .. " --version 2>/dev/null"):gsub("%s+", "")
		result.node_version = node_ver
	end

	-- OpenClaw 版本 (从 package.json 读取)
	local oc_dirs = {
		paths.oc_global .. "/lib/node_modules/openclaw",
		paths.oc_global .. "/node_modules/openclaw",
		paths.node_base .. "/lib/node_modules/openclaw",
	}
	for _, d in ipairs(oc_dirs) do
		local pf = io.open(d .. "/package.json", "r")
		if pf then
			local pj = pf:read("*a")
			pf:close()
			local ver = pj:match('"version"%s*:%s*"([^"]+)"')
			if ver and ver ~= "" then
				result.oc_version = ver
				break
			end
		end
	end

	-- 网关端口检查
	local gw_check_cmd = "if command -v ss >/dev/null 2>&1; then ss -tulnp 2>/dev/null | grep -c ':" .. port .. " ' || echo 0; else netstat -tulnp 2>/dev/null | grep -c ':" .. port .. " ' || echo 0; fi"
		local gw_check = sys.exec(gw_check_cmd):gsub("%s+", "")
	result.gateway_running = (tonumber(gw_check) or 0) > 0

	local gateway_state = get_gateway_state()
	if gateway_state and gateway_state.pid ~= "" then
		result.pid = gateway_state.pid
	end
	if gateway_state and gateway_state.exit_code ~= nil then
		result.gateway_exit_code = tostring(gateway_state.exit_code)
	end

	-- 如果端口未监听但 procd 状态存在，说明正在启动或已失败
	if not result.gateway_running and enabled == "1" then
		if gateway_state and gateway_state.running then
			result.gateway_starting = true
		elseif gateway_state and gateway_state.exit_code ~= nil and gateway_state.exit_code ~= 0 then
			result.gateway_failed = true
		else
			local procd_pid = sys.exec("pgrep -f 'openclaw.*gateway' 2>/dev/null | head -1"):gsub("%s+", "")
			if procd_pid ~= "" then
				result.gateway_starting = true
			end
		end
	end

	-- PTY 端口检查
	local pty_check = sys.exec("netstat -tulnp 2>/dev/null | grep -c ':" .. pty_port .. " ' || echo 0"):gsub("%s+", "")
	result.pty_running = (tonumber(pty_check) or 0) > 0

	-- 读取当前活跃模型
	local config_file = get_config_file(paths)
	local cf = io.open(config_file, "r")
	if cf then
		local content = cf:read("*a")
		cf:close()
		-- 简单正则提取 "primary": "xxx"
		local model = content:match('"primary"%s*:%s*"([^"]+)"')
		if model and model ~= "" then
			result.active_model = model
		end

		-- 读取已配置的渠道列表
		local channels = {}
		if content:match('"qqbot"%s*:%s*{') and content:match('"appId"%s*:%s*"[^"]+"') then
			channels[#channels+1] = "QQ"
		end
		if content:match('"telegram"%s*:%s*{') and content:match('"botToken"%s*:%s*"[^"]+"') then
			channels[#channels+1] = "Telegram"
		end
		if content:match('"discord"%s*:%s*{') then
			channels[#channels+1] = "Discord"
		end
		if content:match('"feishu"%s*:%s*{') then
			channels[#channels+1] = "飞书"
		end
		if content:match('"slack"%s*:%s*{') then
			channels[#channels+1] = "Slack"
		end
		if #channels > 0 then
			result.channels = table.concat(channels, ", ")
		end
	end

	-- PID 和内存
	if result.gateway_running then
		local pid = sys.exec("netstat -tulnp 2>/dev/null | awk '/:" .. port .. " /{split($NF,a,\"/\");print a[1];exit}'"):gsub("%s+", "")
		if pid and pid ~= "" then
			result.pid = pid
			-- 内存 (VmRSS from /proc)
			local rss = sys.exec("awk '/VmRSS/{print $2}' /proc/" .. pid .. "/status 2>/dev/null"):gsub("%s+", "")
			result.memory_kb = tonumber(rss) or 0
			-- 运行时间
			local stat_time = sys.exec("stat -c %Y /proc/" .. pid .. " 2>/dev/null"):gsub("%s+", "")
			local start_ts = tonumber(stat_time) or 0
			if start_ts > 0 then
				local uptime_s = os.time() - start_ts
				local hours = math.floor(uptime_s / 3600)
				local mins = math.floor((uptime_s % 3600) / 60)
				local secs = uptime_s % 60
				if hours > 0 then
					result.uptime = string.format("%dh %dm %ds", hours, mins, secs)
				elseif mins > 0 then
					result.uptime = string.format("%dm %ds", mins, secs)
				else
					result.uptime = string.format("%ds", secs)
				end
			end
		end
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

-- ═══════════════════════════════════════════
-- 服务控制 API: start/stop/restart/setup
-- ═══════════════════════════════════════════
function action_service_ctl()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()

	local action = http.formvalue("action") or ""

	if action == "start" then
		sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")
	elseif action == "stop" then
		sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
		-- stop 后额外等待确保端口释放
		sys.exec("sleep 2")
	elseif action == "restart" then
		-- 常规“重启”只重启 Gateway，不重启 Web PTY，避免 stop+start 带来的长时间等待。
		-- 如果 procd 没有 gateway 实例，再回退到 start。
		local procd_running = sys.exec("ubus call service list '{\"name\":\"openclaw\"}' 2>/dev/null | jsonfilter -e '$.openclaw.instances.gateway.running' 2>/dev/null"):gsub("%s+", "")
		if procd_running == "true" then
			sys.exec("/etc/init.d/openclaw restart_gateway >/dev/null 2>&1 &")
		else
			sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")
		end
	elseif action == "enable" then
		sys.exec("/etc/init.d/openclaw enable 2>/dev/null")
	elseif action == "disable" then
		sys.exec("/etc/init.d/openclaw disable 2>/dev/null")
	elseif action == "setup" then
		local valid_root, requested_install_root, root_error = normalize_requested_install_root(http.formvalue("install_root"))
		if not valid_root then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = root_error })
			return
		end

		local requested_paths = get_runtime_paths(requested_install_root)
		local current_paths = get_runtime_paths()

		if not directory_exists(requested_paths.install_root) then
			http.prepare_content("application/json")
			http.write_json({
				status = "error",
				message = "检测目录不存在: " .. requested_paths.install_root .. "。请先挂载或创建该目录后再安装。"
			})
			return
		end

		if runtime_installed(current_paths) and requested_paths.install_root ~= current_paths.install_root then
			http.prepare_content("application/json")
			http.write_json({
				status = "error",
				message = "当前已安装在 " .. current_paths.oc_root .. "。如需更换目录，请先卸载环境后再重新安装。"
			})
			return
		end

		-- 先清理旧日志和状态
		sys.exec("rm -f /tmp/openclaw-setup.log /tmp/openclaw-setup.pid /tmp/openclaw-setup.exit")
		-- 获取用户选择的版本 (stable=指定版本, latest=最新版)
		local version = http.formvalue("version") or ""
		local env_parts = {
			"OPENCLAW_INSTALL_ROOT=" .. shell_quote(requested_paths.install_root)
		}
		if version == "stable" then
			-- 稳定版: 读取 openclaw-env 中定义的 OC_TESTED_VERSION
			local tested_ver = sys.exec("grep '^OC_TESTED_VERSION=' /usr/bin/openclaw-env 2>/dev/null | cut -d'\"' -f2"):gsub("%s+", "")
			if tested_ver ~= "" then
				table.insert(env_parts, 1, "OC_VERSION=" .. shell_quote(tested_ver))
			end
		elseif version == "latest" then
			env_prefix = "OC_VERSION='latest' "
		elseif version ~= "" and version ~= "latest" then
			-- 校验版本号格式 (仅允许数字、点、横线、字母)
			if version:match("^[%d%.%-a-zA-Z]+$") then
				table.insert(env_parts, 1, "OC_VERSION=" .. shell_quote(version))
			end
			-- 保存规范化后的基础路径，公开字段仍为 install_path，避免破坏兼容。
			sys.exec("uci set openclaw.main.install_path=" .. shell_quote(normalized) .. "; uci commit openclaw 2>/dev/null")
			env_prefix = env_prefix .. "OC_INSTALL_PATH=" .. shell_quote(normalized) .. " "
		end

		uci:set("openclaw", "main", "install_root", requested_paths.install_root)
		uci:commit("openclaw")
		-- 后台安装，成功后自动启用并启动服务
		-- 注: openclaw-env 脚本有 set -e，init_openclaw 中的非关键失败不应阻止启动
		sys.exec("( " .. table.concat(env_parts, " ") .. " /usr/bin/openclaw-env setup > /tmp/openclaw-setup.log 2>&1; RC=$?; echo $RC > /tmp/openclaw-setup.exit; if [ $RC -eq 0 ]; then uci set openclaw.main.enabled=1; uci commit openclaw; /etc/init.d/openclaw enable 2>/dev/null; sleep 1; /etc/init.d/openclaw start >> /tmp/openclaw-setup.log 2>&1; fi ) & echo $! > /tmp/openclaw-setup.pid")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "安装已启动，请查看安装日志..." })
		return
	else
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "未知操作: " .. action })
		return
	end

	http.prepare_content("application/json")
	http.write_json({ status = "ok", action = action })
end

-- ═══════════════════════════════════════════
-- 安装日志轮询 API
-- ═══════════════════════════════════════════
function action_setup_log()
	local http = require "luci.http"
	local sys = require "luci.sys"

	-- 读取日志内容
	local log = ""
	local f = io.open("/tmp/openclaw-setup.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	-- 检查进程是否还在运行
	local running = false
	local pid_file = io.open("/tmp/openclaw-setup.pid", "r")
	if pid_file then
		local pid = pid_file:read("*a"):gsub("%s+", "")
		pid_file:close()
		if pid ~= "" then
			local check = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
			running = (check == "yes")
		end
	end

	-- 读取退出码
	local exit_code = -1
	if not running then
		local exit_file = io.open("/tmp/openclaw-setup.exit", "r")
		if exit_file then
			local code = exit_file:read("*a"):gsub("%s+", "")
			exit_file:close()
			exit_code = tonumber(code) or -1
		end
	end

	-- 判断状态
	local state = "idle"
	if running then
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({
		state = state,
		exit_code = exit_code,
		log = log
	})
end

-- ═══════════════════════════════════════════
-- 版本检查 API
-- ═══════════════════════════════════════════
function action_check_update()
	local http = require "luci.http"
	local sys = require "luci.sys"

	-- 插件版本检查 (优先 GitHub API, 失败回退 Gitea 镜像)
	local plugin_current = ""
	local pf = io.open("/usr/share/openclaw/VERSION", "r")
		or io.open("/root/luci-app-openclaw/VERSION", "r")
	if pf then
		plugin_current = pf:read("*a"):gsub("%s+", "")
		pf:close()
	end

	local plugin_latest = ""
	local release_notes = ""
	local plugin_has_update = false

	local sources = {
		{ api = GITHUB_API_RELEASES_URL, releases = GITHUB_RELEASES_URL },
		{ api = GITEA_API_RELEASES_URL, releases = GITEA_RELEASES_URL },
	}

	for _, source in ipairs(sources) do
		local tag, body = fetch_release_metadata_from_api(sys, source.api)
		if plugin_latest == "" and tag ~= "" then
			plugin_latest = tag
		elseif tag ~= "" and compare_plugin_versions(tag, plugin_latest) > 0 then
			plugin_latest = tag
		end

		if body and body ~= "" and release_notes == "" then
			release_notes = body
		end

		if plugin_latest == "" then
			tag = fetch_release_tag_from_redirect(sys, source.releases)
			if tag ~= "" and (plugin_latest == "" or compare_plugin_versions(tag, plugin_latest) > 0) then
				plugin_latest = tag
			end
		end

		if plugin_latest ~= "" and release_notes ~= "" then
			break
		end
	end

	if plugin_current ~= "" and plugin_latest ~= "" then
		plugin_has_update = compare_plugin_versions(plugin_latest, plugin_current) > 0
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		plugin_current = plugin_current,
		plugin_latest = plugin_latest,
		plugin_has_update = plugin_has_update,
		release_notes = release_notes
	})
end

-- ═══════════════════════════════════════════
-- 卸载运行环境 API
-- ═══════════════════════════════════════════
function action_uninstall()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local paths = get_runtime_paths()
	local install_path = paths.oc_root
	if not is_safe_openclaw_root(install_path) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "安装路径未通过安全校验，已取消卸载: " .. install_path })
		return
	end
	local q_install_path = shell_quote(install_path)

	-- 停止服务
	sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
	-- 禁用开机启动
	sys.exec("/etc/init.d/openclaw disable 2>/dev/null")
	-- 设置 UCI enabled=0
	sys.exec("uci set openclaw.main.enabled=0; uci commit openclaw 2>/dev/null")
	-- 删除 Node.js + OpenClaw 运行环境 (包含所有插件: qqbot, 飞书等)
	sys.exec("rm -rf " .. q_install_path)
	-- 清理临时文件
	sys.exec("rm -f /tmp/openclaw-setup.* /tmp/openclaw-update.log /tmp/openclaw-plugin-upgrade.* /var/run/openclaw*.pid")
	-- 清理 LuCI 缓存
	sys.exec("rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null")
	-- 删除 openclaw 系统用户
	sys.exec("sed -i '/^openclaw:/d' /etc/passwd /etc/shadow /etc/group 2>/dev/null")

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		message = "运行环境已卸载。已清理: Node.js 运行环境 (" .. paths.oc_root .. ")、所有插件 (qqbot/飞书等)、旧数据目录 (/root/.openclaw)、临时文件、LuCI 缓存。"
	})
end

-- ═══════════════════════════════════════════
-- 获取 Token API
-- 仅通过 LuCI 认证后可调用，避免 Token 嵌入 HTML 源码
-- 返回网关 Token 和 PTY Token
-- ═══════════════════════════════════════════
function action_get_token()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local token = uci:get("openclaw", "main", "token") or ""
	local pty_token = uci:get("openclaw", "main", "pty_token") or ""
	http.prepare_content("application/json")
	http.write_json({ token = token, pty_token = pty_token })
end

-- ═══════════════════════════════════════════
-- 插件升级 API (后台下载升级包并执行)
-- 参数: version — 目标版本号 (如 1.0.8)
-- ═══════════════════════════════════════════
function action_plugin_upgrade()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local version = http.formvalue("version") or ""
	if version == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "缺少版本号参数" })
		return
	end

	-- 安全检查: version 只允许数字和点
	if not version:match("^[%d%.]+$") then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "版本号格式无效" })
		return
	end

	-- 清理旧日志和状态
	sys.exec("rm -f /tmp/openclaw-plugin-upgrade.log /tmp/openclaw-plugin-upgrade.pid /tmp/openclaw-plugin-upgrade.exit")

	-- 后台执行:
	-- 1) 优先下载 GitHub Release (失败回退 Gitea 镜像)
	-- 2) 若系统存在 apk, 优先尝试 .apk 安装 (失败回退 .run)
	local run_url_gitea = GITEA_RELEASES_URL .. "/download/v" .. version .. "/luci-app-openclaw_" .. version .. ".run"
	local run_url_github = GITHUB_RELEASES_URL .. "/download/v" .. version .. "/luci-app-openclaw_" .. version .. ".run"
	local apk_url_gitea = GITEA_RELEASES_URL .. "/download/v" .. version .. "/luci-app-openclaw_" .. version .. "-r1_all.apk"
	local apk_url_github = GITHUB_RELEASES_URL .. "/download/v" .. version .. "/luci-app-openclaw_" .. version .. "-r1_all.apk"
	local apk_legacy_url_gitea = GITEA_RELEASES_URL .. "/download/v" .. version .. "/luci-app-openclaw_" .. version .. "-1_all.apk"
	local apk_legacy_url_github = GITHUB_RELEASES_URL .. "/download/v" .. version .. "/luci-app-openclaw_" .. version .. "-1_all.apk"
	sys.exec(string.format(
		"( echo '正在下载插件 v%s ...' > /tmp/openclaw-plugin-upgrade.log; " ..
		"ASSET_KIND='run'; TARGET_FILE='/tmp/luci-app-openclaw-update.run'; " ..
		"URLS='%s %s'; " ..
		"if command -v apk >/dev/null 2>&1; then " ..
		"  ASSET_KIND='apk'; TARGET_FILE='/tmp/luci-app-openclaw-update.apk'; " ..
		"  URLS='%s %s %s %s %s %s'; " ..
		"  echo '检测到 apk 包管理器，优先尝试 .apk 升级包...' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"fi; " ..
		"DL_OK=0; LAST_URL=''; LAST_RC=1; " ..
		"for U in $URLS; do " ..
		"  [ -n \"$U\" ] || continue; " ..
		"  LAST_URL=\"$U\"; " ..
		"  echo \"尝试下载: $U\" >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  curl -sL --connect-timeout 15 --max-time 120 -o \"$TARGET_FILE\" \"$U\" >> /tmp/openclaw-plugin-upgrade.log 2>&1; " ..
		"  RC=$?; LAST_RC=$RC; " ..
		"  if [ $RC -ne 0 ]; then " ..
		"    echo \"下载失败 (curl exit: $RC)\" >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    continue; " ..
		"  fi; " ..
		"  FSIZE=$(wc -c < \"$TARGET_FILE\" 2>/dev/null | tr -d ' '); " ..
		"  echo \"下载完成 (${FSIZE} bytes)\" >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  FHEAD=$(head -c 9 \"$TARGET_FILE\" 2>/dev/null); " ..
		"  if [ \"$FSIZE\" -lt 10000 ] 2>/dev/null; then " ..
		"    if [ \"$FHEAD\" = 'Not Found' ]; then " ..
		"      echo '⚠️ 远端返回 Not Found，继续尝试下一个镜像...' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    else " ..
		"      echo '⚠️ 文件过小，可能是网络异常或资产缺失，继续尝试下一个镜像...' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    fi; " ..
		"    continue; " ..
		"  fi; " ..
		"  DL_OK=1; break; " ..
		"done; " ..
		"if [ $DL_OK -ne 1 ]; then " ..
		"  echo '❌ 所有下载地址均失败。' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  echo \"最后尝试地址: $LAST_URL\" >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  echo '请手动下载后安装: %s' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  echo $LAST_RC > /tmp/openclaw-plugin-upgrade.exit; " ..
		"  rm -f /tmp/luci-app-openclaw-update.run /tmp/luci-app-openclaw-update.apk; " ..
		"else " ..
		"  echo '' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  if [ \"$ASSET_KIND\" = 'apk' ]; then " ..
		"    echo '正在通过 apk 安装...' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    apk add --allow-untrusted --repositories-file /dev/null \"$TARGET_FILE\" >> /tmp/openclaw-plugin-upgrade.log 2>&1; " ..
		"    RC2=$?; " ..
		"    if [ $RC2 -ne 0 ]; then " ..
		"      echo 'apk 安装失败，回退到 .run 安装器...' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"      RUN_OK=0; " ..
		"      for RU in '%s' '%s'; do " ..
		"        echo \"尝试下载 .run: $RU\" >> /tmp/openclaw-plugin-upgrade.log; " ..
		"        curl -sL --connect-timeout 15 --max-time 120 -o /tmp/luci-app-openclaw-update.run \"$RU\" >> /tmp/openclaw-plugin-upgrade.log 2>&1; " ..
		"        RC3=$?; " ..
		"        if [ $RC3 -eq 0 ]; then " ..
		"          FSIZE2=$(wc -c < /tmp/luci-app-openclaw-update.run 2>/dev/null | tr -d ' '); " ..
		"          if [ \"$FSIZE2\" -ge 10000 ] 2>/dev/null; then RUN_OK=1; break; fi; " ..
		"        fi; " ..
		"      done; " ..
		"      if [ $RUN_OK -eq 1 ]; then " ..
		"        sh /tmp/luci-app-openclaw-update.run >> /tmp/openclaw-plugin-upgrade.log 2>&1; RC2=$?; " ..
		"      else " ..
		"        RC2=1; echo '回退 .run 下载失败' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"      fi; " ..
		"    fi; " ..
		"  else " ..
		"    echo '正在安装...' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    sh \"$TARGET_FILE\" >> /tmp/openclaw-plugin-upgrade.log 2>&1; " ..
		"    RC2=$?; " ..
		"  fi; " ..
		"  echo $RC2 > /tmp/openclaw-plugin-upgrade.exit; " ..
		"  if [ $RC2 -eq 0 ]; then " ..
		"    echo '' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"    echo '✅ 插件升级完成！请刷新浏览器页面。' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  else " ..
		"    echo '安装执行失败 (exit: '$RC2')' >> /tmp/openclaw-plugin-upgrade.log; " ..
		"  fi; " ..
		"  rm -f /tmp/luci-app-openclaw-update.run /tmp/luci-app-openclaw-update.apk; " ..
		"fi " ..
		") & echo $! > /tmp/openclaw-plugin-upgrade.pid",
		version,
		run_url_github, run_url_gitea,
		apk_url_github, apk_url_gitea, apk_legacy_url_github, apk_legacy_url_gitea, run_url_github, run_url_gitea,
		GITEA_RELEASES_URL .. "/tag/v" .. version,
		run_url_github, run_url_gitea
	))

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		message = "插件升级已在后台启动..."
	})
end

-- ═══════════════════════════════════════════
-- 插件升级日志轮询 API
-- ═══════════════════════════════════════════
function action_plugin_upgrade_log()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local log = ""
	local f = io.open("/tmp/openclaw-plugin-upgrade.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	local running = false
	local pid_file = io.open("/tmp/openclaw-plugin-upgrade.pid", "r")
	if pid_file then
		local pid = pid_file:read("*a"):gsub("%s+", "")
		pid_file:close()
		if pid ~= "" then
			local check = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
			running = (check == "yes")
		end
	end

	local exit_code = -1
	if not running then
		local exit_file = io.open("/tmp/openclaw-plugin-upgrade.exit", "r")
		if exit_file then
			local code = exit_file:read("*a"):gsub("%s+", "")
			exit_file:close()
			exit_code = tonumber(code) or -1
		end
	end

	local state = "idle"
	if running then
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		log = log,
		state = state,
		running = running,
		exit_code = exit_code
	})
end

-- ═══════════════════════════════════════════
-- OpenClaw 运行体升级 API (后台执行 openclaw-env upgrade)
-- ═══════════════════════════════════════════
function action_runtime_upgrade()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local paths = get_runtime_paths()

	if not file_exists("/usr/bin/openclaw-env") then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "未找到 /usr/bin/openclaw-env，请先升级或重装插件。" })
		return
	end

	if not file_exists(get_node_bin(paths)) or find_oc_entry(paths) == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw 运行环境未安装，请先点击「安装运行环境」。" })
		return
	end

	local plugin_version = get_plugin_version()
	local target_env = ""
	local target_label = "latest"
	if plugin_version ~= "" then
		target_env = "OC_VERSION=" .. shell_quote(plugin_version) .. " "
		target_label = "v" .. plugin_version
	end

	sys.exec("rm -f /tmp/openclaw-runtime-upgrade.log /tmp/openclaw-runtime-upgrade.pid /tmp/openclaw-runtime-upgrade.exit")
	sys.exec(
		"( " ..
		"echo '正在升级 OpenClaw 运行体...' > /tmp/openclaw-runtime-upgrade.log; " ..
		"echo '安装根目录: " .. shell_quote(paths.install_root) .. "' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"echo '实际运行目录: " .. shell_quote(paths.oc_root) .. "' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"echo '目标版本: " .. target_label .. "' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"echo '' >> /tmp/openclaw-runtime-upgrade.log; " ..
		target_env .. "OPENCLAW_INSTALL_ROOT=" .. shell_quote(paths.install_root) .. " /usr/bin/openclaw-env upgrade >> /tmp/openclaw-runtime-upgrade.log 2>&1; " ..
		"RC=$?; " ..
		"if [ $RC -eq 0 ]; then " ..
		"  echo '' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"  echo '正在重启 OpenClaw 服务...' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"  /etc/init.d/openclaw restart >> /tmp/openclaw-runtime-upgrade.log 2>&1; " ..
		"  RC=$?; " ..
		"fi; " ..
		"echo $RC > /tmp/openclaw-runtime-upgrade.exit; " ..
		"if [ $RC -eq 0 ]; then " ..
		"  echo '' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"  echo '✅ OpenClaw 运行体升级完成！' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"else " ..
		"  echo '' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"  echo '❌ OpenClaw 运行体升级失败 (exit: '$RC')' >> /tmp/openclaw-runtime-upgrade.log; " ..
		"fi " ..
		") & echo $! > /tmp/openclaw-runtime-upgrade.pid"
	)

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		message = "OpenClaw 升级已在后台启动...",
		install_root = paths.install_root,
		oc_root = paths.oc_root,
		target_version = plugin_version
	})
end

-- ═══════════════════════════════════════════
-- OpenClaw 运行体升级日志轮询 API
-- ═══════════════════════════════════════════
function action_runtime_upgrade_log()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local log = ""
	local f = io.open("/tmp/openclaw-runtime-upgrade.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	local running = false
	local pid_file = io.open("/tmp/openclaw-runtime-upgrade.pid", "r")
	if pid_file then
		local pid = pid_file:read("*a"):gsub("%s+", "")
		pid_file:close()
		if pid ~= "" then
			local check = sys.exec("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "")
			running = (check == "yes")
		end
	end

	local exit_code = -1
	if not running then
		local exit_file = io.open("/tmp/openclaw-runtime-upgrade.exit", "r")
		if exit_file then
			local code = exit_file:read("*a"):gsub("%s+", "")
			exit_file:close()
			exit_code = tonumber(code) or -1
		end
	end

	local state = "idle"
	if running then
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		log = log,
		state = state,
		running = running,
		exit_code = exit_code
	})
end

-- ═══════════════════════════════════════════
-- 配置备份 API (v2026.3.8+)
-- action=create: 创建配置备份
-- action=verify:  验证最新备份
-- action=list:    列出现有备份(含类型/大小)
-- action=delete:  删除指定备份文件
-- ═══════════════════════════════════════════
function action_backup()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local action = http.formvalue("action") or "create"
	local paths = get_runtime_paths()

	local node_bin = get_node_bin(paths)
	local oc_entry = find_oc_entry(paths)

	if oc_entry == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw 未安装，无法执行备份操作" })
		return
	end

	local env_prefix = string.format(
		"OPENCLAW_INSTALL_ROOT=%s " ..
		"HOME=%s OPENCLAW_HOME=%s " ..
		"OPENCLAW_STATE_DIR=%s " ..
		"OPENCLAW_CONFIG_PATH=%s " ..
		"PATH=%s:%s:$PATH ",
		shell_quote(paths.install_root),
		shell_quote(paths.oc_data),
		shell_quote(paths.oc_data),
		shell_quote(paths.oc_data .. "/.openclaw"),
		shell_quote(get_config_file(paths)),
		shell_quote(paths.node_base .. "/bin"),
		shell_quote(paths.oc_global .. "/bin")
	)

	-- 备份目录 (openclaw backup create 输出到 CWD，需要 cd)
	local backup_dir = paths.oc_data .. "/.openclaw/backups"
	local cd_prefix = "mkdir -p " .. shell_quote(backup_dir) .. " && cd " .. shell_quote(backup_dir) .. " && "

	-- ── 辅助: 解析单个备份文件的 manifest 信息 ──
	local function parse_backup_info(filepath)
		local filename = filepath:match("([^/]+)$") or filepath
		-- 文件大小
			local st = nixio_fs.stat(filepath)
		local size = st and st.size or 0
		-- 从文件名提取时间戳: 2026-03-11T18-28-43.149Z-openclaw-backup.tar.gz
		local ts = filename:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%d%.%d+Z)")
		local display_time = ""
		if ts then
			-- 2026-03-11T18-28-43.149Z -> 2026-03-11 18:28:43
			display_time = ts:gsub("T", " "):gsub("(%d%d)%-(%d%d)%-(%d%d)%.%d+Z", "%1:%2:%3")
		end
		-- 读取 manifest.json 判断备份类型
		local backup_type = "unknown"
			local manifest_json = sys.exec(
				"tar --wildcards -xzf " .. shell_quote(filepath) .. " '*/manifest.json' -O 2>/dev/null"
			)
		if manifest_json and manifest_json ~= "" then
			-- 简单字符串匹配，避免依赖 JSON 库
			if manifest_json:match('"onlyConfig"%s*:%s*true') then
				backup_type = "config"
			elseif manifest_json:match('"onlyConfig"%s*:%s*false') then
				backup_type = "full"
			end
		else
			-- 无法读取 manifest，通过文件大小推断
			if size < 50000 then
				backup_type = "config"
			else
				backup_type = "full"
			end
		end
		-- 格式化大小
		local size_str
		if size >= 1073741824 then
			size_str = string.format("%.1f GB", size / 1073741824)
		elseif size >= 1048576 then
			size_str = string.format("%.1f MB", size / 1048576)
		elseif size >= 1024 then
			size_str = string.format("%.1f KB", size / 1024)
		else
			size_str = tostring(size) .. " B"
		end
		return {
			filename = filename,
			filepath = filepath,
			size = size,
			size_str = size_str,
			time = display_time,
			backup_type = backup_type
		}
	end

		if action == "create" then
			local only_config = http.formvalue("only_config") or "1"
			local backup_cmd
			if only_config == "1" then
				backup_cmd = cd_prefix .. env_prefix .. shell_quote(node_bin) .. " " .. shell_quote(oc_entry) .. " backup create --only-config --no-include-workspace 2>&1"
			else
				backup_cmd = cd_prefix .. "HOME=" .. shell_quote(backup_dir) .. " " .. env_prefix .. shell_quote(node_bin) .. " " .. shell_quote(oc_entry) .. " backup create --no-include-workspace 2>&1"
			end
		local output = sys.exec(backup_cmd)
		-- 完整备份可能输出到 HOME，移动到 backup_dir
		sys.exec("mv " .. shell_quote(paths.oc_data) .. "/*-openclaw-backup.tar.gz " .. shell_quote(backup_dir .. "/") .. " 2>/dev/null")
		-- 提取备份文件路径
		local backup_path = output:match("([%S]+%.tar%.gz)")
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "create",
			output = output,
			backup_path = backup_path or ""
		})
	elseif action == "verify" then
		-- 找到最新的备份文件
			local latest = sys.exec("ls -t " .. shell_quote(backup_dir) .. "/*-openclaw-backup.tar.gz 2>/dev/null | head -1"):gsub("%s+", "")
		if latest == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "未找到备份文件，请先创建备份" })
			return
		end
			local output = sys.exec(env_prefix .. shell_quote(node_bin) .. " " .. shell_quote(oc_entry) .. " backup verify " .. shell_quote(latest) .. " 2>&1")
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "verify",
			output = output,
			backup_path = latest
		})
	elseif action == "restore" then
		-- 支持指定文件名，不指定则用最新
		local target_file = http.formvalue("file") or ""
		local restore_path = ""
		if target_file ~= "" then
			-- 安全: 只允许文件名，不允许路径穿越
			target_file = target_file:match("([^/]+)$") or ""
			if target_file:match("%-openclaw%-backup%.tar%.gz$") then
				restore_path = backup_dir .. "/" .. target_file
			end
		end
			if restore_path == "" or not nixio_fs.stat(restore_path, "type") then
				-- fallback 到最新
				restore_path = sys.exec("ls -t " .. shell_quote(backup_dir) .. "/*-openclaw-backup.tar.gz 2>/dev/null | head -1"):gsub("%s+", "")
		end
		if restore_path == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "未找到备份文件，请先创建备份" })
			return
		end
		local oc_data_dir = paths.oc_data .. "/.openclaw"
		local config_path = oc_data_dir .. "/openclaw.json"

		-- 1) 先验证备份中的 openclaw.json 是否有效
			local check_cmd = "tar -xzf " .. shell_quote(restore_path) .. " --wildcards '*/openclaw.json' -O 2>/dev/null"
		local json_content = sys.exec(check_cmd)
		if not json_content or json_content == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件中未找到 openclaw.json" })
			return
		end
		-- 写入临时文件并用 node 验证
		local tmpfile = "/tmp/oc-restore-check.json"
		local f = io.open(tmpfile, "w")
		if f then f:write(json_content); f:close() end
			local check = sys.exec(shell_quote(node_bin) .. " -e \"try{JSON.parse(require('fs').readFileSync('" .. tmpfile .. "','utf8'));console.log('OK')}catch(e){console.log('FAIL')}\" 2>/dev/null"):gsub("%s+", "")
		os.remove(tmpfile)
		if check ~= "OK" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件中的配置无效，恢复已取消" })
			return
		end

		-- 2) 备份当前配置
			sys.exec("cp -f " .. shell_quote(config_path) .. " " .. shell_quote(config_path .. ".pre-restore") .. " 2>/dev/null")

		-- 3) 获取备份名前缀 (如: 2026-03-11T18-21-17.209Z-openclaw-backup)
		--    备份结构: <backup_name>/payload/posix/<绝对路径>
			local first_entry = sys.exec("tar -tzf " .. shell_quote(restore_path) .. " 2>/dev/null | head -1"):gsub("%s+", "")
		local backup_name = first_entry:match("^([^/]+)/") or ""
		if backup_name == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件格式无法识别" })
			return
		end
		local payload_prefix = backup_name .. "/payload/posix/"
		-- strip 3 层: <backup_name> / payload / posix
		local strip_count = 3

		-- 4) 停止服务
		sys.exec("/etc/init.d/openclaw stop >/dev/null 2>&1")
		-- 等待端口释放
		sys.exec("sleep 2")

		-- 5) 提取 payload 文件到根目录 (还原到原始绝对路径)
		--    注: --wildcards 与 --strip-components 组合在某些 tar 版本不兼容
		--    使用精确路径前缀代替 wildcards
			local extract_cmd = string.format(
				"tar -xzf %s --strip-components=%d -C / '%s' 2>&1",
				shell_quote(restore_path), strip_count, payload_prefix
			)
		local extract_out = sys.exec(extract_cmd)

		-- 6) 修复权限
			sys.exec("chown -R openclaw:openclaw " .. shell_quote(oc_data_dir) .. " 2>/dev/null")

		-- 7) 重启服务
		sys.exec("/etc/init.d/openclaw start >/dev/null 2>&1 &")

		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "restore",
			message = "已从备份完整恢复所有配置和数据，服务正在重启。原配置已保存为 openclaw.json.pre-restore",
			backup_path = restore_path,
			extract_output = extract_out or ""
		})
	elseif action == "list" then
		-- 返回结构化的备份文件列表(含类型/大小/时间)
			local files_raw = sys.exec("ls -t " .. shell_quote(backup_dir) .. "/*-openclaw-backup.tar.gz 2>/dev/null"):gsub("%s+$", "")
		local backups = {}
		if files_raw ~= "" then
			for fpath in files_raw:gmatch("[^\n]+") do
				fpath = fpath:gsub("%s+", "")
				if fpath ~= "" then
					backups[#backups + 1] = parse_backup_info(fpath)
				end
				-- 最多返回 20 条
				if #backups >= 20 then break end
			end
		end
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "list",
			backups = backups
		})
	elseif action == "delete" then
		local target_file = http.formvalue("file") or ""
		-- 安全: 只允许文件名，不允许路径穿越
		target_file = target_file:match("([^/]+)$") or ""
		if target_file == "" or not target_file:match("%-openclaw%-backup%.tar%.gz$") then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "无效的备份文件名" })
			return
		end
		local del_path = backup_dir .. "/" .. target_file
			if not nixio_fs.stat(del_path, "type") then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "备份文件不存在" })
			return
		end
		os.remove(del_path)
		http.prepare_content("application/json")
		http.write_json({
			status = "ok",
			action = "delete",
			message = "已删除备份: " .. target_file
		})
	else
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "未知备份操作: " .. action })
	end
end

-- ═══════════════════════════════════════════
-- 系统配置检测 API (安装前检测)
-- 检测内存和磁盘空间是否满足最低要求
-- 要求: 内存 > 1GB, 磁盘可用空间 > 1.5GB
-- ═══════════════════════════════════════════
function action_check_system()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local valid_root, install_root, root_error = normalize_requested_install_root(http.formvalue("install_root"))

	-- 最低要求配置
	local MIN_MEMORY_MB = 1024      -- 1GB
	local MIN_DISK_MB = 1536        -- 1.5GB
	local paths = get_runtime_paths(install_root)

	local result = {
		memory_mb = 0,
		memory_ok = false,
		disk_mb = 0,
		disk_ok = false,
		disk_path = "",
		install_root = paths.install_root,
		oc_root = paths.oc_root,
		pass = false,
		message = ""
	}

	if not valid_root then
		result.message = root_error
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- 检测总内存 (从 /proc/meminfo 读取 MemTotal)
	local meminfo = io.open("/proc/meminfo", "r")
	if meminfo then
		for line in meminfo:lines() do
			local mem_total = line:match("MemTotal:%s+(%d+)%s+kB")
			if mem_total then
				result.memory_mb = math.floor(tonumber(mem_total) / 1024)
				break
			end
		end
		meminfo:close()
	end
	result.memory_ok = result.memory_mb >= MIN_MEMORY_MB

	-- 检测磁盘可用空间
	if directory_exists(paths.install_root) then
		local df_output = sys.exec("df -m " .. shell_quote(paths.install_root) .. " 2>/dev/null | tail -1 | awk '{print $4}'"):gsub("%s+", "")
		if df_output and df_output ~= "" and tonumber(df_output) then
			result.disk_mb = tonumber(df_output)
			result.disk_path = paths.install_root
		end
		result.disk_ok = result.disk_mb >= MIN_DISK_MB
	else
		result.message = "检测目录不存在: " .. paths.install_root .. "。请先挂载或创建该目录。"
	end

	-- 安装前写入探针：先在实际存在的父目录创建临时目录。
	-- 这能明确识别 overlay 满、只读挂载、路径挂载点不可写等问题，避免下载完才失败。
	local probe_dir = disk_check_path .. "/.openclaw-write-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
	local probe_rc = os.execute("mkdir " .. shell_quote(probe_dir) .. " >/dev/null 2>&1")
	if probe_rc == 0 or probe_rc == true then
		result.writable_ok = true
		os.execute("rmdir " .. shell_quote(probe_dir) .. " >/dev/null 2>&1")
	else
		result.writable_ok = false
	end

	-- 综合判断
	result.pass = result.memory_ok and result.disk_ok and result.writable_ok

	-- 生成提示信息
	if result.pass then
		result.message = "系统配置检测通过"
	else
		local issues = {}
		if result.message ~= "" then
			table.insert(issues, result.message)
		end
		if not result.memory_ok then
			table.insert(issues, string.format("内存不足: 当前 %d MB，需要至少 %d MB", result.memory_mb, MIN_MEMORY_MB))
		end
		if result.message == "" and not result.disk_ok then
			table.insert(issues, string.format("磁盘空间不足: 当前 %d MB 可用，需要至少 %d MB", result.disk_mb, MIN_DISK_MB))
		end
		if not result.writable_ok then
			table.insert(issues, "安装路径所在挂载点不可写，可能是 overlay 已满、只读或外置盘未正确挂载")
		end
		result.message = table.concat(issues, "；")
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_wechat_status()
	local http = require "luci.http"
	local paths = get_runtime_paths()
	local wechat_paths = get_wechat_paths(paths)
	local result = {
		plugin_installed = false,
		plugin_version = "",
		logged_in = false,
		accounts = {},
		install_path = paths.install_root,
		oc_root = paths.oc_root,
	}

	if file_exists(wechat_paths.plugin_json) then
		result.plugin_installed = true
		if file_exists(wechat_paths.package_json) then
			local pf = io.open(wechat_paths.package_json, "r")
			if pf then
				local content = pf:read("*a") or ""
				pf:close()
				result.plugin_version = content:match('"version"%s*:%s*"([^"]+)"') or ""
			end
		end
	end

	local accounts_text = read_text_file(wechat_paths.accounts_json)
	if accounts_text ~= "" then
		for acc in accounts_text:gmatch('"([^"]+)"') do
			table.insert(result.accounts, { name = acc })
		end
		if #result.accounts > 0 then
			result.logged_in = true
		end
	end

	local config_text = read_text_file(wechat_paths.config_json)
	if config_text ~= "" and config_text:match('"openclaw%-weixin"%s*:%s*{') then
		local accounts_str = config_text:match('"accounts"%s*:%s*%[([^%]]*)%]')
		if accounts_str and accounts_str ~= "" then
			local count = 0
			for _ in accounts_str:gmatch('"wxid') do
				count = count + 1
			end
			for _ in accounts_str:gmatch('"nickName"') do
				count = count + 1
			end
			if count > 0 and not result.logged_in then
				result.logged_in = true
				result.accounts = { { name = "微信账号" } }
			end
		end

		if config_text:match('"credential"%s*:%s*{') and not result.logged_in then
			result.logged_in = true
			result.accounts = { { name = "微信账号" } }
		end
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_wechat_install()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local paths = get_runtime_paths()

	if not runtime_installed(paths) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw 运行环境未安装，请先在基本设置中安装运行环境" })
		return
	end
	if not ensure_openclaw_user(paths.oc_data) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "无法创建 openclaw 系统用户" })
		return
	end
	if not file_exists(WECHAT_HELPER) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "微信 helper 未安装" })
		return
	end
	if sys.call("command -v python3 >/dev/null 2>&1") ~= 0 then
		sys.exec("opkg update >/dev/null 2>&1 && opkg install python3-light >/dev/null 2>&1")
	end

	sys.exec("rm -f " .. shell_quote(WECHAT_INSTALL_LOG) .. " " .. shell_quote(WECHAT_INSTALL_PID) .. " " .. shell_quote(WECHAT_INSTALL_EXIT) .. " " .. shell_quote(WECHAT_STATE_FILE))
	wechat_spawn("install", WECHAT_INSTALL_PID)

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件安装已在后台启动..." })
end

function action_wechat_install_log()
	local http = require "luci.http"

	local log = read_text_file(WECHAT_INSTALL_LOG)
	local state_file = read_kv_file(WECHAT_STATE_FILE)
	local running = false
	local pid = trim(state_file.pid or read_text_file(WECHAT_INSTALL_PID))
	local exit_code = -1

	if state_file.status == "running" then
		running = pid ~= "" and pid_is_running(pid)
	elseif state_file.status == "finished" then
		local exit_text = trim(state_file.exit_code or read_text_file(WECHAT_INSTALL_EXIT))
		if exit_text ~= "" then
			exit_code = tonumber(exit_text) or -1
		end
	else
		if pid ~= "" then
			running = pid_is_running(pid)
		end

		if not running then
			local exit_text = trim(read_text_file(WECHAT_INSTALL_EXIT))
			if exit_text ~= "" then
				exit_code = tonumber(exit_text) or -1
			end
		end
	end

	if state_file.status == "finished" and exit_code == -1 then
		local exit_text = trim(state_file.exit_code or "")
		if exit_text ~= "" then
			exit_code = tonumber(exit_text) or -1
		end
	end

	local state = "idle"
	if state_file.status == "finished" then
		if exit_code == 0 then
			state = "success"
		elseif exit_code > 0 then
			state = "failed"
		end
	elseif running then
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		log = log,
		running = running,
		exit_code = exit_code,
		state = state,
	})
end

function action_wechat_login()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local paths = get_runtime_paths()

	if not runtime_installed(paths) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw 运行环境未安装，请先在基本设置中安装运行环境" })
		return
	end

	if not file_exists(WECHAT_HELPER) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "微信 helper 未安装" })
		return
	end
	if file_exists("/usr/libexec/openclaw-permissions.sh") then
		sys.exec("/usr/libexec/openclaw-permissions.sh prepare-workdirs " .. shell_quote(paths.oc_data) .. " >/dev/null 2>&1")
	end
	local writable_check = "test -w " .. shell_quote(paths.oc_data .. "/.npm") .. " && test -w " .. shell_quote(paths.oc_data .. "/.openclaw")
	if sys.call("start-stop-daemon -S -c openclaw -x /bin/sh -- -c " .. shell_quote(writable_check) .. " >/dev/null 2>&1") ~= 0 then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "openclaw 用户无法写入微信登录目录" })
		return
	end

	sys.exec("rm -f " .. shell_quote(WECHAT_LOGIN_QR) .. " " .. shell_quote(WECHAT_LOGIN_PID) .. " " .. shell_quote(WECHAT_LOGIN_EXIT) .. " " .. shell_quote(WECHAT_RESTARTED) .. " " .. shell_quote(WECHAT_STATE_FILE))
	wechat_spawn("login", WECHAT_LOGIN_PID)

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信登录流程已启动" })
end

function action_wechat_login_status()
	local http = require "luci.http"
	local sys = require "luci.sys"

	local qrcode = read_text_file(WECHAT_LOGIN_QR)
	local state_file = read_kv_file(WECHAT_STATE_FILE)
	local pid = trim(state_file.pid or read_text_file(WECHAT_LOGIN_PID))
	local running = false
	local helper_finished = state_file.status == "finished"

	if state_file.status == "running" then
		running = pid ~= "" and pid_is_running(pid)
	elseif not helper_finished and pid ~= "" then
		running = pid_is_running(pid)
	end

	local exit_code = -1
	if not running then
		local exit_text = trim(state_file.exit_code or read_text_file(WECHAT_LOGIN_EXIT))
		if exit_text ~= "" then
			exit_code = tonumber(exit_text) or -1
		end
	end

	local qrcode_url = ""
	for url in qrcode:gmatch("https?://[^\n\r]+") do
		qrcode_url = url
	end

	local logged_in = qrcode:find("登录成功") ~= nil
		or qrcode:find("成功登录") ~= nil
		or qrcode:find("Login success") ~= nil
		or qrcode:find("Logged in") ~= nil
		or qrcode:find("已将此 OpenClaw 连接到微信", 1, true) ~= nil
		or qrcode:find("Local login saved auth for openclaw%-weixin") ~= nil

	local state = "idle"
	if helper_finished and exit_code == 0 then
		state = "success"
	elseif logged_in then
		state = "success"
	elseif running and qrcode_url ~= "" then
		state = "qrcode"
	elseif running then
		state = "starting"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	if state == "success" and not nixio_fs.stat(WECHAT_RESTARTED, "type") then
		sys.exec("touch " .. shell_quote(WECHAT_RESTARTED))
		sys.exec("/etc/init.d/openclaw restart_gateway >/dev/null 2>&1 &")
	end
	local error_detail = state == "failed" and qrcode:sub(-2000) or ""

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		state = state,
		qrcode = qrcode,
		qrcode_url = qrcode_url,
		running = running,
		exit_code = exit_code,
		logged_in = logged_in,
		error_detail = error_detail,
	})
end

function action_wechat_check_upgrade()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local paths = get_runtime_paths()
	local wechat_paths = get_wechat_paths(paths)
	local npm_bin = paths.node_base .. "/bin/npm"

	local current_version = ""
	if file_exists(wechat_paths.package_json) then
		local pf = io.open(wechat_paths.package_json, "r")
		if pf then
			local content = pf:read("*a") or ""
			pf:close()
			current_version = content:match('"version"%s*:%s*"([^"]+)"') or ""
		end
	end

	local latest_version = ""
	local check_err = ""
	if runtime_installed(paths) and file_exists(get_node_bin(paths)) then
		local env_prefix = string.format(
			"HOME=%s PATH=%s:%s:$PATH",
			shell_quote(paths.oc_data),
			shell_quote(paths.node_base .. "/bin"),
			shell_quote(paths.oc_global .. "/bin")
		)
		local check_cmd = string.format(
			"%s %s view @tencent-weixin/openclaw-weixin version 2>&1",
			env_prefix,
			shell_quote(npm_bin)
		)
		local raw = sys.exec(check_cmd) or ""
		latest_version = raw:match("(%d+%.%d+%.%d+[%w%.%-]*)%s*$") or ""
		check_err = latest_version == "" and raw:gsub("%s+$", ""):sub(1, 200) or ""
	end

	local has_upgrade = false
	if current_version ~= "" and latest_version ~= "" and compare_plugin_versions(latest_version, current_version) > 0 then
		has_upgrade = true
	end

	http.prepare_content("application/json")
	-- 查询失败时必须显式区分"已是最新"与"查不到"，
	-- 否则用户永远看到"已是最新版"而不知道检测其实没跑通。
	http.write_json({
		status = (latest_version ~= "") and "ok" or "error",
		current_version = current_version,
		latest_version = latest_version,
		has_upgrade = has_upgrade,
		message = (latest_version ~= "") and "" or ("无法查询最新版本: " .. (check_err or "")),
	})
end

function action_wechat_upgrade_plugin()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local paths = get_runtime_paths()

	if not runtime_installed(paths) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw 运行环境未安装，请先在基本设置中安装运行环境" })
		return
	end
	if not ensure_openclaw_user(paths.oc_data) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "无法创建 openclaw 系统用户" })
		return
	end
	if not file_exists(WECHAT_HELPER) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "微信 helper 未安装" })
		return
	end

	sys.exec("rm -f " .. shell_quote(WECHAT_INSTALL_LOG) .. " " .. shell_quote(WECHAT_INSTALL_PID) .. " " .. shell_quote(WECHAT_INSTALL_EXIT) .. " " .. shell_quote(WECHAT_STATE_FILE))
	wechat_spawn("upgrade", WECHAT_INSTALL_PID)

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件升级已在后台启动..." })
end

function action_wechat_logout()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local paths = get_runtime_paths()
	local account_id = http.formvalue("account")

	if not account_id or account_id == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "参数错误：未提供账号 ID" })
		return
	end

	if not runtime_installed(paths) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "OpenClaw 运行环境未安装，请先在基本设置中安装运行环境" })
		return
	end

	if not file_exists(WECHAT_HELPER) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "微信 helper 未安装" })
		return
	end

	wechat_run("logout", "--account " .. shell_quote(account_id))
	sys.exec("/etc/init.d/openclaw restart &")

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信账号已退出" })
end

function action_wechat_uninstall()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local paths = get_runtime_paths()
	local wechat_paths = get_wechat_paths(paths)
	local wechat_state_dir = paths.oc_data .. "/.openclaw/openclaw-weixin"

	if not file_exists(WECHAT_HELPER) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "微信 helper 未安装" })
		return
	end

	wechat_run("uninstall")
	local npm_projects = paths.oc_data .. "/.openclaw/npm/projects"
	if directory_exists(npm_projects) then
		sys.exec("find " .. shell_quote(npm_projects) .. " -path '*/node_modules/@tencent-weixin/openclaw-weixin' -type d -prune -exec rm -rf {} + 2>/dev/null")
	end
	local config_file = get_config_file(paths)
	if file_exists(config_file) and file_exists(get_node_bin(paths)) then
		local cleanup_js = [[
const fs = require('fs');
const p = process.env.OC_CONFIG;
let d = JSON.parse(fs.readFileSync(p, 'utf8'));
function drop(o, k) { if (o && typeof o === 'object') delete o[k]; }
function dropChannel(o) { drop(o, 'openclaw-weixin'); drop(o, 'weixin'); }
if (d.plugins && Array.isArray(d.plugins.allow)) d.plugins.allow = d.plugins.allow.filter((x) => x !== 'openclaw-weixin' && x !== 'weixin');
if (d.plugins) { dropChannel(d.plugins.installs); dropChannel(d.plugins.entries); }
dropChannel(d.channels); dropChannel(d.channel);
fs.writeFileSync(p, JSON.stringify(d, null, 2));
]]
		sys.exec("OC_CONFIG=" .. shell_quote(config_file) .. " " .. shell_quote(get_node_bin(paths)) .. " -e " .. shell_quote(cleanup_js) .. " 2>/dev/null")
	end

	if file_exists(wechat_paths.plugin_dir) then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "微信插件卸载失败" })
		return
	end

	sys.exec("/etc/init.d/openclaw restart &")
	sys.exec("(sleep 6; rm -rf " .. shell_quote(wechat_state_dir) .. " 2>/dev/null) &")

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "微信插件已卸载" })
end
