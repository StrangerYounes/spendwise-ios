#if DEBUG
import Foundation
import SpendWiseCore

/// Debug builds only: plays a role against the Firebase emulators on CI and writes what happened to
/// Documents/test-report.json (scripts/backend-test.sh reads it). `-SpendWiseTest <role>`.
@MainActor
enum TestDriver {
    static var role: String? { UserDefaults.standard.string(forKey: "SpendWiseTest") }
    static var isOn: Bool { role != nil }

    /// The test's own database: kept between roles on one phone, emptied with -SpendWiseFresh YES.
    static func databasePath() -> String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("test.sqlite")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if UserDefaults.standard.bool(forKey: "SpendWiseFresh") {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            // What the phone knew of an account goes with its data
            for key in ["sync.joined_account", "onboarding.step"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        return url.path
    }

    static func run(_ model: AppModel, _ router: Router) {
        guard let role else { return }
        Task { await BackendTest.run(role, model) }
    }
}
#endif
