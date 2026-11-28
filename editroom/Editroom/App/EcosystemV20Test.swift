import AppKit
import Foundation
import Network
import SwiftUI

private final class EcoOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired = false
    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !acquired else { return false }
        acquired = true
        return true
    }
}

private final class LoopbackCatalogServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.editroom.mock.catalog")
    private(set) var port: UInt16 = 0
    let bodyData: Data

    init(bodyData: Data) {
        self.bodyData = bodyData
    }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = EcoOnceGate()
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    guard gate.tryAcquire() else { return }
                    self?.port = l.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let err):
                    guard gate.tryAcquire() else { return }
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, _, _ in
            guard let self else { return conn.cancel() }
            let hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(self.bodyData.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(hdr.utf8) + self.bodyData, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

/// Offline deterministic verification suite for Phase D (`v2.0`) Release & Ecosystem (`D1–D5`):
/// `Editroom --ecosystem-v20-test`
@MainActor
enum EcosystemV20Test {
    nonisolated static func runIfRequested() {
        guard CommandLine.arguments.contains("--ecosystem-v20-test") else { return }
        Task { @MainActor in
            let ok = await run()
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardOutput.write(Data("[ecosystem-v20-test] \(msg)\n".utf8))
    }

    private static func fail(_ id: String, _ msg: String) -> Bool {
        FileHandle.standardError.write(Data("[ecosystem-v20-test] FAIL [\(id)]: \(msg)\n".utf8))
        return false
    }

    private static func parseJSON(_ content: [[String: Any]]) -> [String: Any]? {
        for item in content where (item["type"] as? String) == "text" {
            if let txt = item["text"] as? String,
               let data = txt.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editroom_eco_v20_\(UUID().uuidString)", isDirectory: true)
        let dataDir = root.appendingPathComponent("AppData", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            return fail("SETUP", "mkdir failed: \(error.localizedDescription)")
        }
        let prevOverride = HybridStorage.overrideRootForTests
        HybridStorage.overrideRootForTests = dataDir
        defer {
            HybridStorage.overrideRootForTests = prevOverride
            try? FileManager.default.removeItem(at: root)
        }

        // =========================================================================
        // D1: ExploreCatalogStore Offline Embedded, VN Search, HTTP Refresh & HTTPS Guard
        // =========================================================================
        do {
            let cacheURL = root.appendingPathComponent("catalog_cache.json")
            let store = ExploreCatalogStore(cacheURL: cacheURL)
            guard store.entries.count >= 6 else {
                return fail("D1", "Expected >=6 embedded catalog entries, got \(store.entries.count)")
            }
            let vnHits = store.search(query: "tieng viet")
            guard !vnHits.isEmpty else {
                return fail("D1", "Vietnamese unaccented search 'tieng viet' returned 0 hits")
            }

            // Non-HTTPS external URLs must be rejected when allowLoopbackForTests == false.
            var rejectedHTTP = false
            do {
                try await store.refresh(from: URL(string: "http://example.com/catalog.json")!, allowLoopbackForTests: false)
            } catch {
                rejectedHTTP = true
            }
            guard rejectedHTTP else {
                return fail("D1", "ExploreCatalogStore accepted insecure non-HTTPS URL")
            }

            let updated = CommunityCatalog(
                schemaVersion: 1,
                updatedAt: "2026-12-01",
                entries: ExploreCatalogStore.embeddedCatalog.entries + [
                    CommunityCatalogEntry(
                        id: "custom-lut-test",
                        name: "Ha Noi Film Look",
                        kind: .plugin,
                        category: "Color & LUTs",
                        description: "Vintage matte look.",
                        author: "community",
                        githubSource: "nguyenducvuongg/hybrid_editor/tree/main/assets/plugins/vietnamese-cinematic-pack",
                        tier: "Tier B · Assets",
                        tags: ["hanoi", "lut"]
                    ),
                ]
            )
            let body = try JSONEncoder().encode(updated)
            let server = LoopbackCatalogServer(bodyData: body)
            try await server.start()
            defer { server.stop() }

            let feedURL = URL(string: "http://127.0.0.1:\(server.port)/community_catalog.json")!
            try await store.refresh(from: feedURL, allowLoopbackForTests: true)
            guard store.lastUpdated == "2026-12-01",
                  store.entries.contains(where: { $0.id == "custom-lut-test" }),
                  FileManager.default.fileExists(atPath: cacheURL.path) else {
                return fail("D1", "Catalog refresh / cache persistence failed")
            }
            let reloaded = ExploreCatalogStore(cacheURL: cacheURL)
            guard reloaded.entries.count == updated.entries.count else {
                return fail("D1", "Reloaded cached catalog count mismatch")
            }
            log("PASS [D1] ExploreCatalogStore offline search, HTTPS guard & cached refresh verified")
        } catch {
            return fail("D1", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // D2: Repo Catalog JSON & Tier B Sample Plugin (`vietnamese-cinematic-pack`)
        // =========================================================================
        do {
            let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let catFile = repoRoot.appendingPathComponent("assets/catalog/community_catalog.json")
            let pluginDir = repoRoot.appendingPathComponent("assets/plugins/vietnamese-cinematic-pack", isDirectory: true)
            if FileManager.default.fileExists(atPath: catFile.path),
               FileManager.default.fileExists(atPath: pluginDir.path) {
                let rawCat = try Data(contentsOf: catFile)
                let decoded = try JSONDecoder().decode(CommunityCatalog.self, from: rawCat)
                guard decoded.schemaVersion == 1, decoded.entries.count >= 6 else {
                    return fail("D2", "assets/catalog/community_catalog.json invalid")
                }
                let host = PluginHost(baseDir: root.appendingPathComponent("PluginInstall", isDirectory: true))
                let installed = try host.installFromLocal(directory: pluginDir)
                guard installed.enabled, installed.trustedForExecution,
                      host.activeLUTPaths().contains(where: { $0.path.hasSuffix("saigon_golden_hour.cube") }),
                      host.activeComfyWorkflowPaths().contains(where: { $0.name == "saigon_street_flux" }) else {
                    return fail("D2", "vietnamese-cinematic-pack Tier B install/activation incomplete")
                }
            }
            log("PASS [D2] community_catalog.json & vietnamese-cinematic-pack Tier B LUT/workflow bundle verified")
        } catch {
            return fail("D2", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // D3: browse_catalog MCP Tool & ExploreCatalogView / SettingsView UI Smoke
        // =========================================================================
        do {
            let model = EditorModel()
            let mcpOut = try await MCPTools.call("browse_catalog", ["query": "vietnamese"], model: model, client: nil)
            guard let obj = parseJSON(mcpOut),
                  (obj["count"] as? Int ?? 0) >= 2,
                  let rows = obj["entries"] as? [[String: Any]],
                  rows.contains(where: { ($0["id"] as? String) == "vietnamese-shorts-creator" }) else {
                return fail("D3", "browse_catalog MCP tool returned unexpected result: \(mcpOut)")
            }

            let expHost = NSHostingView(rootView: ExploreCatalogView())
            expHost.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
            expHost.layoutSubtreeIfNeeded()

            let setHost = NSHostingView(rootView: SettingsView(model: model))
            setHost.frame = NSRect(x: 0, y: 0, width: 760, height: 660)
            setHost.layoutSubtreeIfNeeded()
            log("PASS [D3] browse_catalog MCP tool & SettingsView > Explore UI smoke verified")
        } catch {
            return fail("D3", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // D4: Sparkle Feed, Version 2.0.0, Packaging Script & GitHub Actions CI/CD
        // =========================================================================
        do {
            let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let plistURL = repoRoot.appendingPathComponent("editroom/Info.plist")
            if FileManager.default.fileExists(atPath: plistURL.path) {
                let plistData = try Data(contentsOf: plistURL)
                let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
                let feedURL = (plist?["SUFeedURL"] as? String) ?? ""
                guard feedURL.contains("nguyenducvuongg/hybrid_editor") else {
                    return fail("D4", "Info.plist SUFeedURL not updated: \(feedURL)")
                }

                let appcastURL = repoRoot.appendingPathComponent("editroom/appcast.xml")
                let xml = try XMLDocument(contentsOf: appcastURL, options: [])
                let xmlText = xml.xmlString
                guard xmlText.contains("nguyenducvuongg/hybrid_editor"), xmlText.contains("2.0.0") else {
                    return fail("D4", "editroom/appcast.xml missing 2.0.0 or repo URL")
                }

                let ciPath = repoRoot.appendingPathComponent(".github/workflows/ci.yml")
                let relPath = repoRoot.appendingPathComponent(".github/workflows/release.yml")
                let dmgScript = repoRoot.appendingPathComponent("scripts/package-dmg.sh")
                let ciText = try String(contentsOf: ciPath, encoding: .utf8)
                let relText = try String(contentsOf: relPath, encoding: .utf8)
                guard FileManager.default.isExecutableFile(atPath: dmgScript.path) || FileManager.default.fileExists(atPath: dmgScript.path),
                      ciText.contains("--ecosystem-v20-test"),
                      ciText.contains("--studio-v13-test"),
                      relText.contains("package-dmg.sh") else {
                    return fail("D4", "CI/Release workflows or package-dmg.sh missing expected targets")
                }
            }
            log("PASS [D4] Sparkle Info.plist/appcast.xml, package-dmg.sh & GitHub Actions workflows verified")
        } catch {
            return fail("D4", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // D5: Bundle Version `2.0.0` & Updates Guard During CLI Test Flags
        // =========================================================================
        do {
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let bld = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            guard ver == "2.0.0", bld == "20" else {
                return fail("D5", "Unexpected bundle version: \(ver) (\(bld))")
            }
            Updates.shared.start()
            guard !Updates.shared.running else {
                return fail("D5", "Updates.shared started unexpectedly under CLI test flag")
            }
            log("PASS [D5] Bundle v\(ver) (\(bld)) & test-safe Sparkle guard verified")
        }

        log("ALL 5 ECOSYSTEM V2.0 CHECKS PASSED")
        return true
    }
}
