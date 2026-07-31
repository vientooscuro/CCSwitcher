import SwiftUI

/// Settings tab showing the resolved Codex CLI binary path, version and login status.
///
/// Read-only by design. `CodexCLIService.login()`/`logout()` exist for Stage 3's
/// account-switching work, but this machine has exactly one ChatGPT account, so a
/// Sign in/Sign out button here — one stray click while browsing settings — would
/// force a fresh browser re-auth with no stored fallback. Omitted deliberately.
struct CodexCLITabView: View {
    @AppStorage(CodexCLIService.binaryPathPreferenceKey) private var preference: String = ""

    @State private var customInput: String = ""
    @State private var customError: String? = nil
    @State private var resolvedPath: String? = nil
    @State private var installedVersion: String? = nil
    @State private var loginStatusText: String? = nil
    @State private var isLoading: Bool = false

    var body: some View {
        Form {
            Section(String(localized: "Binary path", bundle: L10n.bundle)) {
                TextField(
                    String(localized: "/absolute/path/to/codex (leave empty for auto-detect)", bundle: L10n.bundle),
                    text: $customInput
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitCustomPath() }

                if let customError {
                    Label(customError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !preference.isEmpty {
                    Button(String(localized: "Reset to auto-detect", bundle: L10n.bundle)) {
                        applyPreference("")
                    }
                    .font(.caption)
                }

                HStack(spacing: 6) {
                    if let resolvedPath {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "Currently using: \(resolvedPath)", bundle: L10n.bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(String(localized: "codex CLI not found", bundle: L10n.bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(String(localized: "Version", bundle: L10n.bundle)) {
                HStack {
                    Text(String(localized: "Installed", bundle: L10n.bundle))
                    Spacer()
                    Text(installedVersion ?? placeholder)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section(String(localized: "Login status", bundle: L10n.bundle)) {
                Text(loginStatusText ?? placeholder)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label(
                        isLoading
                            ? String(localized: "Refreshing…", bundle: L10n.bundle)
                            : String(localized: "Refresh", bundle: L10n.bundle),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isLoading)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            customInput = preference
            await refreshAll()
        }
    }

    private var placeholder: String {
        isLoading ? String(localized: "Checking…", bundle: L10n.bundle) : "—"
    }

    // MARK: - Loaders

    private func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        async let path = CodexCLIService.shared.resolvedBinaryPath()
        async let status = CodexCLIService.shared.loginStatus()
        let resolved = await path
        resolvedPath = resolved
        loginStatusText = await status
        guard let resolved else {
            installedVersion = nil
            return
        }
        installedVersion = await CodexCLIService.readVersion(at: resolved)
    }

    // MARK: - Override handling

    private func commitCustomPath() {
        let trimmed = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customError = nil
            applyPreference("")
            return
        }
        guard trimmed.hasPrefix("/") else {
            customError = String(localized: "Path must be absolute (start with /).", bundle: L10n.bundle)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else {
            customError = String(localized: "Not found or not executable.", bundle: L10n.bundle)
            return
        }
        customError = nil
        applyPreference(trimmed)
    }

    private func applyPreference(_ newValue: String) {
        preference = newValue
        customInput = newValue
        Task { await refreshAll() }
    }
}
