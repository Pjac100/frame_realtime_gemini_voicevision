//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <objectbox_flutter_libs/objectbox_flutter_libs_plugin.h>
#include <share_plus/share_plus_windows_plugin_c_api.h>
#include <tflite_flutter_processing/tflite_flutter_processing_plugin.h>
#include <url_launcher_windows/url_launcher_windows.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  ObjectboxFlutterLibsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ObjectboxFlutterLibsPlugin"));
  SharePlusWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SharePlusWindowsPluginCApi"));
  TfliteFlutterProcessingPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("TfliteFlutterProcessingPlugin"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
}
