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

The cask links three bundled executables into Homebrew's bin directory:

| Command | Purpose |
| --- | --- |
| `zest` | Launch the native app (it remains attached to the terminal; `zest &` backgrounds it) |
| `zest-query` | Read-only indexed file discovery |
| `zest-indexer` | Low-level scanner and foreground daemon |

There is no `zest-index` alias. Use the app's **Index** menu to manage the installed
background service. The indexer's `install`, `start`, `stop`, `restart`, and
`status` commands concern the separate legacy development service, not the app's
SMAppService registration. Running `zest-indexer` without arguments starts a
foreground daemon; do not run it alongside the app-managed daemon.

For an isolated one-shot scan (without replacing your normal index):

```sh
fixture="$(mktemp -d)"
HOME="$fixture" zest-indexer --full-scan "$(pwd -P)"
HOME="$fixture" zest-query --scope "$(pwd -P)" --depth all
```

The temporary index remains under `$fixture` until you remove it. Every bundled
command accepts `--help` and `--version`; run `zest-indexer --help` for its
commands (0.1.1 shipped without it; use the documented `--full-scan PATH` form there).

If you installed the earlier query-only cask, run `brew update` followed by
`brew reinstall --cask helgesverre/tap/zest` to add the other commands. Disable
background indexing before reinstalling.

A direct PKG installation is not tracked by Homebrew and does not create terminal
links. To switch to Homebrew, use `brew install --cask helgesverre/tap/zest`, not
`brew upgrade`. For an existing Homebrew installation, use `brew update` then
`brew upgrade --cask zest`. Disable indexing and quit Zest before either operation;
the index and preferences are retained.

With the PKG installed directly, invoke:

```sh
"/Applications/Zest.app/Contents/Helpers/zest-query" --help
```

Since 0.1.1, `zest --indexer-status` checks the **packaged** background service
without launching the GUI or starting a scan. With a direct PKG install, use
`/Applications/Zest.app/Contents/MacOS/Zest --indexer-status`. This reports service
state, not index freshness or scan coverage; `zest-indexer status` still refers
only to the separate development daemon.

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
| `-h`, `--help` | | Print usage and exit 0 |
| `-V`, `--version` | | Print `zest-query X.Y.Z (build N)` and exit 0 |
| `-- QUERY` | | Treat the next argument as search text even if it starts with `-` (`zest-query -- -h`) |

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
