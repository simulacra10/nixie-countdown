/*
Nixie Countdown for OBS Studio
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT

Licensed under the MIT License. See the LICENSE file in the project root.
*/

/*
 * Unit tests for src/nixie-logic.c. Plain C with no OBS or test framework
 * dependency, so they build and run the same way on Windows, macOS and Linux.
 * Run them with run-tests.sh or run-tests.ps1 in the project root.
 */

#include "nixie-logic.h"

#include <stdio.h>
#include <string.h>

static int checks = 0;
static int failures = 0;

#define CHECK(cond)                                                               \
	do {                                                                      \
		checks++;                                                         \
		if (!(cond)) {                                                    \
			failures++;                                               \
			printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
		}                                                                 \
	} while (0)

#define CHECK_LAYOUT(remaining, total, format, expected)                                                   \
	do {                                                                                               \
		char buf_[NIXIE_LAYOUT_MAX];                                                                \
		nixie_build_layout(buf_, (remaining), (total), (format));                                   \
		checks++;                                                                                  \
		if (strcmp(buf_, (expected)) != 0) {                                                       \
			failures++;                                                                        \
			printf("  FAIL %s:%d: layout(%s, %s, %s) = \"%s\", expected \"%s\"\n", __FILE__, __LINE__, \
			       #remaining, #total, #format, buf_, (expected));                              \
		}                                                                                          \
	} while (0)

#define RUN(test)                          \
	do {                               \
		int before_ = failures;    \
		test();                    \
		printf("%s %s\n", failures == before_ ? "ok  " : "FAIL", #test); \
	} while (0)

/* ------------------------------------------------------------------ */
/* Clamping and input                                                 */
/* ------------------------------------------------------------------ */

static void test_clamp(void)
{
	CHECK(nixie_clamp_i64(5, 0, 10) == 5);
	CHECK(nixie_clamp_i64(-1, 0, 10) == 0);
	CHECK(nixie_clamp_i64(11, 0, 10) == 10);
	CHECK(nixie_clamp_i64(INT64_MIN, -60, 150) == -60);
	CHECK(nixie_clamp_i64(INT64_MAX, -60, 150) == 150);
}

static void test_total_seconds(void)
{
	CHECK(nixie_total_seconds(0, 5, 0) == 300);
	CHECK(nixie_total_seconds(1, 2, 3) == 3723);
	CHECK(nixie_total_seconds(999, 59, 59) == 999 * 3600 + 59 * 60 + 59);
	/* Out of range values from a crafted scene collection (NIXIE-2026-001) */
	CHECK(nixie_total_seconds(INT64_MAX, INT64_MAX, INT64_MAX) == 999 * 3600 + 59 * 60 + 59);
	CHECK(nixie_total_seconds(INT64_MIN, -5, -5) == 0);
	CHECK(nixie_total_seconds(0, 75, 90) == 59 * 60 + 59);
}

static void test_network_path(void)
{
	/* NIXIE-2026-002 */
	CHECK(nixie_is_network_path("\\\\host\\share"));
	CHECK(nixie_is_network_path("//host/share"));
	CHECK(nixie_is_network_path("\\/host"));
	CHECK(nixie_is_network_path("\\\\?\\C:\\tubes"));
	CHECK(!nixie_is_network_path("C:\\tubes"));
	CHECK(!nixie_is_network_path("/home/user/tubes"));
	CHECK(!nixie_is_network_path("\\tubes"));
	CHECK(!nixie_is_network_path(""));
	CHECK(!nixie_is_network_path(NULL));
}

/* ------------------------------------------------------------------ */
/* Layout                                                             */
/* ------------------------------------------------------------------ */

static void test_layout_auto_format(void)
{
	CHECK_LAYOUT(10, 10, FMT_AUTO, "10");
	CHECK_LAYOUT(59, 59, FMT_AUTO, "59");
	CHECK_LAYOUT(60, 60, FMT_AUTO, "01:00");
	CHECK_LAYOUT(300, 300, FMT_AUTO, "05:00");
	CHECK_LAYOUT(3599, 3599, FMT_AUTO, "59:59");
	CHECK_LAYOUT(3600, 3600, FMT_AUTO, "01:00:00");
	CHECK_LAYOUT(3723, 3723, FMT_AUTO, "01:02:03");
}

static void test_layout_fixed_formats(void)
{
	CHECK_LAYOUT(10, 10, FMT_SECONDS, "10");
	CHECK_LAYOUT(5, 5, FMT_SECONDS, "05");
	CHECK_LAYOUT(10, 10, FMT_MMSS, "00:10");
	CHECK_LAYOUT(10, 10, FMT_HHMMSS, "00:00:10");
	CHECK_LAYOUT(300, 300, FMT_SECONDS, "300");
	CHECK_LAYOUT(3723, 3723, FMT_MMSS, "62:03");
	/* Unknown format values fall back to hours, minutes and seconds */
	CHECK_LAYOUT(10, 10, 99, "00:00:10");
}

static void test_layout_stable_width(void)
{
	/* Field widths follow the configured total, not the time left */
	CHECK_LAYOUT(7, 300, FMT_SECONDS, "007");
	CHECK_LAYOUT(5, 6000, FMT_MMSS, "000:05");
	CHECK_LAYOUT(0, 6000, FMT_MMSS, "000:00");
	CHECK_LAYOUT(59, 999 * 3600, FMT_HHMMSS, "000:00:59");
	CHECK_LAYOUT(999 * 3600 + 59 * 60 + 59, 999 * 3600 + 59 * 60 + 59, FMT_AUTO, "999:59:59");
}

static void test_layout_rounding(void)
{
	/* Partial seconds round up, so 00:00 shows only when time is up */
	CHECK_LAYOUT(4.2, 10, FMT_SECONDS, "05");
	CHECK_LAYOUT(4.0, 10, FMT_SECONDS, "04");
	CHECK_LAYOUT(0.01, 10, FMT_SECONDS, "01");
	CHECK_LAYOUT(0.0, 10, FMT_SECONDS, "00");
	CHECK_LAYOUT(-3.0, 10, FMT_SECONDS, "00");
	CHECK_LAYOUT(59.5, 60, FMT_MMSS, "01:00");
}

static void test_layout_bounds(void)
{
	/* Extreme totals must stay inside the fixed buffer */
	char buf[NIXIE_LAYOUT_MAX + 8];
	memset(buf, 'x', sizeof(buf));
	nixie_build_layout(buf, 1e30, INT64_MAX, FMT_HHMMSS);
	CHECK(strlen(buf) < NIXIE_LAYOUT_MAX);
	CHECK(buf[NIXIE_LAYOUT_MAX] == 'x');

	memset(buf, 'x', sizeof(buf));
	nixie_build_layout(buf, 1e30, INT64_MAX, FMT_SECONDS);
	CHECK(strlen(buf) < NIXIE_LAYOUT_MAX);
	CHECK(buf[NIXIE_LAYOUT_MAX] == 'x');

	/* Negative totals (the plugin starts with -1 before settings load) */
	CHECK_LAYOUT(-1, -1, FMT_AUTO, "00");
}

static void test_layout_width(void)
{
	CHECK(nixie_layout_width("00:10", true, 150, 50, 0) == 650);
	CHECK(nixie_layout_width("00:10", false, 150, 50, 0) == 600);
	CHECK(nixie_layout_width("00:10", true, 150, 50, 10) == 690);
	CHECK(nixie_layout_width("00:10", false, 150, 50, 10) == 630);
	CHECK(nixie_layout_width("10", true, 150, 50, -60) == 240);
	CHECK(nixie_layout_width("0", true, 150, 50, 100) == 150);
	CHECK(nixie_layout_width("", true, 150, 50, 0) == 1);
	CHECK(nixie_layout_width("00:10", true, 150, 50, -1000) == 1);
	/* Huge sizes saturate instead of overflowing (NIXIE-2026-001) */
	CHECK(nixie_layout_width("000000000000000000000000000000", true, UINT32_MAX, UINT32_MAX, INT32_MAX) ==
	      UINT32_MAX);
}

/* ------------------------------------------------------------------ */
/* Timer                                                              */
/* ------------------------------------------------------------------ */

static struct nixie_timer make_timer(int64_t total)
{
	struct nixie_timer t;
	memset(&t, 0, sizeof(t));
	t.total = total;
	nixie_timer_reset(&t);
	return t;
}

static void test_timer_reset(void)
{
	struct nixie_timer t = make_timer(10);
	CHECK(t.remaining == 10.0);
	CHECK(!t.running);
	CHECK(!t.finished);
	CHECK(t.blink_visible);

	nixie_timer_start(&t);
	nixie_timer_tick(&t, 3.0, true);
	nixie_timer_reset(&t);
	CHECK(t.remaining == 10.0);
	CHECK(!t.running);
}

static void test_timer_countdown(void)
{
	struct nixie_timer t = make_timer(10);
	nixie_timer_start(&t);
	CHECK(t.running);

	for (int i = 0; i < 60; i++)
		nixie_timer_tick(&t, 1.0 / 60.0, true);
	CHECK(t.remaining > 8.99 && t.remaining < 9.01);
	CHECK(t.running);

	/* Ticks while stopped do nothing */
	nixie_timer_pause(&t);
	double left = t.remaining;
	nixie_timer_tick(&t, 1.0, true);
	CHECK(t.remaining == left);
	CHECK(!t.running);
}

static void test_timer_finish(void)
{
	struct nixie_timer t = make_timer(2);
	nixie_timer_start(&t);
	nixie_timer_tick(&t, 1.5, false);
	CHECK(!t.finished);
	nixie_timer_tick(&t, 1.0, false);
	CHECK(t.finished);
	CHECK(!t.running);
	CHECK(t.remaining == 0.0);
}

static void test_timer_restart_after_finish(void)
{
	struct nixie_timer t = make_timer(2);
	nixie_timer_start(&t);
	nixie_timer_tick(&t, 5.0, true);
	CHECK(t.finished);

	/* Start after finishing starts over from the full duration */
	nixie_timer_start(&t);
	CHECK(t.running);
	CHECK(!t.finished);
	CHECK(t.remaining == 2.0);
	CHECK(t.blink_visible);
}

static void test_timer_zero_duration(void)
{
	struct nixie_timer t = make_timer(0);
	nixie_timer_start(&t);
	CHECK(!t.running);
	nixie_timer_toggle(&t);
	CHECK(!t.running);
}

static void test_timer_toggle(void)
{
	struct nixie_timer t = make_timer(10);
	nixie_timer_toggle(&t);
	CHECK(t.running);
	nixie_timer_tick(&t, 4.0, true);
	nixie_timer_toggle(&t);
	CHECK(!t.running);
	CHECK(t.remaining == 6.0);
	/* Resuming keeps the time left */
	nixie_timer_toggle(&t);
	CHECK(t.running);
	CHECK(t.remaining == 6.0);
}

static void test_timer_blink(void)
{
	struct nixie_timer t = make_timer(1);
	nixie_timer_start(&t);
	nixie_timer_tick(&t, 1.0, true); /* reaches zero, blink starts */
	CHECK(t.finished);

	/* Visible for the first half of each second, hidden for the second */
	nixie_timer_tick(&t, 0.25, true);
	CHECK(t.blink_visible);
	nixie_timer_tick(&t, 0.5, true);
	CHECK(!t.blink_visible);
	nixie_timer_tick(&t, 0.5, true);
	CHECK(t.blink_visible);

	/* Turning blink off shows the tubes again */
	nixie_timer_tick(&t, 0.5, false);
	CHECK(t.blink_visible);
}

static void test_timer_no_blink_while_running(void)
{
	struct nixie_timer t = make_timer(10);
	nixie_timer_start(&t);
	for (int i = 0; i < 10; i++) {
		nixie_timer_tick(&t, 0.3, true);
		CHECK(t.blink_visible);
	}
}

int main(void)
{
	printf("Nixie Countdown unit tests\n");

	RUN(test_clamp);
	RUN(test_total_seconds);
	RUN(test_network_path);
	RUN(test_layout_auto_format);
	RUN(test_layout_fixed_formats);
	RUN(test_layout_stable_width);
	RUN(test_layout_rounding);
	RUN(test_layout_bounds);
	RUN(test_layout_width);
	RUN(test_timer_reset);
	RUN(test_timer_countdown);
	RUN(test_timer_finish);
	RUN(test_timer_restart_after_finish);
	RUN(test_timer_zero_duration);
	RUN(test_timer_toggle);
	RUN(test_timer_blink);
	RUN(test_timer_no_blink_while_running);

	printf("\n%d checks, %d failed\n", checks, failures);
	return failures == 0 ? 0 : 1;
}
