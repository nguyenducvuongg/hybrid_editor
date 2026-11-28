# Tasks: Milestone 3-E (`004-native-hybrid-ui`)

- [x] **U001** Create Spec Kit `specs/004-native-hybrid-ui/` (`spec.md`, `plan.md`, `tasks.md`)
- [x] **U002** Create `editroom/Editroom/Extensions/IntegrationPrefs.swift` (`ComfyConnectionPrefs`, `ChatProviderPrefs`, endpoint connection test) & extend `PanelLayout` in `Workspace.swift`
- [x] **U003** Expose `SettingsView` shared section/row helpers and add `Skills`, `Plugins`, `Integrations` tabs
- [x] **U004** Create `editroom/Editroom/UI/ExtensionsSettingsView.swift` (`SkillsSettingsView`, `PluginsSettingsView`, `IntegrationsSettingsView`)
- [x] **U005** Create `editroom/Editroom/UI/AgentChatPanel.swift` (multi-turn chat sidebar, `/skill` chips, `@mention` shortcuts, `AgentTurn` card with 1-click Undo)
- [x] **U006** Create `editroom/Editroom/UI/StockLibraryView.swift` & wire sidebar/toolbar/library/menu hooks in `ContentView.swift`, `LibraryView.swift`, `EditroomApp.swift`
- [x] **U007** Add `E7` SwiftUI `NSHostingView` smoke test & prefs round-trip to `ExtensionsTest.swift`; pass `--extensions-test` (7/7) and `--hybrid-test` (7/7)
- [x] **U008** Update `PROJECT.md`, refresh `graphify update .`, and commit locally on `feat/editroom-core`
