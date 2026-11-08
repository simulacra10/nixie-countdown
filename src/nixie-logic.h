/*
Nixie Countdown
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT

Licensed under the MIT License. See the LICENSE file in the project root.
*/

/*
 * Timer and layout logic with no OBS dependency, so it can be unit tested
 * on its own (see tests/). None of these functions lock; the plugin calls
 * them while holding its source mutex.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NIXIE_LAYOUT_MAX 32

/* Setting ranges. The properties UI uses these, and nixie_update clamps to
 * them because settings can also come from an edited scene collection. */
#define NIXIE_HOURS_MAX 999
#define NIXIE_SPACING_MIN -60
#define NIXIE_SPACING_MAX 150

enum nixie_format {
	FMT_AUTO = 0,
	FMT_SECONDS = 1, /* 10          */
	FMT_MMSS = 2,    /* 00:10       */
	FMT_HHMMSS = 3,  /* 00:00:10    */
};

struct nixie_timer {
	int64_t total;    /* configured duration in seconds */
	double remaining; /* seconds left */
	bool running;
	bool finished;
	double blink_time;
	bool blink_visible;
};

int64_t nixie_clamp_i64(int64_t v, int64_t lo, int64_t hi);

/* Total seconds from hours, minutes and seconds, each clamped to the range
 * the properties UI allows. */
int64_t nixie_total_seconds(int64_t hours, int64_t minutes, int64_t seconds);

/* True for paths that start with two slashes or backslashes, such as
 * \\host\share or //host/share (Windows network paths). */
bool nixie_is_network_path(const char *path);

/* Build the character layout, for example "05:00", into out (which must hold
 * NIXIE_LAYOUT_MAX bytes). Field widths come from the configured total, not
 * the remaining time, so the source keeps a stable size while counting down. */
void nixie_build_layout(char *out, double remaining, int64_t total, int format);

/* Width in pixels of a layout drawn with the given tube sizes and spacing.
 * Never returns 0, and saturates instead of overflowing. */
uint32_t nixie_layout_width(const char *layout, bool show_separators, uint32_t digit_cx, uint32_t colon_cx,
			    int spacing);

void nixie_timer_reset(struct nixie_timer *t);
void nixie_timer_start(struct nixie_timer *t);
void nixie_timer_pause(struct nixie_timer *t);
void nixie_timer_toggle(struct nixie_timer *t);

/* Advance the timer by `seconds` of frame time. When blink_at_zero is set,
 * a finished timer blinks: visible for half of each second. */
void nixie_timer_tick(struct nixie_timer *t, double seconds, bool blink_at_zero);

#ifdef __cplusplus
}
#endif
