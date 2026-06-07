#ifndef ZEST_CORE_H
#define ZEST_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { const uint8_t *ptr; size_t len; } ZestStr; // NOT null-terminated
typedef struct {
    ZestStr  name;
    ZestStr  dir_path;
    uint64_t size;
    int64_t  mtime;   // unix seconds
    uint8_t  kind;    // 0 file, 1 dir, 2 symlink (FileKind order)
    uint8_t  category;// FileCategory enum
} ZestRow;

typedef struct Core  Core;   // opaque
typedef struct Query Query;  // opaque

// Borrows index_bytes until zest_close (caller keeps them mapped).
Core  *zest_open(const uint8_t *index_bytes, size_t len);
void   zest_close(Core *core);
size_t zest_count(Core *core); // total indexed entries (files + dirs)

// scope_root "" or "/" = whole index; max_depth 1 = folder listing, large = subtree.
Query *zest_query(Core *core, const char *query_utf8, const char *scope_root,
                  uint32_t max_depth, uint32_t max_results);
size_t  zest_query_count(const Query *q);
ZestRow zest_query_row(const Query *q, size_t i); // strings valid until zest_query_free
void    zest_query_free(Query *q);

// 9 per-category counts (matches the FileCategory enum order: 0=uncategorized,
// 1=images, 2=text, 3=documents, 4=spreadsheets, 5=audio, 6=video, 7=code,
// 8=archives). O(1) at max_depth=1; O(D) for deeper scopes.
typedef struct { uint32_t counts[9]; } ZestHistogram;
ZestHistogram zest_histogram(Core *core, const char *scope_root, uint32_t max_depth);

// One (ext name, count) row. `name` is NUL-padded but NOT NUL-terminated;
// use the `len` returned by the call to read the prefix. Fixed size so the
// caller can stack-allocate the breakdown struct without a heap round-trip.
typedef struct { char name[16]; uint32_t count; } ZestExtCount;

// Per-(dir, cat) ext breakdown. `entries[0..len)` are the top-N ext rows for
// the requested scope/category, sorted by count descending. Capped at 32.
typedef struct { ZestExtCount entries[32]; uint32_t len; } ZestExtBreakdown;

// Read up to `max` exts for the (scope, category) pair. Returns the number
// of rows written. 0 on missing folder or empty category. `out` must have
// room for at least `max` ZestExtCount rows.
size_t zest_ext_breakdown(Core *core, const char *scope_root, uint32_t max_depth,
                          uint8_t cat, uint32_t max, ZestExtCount *out);

#ifdef __cplusplus
}
#endif

#endif // ZEST_CORE_H
