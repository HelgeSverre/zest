/// Accessibility identifiers shared by the app views and the headless UI
/// tests (`Sources/ZestTests/UIHarness.swift`), which locate views by them.
enum A11y {
  static let search = "zest.search"
  static let browserTable = "zest.browser.table"
  static let sidebar = "zest.sidebar"
  static let breadcrumb = "zest.breadcrumb"
  static let statusCount = "zest.statusbar.count"
  static let statusSelection = "zest.statusbar.selection"
  static let preview = "zest.preview"
  static let toolbarBack = "zest.toolbar.back"
  static let toolbarForward = "zest.toolbar.forward"
  static let toolbarUp = "zest.toolbar.up"

  /// Scope chip in the filter bar: "folder", "subfolders", "everywhere".
  static func filterScope(_ scope: AppCoordinator.Scope) -> String {
    switch scope {
    case .folder: "zest.filter.scope.folder"
    case .subfolders: "zest.filter.scope.subfolders"
    case .everywhere: "zest.filter.scope.everywhere"
    }
  }

  /// Sidebar category row, keyed by `Category.queryKey` (e.g. "code").
  static func sidebarCategory(_ key: String) -> String { "zest.sidebar.cat.\(key)" }
}
