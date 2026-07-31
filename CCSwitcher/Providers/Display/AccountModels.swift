import Foundation

/// Identity block shown in the popover header for the active account.
struct AccountHeaderModel {
    let title: String
    let subtitle: String
    let planBadge: String?
}

/// One row on the Accounts tab.
struct AccountRowModel: Identifiable {
    let id: UUID
    let title: String
    let email: String
    let planBadge: String?
    let isActive: Bool
    let lastUsedText: String?
    /// False when switching to this account would fail for lack of stored
    /// credentials — the row shows a re-authenticate prompt instead.
    let hasStoredCredentials: Bool
    /// Seeds the inline rename field. Nil when no custom label is set.
    let rawLabel: String?
}
