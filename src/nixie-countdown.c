/*
Nixie Countdown for OBS Studio
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT

Licensed under the MIT License. See the LICENSE file in the project root.
*/

#include <obs-module.h>
#include <graphics/graphics.h>
#include <util/threading.h>
#include <util/dstr.h>
#include <util/bmem.h>
#include <string.h>
#include <stdio.h>
#include <plugin-support.h>

#include "nixie-logic.h"

#define T_(s) obs_module_text(s)

#define S_HOURS "hours"
#define S_MINUTES "minutes"
#define S_SECONDS "seconds"
#define S_FORMAT "format"
#define S_SHOW_SEPARATORS "show_separators"
#define S_SPACING "spacing"
#define S_BLINK "blink_at_zero"
#define S_AUTO_START "auto_start"
#define S_IMAGE_DIR "image_dir"

struct nixie_countdown {
	obs_source_t *source;

	/* graphics (only touched inside obs_enter_graphics) */
	gs_texture_t *digit[10];
	gs_texture_t *colon;
	/* also written under mutex so get_width/get_height can read them */
	uint32_t digit_cx, digit_cy, colon_cx, colon_cy;
	char *image_dir;

	/* timer state, guarded by mutex */
	pthread_mutex_t mutex;
	struct nixie_timer timer;

	/* display options */
	int format;
	bool show_separators;
	int spacing;
	bool blink_at_zero;
	bool auto_start;

	char layout[NIXIE_LAYOUT_MAX];

	obs_hotkey_id hk_start_pause;
	obs_hotkey_id hk_reset;
};

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

/* On Windows, a UNC path (\\host\share) makes the system contact that host
 * and send the user's network credentials. A scene collection from someone
 * else could set one, so only local folders are accepted. */
static bool is_allowed_dir(const char *dir)
{
#ifdef _WIN32
	if (nixie_is_network_path(dir)) {
		obs_log(LOG_WARNING, "ignoring network path '%s' for tube images, use a local folder", dir);
		return false;
	}
#else
	UNUSED_PARAMETER(dir);
#endif
	return true;
}

/* Caller holds mutex. */
static void build_layout(struct nixie_countdown *n)
{
	nixie_build_layout(n->layout, n->timer.remaining, n->timer.total, n->format);
}

static gs_texture_t *load_tex(const char *custom_dir, const char *name)
{
	gs_texture_t *tex = NULL;

	if (custom_dir && *custom_dir) {
		struct dstr path = {0};
		dstr_printf(&path, "%s/%s", custom_dir, name);
		tex = gs_texture_create_from_file(path.array);
		if (!tex)
			obs_log(LOG_WARNING, "could not load '%s', falling back to built-in image", path.array);
		dstr_free(&path);
	}

	if (!tex) {
		struct dstr rel = {0};
		dstr_printf(&rel, "digits/%s", name);
		char *file = obs_module_file(rel.array);
		if (file) {
			tex = gs_texture_create_from_file(file);
			bfree(file);
		}
		if (!tex)
			obs_log(LOG_ERROR, "missing built-in image '%s'", rel.array);
		dstr_free(&rel);
	}
	return tex;
}

static void free_textures(struct nixie_countdown *n)
{
	for (int i = 0; i < 10; i++) {
		gs_texture_destroy(n->digit[i]);
		n->digit[i] = NULL;
	}
	gs_texture_destroy(n->colon);
	n->colon = NULL;
}

static void load_textures(struct nixie_countdown *n)
{
	obs_enter_graphics();
	free_textures(n);

	char name[16];
	for (int i = 0; i < 10; i++) {
		snprintf(name, sizeof(name), "%d.png", i);
		n->digit[i] = load_tex(n->image_dir, name);
	}
	n->colon = load_tex(n->image_dir, "colon.png");

	pthread_mutex_lock(&n->mutex);
	n->digit_cx = n->digit[0] ? gs_texture_get_width(n->digit[0]) : 150;
	n->digit_cy = n->digit[0] ? gs_texture_get_height(n->digit[0]) : 300;
	n->colon_cx = n->colon ? gs_texture_get_width(n->colon) : 50;
	n->colon_cy = n->colon ? gs_texture_get_height(n->colon) : 300;
	pthread_mutex_unlock(&n->mutex);
	obs_leave_graphics();
}

