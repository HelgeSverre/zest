#ifndef ZEST_FSEVENTS_BRIDGE_H
#define ZEST_FSEVENTS_BRIDGE_H
#include <stddef.h>
#include <stdbool.h>
typedef void (*zest_events_callback)(void *, size_t, const char *const *, bool);
void *zest_events_create(const char *, const char *const *, size_t, zest_events_callback, void *);
bool zest_events_start(void *);
void zest_events_stop(void *);
void zest_events_destroy(void *);
void zest_run_loop_stop(void);
void zest_run_loop_run(double);
#endif
