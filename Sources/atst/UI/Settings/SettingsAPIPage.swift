import SwiftUI

/// "API translation" subpage. Lists the built-in providers (Google,
/// Microsoft) as toggle rows, with a placeholder for the future "+
/// Custom provider" v2 feature. Re-ordering is per-row only for now — users
/// can disable a provider but the visual order in the tooltip mirrors the
/// list order here.
struct SettingsAPIPage: View {
    @Binding var draft: AppConfiguration
    var save: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusSection
                providersSection
                customSection
                noticeSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 500)
    }

    private var statusSection: some View {
        SettingsSection(title: L.pick("Status", "状态")) {
            SettingsToggleRow(
                title: L.pick("Enable API translation", "启用 API 翻译"),
                subtitle: L.pick(
                    "Run enabled providers in parallel and show their results above the AI section.",
                    "并行调用启用的 provider，结果显示在 AI 段上方。"
                ),
                isOn: $draft.apiEnabled,
                onChange: save
            )
        }
    }

    private var providersSection: some View {
        SettingsSection(title: L.pick("Built-in providers", "内置 provider")) {
            ForEach(Array(draft.apiProviders.enumerated()), id: \.element.id) { index, entry in
                providerRow(index: index, entry: entry)
                if index < draft.apiProviders.count - 1 {
                    Divider().padding(.horizontal, 10)
                }
            }
        }
    }

    private func providerRow(index: Int, entry: APIProviderEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: entry))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle(for: entry))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            // Up / Down buttons reorder the array directly. The tooltip
            // renders providers in this exact order, so moving Microsoft
            // above Google here flips the same vertical order in the
            // live result panel. Disabled at the array ends so users
            // don't see them flash as no-ops.
            reorderControls(index: index)
            Toggle("", isOn: Binding(
                get: { draft.apiProviders[index].enabled },
                set: { newValue in
                    draft.apiProviders[index].enabled = newValue
                    save()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!draft.apiEnabled)
            .opacity(draft.apiEnabled ? 1 : 0.4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func reorderControls(index: Int) -> some View {
        HStack(spacing: 0) {
            Button {
                moveProvider(from: index, to: index - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .disabled(index == 0 || !draft.apiEnabled)
            .help(L.pick("Move up", "上移"))

            Button {
                moveProvider(from: index, to: index + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .disabled(index == draft.apiProviders.count - 1 || !draft.apiEnabled)
            .help(L.pick("Move down", "下移"))
        }
        .opacity(draft.apiEnabled ? 1 : 0.4)
    }

    private func moveProvider(from source: Int, to dest: Int) {
        guard source >= 0, source < draft.apiProviders.count,
              dest >= 0, dest < draft.apiProviders.count else { return }
        let item = draft.apiProviders.remove(at: source)
        draft.apiProviders.insert(item, at: dest)
        save()
    }

    private func displayName(for entry: APIProviderEntry) -> String {
        switch entry.kind {
        case .google: return "Google"
        case .microsoft: return "Microsoft"
        case .ai, .none: return entry.id
        }
    }

    private func subtitle(for entry: APIProviderEntry) -> String {
        switch entry.kind {
        case .google:
            return L.pick(
                "Unofficial public endpoint · fast, no key",
                "非官方公开接口 · 速度快，无需 Key"
            )
        case .microsoft:
            return L.pick(
                "Unofficial Edge endpoint · auto JWT auth",
                "非官方 Edge 接口 · 自动鉴权"
            )
        case .ai, .none:
            return ""
        }
    }

    private var customSection: some View {
        SettingsSection(title: L.pick("Custom providers (coming soon)", "自定义 provider（即将支持）")) {
            HStack(spacing: 10) {
                Image(systemName: "plus.app")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.pick("Add custom HTTP provider", "添加自定义 HTTP provider"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L.pick(
                        "Bring your own DeepL / Lingva / Libretranslate (v2)",
                        "v2 支持自填 DeepL / Lingva / Libretranslate"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .opacity(0.55)
        }
    }

    private var noticeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(L.pick("About these endpoints", "关于这些接口"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(L.pick(
                "Both Google and Microsoft adapters use unofficial public endpoints. They may be rate-limited or blocked at any time. Your selection text is sent to the respective service.",
                "Google 与 Microsoft 都使用非官方公开接口，随时可能限流或不可用。选区文本会被发送到对应服务方。"
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}
