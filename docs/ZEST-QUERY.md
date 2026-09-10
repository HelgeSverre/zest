# zest-query: indexed file discovery for humans and coding agents

`zest-query` searches Zest's existing local file index using the same search engine
as the app. It reads the index, not the contents of the matching files, and does
not recursively walk the search root or start a daemon. Use it to find likely
files quickly, then read those files or search their contents with `rg`.

## Installation and prerequisites

```sh
brew install --cask helgesverre/tap/zest
zest-query --help
```

The cask links the bundled query executable into Homebrew's bin directory. With
the PKG installed directly, invoke:

```sh
"/Applications/Zest.app/Contents/Helpers/zest-query" --help
```

For development, `just query-build` produces `./zig-out/bin/zest-query`.
Open Zest and finish **Index > Set Up Indexer**, or build a development index with
`just index`, before querying. The default index is
`~/Library/Application Support/zest/index.zst`. `--index PATH` selects another
index; this does not create or refresh it.

## Useful discovery commands

```sh
# Find filenames containing "coordinator" anywhere under this repository.
zest-query 'coordinator kind:file' --scope "$(pwd -P)" --depth all --sort name --asc

# Find Swift files under a known project root.
zest-query 'ext:swift kind:file' --scope "$HOME/code/zest" --depth all --limit 200

# Find package manifests across the indexed home directory.
zest-query 'Package.swift kind:file' --depth all --sort name --asc

# Find recently modified files in this repository.
zest-query 'date:week kind:file' --scope "$(pwd -P)" --depth all --sort mtime --desc

# List immediate children, largest first (the default depth and sort).
zest-query --scope "$(pwd -P)"

# Machine-oriented sizes and no header; paths are still raw TSV fields.
zest-query 'ext:zig kind:file' --scope "$(pwd -P)" --depth all --bytes --no-header
```

Pass the query as one quoted argument. Plain text is a case-insensitive filename
substring, not a glob, regular expression, or content search. Qualifiers include
`kind:file`, `kind:folder`, `ext:swift`, `size:>100mb`, `date:week`, `cat:code`, and
`path:src`. Prefer `--scope` for an explicit search boundary. Unknown or malformed
qualifiers may be treated as literal search text rather than rejected.

## Defaults that matter

| Option | Default | Meaning |
| --- | --- | --- |
| `--scope PATH` | `$HOME` | Absolute indexed root; use a canonical path such as `pwd -P` |
| `--depth N\|all` | `1` | Direct children only; use `all` for recursive discovery |
| `--limit N` | `50` | Maximum rows printed |
| `--scan-limit N` | `100000` | Maximum matching rows collected **before sorting** |
| `--sort COLUMN` | `size` | `name`, `size`, `mtime`/`date`, or `type`/`category` |
| `--asc` / `--desc` | descending | Sort direction |
| `--bytes` | off | Exact indexed byte counts instead of human-readable sizes |
| `--no-header` | off | Suppress the first TSV line |

`--limit` must not exceed `--scan-limit`. If matching entries exceed the scan
limit, sorting covers only the collected subset: this is not a guaranteed global
top-N query. Scope narrowly and increase the limits when completeness matters.
The CLI does not print a separate truncation warning.

## Output and exit status

Standard output is tab-separated, with this header unless suppressed:

```text
SIZE\tMTIME\tKIND\tPATH
```

The separators are actual tabs. `MTIME` is a Unix timestamp in seconds; `KIND` is
`file`, `directory`, or `symlink`; `PATH` is the indexed full path. Sizes are
indexed filesystem sizes, not a fresh `stat` result. Directories carry recursive
indexed totals. `--bytes` changes formatting, not the meaning of the size.

Paths are **not escaped**. Filenames containing tabs or newlines make TSV
ambiguous. There is no JSON or NUL-delimited mode yet; do not blindly pipe this
output into shell commands or destructive bulk operations. Quote paths when
opening individual results and verify their current existence first.

Success, including zero results, exits 0. Invalid command-line arguments exit 2;
an unreadable, missing, or invalid index exits 1. Diagnostics and `--help` go to
standard error, leaving query rows on standard output.

## Suggested coding-agent instructions

> Use `zest-query` for fast filename discovery when a Zest index is available.
> Scope to the repository's canonical absolute path and pass `--depth all`.
> Treat results as candidates: verify files before reading or editing them.
> Use `rg` for content searches and `rg --files` when live repository coverage is
> required. Do not treat no results as proof that a file does not exist. Do not
> start a full re-index or change privacy permissions without the user's request.

The index may lag recent changes. Ignored directories and locations the indexer
cannot access are absent; Full Disk Access does not override Zest's exclusions.
The query CLI cannot currently report index freshness or completeness. On a
missing index, stale result, or unexpected empty result, fall back to live,
scoped filesystem tools rather than silently claiming the file is absent.
