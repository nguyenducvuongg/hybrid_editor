import SwiftUI

enum StockMediaKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case photos = "Photos"
    case videos = "Videos"

    var id: String { rawValue }
}

/// Quick Stock browser hosted inside `LibraryView`, connected to `StockMediaManager.shared`.
struct StockLibraryView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var stock = StockMediaManager.shared
    @ObservedObject private var themes = ThemeStore.shared
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var kind: StockMediaKind = .videos
    @State private var searching = false
    @State private var importingId: String?
    @State private var errorMessage: String?
    @State private var statusBanner: String?

    private var hasPexelsKey: Bool {
        !((try? AppSecrets.shared.get(.pexelsAPIKey)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPixabayKey: Bool {
        !((try? AppSecrets.shared.get(.pixabayAPIKey)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var anyConfigured: Bool { hasPexelsKey || hasPixabayKey || stock.customProvidersForTests != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                providerPill("Pexels", active: hasPexelsKey)
                providerPill("Pixabay", active: hasPixabayKey)
                Spacer()
                Picker("", selection: $kind) {
                    ForEach(StockMediaKind.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                TextField("Search stock media…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .onSubmit { runSearch() }
                if searching {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xE5735C))
                    .lineLimit(2)
            } else if let statusBanner {
                Text(statusBanner)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x39B54A))
                    .lineLimit(1)
            }

            if !anyConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect Free Stock APIs")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Add a Pexels or Pixabay API key in Settings > Integrations to search HD/4K stock footage and import directly into your project.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Open Integrations", prominent: true) {
                        UserDefaults.standard.set("integrations", forKey: "settingsTab")
                        openSettings()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
            } else if stock.lastResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Press Return to search Pexels & Pixabay.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        PillButton(title: "Search", prominent: true) { runSearch() }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(stock.lastResults) { item in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Text("\(item.provider) · \(item.width)x\(item.height)\(item.durationSeconds.map { String(format: " · %.1fs", $0) } ?? "")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textFaint)
                                }
                                Spacer()
                                if importingId == item.id {
                                    ProgressView().controlSize(.small).scaleEffect(0.65)
                                } else {
                                    PillButton(title: "Import", prominent: false) { importItem(item) }
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .id(themes.look)
    }

    private func providerPill(_ name: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color(hex: 0x39B54A) : Theme.textFaint)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(active ? Theme.text : Theme.textFaint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !searching else { return }
        searching = true
        errorMessage = nil
        statusBanner = nil
        let targetKind = kind
        Task {
            do {
                let items = try await stock.search(query: q, kind: targetKind)
                if items.isEmpty { errorMessage = "No matching stock media found." }
            } catch {
                errorMessage = error.localizedDescription
            }
            searching = false
        }
    }

    private func importItem(_ item: StockSearchItem) {
        importingId = item.id
        errorMessage = nil
        statusBanner = nil
        let folder = model.fileURL?.deletingLastPathComponent().appendingPathComponent("Stock Media", isDirectory: true)
            ?? HybridStorage.subdir("Stock Media")
        Task {
            do {
                let url = try await stock.downloadAndVerify(item, into: folder)
                model.importFiles([url], offerMatch: false) { _ in }
                statusBanner = "Imported \(url.lastPathComponent)"
            } catch {
                errorMessage = error.localizedDescription
            }
            importingId = nil
        }
    }
}
