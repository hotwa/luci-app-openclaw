# luci-app-openclaw

[![Bilibili](https://img.shields.io/badge/B%E7%AB%99-59438380-00a1d6?logo=bilibili)](https://space.bilibili.com/59438380)
[![Blog](https://img.shields.io/badge/Blog-910501.xyz-orange)](https://blog.910501.xyz/)
[![Build & Release](https://github.com/hotwa/luci-app-openclaw/actions/workflows/build.yml/badge.svg)](https://github.com/hotwa/luci-app-openclaw/actions/workflows/build.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

[OpenClaw](https://github.com/openclaw/openclaw) AI 网关的 OpenWrt LuCI 管理插件。

在路由器上运行 OpenClaw，通过 LuCI 管理界面完成安装、配置和服务管理。

**GitHub Actions 配置**

如果你只想让 `main` 分支走自用发布和 Gitea 同步，请在仓库里配置这些值：

- 仓库变量 `GITEA_API_BASE`
- 仓库变量 `GITEA_REPO`
- 仓库密钥 `GITEA_TOKEN`

纯上游对齐分支 `codex/pure-upstream-align-20260421` 不需要这些值。`GITEA_API_BASE` 和 `GITEA_REPO` 放在 Variables 里即可，`GITEA_TOKEN` 放在 Secrets 里更合适。

**合并上游时必须保留的 hotwa 增强**

本仓库不是上游 `10000ge10000/luci-app-openclaw` 的纯镜像。当前 `main` 包含一组已经在线使用的增强，合并上游时只应移植必要兼容性修复，不要把下面内容改回上游默认实现：

- **版本命名与发布资产**: hotwa 主线使用 OpenClaw 运行时版本命名，例如 `2026.6.10`，发布资产为 `luci-app-openclaw_${VER}.run`、`luci-app-openclaw_${VER}-1_all.ipk`、`luci-app-openclaw_${VER}-r1_all.apk`。不要改回上游 `2.0.x` 插件版本命名，也不要覆盖已有 hotwa tag/release 语义。
- **稳定版运行时 pin**: `VERSION` 与 `root/usr/bin/openclaw-env` 中的 `OC_TESTED_VERSION` 应保持一致；默认安装和升级应安装已测试稳定版。只有显式设置 `OC_VERSION=latest` 时才跟随 npm `latest`。
- **ARM64 musl Node.js 策略**: 保留 hotwa `node-bins` release 的 Node.js `24.14.1` V2 资产、`NODE_VERSION_V2="24.14.1"`、GitHub 优先加 Gitea fallback 的下载链路。不要因为上游使用 `22.22.2` 就直接降回上游版本，除非先发布新的 hotwa `node-bins` 资产并同步 contract tests。
- **下载源与更新源**: LuCI 更新检查、插件升级、运行时安装默认指向 `hotwa/luci-app-openclaw`，并以 `group/luci-app-openclaw` 的 Gitea 镜像作为 fallback。合并上游时不要改回只依赖上游 GitHub release/API。
- **发布链路**: 保留 `.run`、`.ipk`、OpenWrt `.apk` 三种产物，保留可选 Gitea release 同步、OpenList 上传和 release 历史清理脚本。上游没有这些热备发布能力时，不应删除本仓库脚本或 workflow 步骤。
- **路由器现场兼容**: 保留可迁移安装根、npm/cache/tmp 定向到安装数据目录、ARM64 musl 资产动态选择、旧版 `/opt/openclaw` 兼容链接、网关 crash-loop 状态识别、微信长期渠道兼容和独立 OpenClaw runtime upgrade 按钮/日志。
- **测试契约是保护线**: 合并后必须跑 `tests/test_node_packaging_contract.sh`、`tests/test_openclaw_node.sh`、`tests/test_update_check_contract.sh`、`tests/test_release_workflow_contract.sh` 等 contract tests。若这些测试要求 hotwa 行为，优先保留 hotwa 行为，而不是为了贴近上游删除测试。

<div align="center">
  <img src="docs/images/2.png" alt="OpenClaw LuCI 管理界面" width="800" style="border-radius:8px;" />
</div>

**系统要求**

| 项目 | 要求 |
|------|------|
| 架构 | x86_64 或 aarch64 (ARM64) |
| C 库 | musl（自动检测；离线包仅支持 musl） |
| 依赖 | luci-compat, luci-base, curl, openssl-util, tar, script-utils |
| 存储 | **2GB 以上可用空间** |
| 内存 | 推荐 1GB 及以上 |

**当前适配版本**

| 组件 | 默认版本 | 说明 |
|------|----------|------|
| OpenClaw | `2026.7.1-2` | npm `latest` 稳定标签 |
| Node.js | `22.23.0` | Alpine musl LTS 包；OpenClaw 2026.7.x 要求 `>=22.22.3`，安装后会按 `engines.node` 做强校验 |
| 微信插件 | `@tencent-weixin/openclaw-weixin@2.4.6` | CLI 使用 `@tencent-weixin/openclaw-weixin-cli@2.1.4` |

## 📦 安装

### 方式一：.run 自解压包（推荐）

无需 SDK，适用于已安装好的系统。

```bash
# 下载最新版本（自动获取版本号）
VER=$(curl -sI "https://github.com/hotwa/luci-app-openclaw/releases/latest" 2>/dev/null | grep -i "location:" | sed 's/.*tag\/v\{0,1\}//' | tr -d '\r\n')
wget "https://github.com/hotwa/luci-app-openclaw/releases/download/v${VER}/luci-app-openclaw_${VER}.run"
sh "luci-app-openclaw_${VER}.run"
```

### 方式二：.ipk 安装

```bash
# 下载最新版本（自动获取版本号）
VER=$(curl -sI "https://github.com/hotwa/luci-app-openclaw/releases/latest" 2>/dev/null | grep -i "location:" | sed 's/.*tag\/v\{0,1\}//' | tr -d '\r\n')
wget "https://github.com/hotwa/luci-app-openclaw/releases/download/v${VER}/luci-app-openclaw_${VER}-1_all.ipk"
opkg install "luci-app-openclaw_${VER}-1_all.ipk"
```

### 方式三：.apk 安装（OpenWrt 25.12+）

```bash
# 下载最新版本（自动获取版本号）
VER=$(curl -sI "https://github.com/hotwa/luci-app-openclaw/releases/latest" 2>/dev/null | grep -i "location:" | sed 's/.*tag\/v\{0,1\}//' | tr -d '\r\n')
wget "https://github.com/hotwa/luci-app-openclaw/releases/download/v${VER}/luci-app-openclaw_${VER}-r1_all.apk"
apk add --allow-untrusted "luci-app-openclaw_${VER}-r1_all.apk"
```

### 方式四：集成到固件编译

适用于自行编译固件或使用在线编译平台的用户。

```bash
cd /path/to/openwrt

# 添加 feeds
echo "src-git openclaw https://github.com/hotwa/luci-app-openclaw.git" >> feeds.conf.default

# 更新安装
./scripts/feeds update -a
./scripts/feeds install -a

# 选择插件
make menuconfig
# LuCI → Applications → luci-app-openclaw

# 编译
make package/luci-app-openclaw/compile V=s
```

使用 OpenWrt SDK 单独编译：

```bash
git clone https://github.com/hotwa/luci-app-openclaw.git package/luci-app-openclaw
make defconfig
make package/luci-app-openclaw/compile V=s
find bin/ -name "luci-app-openclaw*.ipk"
```


## 🔰 首次使用

1. 打开 LuCI → 服务 → OpenClaw，点击「安装运行环境」
2. 安装完成后服务会自动启动，点击「刷新页面」查看状态
3. 进入「Web 控制台」添加 AI 模型和 API Key
4. 进入「配置管理」可使用向导配置消息渠道

## 自定义安装路径

UCI 字段仍然是 `openclaw.main.install_path`，语义为基础目录。例如：

```bash
uci set openclaw.main.install_path='/mnt/data'
uci commit openclaw
openclaw-env setup
```

实际运行目录会固定展开为 `/mnt/data/openclaw`。如果误填 `/mnt/data/openclaw`，插件会自动规范化为 `/mnt/data`，不会再拼成 `/mnt/data/openclaw/openclaw`。

安装前会执行写入探针；如果 overlay 已满、只读或外置盘未正确挂载，安装会在下载前失败并给出明确日志。

## 微信插件依赖

微信渠道安装前会检查：

- `openclaw` 系统用户是否存在，不存在时自动创建
- `python3` 是否已安装；缺失时会自动执行 `opkg update && opkg install python3-light`
- npm cache、tmp、OpenClaw 数据目录是否可由 `openclaw` 用户写入
- 路由器到 `https://ilinkai.weixin.qq.com` 的 TLS/超时状态
- npm 插件是否已写入 `plugins.installs.openclaw-weixin`、`plugins.allow` 和 `channels.openclaw-weixin.enabled`
- 旧渠道名 `weixin` 会迁移为 `openclaw-weixin`

如自动安装失败，可手动安装：

```bash
opkg update
opkg install python3-light
```

微信配对推荐流程：

1. 在 LuCI「微信配置」页点击「安装/重新安装插件」。
2. 插件安装成功后点击「登录账号」。
3. 页面出现链接后，先点击打开链接，再用微信「扫一扫」扫码。
4. 等待页面提示登录成功，网关会重新加载微信账号。
5. 用微信给网关发一条测试消息，确认能触发 AI 回复。

常见失败原因：

- 二维码过期：重新点击「登录账号」生成新链接。
- 微信账号触发安全风控：更换常用设备/常用网络后再扫码，或换账号测试。
- 路由器网络异常：检查日志中的 `微信接口连通性检查`，重点看 TLS、timeout、DNS。
- 插件注册缺失：重新安装插件，启动时也会自动补齐 `openclaw-weixin` 配置。
- 目录权限错误：按页面日志提示修复 OpenClaw 数据目录权限。

## AI 模型选择机制

配置菜单里的模型清单分三层，避免硬编码的模型 ID 随上游迭代而过期：

1. **精选模型** —— 内置于 `model-presets.json`，每个 Provider 给推荐/最强/均衡/快速四档。
   离线可用、首屏即显示。
2. **从 OpenClaw 获取完整模型列表** —— 调用 `openclaw models list --provider <id>`
   动态发现当前实际可用的模型（带 6 秒超时，失败或超时自动回落到精选列表）。
   未安装对应 Provider 插件、或未配置 API Key 时可能返回空，属正常情况。
3. **手动输入模型 ID** —— 永久保留。上游发布新模型时无需等待本插件更新。

因此 GPT / Claude / Gemini 等更新后，通常不必升级本插件即可使用新模型。

## 已知说明

- OpenClaw 的 diagnostic heartbeat 可能在日志中出现类似周期性探测记录。它不是一次真实用户对话请求；如需降低噪音，优先在 OpenClaw 配置或日志采集侧降低诊断日志级别，不建议直接修改模型调用逻辑。
- 配置管理界面依赖 `oc-config-interactive.js`；若该文件缺失（例如自行裁剪打包清单），
  界面会静默回落到功能较少的传统数字菜单。`tests/test_packaging_parity.sh` 会校验
  三条打包路径的文件清单一致性。
- 当前仓库提供源码、OpenWrt feeds 集成方式、本地 `.run` / `.ipk` 构建脚本入口；推送 `v*` 标签后 CI 会自动构建并发布 Release 产物。

## 📂 目录结构

```
luci-app-openclaw/
├── Makefile                          # OpenWrt 包定义
├── luasrc/
│   ├── controller/openclaw.lua       # LuCI 路由和 API
│   ├── openclaw/paths.lua            # 路径规范化与安全校验
│   ├── model/cbi/openclaw/basic.lua  # 主页面
│   └── view/openclaw/
│       ├── status.htm                # 状态面板
│       ├── advanced.htm              # 配置管理（终端）
│       ├── console.htm               # Web 控制台
│       └── wechat.htm                # 微信渠道向导
├── root/
│   ├── etc/
│   │   ├── config/openclaw           # UCI 配置
│   │   ├── init.d/openclaw           # 服务脚本
│   │   └── uci-defaults/99-openclaw  # 初始化脚本
│   └── usr/
│       ├── libexec/                  # 共享 shell helper
│       ├── bin/openclaw-env          # 环境管理工具
│       └── share/openclaw/
│           ├── oc-config.sh          # 配置管理入口（无 TTY 时的回退菜单）
│           ├── oc-config-interactive.js  # 交互式配置菜单（默认路径）
│           ├── oc-menu-engine.js     # 方向键菜单引擎
│           ├── model-presets.json    # 精选模型预设（shell 与 JS 共读）
│           ├── web-pty.js            # Web PTY 服务
│           └── ui/                   # 配置终端前端资源
├── scripts/
│   ├── build_ipk.sh                  # 本地 IPK 构建
│   ├── build_run.sh                  # .run 安装包构建
│   ├── gen-release-body.sh           # Release 说明生成
│   └── build-node-musl.sh            # 编译 Node.js musl 静态链接版本
├── tests/                            # 契约测试（sh tests/run_all.sh）
└── .github/workflows/
    ├── build.yml                     # 在线构建 + 发布
    └── build-node-musl.yml           # Node.js musl 构建
```

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 License

[GPL-3.0](LICENSE)
