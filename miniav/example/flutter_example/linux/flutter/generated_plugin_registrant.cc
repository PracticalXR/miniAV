//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <minigpu_view/minigpu_view_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) minigpu_view_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "MinigpuViewPlugin");
  minigpu_view_plugin_register_with_registrar(minigpu_view_registrar);
}
