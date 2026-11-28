# Tasks — Phase D (`v2.0`): Release Packaging, GitHub CI/CD & Community Ecosystem (`011-v20-release-ecosystem`)

**Status:** ✅ Complete & Verified (`53/53` checks across all 8 suites + `.dmg` packaging verified on Apple M4 Pro)

## Checklist

- [x] **D1.1 Community Catalog Store (`ExploreCatalog.swift`):** Implemented `ExploreCatalogStore` with embedded offline entries, Vietnamese accented/unaccented search (`BRollFTSIndex.normalizeVietnamese`), HTTPS feed refresh with loopback test flag, and atomic persistence in `HybridStorage.subdir("Catalog")/community_catalog.json`.
- [x] **D1.2 Community Catalog JSON & Tier B Sample Bundle (`assets/catalog/community_catalog.json`, `assets/plugins/vietnamese-cinematic-pack/`):** Published 6 curated entries and a complete Tier B plugin bundle containing `plugin.json`, `luts/saigon_golden_hour.cube`, and `workflows/saigon_street_flux.json`.
- [x] **D1.3 `Settings > Explore` UI & `browse_catalog` MCP Tool (`ExtensionsSettingsView.swift`, `SettingsView.swift`, `MCPTools+Hybrid.swift`):** Added `ExploreCatalogView` tab with search, `All | Skills | Plugins` filter, **Refresh**, 1-click **Install** (`SkillRegistry` / `PluginHost`), plus `browse_catalog` read-only MCP tool (`66` tools total, `44,215` bytes).
- [x] **D2.1 Sparkle Config & Version `2.0.0` (`Info.plist`, `project.pbxproj`, `appcast.xml`, `publish.sh`):** Updated `SUFeedURL` & `REPO` to `nguyenducvuongg/hybrid_editor` and bumped `MARKETING_VERSION = 2.0.0`, `CURRENT_PROJECT_VERSION = 20`.
- [x] **D2.2 DMG Packaging & GitHub Actions CI/CD (`scripts/package-dmg.sh`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`):** Added compressed `UDZO` `.dmg` builder + SHA-256 + `hdiutil verify` + optional Sparkle `sign_update` + `macos-15` CI running all 8 suites and tag/dispatch Release workflow.
- [x] **D3 Verification (`EcosystemV20Test.swift` `--ecosystem-v20-test` + `package-dmg.sh`):** Verified `5/5` (`D1–D5`), all `7` regression suites (`53/53` total), and real `Editroom-2.0.0.dmg` creation (`hdiutil verify` VALID).
