# Embedded tree-sitter highlight queries

These files are hermetic inputs to `EmbedHighlightQueriesPlugin`. The plugin
generates Swift byte arrays that are compiled into the Zest executable; they
are not discovered or read from resource bundles at runtime.

| File | Upstream | Version | Revision |
| --- | --- | --- | --- |
| `json-highlights.scm` | `tree-sitter/tree-sitter-json` | 0.24.8 | `ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24` |
| `markdown-highlights.scm` | `tree-sitter-grammars/tree-sitter-markdown/tree-sitter-markdown` | 0.5.3 | `f969cd3ae3f9fbd4e43205431d0ae286014c05b5` |
| `markdown-inline-highlights.scm` | `tree-sitter-grammars/tree-sitter-markdown/tree-sitter-markdown-inline` | 0.5.3 | `f969cd3ae3f9fbd4e43205431d0ae286014c05b5` |

The Sema input remains at `Vendor/TreeSitterSema/queries/highlights.scm`, from
the existing vendored `tree-sitter-sema` snapshot at commit `be9019c`.

When a grammar dependency changes, update its query snapshot and provenance in
the same change. The copied upstream files remain covered by their respective
MIT licenses in this directory.
