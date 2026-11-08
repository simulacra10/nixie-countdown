/*
Nixie Countdown
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT

Licensed under the MIT License. See the LICENSE file in the project root.
*/

#include "nixie-logic.h"

#include <math.h>
#include <stddef.h>

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

static int num_digits(int64_t v)
{
	int n = 1;
	while (v >= 10) {
		v /= 10;
		n++;
	}
	return n;
}

static int max_int(int a, int b)
{
	return a > b ? a : b;
}

int64_t nixie_clamp_i64(int64_t v, int64_t lo, int64_t hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

int64_t nixie_total_seconds(int64_t hours, int64_t minutes, int64_t seconds)
{
	int64_t h = nixie_clamp_i64(hours, 0, NIXIE_HOURS_MAX);
	int64_t m = nixie_clamp_i64(minutes, 0, 59);
	int64_t s = nixie_clamp_i64(seconds, 0, 59);
	return h * 3600 + m * 60 + s;
}

bool nixie_is_network_path(const char *path)
{
	if (!path)
		return false;
	return (path[0] == '\\' || path[0] == '/') && (path[1] == '\\' || path[1] == '/');
}

/* ------------------------------------------------------------------ */
/* Layout                                                             */
/* ------------------------------------------------------------------ */

static void append_char(char *buf, size_t *pos, char c)
{
	if (*pos < NIXIE_LAYOUT_MAX - 1)
		buf[(*pos)++] = c;
}

/* Append v as a zero padded decimal of at least `width` digits. */
static void append_num(char *buf, size_t *pos, int64_t v, int width)
{
	char tmp[24];
	int len = 0;
	if (v < 0)
		v = 0;
	do {
		tmp[len++] = (char)('0' + (v % 10));
		v /= 10;
	} while (v > 0 && len < (int)sizeof(tmp));
	while (len < width && len < (int)sizeof(tmp))
		tmp[len++] = '0';
	while (len > 0)
		append_char(buf, pos, tmp[--len]);
}

void nixie_build_layout(char *out, double remaining, int64_t total, int format)
{
	int64_t s = (int64_t)ceil(remaining - 1e-6);
	if (s < 0)
		s = 0;
	int64_t t = total;

	int fmt = format;
	if (fmt == FMT_AUTO) {
		if (t < 60)
			fmt = FMT_SECONDS;
		else if (t < 3600)
			fmt = FMT_MMSS;
		else
			fmt = FMT_HHMMSS;
	}

	size_t pos = 0;
	switch (fmt) {
	case FMT_SECONDS:
		append_num(out, &pos, s, max_int(2, num_digits(t)));
		break;
	case FMT_MMSS:
		append_num(out, &pos, s / 60, max_int(2, num_digits(t / 60)));
		append_char(out, &pos, ':');
		append_num(out, &pos, s % 60, 2);
		break;
	case FMT_HHMMSS:
	default:
		append_num(out, &pos, s / 3600, max_int(2, num_digits(t / 3600)));
		append_char(out, &pos, ':');
		append_num(out, &pos, (s / 60) % 60, 2);
		append_char(out, &pos, ':');
		append_num(out, &pos, s % 60, 2);
		break;
	}
	out[pos] = '\0';
}

uint32_t nixie_layout_width(const char *layout, bool show_separators, uint32_t digit_cx, uint32_t colon_cx, int spacing)
{
	int64_t x = 0;
	int64_t count = 0;
	for (const char *c = layout; *c; c++) {
		if (*c == ':') {
			if (!show_separators)
				continue;
			x += colon_cx;
		} else {
			x += digit_cx;
		}
		count++;
	}
	if (count > 1)
		x += (int64_t)spacing * (count - 1);
	if (x < 1)
		return 1;
	return x > UINT32_MAX ? UINT32_MAX : (uint32_t)x;
}

/* ------------------------------------------------------------------ */
/* Timer                                                              */
/* ------------------------------------------------------------------ */

void nixie_timer_reset(struct nixie_timer *t)
{
	t->remaining = (double)t->total;
	t->running = false;
	t->finished = false;
	t->blink_time = 0.0;
	t->blink_visible = true;
}

void nixie_timer_start(struct nixie_timer *t)
{
	if (t->finished || t->remaining <= 0.0)
		nixie_timer_reset(t);
	if (t->total > 0)
		t->running = true;
}

void nixie_timer_pause(struct nixie_timer *t)
{
	t->running = false;
}

void nixie_timer_toggle(struct nixie_timer *t)
{
	if (t->running)
		nixie_timer_pause(t);
	else
		nixie_timer_start(t);
}

void nixie_timer_tick(struct nixie_timer *t, double seconds, bool blink_at_zero)
{
	if (t->running) {
		t->remaining -= seconds;
		if (t->remaining <= 0.0) {
			t->remaining = 0.0;
			t->running = false;
			t->finished = true;
			t->blink_time = 0.0;
		}
	}

	if (t->finished && blink_at_zero) {
		t->blink_time += seconds;
		t->blink_visible = fmod(t->blink_time, 1.0) < 0.5;
	} else {
		t->blink_visible = true;
	}
}
