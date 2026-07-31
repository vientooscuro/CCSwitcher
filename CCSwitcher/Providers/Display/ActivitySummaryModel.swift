import SwiftUI

struct ModelUsageEntry: Identifiable {
    let displayName: String
    let count: Int
    let tint: Color

    var id: String { displayName }
}

struct ActivitySummaryModel {
    let turns: Int
    /// Pre-formatted ("4h 38m") because providers compute it differently.
    let activeTimeText: String
    /// Nil when the provider cannot measure edited lines; the view hides the stat.
    let linesWritten: Int?
    let perModel: [ModelUsageEntry]

    static let empty = ActivitySummaryModel(turns: 0, activeTimeText: "0m", linesWritten: nil, perModel: [])
}
