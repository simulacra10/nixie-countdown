/*
Nixie Countdown for OBS Studio
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT

Licensed under the MIT License. See the LICENSE file in the project root.
*/

/*
 * Puts Start / Pause / Reset buttons in the source context bar (the strip
 * under the preview with "Properties" and "Filters") while a Nixie Countdown
 * source is selected.
 *
 * OBS has no public API for custom context bar toolbars, so this looks up the
 * bar's widgets by object name ("contextSourceLabel" and "emptySpace", the
 * same in OBS 30 and 31). OBS clears that slot whenever the selection
 * changes; a short timer re-adds our buttons when needed. If a future OBS
 * renames those widgets, the buttons simply do not appear and everything
 * else in the plugin keeps working.
 */

#include <obs-module.h>
#include <obs-frontend-api.h>
#include <plugin-support.h>

#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QLayout>
#include <QMainWindow>
#include <QPointer>
#include <QPushButton>
#include <QTimer>

#include <cstring>

static const char *SOURCE_ID = "nixie_countdown_source";

/* Press a button from the source's Controls group, exactly as the
 * Properties window does. */
static void press_property_button(obs_source_t *source, const char *name)
{
	obs_properties_t *props = obs_source_properties(source);
	if (!props)
		return;
	obs_property_t *p = obs_properties_get(props, name);
	if (p && obs_property_get_type(p) == OBS_PROPERTY_BUTTON)
		obs_property_button_clicked(p, source);
	obs_properties_destroy(props);
}

class NixieContextBar {
public:
	explicit NixieContextBar(QMainWindow *main) : main(main)
	{
		timer = new QTimer(main);
		timer->setInterval(150);
		QObject::connect(timer, &QTimer::timeout, [this]() { Tick(); });
		timer->start();
	}

	~NixieContextBar()
	{
		if (timer)
			delete timer;
		RemoveBar();
	}

private:
	QPointer<QMainWindow> main;
	QPointer<QTimer> timer;
	QPointer<QFrame> emptySpace;
	QPointer<QLabel> sourceLabel;
	QPointer<QWidget> bar;
	obs_weak_source_t *barSource = nullptr;

	void RemoveBar()
	{
		if (bar) {
			if (emptySpace && emptySpace->layout())
				emptySpace->layout()->removeWidget(bar);
			delete bar;
		}
		obs_weak_source_release(barSource);
		barSource = nullptr;
	}

	bool FindWidgets()
	{
		if (!main)
			return false;
		if (!emptySpace)
			emptySpace = main->findChild<QFrame *>("emptySpace");
		if (!sourceLabel)
			sourceLabel = main->findChild<QLabel *>("contextSourceLabel");
		return emptySpace && sourceLabel && emptySpace->layout();
	}

	/* Returns a new reference to the selected source if it is ours. */
	obs_source_t *SelectedNixieSource()
	{
		QByteArray name = sourceLabel->text().toUtf8();
		if (name.isEmpty())
			return nullptr;
		obs_source_t *src = obs_get_source_by_name(name.constData());
		if (!src)
			return nullptr;
		const char *id = obs_source_get_unversioned_id(src);
		if (!id || strcmp(id, SOURCE_ID) != 0) {
			obs_source_release(src);
			return nullptr;
		}
		return src;
	}

	QPushButton *MakeButton(const char *textKey, const char *propName)
	{
		QPushButton *btn = new QPushButton(QString::fromUtf8(obs_module_text(textKey)));
		btn->setFocusPolicy(Qt::NoFocus);
		QObject::connect(btn, &QPushButton::clicked, [this, propName]() {
			obs_source_t *src = obs_weak_source_get_source(barSource);
			if (src) {
				press_property_button(src, propName);
				obs_source_release(src);
			}
		});
		return btn;
	}

	void AddBar(obs_source_t *src)
	{
		bar = new QWidget(emptySpace);
		QHBoxLayout *layout = new QHBoxLayout(bar);
		layout->setContentsMargins(0, 0, 0, 0);
		layout->addWidget(MakeButton("Start", "btn_start"));
		layout->addWidget(MakeButton("Pause", "btn_pause"));
		layout->addWidget(MakeButton("Reset", "btn_reset"));
		layout->addStretch(1);

		obs_weak_source_release(barSource);
		barSource = obs_source_get_weak_source(src);
		emptySpace->layout()->addWidget(bar);
	}

	void Tick()
	{
		if (!FindWidgets())
			return;

		obs_source_t *src = SelectedNixieSource();

		if (!src) {
			/* Something else is selected. OBS normally clears our bar
			 * itself; this covers the cases where it does not. */
			if (bar || barSource)
				RemoveBar();
			return;
		}

		bool current = bar && obs_weak_source_references_source(barSource, src);
		if (!current) {
			RemoveBar();
			/* Only use the slot when the bar is shown and OBS left it empty. */
			if (emptySpace->isVisible() && emptySpace->layout()->count() == 0)
				AddBar(src);
		}
		obs_source_release(src);
	}
};

static NixieContextBar *context_bar = nullptr;

static void frontend_event(enum obs_frontend_event event, void *)
{
	if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
		if (!context_bar) {
			QMainWindow *main = static_cast<QMainWindow *>(obs_frontend_get_main_window());
			if (main)
				context_bar = new NixieContextBar(main);
		}
	} else if (event == OBS_FRONTEND_EVENT_EXIT) {
		delete context_bar;
		context_bar = nullptr;
	}
}

extern "C" void nixie_context_bar_init(void)
{
	obs_frontend_add_event_callback(frontend_event, nullptr);
}

extern "C" void nixie_context_bar_free(void)
{
	obs_frontend_remove_event_callback(frontend_event, nullptr);
	delete context_bar;
	context_bar = nullptr;
}
