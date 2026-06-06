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

// scope_root "" or "/" = whole index; max_depth 1 = folder listing, large = subtree.
Query *zest_query(Core *core, const char *query_utf8, const char *scope_root,
                  uint32_t max_depth, uint32_t max_results);
size_t  zest_query_count(const Query *q);
ZestRow zest_query_row(const Query *q, size_t i); // strings valid until zest_query_free
void    zest_query_free(Query *q);

#ifdef __cplusplus
}
#endif

#endif // ZEST_CORE_H
