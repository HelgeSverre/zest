# libzest-core C ABI reference

`libzest-core.a` is the Zest search engine behind a C ABI. Source of truth:
`src/capi/zest_core.zig` (exports), `Sources/CZestCore/include/zest_core.h`
(the header Swift imports). This document describes what the code does; where
the two disagree, the Zig wins.

## 1. Overview

**What it is.** Pure CPU over caller-owned bytes. The caller `mmap`s (or
otherwise loads) an index file and hands the bytes to `zest_open`; the library
borrows them until `zest_close`. Queries, histograms and extension breakdowns
are computed directly against the mapped columns.

**What it is not.**

- No I/O. The lib never opens, reads, or watches files. It has no Zig `Io`
  handle and no `main`. (The only libc call is `time()`, to anchor relative
  `date:` qualifiers at parse time.)
- No global state. Every handle (`Core`, `Query`, `CancelToken`) is heap
  allocated with the C allocator and owned by the caller.
- No sorting, no path display logic, no index building. Rows come back in
  index order; presentation is the caller's job.

**Build.**

```sh
zig build core -Doptimize=ReleaseFast     # -> zig-out/lib/libzest-core.a
```

Always leave `zig-out/lib/libzest-core.a` in ReleaseFast. A bare `zig build`
or `zig build test` installs a Debug archive at the same path, and a Debug
engine is ~19x slower (an 82-second one-character query on a full index). The
`justfile` recipes (`just build`, `just test`) rebuild the ReleaseFast archive
after every Zig step for this reason.

**Link.** `Package.swift` links the archive from the executable target:

```swift
linkerSettings: [.unsafeFlags(["-L\(zigLibDir)", "-lzest-core"]), .linkedLibrary("c")]
```

where `zigLibDir` is `$ZEST_CORE_LIB_DIR` or `zig-out/lib`. The header is
exposed as the Clang module `CZestCore` (`Sources/CZestCore/include/zest_core.h`;
`empty.c` exists only so SwiftPM treats the directory as a target). SwiftPM does
not track the archive as an input; the justfile `touch`es `empty.c` after each
Zig build so Swift relinks. From C or Zig, link the archive plus libc:

```sh
zig build-exe main.zig zig-out/lib/libzest-core.a -lc
```

**Thread safety.**

| Object | Rule |
| --- | --- |
| `Core` | Read-only after `zest_open` (category bitmaps are built eagerly in `IndexReader.init`). Concurrent `zest_query*`, `zest_histogram`, `zest_ext_breakdown`, `zest_count` on one `Core` from multiple threads are safe. `zest_close` must not run while any call on that `Core` is in flight. |
| `Query` | Owned by the thread that got it. Not synchronised; do not share between threads. |
| `CancelToken` | `zest_cancel_token_cancel` is an atomic store, safe from any thread, before/during/after the query. `create`/`destroy` are plain allocations; destroy only after the query call has returned. |
| Index bytes | Must stay mapped and unchanged for the `Core`'s lifetime. Remap a rebuilt index into a new `Core`; see section 7. |

## 2. Types

### `ZestStr`

```c
typedef struct { const uint8_t *ptr; size_t len; } ZestStr;
```

A byte slice. **Not NUL-terminated.** Points into the index mapping (see section 5).

### `ZestRow`

```c
typedef struct {
    ZestStr  name;      // basename, borrowed from the index
    ZestStr  dir_path;  // absolute parent directory, no trailing slash, borrowed
    uint64_t size;      // bytes; for directories the recursive subtree total (index v4+)
    int64_t  mtime;     // unix seconds
    uint8_t  kind;      // FileKind
    uint8_t  category;  // FileCategory
} ZestRow;
```

Swift imports this layout from the header directly (no hand-written mirror);
`bench_capi.zig` mirrors it as an `extern struct`. Trailing padding to 8 bytes
is standard C ABI. Full path = `dir_path + "/" + name`.

`kind` (`src/core/types.zig` `FileKind`):

| Code | Name |
| --- | --- |
| 0 | file |
| 1 | directory |
| 2 | symlink |

