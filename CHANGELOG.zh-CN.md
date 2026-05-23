# 更新日志

[English](./CHANGELOG.md)

所有显著变更都记录在这里，每个版本段落就是对应 GitHub release notes 的内容。

## Unreleased

（暂无变更）

## v0.2.1

- 设置面板在 macOS 26+ 且使用 Swift 6.2+ 构建时启用 Liquid Glass，跟 v0.2.0 引入的浮窗 / 固定便签风格保持一致；旧系统自动回退到原有 menu 材质
- 通用设置页右侧四个控件（目标语言、超时、界面语言、外观）全部对齐到同一条右边参考线——分段控件不再因为标签字数差异而错位
- 设置页标题旁新增版本号（`atst v0.2.1`），点击直达对应 release 页；并新增自动更新提示，发现新版本时显示橙色小药丸
- Google 翻译多行选区时保留换行和空行，列表 / 段落结构不会再被压平
- API 子页新增 ▲/▼ 按钮可以调整翻译来源顺序，tooltip 和结果面板都会按这个顺序渲染
- 通用页"翻译方式"分区把 API Translation 放到 AI Translation 之上，跟 tooltip 的布局保持一致
- 针对 macOS Secure Keyboard Entry 的坑加了诊断：当其他 App（例如 1Password）独占 secure input 时，设置页会显示橙色警告，避免再被误判为权限问题
- 一次系统性的代码清理：移除死代码、未使用的字段 / 参数、废弃方法以及孤儿 UI 文件；行为无变化

## v0.2.0

- 翻译浮窗和固定便签在 macOS 26+ 且使用 Swift 6.2+ 构建时会启用原生 Liquid Glass；旧系统会自动保留现有 AppKit toolTip 材质回退

## v0.1.3

- 通用设置布局统一：所有控件右边对齐到同一条参考线；目标语言下拉文字加大，跟左侧标签同级
- Tooltip 宽度自适应：短选区保持紧凑（320pt），长句或多行内容自动加宽到 480pt 更易读
- Tooltip 不再溢出屏幕：内置 ScrollView 按当前屏幕可用高度封顶，拖到剩余空间更大的位置时滚动条自动消失
- 缓存更挑剔：多行文本、超过 200 字符的句子、含 URL 的内容、以及空 / 仅标点的结果都不再缓存——把容量留给真正高频复用的词组
- App icon 源图改为满幅：源 PNG 直接控制完整 icon（背景 + 主体），不再被一层白色 squircle 套住后缩到 74%，消除"大白边里的小贴纸"问题

## v0.1.2

- 目标语言下拉换成原生 AppKit 弹出按钮（chevron 更清爽）
- 新增中英双语 `CHANGELOG.md` / `CHANGELOG.zh-CN.md`
- 新增 `Scripts/release.sh`：一条命令完成构建 + 打 tag + 发 GitHub release

## v0.1.1

- 界面语言可手动覆盖（自动 / English / 中文）；自动会跟随系统语言
- 目标语言改为预设下拉菜单
- 默认请求超时 60s → 10s
- README 解释了 `atst` 缩写（`a` AI · `t` text · `s` select · `t` translate）
- 强调极小体积（DMG 约 2 MB，安装后约 4 MB）
- Liquid Glass 浮窗写进 roadmap（在 macOS 26 + Xcode 26 / Swift 6.2 下会自动启用）

## v0.1.0

- 首个公开版本。
