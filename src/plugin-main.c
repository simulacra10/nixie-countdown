/*
Nixie Countdown for OBS Studio
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT

Licensed under the MIT License. See the LICENSE file in the project root.
*/

#include <obs-module.h>
#include <plugin-support.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE(PLUGIN_NAME, "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
	return "Nixie tube countdown timer source";
}

extern struct obs_source_info nixie_countdown_source;
extern void nixie_context_bar_init(void);
extern void nixie_context_bar_free(void);

bool obs_module_load(void)
{
	obs_register_source(&nixie_countdown_source);
	nixie_context_bar_init();
	obs_log(LOG_INFO, "plugin loaded successfully (version %s)", PLUGIN_VERSION);
	return true;
}

void obs_module_unload(void)
{
	nixie_context_bar_free();
	obs_log(LOG_INFO, "plugin unloaded");
}