`category` (`FileCategory`, `count = 9`; also the index into `ZestHistogram.counts` and the `cat` argument of `zest_ext_breakdown`):

| Code | Name | Display name | `cat:` spellings accepted by the parser |
| --- | --- | --- | --- |
| 0 | uncategorized | Other | `other`, `uncategorized` |
| 1 | images | Images | `images`, `image` |
| 2 | text | Text | `text` |
| 3 | documents | Documents | `documents`, `docs`, `doc` |
| 4 | spreadsheets | Spreadsheets | `spreadsheets`, `sheets` |
| 5 | audio | Audio | `audio` |
| 6 | video | Video | `video` |
| 7 | code | Code | `code` |
| 8 | archives | Archives | `archives`, `archive` |

### Opaque handles

```c
typedef struct Core        Core;         // one opened index
typedef struct Query       Query;        // one result set
typedef struct CancelToken CancelToken;  // one atomic cancel flag
```

### `ZestHistogram`

```c
typedef struct { uint32_t counts[9]; } ZestHistogram;   // indexed by FileCategory
```

Returned by value.

### `ZestExtCount` / `ZestExtBreakdown`

```c
typedef struct { char name[16]; uint32_t count; } ZestExtCount;
typedef struct { ZestExtCount entries[32]; uint32_t len; } ZestExtBreakdown;
```

`name` is the extension without the leading dot, case-folded, NUL-padded to 16
bytes. The on-disk cap (`format.MAX_EXT_NAME_LEN`) is 15 bytes, so in practice
there is always at least one trailing NUL, but the contract is "use the row
count returned by the call, scan to the first NUL for the length". Longer
extensions are dropped from the index at build time and skipped by the reader.

`ZestExtBreakdown` is a convenience type only: no exported function takes or
returns it. `zest_ext_breakdown` writes into a caller array of `ZestExtCount`.
Bucket capacity is 32 (`format.MAX_EXTS_PER_BUCKET`), which is why `entries[32]`.

### Status codes

Written through `out_status` of `zest_query_cancellable`.

| Constant | Value | Meaning |
| --- | --- | --- |
| `ZEST_QUERY_OK` | 0 | A `Query` was returned. |
| `ZEST_QUERY_ERROR` | 1 | `NULL` returned: allocation failure, or the text part of the query exceeds 256 bytes (`error.QueryTooLong`). |
| `ZEST_QUERY_CANCELLED` | 2 | `NULL` returned: the token was cancelled before or during the scan. Drop the delivery. |

## 3. Functions

Complete export list (14 functions, verified against `export fn` in
`src/capi/zest_core.zig`): `zest_open`, `zest_close`, `zest_count`,
`zest_query`, `zest_query_cancellable`, `zest_query_count`, `zest_query_row`,
`zest_query_free`, `zest_cancel_token_create`, `zest_cancel_token_destroy`,
`zest_cancel_token_cancel`, `zest_histogram`, `zest_ext_breakdown`,
`zest_casefold_utf8`.

### `zest_open`

```c
Core *zest_open(const uint8_t *index_bytes, size_t len);
```

Opens an index from caller-owned bytes. Borrows `index_bytes[0..len]` until
`zest_close`; the caller must keep them mapped and unchanged.

Validation (`IndexReader.init` + `format.Header.deserialize`), any failure returns `NULL`:

1. `len >= 80` (`HEADER_SIZE`).
2. Magic `0x5A455354494E4458` little-endian (`"ZESTINDX"`).
3. Header version in `[MIN_READ_VERSION, VERSION]` = `[6, 7]`.
4. `num_entries * 18` bytes fit after `meta_offset` (guards against absurd counts and overflow).
5. Allocation of the `Core` succeeds.

Category bitmaps are read eagerly; if that fails the `Core` still opens and
`cat:` filters degrade to a full scan. Cost: header parse plus reading the
bitmap column.

```c
Core *core = zest_open(mapped, mapped_len);
if (!core) { /* not a Zest index, wrong version, or truncated */ }
```

### `zest_close`

```c
void zest_close(Core *core);
```

