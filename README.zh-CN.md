<div align="center">

<img src="Resources/AppIcon.iconset/icon_128x128.png" alt="atst" width="128" height="128" />

# atst

**a(i)-text-select-translate** — macOS 菜单栏轻量翻译工具

`a`（AI）· `t`（text）· `s`（select）· `t`（translate）

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](#要求)
[![Latest release](https://img.shields.io/github/v/release/itaober/atst?label=version&color=blue)](https://github.com/itaober/atst/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-orange)](./LICENSE)

按下快捷键，立刻得到翻译。内置 Google + Microsoft 接口**开箱即用**；配置自己的 AI 模型后还能解锁词典级释义、IPA 音标和智能解释。

[English](./README.md) · [安装](#安装) · [使用](#使用) · [功能](#功能)

</div>

---

## 亮点

- ⚡ **一键划词翻译** — 在 macOS 任何应用里选中文本，按 `⌥D`，~200ms 出结果
- 🖼️ **截图翻译** — 按 `⌥S` 框选区域即可翻译。默认走本地 Vision OCR（快 + 隐私 + 免费）；OCR 找不到文字时自动 fallback 到 AI 视觉
- 🔀 **多源并列对照** — Google 和 Microsoft 结果显示在上方，AI 结果在下方，一眼对比
- 🧠 **AI 词典模式** — 单词查询能返回多个义项、IPA 音标、用法解释
- 📌 **固定为便签** — 把翻译结果钉成悬浮便签，方便回看
- 💾 **本地缓存** — 重复查询命中 JSON 缓存，按 provider 分别缓存，TTL 和容量上限可配
- 🫧 **原生 Liquid Glass** — 支持的 macOS 26+ 环境会让翻译浮窗和固定便签使用 Liquid Glass；旧系统自动回退到原来的材质
- 🪶 **体积小** — DMG 约 2 MB，安装后约 4 MB。纯 Swift/AppKit，无 Electron / Web 视图
- 🌐 **双语界面** — 根据系统语言自动切换中文 / 英文，也支持手动指定
- 🆓 **零配置即用** — 不填 API key 也能用（内置 Google + Microsoft）；想要更丰富的输出再接 OpenAI 兼容接口

---

## 安装

### 下载最新版本

1. 在 [Releases 页面](https://github.com/itaober/atst/releases) 下载最新的 `atst.dmg`
2. 打开 DMG，把 **atst** 拖到 `应用程序` 文件夹
3. 启动 atst — 菜单栏右上角会出现 **`atst`** 字样
4. 首次按快捷键时 macOS 会请求 **辅助功能** 权限，到 系统设置 → 隐私与安全性 → 辅助功能 授权

> **提示**：因为 atst 还没拿 Apple 开发者签名，首次启动可能提示"无法打开，因为它来自身份不明的开发者"。右键应用 → **打开** → **仍要打开**，或一次性运行 `xattr -d com.apple.quarantine /Applications/atst.app` 即可。

### 从源码构建

需要 **macOS 13+** 和 **Swift 5.9+**（Xcode 15 或 Command Line Tools）。

```bash
git clone https://github.com/itaober/atst.git
cd atst

# 快速调试运行
swift run atst

# 打包成 .app（带图标 / Info.plist / 代码签名）
bash Scripts/build-app.sh
open .build/atst.app

# 打包成 DMG 安装包
bash Scripts/build-dmg.sh
open .build/atst.dmg
```

---

## 使用

### 快捷键

| 快捷键 | 动作 |
|---|---|
| `⌥D` | 翻译当前选中的文本 |
| `⌥S` | 截图选区并翻译其中文字 |

两个快捷键都能在 **设置 → 快捷键** 里改。

### 翻译浮窗

每次翻译会显示一段或两段内容：

- **上方 — API 翻译结果**（Google / Microsoft）：快、免费、无需 key
- **下方 — AI 翻译结果**（如果启用）：包含多义、音标、技术术语解释等丰富信息

每行右侧有独立的复制按钮。整个浮窗 **拖动 header 可以移动位置**；点击外部关闭。点击 header 的 📌 图标可以固定为便签。

### 翻译方式设置

点击菜单栏的 **`atst`** 字样打开设置面板。

通用页有两个开关：

- ☑️ **API 翻译**（默认开启）— Google + Microsoft，零配置
- ☐ **AI 翻译**（默认关闭）— OpenAI 兼容接口，在 AI 子页配置 base URL / key / model

#### AI 配置（可选）

进入 **AI 翻译** 子页：

- **Base URL** — 任何 OpenAI 兼容接口，例如 `https://api.openai.com/v1`、`http://localhost:11434/v1`（Ollama）、`https://generativelanguage.googleapis.com/v1beta/openai/`（Gemini OpenAI 兼容层）
- **API Key** — 本地保存在 `~/Library/Preferences/dev.local.atst.plist`
- **翻译模型** — 划词翻译用的模型名（如 `gpt-4o-mini`、`qwen2.5:7b`）
- **截图模型** — Vision OCR 关闭时用的视觉模型（如 `gpt-4o`、`claude-3.5-sonnet`）
- **音标** — 给单词查询追加 IPA
- **智能注释** — 添加词典风格的释义块（习语、专有名词定义等）
- **翻译提示词** — 系统提示词和智能注释提示词完全可编辑

#### 截图 OCR 设置

通用页 **截图** 区域控制 `⌥S` 的行为：

- ☑️ **使用 Vision OCR**（默认开启）— 用 macOS Vision 在本地识别文字（**完全不需要 AI**），再交给翻译 provider
- ☐ 关闭 **Vision OCR** — 直接把截图发给 AI 视觉模型

下方的 chip 行可以增删识别语言。默认：简体中文 + 英文 + 日文。

---

## 功能

### 翻译 provider 对比

| Provider | 需要 key | 免费 | 流式 | 多义 | 音标 | 智能解释 |
|---|---|---|---|---|---|---|
| Google（内置） | ❌ | ✅ | — | ❌ | ❌ | ❌ |
| Microsoft（内置） | ❌ | ✅ | — | ❌ | ❌ | ❌ |
| OpenAI 兼容 | ✅ | 看接口 | ✅ | ✅ | ✅ | ✅ |

### 其他细节

- **智能浮窗定位** — Web 风格的 flip 算法；浮窗永远不会被推到屏幕外，也不会盖住你选中的内容
- **自适应玻璃表面** — macOS 26+ 与 Swift 6.2+ 构建下使用原生 Liquid Glass；更早的 macOS 继续使用 AppKit `NSVisualEffectView` toolTip 材质
- **缓存统计** — 显示缓存条目数和占用磁盘大小，一键清空
- **无法翻译识别** — 专有名词 / 品牌名 / 拼写错误会标识 🔘 并跳过缓存
- **外观** — 自动 / 浅色 / 深色，全局生效

---

## 系统要求

- macOS **13.0**（Ventura）及以上
- 本地缓存占用几 MB 磁盘
- AI 功能：任何 OpenAI 兼容接口（付费或本地 LLM 均可）

---

## 隐私

- atst 是 **纯本地应用**。无遥测、无埋点、无崩溃上报。
- 翻译时只有你触发的那段文字会发送给你启用的 API provider（Google / Microsoft / 你的 AI 接口）。
- 缓存保存在 `~/Library/Caches/dev.local.atst/translations.json`，设置保存在 `~/Library/Preferences/dev.local.atst.plist`，随时可删除。

---

## 后续计划

考虑中的功能（欢迎开 issue 投票）：

- [ ] 自定义 HTTP 翻译 provider（模板驱动，自己接 DeepL / Lingva / Libretranslate）
- [ ] API provider 拖拽排序
- [ ] 翻译历史 + 全文检索
- [ ] AI 流式逐 token 渲染
- [ ] Apple 公证 + 正规代码签名（不用再右键 → 打开）

---

## License

Apache 2.0 — 详见 [LICENSE](./LICENSE)。

## 致谢

- macOS [Vision framework](https://developer.apple.com/documentation/vision) 提供 OCR 能力
- OpenAI Chat Completions 协议 —— 几乎所有现代 LLM 接口都兼容
- 与作者协作使用 [Claude Code](https://claude.com/claude-code) 完成