/* Timer controls. Caller holds mutex. */
static void timer_reset_locked(struct nixie_countdown *n)
{
	nixie_timer_reset(&n->timer);
	build_layout(n);
}

/* ------------------------------------------------------------------ */
/* Hotkeys and buttons                                                */
/* ------------------------------------------------------------------ */

static void action_toggle(struct nixie_countdown *n)
{
	pthread_mutex_lock(&n->mutex);
	nixie_timer_toggle(&n->timer);
	build_layout(n);
	pthread_mutex_unlock(&n->mutex);
}

static void action_start(struct nixie_countdown *n)
{
	pthread_mutex_lock(&n->mutex);
	nixie_timer_start(&n->timer);
	build_layout(n);
	pthread_mutex_unlock(&n->mutex);
}

static void action_pause(struct nixie_countdown *n)
{
	pthread_mutex_lock(&n->mutex);
	nixie_timer_pause(&n->timer);
	pthread_mutex_unlock(&n->mutex);
}

static void action_reset(struct nixie_countdown *n)
{
	pthread_mutex_lock(&n->mutex);
	timer_reset_locked(n);
	pthread_mutex_unlock(&n->mutex);
}

static void hotkey_start_pause(void *data, obs_hotkey_id id, obs_hotkey_t *hotkey, bool pressed)
{
	UNUSED_PARAMETER(id);
	UNUSED_PARAMETER(hotkey);
	if (pressed)
		action_toggle(data);
}

static void hotkey_reset(void *data, obs_hotkey_id id, obs_hotkey_t *hotkey, bool pressed)
{
	UNUSED_PARAMETER(id);
	UNUSED_PARAMETER(hotkey);
	if (pressed)
		action_reset(data);
}

/* These are also pressed by the context bar buttons (see context-bar.cpp),
 * which call obs_property_button_clicked on the same properties. data is
 * NULL when the properties were built without a source instance. */
static bool button_start(obs_properties_t *props, obs_property_t *p, void *data)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(p);
	if (!data)
		return false;
	action_start(data);
	return false;
}

static bool button_pause(obs_properties_t *props, obs_property_t *p, void *data)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(p);
	if (!data)
		return false;
	action_pause(data);
	return false;
}

static bool button_reset(obs_properties_t *props, obs_property_t *p, void *data)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(p);
	if (!data)
		return false;
	action_reset(data);
	return false;
}

/* ------------------------------------------------------------------ */
/* obs_source_info callbacks                                          */
/* ------------------------------------------------------------------ */

static const char *nixie_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return T_("NixieCountdown");
}

static void nixie_update(void *data, obs_data_t *settings)
{
	struct nixie_countdown *n = data;

	int64_t total = nixie_total_seconds(obs_data_get_int(settings, S_HOURS), obs_data_get_int(settings, S_MINUTES),
					    obs_data_get_int(settings, S_SECONDS));

	const char *dir = obs_data_get_string(settings, S_IMAGE_DIR);
	if (dir && !is_allowed_dir(dir))
		dir = "";
	bool dir_changed = strcmp(dir ? dir : "", n->image_dir ? n->image_dir : "") != 0;
	if (dir_changed) {
		bfree(n->image_dir);
		n->image_dir = bstrdup(dir ? dir : "");
	}

	pthread_mutex_lock(&n->mutex);
	n->format = (int)nixie_clamp_i64(obs_data_get_int(settings, S_FORMAT), FMT_AUTO, FMT_HHMMSS);
	n->show_separators = obs_data_get_bool(settings, S_SHOW_SEPARATORS);
	n->spacing = (int)nixie_clamp_i64(obs_data_get_int(settings, S_SPACING), NIXIE_SPACING_MIN, NIXIE_SPACING_MAX);
	n->blink_at_zero = obs_data_get_bool(settings, S_BLINK);
	n->auto_start = obs_data_get_bool(settings, S_AUTO_START);

	bool duration_changed = total != n->timer.total;
	if (duration_changed) {
		n->timer.total = total;
		timer_reset_locked(n);
	} else {
		build_layout(n);
	}
	pthread_mutex_unlock(&n->mutex);

	if (dir_changed || !n->digit[0])
		load_textures(n);
}