Frees the `Core` and its bitmaps. Does not touch the index bytes; unmap them
afterwards. Every `Query` from this `Core` must already be freed (its rows point
into the mapping, not the `Core`, but there is no reason to keep them).

### `zest_count`

```c
size_t zest_count(Core *core);
```

Total entries (files + directories + symlinks) from the header. O(1).

### `zest_query`

```c
Query *zest_query(Core *core, const char *query_utf8, const char *scope_root,
                  uint32_t max_depth, uint32_t max_results);
```

Equivalent to `zest_query_cancellable(core, query_utf8, scope_root, max_depth,
max_results, NULL, NULL)`. Returns `NULL` on error (no way to tell which).

| Parameter | Meaning |
| --- | --- |
| `query_utf8` | NUL-terminated query string, section 4. `""` is allowed. |
| `scope_root` | NUL-terminated absolute path; `""` and `"/"` both mean "everything indexed". |
| `max_depth` | `1` = direct children of `scope_root` (folder listing). Any other value = the whole subtree; use `UINT32_MAX`. |
| `max_results` | Hard cap; the scan stops at this many rows. `0` returns an empty result set. |

```c
Query *q = zest_query(core, "invoice ext:pdf", "/Users/me", UINT32_MAX, 100000);
```

### `zest_query_cancellable`

```c
Query *zest_query_cancellable(Core *core, const char *query_utf8, const char *scope_root,
                              uint32_t max_depth, uint32_t max_results,
                              CancelToken *token, uint32_t *out_status);
```

Same as `zest_query` plus cooperative cancellation. `token` and `out_status`
may both be `NULL`. `out_status` is always written when non-NULL, including on
success (`ZEST_QUERY_OK`).

Behaviour with a token:

- The flag is checked once on entry, before any fast path. An already-cancelled
  token therefore returns `NULL`/`ZEST_QUERY_CANCELLED` even for a query that
  would otherwise short-circuit (for example `""` at `"/"`).
- During a text scan the flag is polled every 64 KiB of the folded-name blob
  (`cancel_check_stride`); the SIMD scan is also chunked at that boundary.
- During a filter-only scan it is polled every 512 entries.
- On cancellation the partial result set is freed and `NULL` is returned.

Cost: text query = one pass over the folded-name blob (SIMD two-anchor filter,
`memcmp` on survivors, binary search to map a hit to an entry), stopping at
`max_results`. Filter-only query = one pass over the entry columns; depth-1
scopes compare the parent-id column against one resolved dir id, unlimited-depth
subtree scopes test one byte per entry after an O(D) mark pass over the dir
table (D = unique directories).

```c
CancelToken *t = zest_cancel_token_create();
uint32_t status;
Query *q = zest_query_cancellable(core, "inv", "/Users/me", UINT32_MAX, 2000, t, &status);
if (!q && status == ZEST_QUERY_CANCELLED) { /* superseded; ignore */ }
zest_cancel_token_destroy(t);   // only after the call has returned
```

### `zest_query_count`

```c
size_t zest_query_count(const Query *q);
```

Number of rows. O(1).

### `zest_query_row`

```c
ZestRow zest_query_row(const Query *q, size_t i);
```

Row `i` by value. Out-of-range `i` returns an all-zero row (`ptr == NULL`,
`len == 0`), not an error. The two `ZestStr` fields point into the index
mapping: valid until `zest_query_free(q)` **and** only while the bytes passed to
`zest_open` stay mapped. Copy before either happens. O(1).

### `zest_query_free`

```c
void zest_query_free(Query *q);
```

Frees the result array and the handle. Must be called exactly once per non-NULL
`Query`.

### `zest_cancel_token_create`

```c
CancelToken *zest_cancel_token_create(void);
```

Allocates a token with the flag clear. Returns `NULL` on allocation failure.
One token per in-flight query is the intended pattern; a token can be reused,
but once cancelled it stays cancelled and aborts every subsequent query it is
passed to.

### `zest_cancel_token_destroy`

```c
void zest_cancel_token_destroy(CancelToken *token);
```

