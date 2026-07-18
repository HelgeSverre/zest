import PackagePlugin

@main
struct EmbedHighlightQueriesPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let tool = try context.tool(named: "EmbedHighlightQueriesTool")
    let packageDirectory = context.package.directory
    let inputs = [
      packageDirectory.appending("Vendor/HighlightQueries/json-highlights.scm"),
      packageDirectory.appending("Vendor/HighlightQueries/markdown-highlights.scm"),
      packageDirectory.appending("Vendor/HighlightQueries/markdown-inline-highlights.scm"),
      packageDirectory.appending("Vendor/TreeSitterSema/queries/highlights.scm"),
    ]
    let output = context.pluginWorkDirectory.appending("EmbeddedHighlightQueries.generated.swift")

    return [
      .buildCommand(
        displayName: "Embedding tree-sitter highlight queries",
        executable: tool.path,
        arguments: [output.string] + inputs.map(\.string),
        inputFiles: inputs,
        outputFiles: [output]
      )
    ]
  }
}