static void *nixie_create(obs_data_t *settings, obs_source_t *source)
{
	struct nixie_countdown *n = bzalloc(sizeof(*n));
	n->source = source;
	n->timer.total = -1;
	pthread_mutex_init(&n->mutex, NULL);

	nixie_update(n, settings);

	n->hk_start_pause = obs_hotkey_register_source(source, "NixieCountdown.StartPause", T_("Hotkey.StartPause"),
						       hotkey_start_pause, n);
	n->hk_reset = obs_hotkey_register_source(source, "NixieCountdown.Reset", T_("Hotkey.Reset"), hotkey_reset, n);
	return n;
}

static void nixie_destroy(void *data)
{
	struct nixie_countdown *n = data;
	obs_hotkey_unregister(n->hk_start_pause);
	obs_hotkey_unregister(n->hk_reset);

	obs_enter_graphics();
	free_textures(n);
	obs_leave_graphics();

	bfree(n->image_dir);
	pthread_mutex_destroy(&n->mutex);
	bfree(n);
}

static void nixie_activate(void *data)
{
	struct nixie_countdown *n = data;
	pthread_mutex_lock(&n->mutex);
	if (n->auto_start) {
		nixie_timer_reset(&n->timer);
		nixie_timer_start(&n->timer);
		build_layout(n);
	}
	pthread_mutex_unlock(&n->mutex);
}

static void nixie_tick(void *data, float seconds)
{
	struct nixie_countdown *n = data;
	pthread_mutex_lock(&n->mutex);
	nixie_timer_tick(&n->timer, seconds, n->blink_at_zero);
	build_layout(n);
	pthread_mutex_unlock(&n->mutex);
}

static uint32_t nixie_get_width(void *data)
{
	struct nixie_countdown *n = data;
	pthread_mutex_lock(&n->mutex);
	uint32_t w = nixie_layout_width(n->layout, n->show_separators, n->digit_cx, n->colon_cx, n->spacing);
	pthread_mutex_unlock(&n->mutex);
	return w;
}

static uint32_t nixie_get_height(void *data)
{
	struct nixie_countdown *n = data;
	pthread_mutex_lock(&n->mutex);
	uint32_t h = n->digit_cy;
	if (n->show_separators && n->colon_cy > h)
		h = n->colon_cy;
	pthread_mutex_unlock(&n->mutex);
	return h ? h : 1;
}

static void draw_tex(gs_eparam_t *image, gs_texture_t *tex, float x, uint32_t cx, uint32_t cy)
{
	if (!tex)
		return;
	gs_effect_set_texture(image, tex);
	gs_matrix_push();
	gs_matrix_translate3f(x, 0.0f, 0.0f);
	gs_draw_sprite(tex, 0, cx, cy);
	gs_matrix_pop();
}

static void nixie_render(void *data, gs_effect_t *effect)
{
	struct nixie_countdown *n = data;
	char layout[NIXIE_LAYOUT_MAX];
	bool visible, show_sep;
	int spacing;

	pthread_mutex_lock(&n->mutex);
	memcpy(layout, n->layout, NIXIE_LAYOUT_MAX);
	visible = n->timer.blink_visible;
	show_sep = n->show_separators;
	spacing = n->spacing;
	pthread_mutex_unlock(&n->mutex);

	if (!visible)
		return;

	gs_eparam_t *image = gs_effect_get_param_by_name(effect, "image");
	float x = 0.0f;

	/* Tube PNGs carry straight (non-premultiplied) alpha. */
	gs_blend_state_push();
	gs_blend_function_separate(GS_BLEND_SRCALPHA, GS_BLEND_INVSRCALPHA, GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);

	for (const char *c = layout; *c; c++) {
		if (*c == ':') {
			if (!show_sep)
				continue;
			draw_tex(image, n->colon, x, n->colon_cx, n->colon_cy);
			x += (float)n->colon_cx + (float)spacing;
		} else if (*c >= '0' && *c <= '9') {
			draw_tex(image, n->digit[*c - '0'], x, n->digit_cx, n->digit_cy);
			x += (float)n->digit_cx + (float)spacing;
		}
	}

	gs_blend_state_pop();
}