Frees the token. The token must outlive the `zest_query_cancellable` call it
was passed to; the engine reads it during the scan.

### `zest_cancel_token_cancel`

```c
void zest_cancel_token_cancel(CancelToken *token);
```

Atomic release-store of 1. Safe from any thread; safe before, during, or after
the query. Never blocks, never allocates.

### `zest_histogram`

```c
ZestHistogram zest_histogram(Core *core, const char *scope_root, uint32_t max_depth);
```

Per-category entry counts for a scope, returned by value.

- `max_depth == 1`: counts of the direct children of `scope_root`. Resolves the
  directory with `findDirId` (a linear scan of the dir table, O(D)), then one
  O(1) read of the per-folder histogram block.
- Any other `max_depth`: sum over the subtree, O(D) over the dir table. `""`
  and `"/"` give the global histogram.
- A scope not present in the index returns all zeros.

Note: unlike `zest_query`, this function does **not** strip a trailing slash.
`"/a/b/"` at depth 1 finds no directory (zeros); at subtree depth it counts
`/a/b/...` descendants but not `/a/b` itself. Pass paths without a trailing
slash.

```c
ZestHistogram h = zest_histogram(core, "/Users/me/Documents", 1);
uint32_t pdf_ish = h.counts[3];   // documents
```

### `zest_ext_breakdown`

```c
uint32_t zest_ext_breakdown(Core *core, const char *scope_root, uint32_t max_depth,
                            uint8_t cat, uint32_t max, ZestExtCount *out);
```

Top-N extensions for one (scope, category), written into the caller's `out`
array (capacity at least `max`). Returns the number of rows written, each row's
`name` NUL-padded to 16 bytes, sorted by `count` descending.

- `max` is clamped to 32. `max == 0` or `cat >= 9` returns 0 without touching `out`.
- `max_depth == 1`: `findDirId` (O(D)) then a walk of the ext column to the
  target bucket (O(D x 9) small header reads; the bucket is already sorted on disk).
- Any other `max_depth`: merges every bucket in the subtree through a temporary
  hash map, sorts, truncates. O(D).
- Missing scope or empty category returns 0. Same trailing-slash caveat as
  `zest_histogram`.
- The return type is `uint32_t` on purpose (the Zig export returns `u32`);
  declaring it wider would read garbage from the upper half of the register.

```c
ZestExtCount rows[32];
uint32_t n = zest_ext_breakdown(core, "/Users/me/code", UINT32_MAX, 7 /* code */, 32, rows);
for (uint32_t i = 0; i < n; i++)
    printf("%.*s %u\n", (int)strnlen(rows[i].name, 16), rows[i].name, rows[i].count);
```

### `zest_casefold_utf8`

```c
size_t zest_casefold_utf8(const uint8_t *input, size_t len, uint8_t *out, size_t out_capacity);
```

Applies the engine's length-preserving UTF-8 case fold (`core/casefold.zig`) to
`input`, writing exactly `len` bytes to `out`. Returns `len`, or `0` when
`out_capacity < len` (nothing written). `input` and `out` may not overlap.
Exposed so a client that builds structured `ext:` filters or compares names
uses exactly the fold the index uses; `lowercased()`-style APIs differ (they
leave U+00B5 micro sign alone and shrink U+1E9E capital sharp S, which the
engine deliberately does not fold). O(len).

```c
uint8_t buf[64];
size_t n = zest_casefold_utf8((const uint8_t *)"PÅ", 3, buf, sizeof buf);   // "på", n == 3
```

## 4. Query language

Implemented in `src/core/filters.zig` (`parse`) and `src/index/search.zig`.
The same grammar backs the `zest-query` CLI (`docs/ZEST-QUERY.md`).

### Tokenisation

The query is split on single spaces (runs of spaces are skipped). Each token is
either a **qualifier** (`[!]key:value`, recognised key, parseable value) or
**text**. Text tokens are re-joined with one space to form the search needle;
so `my  report` and `my report` both search for the substring `"my report"`.
There is no quoting, no escaping, and no per-word matching.

A token is a qualifier only if all of these hold; otherwise it is literal text:

