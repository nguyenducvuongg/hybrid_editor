import Combine
import Sparkle

/// Software updates through Sparkle, the same as Compositor's: the feed is appcast.xml on main (SUFeedURL in
/// Info.plist), each update is signed with the key whose public half is SUPublicEDKey, and an update found is
/// offered in UpdateDriver's alert with what's new listed under it. scripts/release.sh and publish.sh make them.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    /// False while a check is already running.
    @Published private(set) var canCheck = false
    private let driver = UpdateDriver()
    private let delegate = UpdaterDelegate()
    private var updater: SPUUpdater?

    /// Test and helper launches (`--open`, `--magic-local`, …) never check: an update alert would stop them.
    private var active: Bool { !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") } }

    /// Started a moment after launch, so a first-run prompt never holds up the editor window.
    func start() {
        guard active, updater == nil else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        driver.updater = u
        do { try u.start() } catch { NSLog("Sparkle didn't start: \(error)"); return }
        updater = u
        u.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        #if DEBUG
        // Trying an update against a local feed: check straight away.
        if UserDefaults.standard.string(forKey: "UpdateFeedURL") != nil { u.checkForUpdates() }
        #endif
    }

    func check() { updater?.checkForUpdates() }

    var automatic: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }
    var running: Bool { updater != nil }
}