static void nixie_defaults(obs_data_t *settings)
{
	obs_data_set_default_int(settings, S_HOURS, 0);
	obs_data_set_default_int(settings, S_MINUTES, 5);
	obs_data_set_default_int(settings, S_SECONDS, 0);
	obs_data_set_default_int(settings, S_FORMAT, FMT_AUTO);
	obs_data_set_default_bool(settings, S_SHOW_SEPARATORS, true);
	obs_data_set_default_int(settings, S_SPACING, 0);
	obs_data_set_default_bool(settings, S_BLINK, true);
	obs_data_set_default_bool(settings, S_AUTO_START, false);
	obs_data_set_default_string(settings, S_IMAGE_DIR, "");
}

static obs_properties_t *nixie_properties(void *data)
{
	obs_properties_t *props = obs_properties_create();

	obs_properties_t *time = obs_properties_create();
	obs_properties_add_int(time, S_HOURS, T_("Hours"), 0, NIXIE_HOURS_MAX, 1);
	obs_properties_add_int(time, S_MINUTES, T_("Minutes"), 0, 59, 1);
	obs_properties_add_int(time, S_SECONDS, T_("Seconds"), 0, 59, 1);
	obs_properties_add_group(props, "time_group", T_("Duration"), OBS_GROUP_NORMAL, time);

	obs_properties_t *ctl = obs_properties_create();
	obs_properties_add_button2(ctl, "btn_start", T_("Start"), button_start, data);
	obs_properties_add_button2(ctl, "btn_pause", T_("Pause"), button_pause, data);
	obs_properties_add_button2(ctl, "btn_reset", T_("Reset"), button_reset, data);
	obs_properties_add_bool(ctl, S_AUTO_START, T_("AutoStart"));
	obs_properties_add_group(props, "ctl_group", T_("Controls"), OBS_GROUP_NORMAL, ctl);

	obs_properties_t *disp = obs_properties_create();
	obs_property_t *fmt =
		obs_properties_add_list(disp, S_FORMAT, T_("Format"), OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
	obs_property_list_add_int(fmt, T_("Format.Auto"), FMT_AUTO);
	obs_property_list_add_int(fmt, T_("Format.Seconds"), FMT_SECONDS);
	obs_property_list_add_int(fmt, T_("Format.MMSS"), FMT_MMSS);
	obs_property_list_add_int(fmt, T_("Format.HHMMSS"), FMT_HHMMSS);
	obs_properties_add_bool(disp, S_SHOW_SEPARATORS, T_("ShowSeparators"));
	obs_properties_add_int_slider(disp, S_SPACING, T_("Spacing"), NIXIE_SPACING_MIN, NIXIE_SPACING_MAX, 1);
	obs_properties_add_bool(disp, S_BLINK, T_("BlinkAtZero"));
	obs_properties_add_path(disp, S_IMAGE_DIR, T_("ImageDir"), OBS_PATH_DIRECTORY, NULL, NULL);
	obs_properties_add_group(props, "disp_group", T_("Display"), OBS_GROUP_NORMAL, disp);

	return props;
}

struct obs_source_info nixie_countdown_source = {
	.id = "nixie_countdown_source",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_VIDEO,
	.get_name = nixie_get_name,
	.create = nixie_create,
	.destroy = nixie_destroy,
	.update = nixie_update,
	.get_defaults = nixie_defaults,
	.get_properties = nixie_properties,
	.activate = nixie_activate,
	.video_tick = nixie_tick,
	.video_render = nixie_render,
	.get_width = nixie_get_width,
	.get_height = nixie_get_height,
	.icon_type = OBS_ICON_TYPE_TEXT,
};
