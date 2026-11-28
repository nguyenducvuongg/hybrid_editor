import SwiftUI

enum StockMediaKind: String, CaseIterable, Identifiable {
    case photos = "Photos"
    case videos = "Videos"

    var id: String { rawValue }
}

/// Lightweight metadata item prepared for M4-E live Pexels/Pixabay providers.
struct StockMediaItem: Identifiable, Equatable {
    var id: String
    var provider: String
    var title: String
    var durationSeconds: Double?
    var width: Int
    var height: Int
    var previewURL: URL?
    var downloadURL: URL?
}

/// Quick Stock browser hosted inside `LibraryView` when switched to Stock mode.
struct StockLibraryView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var themes = ThemeStore.shared
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var kind: StockMediaKind = .videos
    @State private var results: [StockMediaItem] = []

    private var hasPexelsKey: Bool {
        !((try? AppSecrets.shared.get(.pexelsAPIKey)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPixabayKey: Bool {
        !((try? AppSecrets.shared.get(.pixabayAPIKey)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var anyConfigured: Bool { hasPexelsKey || hasPixabayKey }

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
                if !query.isEmpty {
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
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Ready to search \(kind.rawValue.lowercased()) via Pexels / Pixabay."
                         : "No local results yet for \"\(query)\" — live Pexels/Pixabay fetch lands in Milestone 4-E.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if !results.isEmpty {
                        ForEach(results) { item in
                            Text(item.title).font(.system(size: 12)).foregroundStyle(Theme.text)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
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
}