- it contains a `:` that is neither the first nor the last character (after an optional leading `!`);
- the key (case-insensitive) is one of `kind`, `ext`, `size`, `date`, `cat`, `path`;
- the value parses. `size:abc`, `date:notadate`, `cat:foo`, `ext:,` all fall back to text.

Unknown keys (`foo:bar`) are text. Filter values for `ext:` are case-folded at
parse time; `kind:`/`cat:` values are matched ASCII case-insensitively.

### Qualifiers

| Qualifier | Values | Semantics |
| --- | --- | --- |
| `kind:V` | `file`; `folder`, `dir`, `directory`; `symlink`, `link` | Equality on `FileKind`. |
| `ext:V` | 1-64 bytes, comma-separated list, segments may contain dots (`blade.php`) | Name ends with `"." + segment` for any segment, case-folded. `ext:php` matches `a.php`, `a.blade.php`, `.php`; not `x.aphp`, not `php`. |
| `cat:V` | see the category table in section 2 | Equality on `FileCategory`. A non-negated `cat:` also drives a bitmap prefilter. |
| `size:V` | `N`, `N.Nunit`, `>N`, `>=N`, `<N`, `<=N`, `A..B` | Bytes compared against `size` (directories: subtree total). Units `b`, `k`/`kb`, `m`/`mb`, `g`/`gb`, `t`/`tb`, 1024-based, case-insensitive; no unit = bytes. Bare `N` is exact equality. Overflow or `inf` rejects the token. |
| `date:V` | `today`, `week`, `month`, `year`; `YYYY-MM-DD`; `>YYYY-MM-DD`; `<YYYY-MM-DD`; `YYYY-MM-DD..YYYY-MM-DD` | Compared against `mtime`. Relative words mean `mtime >= now - 1/7/30/365 days`, anchored with libc `time()` at parse time. A bare date matches that whole UTC day; a range is inclusive of both days; `>`/`<` compare against midnight UTC of the given day. Impossible dates (`2024-02-31`) reject the token. |
| `path:V` | 1-255 bytes | Case-sensitive substring of `dir_path` (the parent directory, not the full path and not the name). |

### Negation

A leading `!` negates `kind:`, `ext:`, `cat:`, `path:`. It is accepted but
**ignored** for `size:` and `date:` (`!size:>1mb` behaves as `size:>1mb`).

### Combination

All criteria AND together, with one exception: every non-negated `ext:`
criterion joins a single OR group. `ext:php ext:html` is the same as
`ext:php,html`. Negated `ext:` criteria stay ANDed, so `!ext:php !ext:html`
excludes both. Text (if any) must also match.

### Text matching and case folding

Text is a substring match against the case-folded name blob. The needle is
folded the same way:

- Index v7: `casefold.foldInto`, Unicode simple case folding restricted to
  mappings that preserve UTF-8 byte length (so `RÉSUMÉ`, `Résumé`, `résumé`,
  `ΟΔΟΣ`/`οδος`, `Москва`/`МОСКВА` all match). Codepoints whose fold would
  change length (`İ`, `ẞ`, `K` Kelvin, `ſ`) are left as-is and match only
  themselves. Invalid UTF-8 passes through byte-for-byte.
- Index v6 (accepted during a rolling upgrade): ASCII lowercase only, matching
  what that index's blob contains. Non-ASCII text matches exact bytes only.

The text part is limited to 256 bytes; longer returns `ZEST_QUERY_ERROR`.

### `scope_root`

- `""` is rewritten to `"/"`. `"/"` means the whole index.
- Otherwise an absolute directory path as stored in the index. A single
  trailing slash is stripped (`"/a/b/"` == `"/a/b"`; `"/"` is kept).
- Subtree matching is segment-aware: `/a/b` matches `dir_path == "/a/b"` and
  `/a/b/...`, never `/a/bc`.
- A scope not in the index yields zero rows (not an error).

### `max_depth`

Only two values are meaningful:

| `max_depth` | Meaning |
| --- | --- |
| `1` | `dir_path == scope` exactly: a folder listing. With `"/"` this lists entries whose parent is `/` (typically none in a `$HOME` index). |
| anything else | `scope` and its whole subtree. `UINT32_MAX` takes the fast path (parent-id marks); other values give the same rows through a slower string-prefix path. |

There is no depth-limited-to-N semantics.

### Empty queries

`""` with no qualifiers at `"/"` and `max_depth == UINT32_MAX` returns an empty
result set immediately (no global dump). Any other combination (`""` with a
scope, with `max_depth == 1`, or with qualifiers) scans and returns everything
that matches: `""` + `scope` + `1` is how a folder listing is expressed.

### `max_results` and ordering

Rows are returned in **index order** (ascending entry index, the order the
indexer wrote them). The text path scans blob positions ascending, which is
the same order; the filter path iterates entry indices. Results are not sorted
by any column, and the engine exports no sort. `max_results` stops the scan
after that many matches, so a capped result set is "the first N in index
order", not a top-N by anything. Sort on the caller side (the Swift app sorts
copied rows).

### Examples

| Query | Effect |
| --- | --- |
| `invoice` | names containing `invoice`, any case |
| `invoice ext:pdf` | ... and ending in `.pdf` |
| `ext:png,jpg size:>2mb` | large images by extension |
| `cat:code date:week` | code files modified in the last 7 days |
| `kind:folder !path:node_modules` | directories whose parent path does not contain `node_modules` |
| `date:2024-01-01..2024-03-31 cat:documents` | documents modified in Q1 2024 (UTC days) |
| `size:1mb..10mb` | 1 MiB <= size <= 10 MiB |
| `foo:bar` | literal text `foo:bar` |

## 5. Lifetimes and invariants

- **Rows borrow the mapping.** `ZestRow.name` / `dir_path` point into the bytes
  given to `zest_open`. They are valid until `zest_query_free` and only while
  those bytes remain mapped and unchanged. Copy at the FFI boundary. Strings are
  not NUL-terminated.
- **A `Query` needs its `Core`'s bytes, not its `Core`.** Practically: free
  queries before `zest_close`, and never unmap while a `Query` is alive.
- **Bytes must not change under an open `Core`.** The daemon writes a new file
  and `rename()`s it over the old path, so an existing mapping (a private
  mapping of the old inode) stays valid; open the new file into a new `Core`
  and drop the old one when its queries are done (section 7).
- **Cancel tokens outlive the call.** The engine dereferences the token during
  the scan; destroy it only after `zest_query_cancellable` returns. Cancel from
  any thread; poll intervals are 64 KiB of blob (text scan) or 512 entries
  (filter scan), with one extra check on entry.
- **`ZestExtCount.name` is NUL-padded, not NUL-terminated by contract.** Read at
  most 16 bytes, stop at the first NUL. Today the on-disk cap of 15 guarantees a
  NUL exists.
- **Every allocation has one free.** `zest_open`/`zest_close`,
  `zest_query*`/`zest_query_free`, `zest_cancel_token_create`/`_destroy`.
  `zest_histogram` returns by value; `zest_ext_breakdown` writes into caller
  memory.
- **Errors are values.** No function aborts on malformed input: `zest_open`
  returns `NULL`, queries return `NULL` with a status, readers return
  zeros/empty on truncated columns, and out-of-range row indices return a zero
  row.

## 6. Worked example

### C

