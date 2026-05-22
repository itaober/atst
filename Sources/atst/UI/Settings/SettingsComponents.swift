import SwiftUI

/// Reusable rounded-card container used by every section on the settings
/// page. Centralises the background fill / border / spacing so individual
/// sections only deal with their own row content.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}

/// Two-line toggle row used for feature switches (audio playback, smart
/// explanation, etc).
struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var onChange: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .onChange(of: isOn) { _ in
                    onChange()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Tappable row that drills into a sub-page (e.g. the prompts editor).
struct SettingsNavRow: View {
    let title: String
    let subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Permission status row (Accessibility / Screen Recording). Shows a
/// coloured dot + free-form requirement label and exposes a refresh and
/// open-system-settings button.
struct SettingsPermissionRow: View {
    let title: String
    let requirement: String
    let granted: Bool
    var refresh: () -> Void
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(granted ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(L.pick(
                        "\(requirement) · \(granted ? "Granted" : "Not granted")",
                        "\(requirement) · \(granted ? "已授权" : "未授权")"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L.pick("Refresh permission status", "刷新权限状态"))

            Button(action: openSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L.pick("Open System Settings", "打开系统设置"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// Labelled text field with the secondary-coloured caption layout used
/// throughout the settings panel.
struct SettingsTextRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: text) { _ in onChange() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// SecureField variant of `SettingsTextRow`.
struct SettingsSecureRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: text) { _ in onChange() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
