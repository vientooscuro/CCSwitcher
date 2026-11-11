import Foundation
import Sparkle
import SwiftUI

@MainActor
protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var onStateChange: (() -> Void)? { get set }
    func checkForUpdates()
}

@MainActor
private final class SparkleUpdateDriver: UpdateDriving {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var observations: [NSKeyValueObservation] = []
    var onStateChange: (() -> Void)?

    init() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.onStateChange?() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.onStateChange?() }
            }
        ]
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool
    @Published private(set) var automaticallyChecksForUpdates: Bool
    private let driver: UpdateDriving

    convenience init() {
        self.init(driver: SparkleUpdateDriver())
    }

    init(driver: UpdateDriving) {
        self.driver = driver
        canCheckForUpdates = driver.canCheckForUpdates
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
        driver.onStateChange = { [weak self] in self?.refreshState() }
    }

    func checkForUpdates() {
        guard driver.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        driver.automaticallyChecksForUpdates = enabled
        refreshState()
    }

    private func refreshState() {
        canCheckForUpdates = driver.canCheckForUpdates
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
    }
}
