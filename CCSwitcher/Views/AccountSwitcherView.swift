import SwiftUI

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var hub: ProviderHub
    @Environment(\.providerTheme) private var theme
    @State private var showingAddConfirm = false
    @State private var editingAccountId: UUID?
    @State private var editingLabel = ""

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if hub.surface.accountRows.isEmpty {
                        emptyState
                    } else {
                        ForEach(hub.surface.accountRows) { row in
                            accountRow(row)
                        }
                    }
                }
                .padding(16)
            }

            addAccountButtons
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .padding(.top, 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(theme.textSecondary)

            Text("No Accounts")
                .font(.headline)

            Text("Add your current Claude Code account to get started.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Account Row

    private func accountRow(_ row: AccountRowModel) -> some View {
        HStack(spacing: 12) {
            // Provider icon
            ProviderIcon(provider: hub.activeProvider, size: 22)
                .foregroundStyle(row.isActive ? theme.accent : .secondary)
                .frame(width: 32, height: 32)

            // Account info
            VStack(alignment: .leading, spacing: 2) {
                if editingAccountId == row.id {
                    HStack(spacing: 4) {
                        TextField("Custom label", text: $editingLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .onSubmit { commitLabelEdit(row) }

                        Button {
                            commitLabelEdit(row)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editingAccountId = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(.subheadline.weight(.medium))

                        if hub.surface.capabilities.managesAccounts {
                            Button {
                                editingLabel = row.rawLabel ?? ""
                                editingAccountId = row.id
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption2)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Edit label")
                        }

                        if row.isActive {
                            Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .green)
                        }
                    }
                }

                Text(row.email)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)

                HStack(spacing: 8) {
                    if let sub = row.planBadge {
                        Label(sub, systemImage: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Text(hub.activeProvider.rawValue)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }

            Spacer()

            // Actions
            if hub.surface.capabilities.canSwitchAccounts, !row.isActive {
                Button("Switch") {
                    Task { await hub.surface.switchTo(accountId: row.id) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(theme.accent)
                .disabled(!row.hasStoredCredentials)
            }

            if hub.surface.capabilities.canReauthenticate {
                Button {
                    Task { await hub.surface.reauthenticate(id: row.id) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Re-authenticate (fix stale token)")
            }

            if hub.surface.capabilities.managesAccounts {
                Button {
                    hub.surface.removeAccount(id: row.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove account")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(row.isActive ? theme.cardFillStrong : .clear)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
                .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
        )
    }

    private func commitLabelEdit(_ row: AccountRowModel) {
        hub.surface.setLabel(editingLabel, forAccount: row.id)
        editingAccountId = nil
    }

    // MARK: - Add Account Buttons

    @ViewBuilder
    private var addAccountButtons: some View {
        if hub.surface.isAuthenticating {
            // Logging in state
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser login...")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                Text("Complete the login in your browser, then return here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardFillStrong)
                    .strokeBorder(theme.cardBorder, lineWidth: 1)
                    .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
            )
        } else if showingAddConfirm {
            // Inline confirmation for "Add Current"
            VStack(spacing: 8) {
                Text("This will capture the currently logged-in Claude Code account.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        withAnimation { showingAddConfirm = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Add Account") {
                        showingAddConfirm = false
                        Task { await hub.surface.importCurrentAccount() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardFillStrong)
                    .strokeBorder(theme.cardBorder, lineWidth: 1)
                    .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
            )
        } else {
            VStack(spacing: 8) {
                // Primary: Login new account via browser
                if hub.surface.capabilities.canLoginNewAccount {
                    Button {
                        Task { await hub.surface.loginNewAccount() }
                    } label: {
                        Label("Login New Account", systemImage: "person.badge.plus")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(AppStyle.buttonTextColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                // Secondary: Capture already-logged-in account
                if hub.surface.capabilities.canImportCurrent {
                    Button {
                        withAnimation { showingAddConfirm = true }
                    } label: {
                        Label("Add Current Account", systemImage: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        colorScheme == .dark
                                            ? Color.gray.opacity(0.4)
                                            : Color.white.opacity(0.22),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
