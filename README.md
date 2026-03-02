# luci-app-openclaw

[![Bilibili](https://img.shields.io/badge/B%E7%AB%99-59438380-00a1d6?logo=bilibili)](https://space.bilibili.com/59438380)
[![Blog](https://img.shields.io/badge/Blog-910501.xyz-orange)](https://blog.910501.xyz/)
[![Build & Release](https://github.com/10000ge10000/luci-app-openclaw/actions/workflows/build.yml/badge.svg)](https://github.com/10000ge10000/luci-app-openclaw/actions/workflows/build.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

[OpenClaw](https://github.com/nicepkg/openclaw) AI 网关的 OpenWrt LuCI 管理插件。

在路由器上运行 OpenClaw，通过 LuCI 管理界面完成安装、配置和服务管理。

**系统要求**

| 项目 | 要求 |
|------|------|
| 架构 | x86_64 或 aarch64 |
| C 库 | glibc 或 musl（自动检测） |
| 依赖 | luci-compat, luci-base, curl, openssl-util |
| 存储 | 1.5GB 以上可用空间 |
| 内存 | 推荐 2GB 及以上 |

## 📦 安装

### 方式一：.run 自解压包（推荐）

无需 SDK，适用于已安装好的系统。

```bash
wget https://github.com/10000ge10000/luci-app-openclaw/releases/latest/download/luci-app-openclaw.run
sh luci-app-openclaw.run
```

### 方式二：.ipk 安装

```bash
wget https://github.com/10000ge10000/luci-app-openclaw/releases/latest/download/luci-app-openclaw.ipk
opkg install luci-app-openclaw.ipk
```

### 方式三：集成到固件编译

适用于自行编译固件或使用在线编译平台的用户。

```bash
cd /path/to/openwrt

# 添加 feeds
echo "src-git openclaw https://github.com/10000ge10000/luci-app-openclaw.git" >> feeds.conf.default

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
git clone https://github.com/10000ge10000/luci-app-openclaw.git package/luci-app-openclaw
make defconfig
make package/luci-app-openclaw/compile V=s
find bin/ -name "luci-app-openclaw*.ipk"
```

### 方式四：手动安装

```bash
git clone https://github.com/10000ge10000/luci-app-openclaw.git
cd luci-app-openclaw

cp -r root/* /
mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi/openclaw /usr/lib/lua/luci/view/openclaw
cp luasrc/controller/openclaw.lua /usr/lib/lua/luci/controller/
cp luasrc/model/cbi/openclaw/*.lua /usr/lib/lua/luci/model/cbi/openclaw/
cp luasrc/view/openclaw/*.htm /usr/lib/lua/luci/view/openclaw/

chmod +x /etc/init.d/openclaw /usr/bin/openclaw-env /usr/share/openclaw/oc-config.sh
sh /etc/uci-defaults/99-openclaw
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/*
```

## � 一键部署下载

OpenClaw 支持全平台一键部署，请根据你的设备选择对应方式。

> **💡 提示**：OpenWrt 路由器请直接使用下方 [📦 安装](#-安装) 章节的命令，无需使用本节下载包。

| 平台 | 下载链接 | 说明 |
|------|----------|------|
| 🐧 Linux (Ubuntu/Debian) | [夸克网盘](https://pan.quark.cn/s/c25bb5c20db1) | 或直接 `curl -fsSL "https://alist.910501.xyz/d/openclaw/install.sh?sign=RUSBfm1vy35Z-2S86e-Hr0s1bR2u_rATHXEpY888zi8=:0" \| bash` |
| 🪟 Windows (Win10/Win11) | [夸克网盘](https://pan.quark.cn/s/af01a152dad7) | 解压后右键「一键安装.bat」以管理员身份运行 |
| 🍎 macOS (Intel & Apple Silicon) | [夸克网盘](https://pan.quark.cn/s/99bad2c03e5c) | 解压后 `bash setup.sh` 授权，再双击「一键安装.command」 |
| 🐂 飞牛 NAS (FnOS) | [夸克网盘](https://pan.quark.cn/s/fea2552a1b73) | 离线 FPK 包，在应用商店「手动安装」 |
| 📡 OpenWrt 路由器 | [GitHub Releases](https://github.com/10000ge10000/luci-app-openclaw/releases/latest) | 见下方安装章节 |

---

## �🔰 首次使用

1. 打开 LuCI → 服务 → OpenClaw，点击「安装运行环境」
2. 安装完成后服务会自动启动，点击「刷新页面」查看状态
3. 进入「Web 控制台」添加 AI 模型和 API Key
4. 进入「配置管理」可使用向导配置消息渠道

## 📂 目录结构

```
luci-app-openclaw/
├── Makefile                          # OpenWrt 包定义
├── luasrc/
│   ├── controller/openclaw.lua       # LuCI 路由和 API
│   ├── model/cbi/openclaw/basic.lua  # 主页面
│   └── view/openclaw/
│       ├── status.htm                # 状态面板
│       ├── advanced.htm              # 配置管理（终端）
│       └── console.htm               # Web 控制台
├── root/
│   ├── etc/
│   │   ├── config/openclaw           # UCI 配置
│   │   ├── init.d/openclaw           # 服务脚本
│   │   └── uci-defaults/99-openclaw  # 初始化脚本
│   └── usr/
│       ├── bin/openclaw-env          # 环境管理工具
│       └── share/openclaw/           # 配置终端资源
├── scripts/
│   ├── build_ipk.sh                  # 本地 IPK 构建
│   └── build_run.sh                  # .run 安装包构建
└── .github/workflows/build.yml       # GitHub Actions
```

## 📡 OpenWrt 路由器专属说明

### 为什么选择路由器部署？

路由器 24 小时在线，天然适合作为 AI 网关的宿主——家里所有设备共享同一个 AI 服务，Telegram / Discord 消息也能全天候响应，无需常开电脑。

### 支持的设备

| 架构 | 典型设备 | 支持状态 |
|------|----------|----------|
| x86_64 | N100 / N5105 软路由、iStoreOS 小主机 | ✅ 完全支持 |
| aarch64 | Raspberry Pi 4/5、R4S、部分 ARM64 路由器 | ✅ 完全支持 |
| 32 位 ARM | 老款 MT7620 / MT7621 路由器 | ❌ 不支持（Node.js 22 无 32 位包） |

### 安装步骤（OpenWrt / iStoreOS）

**第一步：安装 LuCI 插件**

```bash
# 推荐：.run 自解压包，一行搞定
wget https://github.com/10000ge10000/luci-app-openclaw/releases/latest/download/luci-app-openclaw.run
sh luci-app-openclaw.run
```

**第二步：安装 OpenClaw 运行环境**

打开 LuCI → **服务** → **OpenClaw** → 点击「📦 安装运行环境」，脚本会自动完成：
- 检测 CPU 架构（x86_64 / aarch64）
- 检测 C 库类型（glibc / musl，绝大多数 OpenWrt 为 musl）
- 下载对应 Node.js 22 预编译包
- 安装 pnpm 和 OpenClaw 本体

> **网络慢？** 可在路由器 SSH 中指定国内镜像加速 Node.js 下载：
> ```bash
> NODE_MIRROR=https://npmmirror.com/mirrors/node openclaw-env setup
> ```

**第三步：配置 AI 模型和消息渠道**

进入「**配置管理**」页面，在内嵌 Web 终端中使用交互式向导，选数字即可完成配置，支持：
- OpenAI / Anthropic Claude / Google Gemini / DeepSeek / GitHub Copilot / OpenRouter / 通义千问 / Grok / Groq / 硅基流动 等 12+ 家提供商
- Telegram / Discord / 飞书 / Slack 消息渠道

**第四步：用 Telegram 与 AI 对话**

配置完 Telegram Bot Token 后，重启网关即可在 Telegram 直接给 Bot 发消息，路由器全天候在线响应。

### 与其他平台脚本的区别

| 对比项 | Linux/Mac/Win 脚本 | OpenWrt 插件 |
|--------|-------------------|--------------|
| 管理界面 | 命令行菜单 | LuCI 可视化界面 |
| 开机自启 | 系统服务 / 守护进程 | procd 托管，崩溃自动重启 |
| 安装包格式 | .sh / .bat / .command | .run / .ipk |
| Node.js 来源 | 官方 + npm 镜像 | 自动检测 musl/glibc，按需拉取 |

---

## ❓ 常见问题

**安装后 LuCI 菜单没有出现**

```bash
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/*
```

刷新浏览器即可。

**提示缺少依赖 luci-compat**

```bash
opkg update && opkg install luci-compat
```

**Node.js 下载失败**

网络问题，可指定国内镜像：

```bash
NODE_MIRROR=https://npmmirror.com/mirrors/node openclaw-env setup
```

**是否支持 ARM 路由器**

支持 aarch64（ARM64）。不支持 32 位 ARM，Node.js 22 没有 32 位预编译包。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 License

[GPL-3.0](LICENSE)
