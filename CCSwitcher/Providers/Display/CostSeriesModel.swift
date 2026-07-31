import Foundation

struct DailyCostEntry: Identifiable {
    /// "yyyy-MM-dd".
    let date: String
    let cost: Double
    let modelBreakdown: [String: Double]
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    var id: String { date }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }
}

struct CostSeriesModel {
    let todayCost: Double
    let daily: [DailyCostEntry]

    var totalCost: Double { daily.reduce(0) { $0 + $1.cost } }

    static let empty = CostSeriesModel(todayCost: 0, daily: [])
}
