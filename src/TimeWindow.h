#pragma once
#include <stdbool.h>
static inline bool MYInWindow(int now, int start, int end) {
    if(start == end) return false; // equal endpoints: no blocked interval
    return start < end ? now >= start && now < end : now >= start || now < end;
}

static inline bool MYKeywordAllowed(bool original, bool enabled, bool settings, int now, int start, int end) {
    if (settings || !enabled) return original;
    return original && !MYInWindow(now, start, end);
}
