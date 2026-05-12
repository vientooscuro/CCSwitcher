import Foundation
import SwiftUI

/// Auto-update is disabled in this fork until we publish our own appcast.xml
/// signed with an EdDSA key we own (see project.yml SUPublicEDKey/SUFeedURL).
/// Sparkle stays linked so we can re-enable without source surgery; this
/// stub just never instantiates `SPUStandardUpdaterController`, so no
/// background checks are scheduled and no network traffic happens.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var isChecking = false

    init() {}

    /// No-op. Kept for source compatibility with the Settings UI.
    func checkForUpdates(manual: Bool = false) {}
}
