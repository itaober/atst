# tst

轻量级 macOS 划词/截图翻译工具，面向开发者阅读英文技术文档场景。当前版本使用 Swift + SwiftUI + AppKit，无第三方依赖，AI 服务由用户在菜单栏弹层中自行配置。

## 产品效果

- `Option + D`：翻译当前选中文本，在选区/鼠标右侧弹出轻量浮窗。
- `Option + S`：调用 macOS 原生区域截图，截图完成后在结束位置右侧弹出轻量浮窗。
- 浮窗支持滚动、复制结果、关闭。
- 顶部菜单栏有一个 `tst` 图标，点击后直接配置目标语言、模型和 API。
- 应用以 menu bar app 方式运行，不常驻 Dock。

## 当前 AI 接入方式

当前实现的是 OpenAI-compatible Chat Completions：

- Base URL：例如 `http://localhost:11434/v1`、`https://api.example.com/v1`
- API Key：可为空，随本地配置保存
- 翻译模型：用于划词翻译
- 截图翻译模型：用于图片输入，必须是支持 vision/image input 的模型
- 系统提示词：用于控制翻译风格

自定义翻译 API 已在 Settings 中预留入口，但还没有实现。

## 目录结构

```text
.
├── Package.swift
├── README.md
├── Scripts
│   └── build-app.sh
└── Sources
    └── tst
        ├── App
        │   ├── AppConfiguration.swift
        │   ├── AppDelegate.swift
        │   ├── SettingsStore.swift
        │   └── TSTApp.swift
        ├── HotKey
        │   └── HotKeyManager.swift
        ├── Selection
        │   ├── ScreenshotProvider.swift
        │   └── SelectedTextProvider.swift
        ├── State
        │   └── TranslatorViewModel.swift
        ├── Support
        │   └── AppError.swift
        ├── Translation
        │   ├── OpenAICompatibleClient.swift
        │   └── TranslationService.swift
        └── UI
            ├── FloatingPanelController.swift
            ├── MenuBarSettingsView.swift
            ├── StatusBarController.swift
            └── TranslationResultView.swift
```

## 本地运行

```bash
cd /Users/t.yang/Workspace/itaober/tst
swift build
swift run tst
```

构建 `.app`：

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open .build/tst.app
```

首次使用：

1. 点击 macOS 顶部菜单栏里的 `tst` 图标
2. 填写目标语言、Base URL、API Key、翻译模型、截图翻译模型
3. 保存
4. 在系统设置中授予必要权限

## 权限

- 划词翻译需要 `辅助功能` 权限，用于读取当前选区和发送复制快捷键兜底。
- 截图翻译会调用 macOS 原生 `screencapture`，系统可能要求 `屏幕录制` 权限。

## 已知兼容性边界

划词取词采用两步：

1. Accessibility 读取 `AXSelectedText`。
2. 失败后临时发送 `Cmd + C`，读取剪贴板，再恢复原剪贴板内容。

因此以下场景可能不兼容或表现不稳定：

- 密码框、受保护输入框。
- 禁止复制内容的 PDF/网页/阅读器。
- 某些自绘控件、游戏、远程桌面、虚拟机窗口。
- 部分浏览器页面中的复杂 Web 编辑器。
- 当前应用拦截了 `Cmd + C`，或剪贴板被安全软件接管。

截图翻译依赖你配置的截图模型是否支持图片输入；如果模型不支持 vision，会返回 API 错误。

## 后续扩展预留

- OCR：可在 `Selection` 下新增 OCR provider。
- 历史记录：可新增 `Storage` 模块落本地 SQLite/JSON。
- 在线翻译 fallback：可在 `Translation` 下新增服务实现。
- 自定义翻译 API：Settings 已预留开关，后续可接非 OpenAI-compatible 协议。
