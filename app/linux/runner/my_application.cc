#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

struct WindowCloseState {
  GtkWindow* window;
  FlMethodChannel* channel = nullptr;
  bool allowed = false;
  bool destroyed = false;
};

static gboolean window_delete_event(GtkWidget*, GdkEvent*, gpointer user_data) {
  auto* state = static_cast<WindowCloseState*>(user_data);
  if (state->allowed) return FALSE;
  if (state->channel != nullptr && !state->destroyed) {
    fl_method_channel_invoke_method(state->channel, "closeRequested", nullptr,
                                   nullptr, nullptr, nullptr);
  }
  // A missing/not-yet-ready Dart handler must never imply consent to exit.
  return TRUE;
}

static void window_destroyed(GtkWidget*, gpointer user_data) {
  auto* state = static_cast<WindowCloseState*>(user_data);
  state->destroyed = true;
  state->window = nullptr;
  if (state->channel != nullptr) {
    fl_method_channel_set_method_call_handler(state->channel, nullptr, nullptr, nullptr);
    g_clear_object(&state->channel);
  }
}

static gboolean finish_window_close(gpointer user_data) {
  auto* window = GTK_WIDGET(user_data);
  auto* state = static_cast<WindowCloseState*>(
      g_object_get_data(G_OBJECT(window), "velum-close-state"));
  if (state != nullptr && !state->destroyed) gtk_window_close(GTK_WINDOW(window));
  return G_SOURCE_REMOVE;
}

static void window_method_call(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  auto* state = static_cast<WindowCloseState*>(user_data);
  GtkWindow* window = state->window;
  if (state->destroyed || window == nullptr) {
    fl_method_call_respond_error(call, "window", "window is not available", nullptr, nullptr);
    return;
  }
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "minimize") == 0) {
    gtk_window_iconify(window);
  } else if (g_strcmp0(method, "maximize") == 0) {
    if (gtk_window_is_maximized(window)) gtk_window_unmaximize(window);
    else gtk_window_maximize(window);
  } else if (g_strcmp0(method, "close") == 0) {
    gtk_window_close(window); // Always routes through delete-event -> Dart.
  } else if (g_strcmp0(method, "closeConfirmed") == 0) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    if (!state->allowed) {
      state->allowed = true;
      // Reply before destroying the engine that carries the method response.
      g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, finish_window_close,
                     g_object_ref(window), g_object_unref);
    }
    return;
  } else if (g_strcmp0(method, "hide") == 0) {
    gtk_widget_hide(GTK_WIDGET(window));
  } else if (g_strcmp0(method, "show") == 0) {
    gtk_widget_show(GTK_WIDGET(window));
    gtk_window_present(window);
  } else if (g_strcmp0(method, "isVisible") == 0) {
    gboolean visible = gtk_widget_get_visible(GTK_WIDGET(window));
    g_autoptr(FlValue) result = fl_value_new_bool(visible);
    fl_method_call_respond_success(call, result, nullptr);
    return;
  } else if (g_strcmp0(method, "drag") == 0) {
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
    GdkDevice* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(display));
    gint x = 0, y = 0;
    gdk_device_get_position(pointer, nullptr, &x, &y);
    gtk_window_begin_move_drag(window, 1, x, y, GDK_CURRENT_TIME);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  gtk_window_set_title(window, "Velum");
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_default_size(window, 980, 760);
  GdkGeometry minimum = {};
  minimum.min_width = 440;
  minimum.min_height = 640;
  gtk_window_set_geometry_hints(window, nullptr, &minimum, GDK_HINT_MIN_SIZE);
  auto* close_state = new WindowCloseState{window};
  g_object_set_data_full(G_OBJECT(window), "velum-close-state", close_state,
      [](gpointer data) { delete static_cast<WindowCloseState*>(data); });
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event), close_state);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroyed), close_state);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "velum/window", FL_METHOD_CODEC(codec));
  close_state->channel = FL_METHOD_CHANNEL(g_object_ref(window_channel));
  fl_method_channel_set_method_call_handler(window_channel, window_method_call,
      close_state, nullptr);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