```c
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "zest_core.h"

int main(void) {
    const char *path = "/Users/me/Library/Application Support/zest/index.zst";
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 1;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size == 0) return 1;
    void *base = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return 1;

    Core *core = zest_open(base, (size_t)st.st_size);
    if (!core) { munmap(base, (size_t)st.st_size); return 1; }
    printf("%zu entries\n", zest_count(core));

    CancelToken *token = zest_cancel_token_create();
    uint32_t status = ZEST_QUERY_OK;
    Query *q = zest_query_cancellable(core, "invoice ext:pdf", "/Users/me",
                                      UINT32_MAX, 100000, token, &status);
    if (q) {
        size_t n = zest_query_count(q);
        for (size_t i = 0; i < n; i++) {
            ZestRow r = zest_query_row(q, i);
            /* copy or consume now: r.name/r.dir_path die with q */
            printf("%.*s/%.*s\t%llu\t%lld\tkind=%u cat=%u\n",
                   (int)r.dir_path.len, r.dir_path.ptr,
                   (int)r.name.len, r.name.ptr,
                   (unsigned long long)r.size, (long long)r.mtime,
                   r.kind, r.category);
        }
        zest_query_free(q);
    } else if (status == ZEST_QUERY_CANCELLED) {
        /* superseded */
    } else {
        /* ZEST_QUERY_ERROR */
    }
    zest_cancel_token_destroy(token);

    ZestHistogram h = zest_histogram(core, "/Users/me", UINT32_MAX);
    ZestExtCount exts[32];
    uint32_t k = zest_ext_breakdown(core, "/Users/me", UINT32_MAX, 7, 32, exts);
    (void)h; (void)k;

    zest_close(core);
    munmap(base, (size_t)st.st_size);
    return 0;
}
```

### Swift

`Sources/Zest/Core/ZestCore.swift` is the reference wrapper. The pattern:

```swift
final class ZestCore {
  init?(indexPath: String)   // open + fstat + mmap(PROT_READ, MAP_PRIVATE) + zest_open; nil on any failure
  deinit                     // zest_close, then munmap
  func query(_ q: String, scope: String, maxDepth: UInt32, maxResults: UInt32,
             cancel: CancelToken?) -> [Row]?
  // nil only on ZEST_QUERY_CANCELLED; ZEST_QUERY_ERROR reads as []
  // every row is copied to Swift Strings inside the call, before zest_query_free
  final class CancelToken { init?(); func cancel(); deinit { zest_cancel_token_destroy } }
  static func caseFoldForQuery(_: Substring) -> String   // zest_casefold_utf8
  func histogram(scope:maxDepth:) -> [Int]               // 9 counts
  func extBreakdown(scope:maxDepth:cat:max:) -> [(name: String, count: Int)]
}
```

Rules the wrapper enforces: strings are copied inside `query` (never held past
the call); the mmap lives exactly as long as the `Core`; a `CancelToken` is
kept alive by the dispatched closure so it outlives the engine call; a
`fileIdentity` (inode, size, mtime) records which file the mapping came from.

## 7. Benchmarking and compatibility

**Benchmark.**

```sh
just bench-capi
```

Builds a ReleaseFast archive into `zig-out/release/lib`, compiles
`benchmarks/bench_capi.zig` against it, and runs it against the real index
(`BENCH_INDEX=/path` overrides; `BENCH_QUICK=1` takes 2 samples instead of 7).
It times `zest_open`, a keystroke ladder (`i`, `in`, ..., `invoice`) at result
caps 100k and 2k, a `/`-scoped search, a depth-1 listing, and the sidebar path
(`zest_histogram` + 9x `zest_ext_breakdown` at depth 1 and subtree), reporting
medians plus a "drain" pass that touches every row through `zest_query_row`.
The harness declares the ABI itself as Zig `extern` structs and functions, so
it doubles as a plain-C-style consumer.

**Result-count rule.** The harness prints the result count of every query.
Engine changes must keep those counts identical before and after; compare the
two tables (the current one lives in `docs/BENCHMARKS.md`) and use medians over 7
samples for timing claims.

**Index compatibility.** `zest_open` accepts header versions 6 and 7
(`format.MIN_READ_VERSION`..`format.VERSION`). v6 and v7 share a layout; the
difference is the folded-name blob (ASCII lowercase in v6, UTF-8 case-fold in
v7), and the engine picks the matching query fold per `Core`. Anything older,
newer, with the wrong magic, or truncated returns `NULL`.

**Hot reload.** The daemon writes a `.tmp` file and `rename()`s it into
place, so the inode changes. The Swift app polls
`ZestCore.currentIdentity(of:)` every 5 seconds and, on any change of inode,
size, or mtime, opens a new `ZestCore` and swaps it in. Because rows are copied
at the FFI boundary, releasing the old `Core` (and its mapping) is safe once
its in-flight queries have returned.
