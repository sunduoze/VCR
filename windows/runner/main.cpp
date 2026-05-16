#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <stdio.h>
#include <io.h>
#include <fcntl.h>

#include "flutter_window.h"
#include "utils.h"

/// Allocate an independent console window for real-time log output.
/// This creates a separate cmd-like window alongside the Flutter GUI.
static void AllocateLogConsole() {
  if (::AllocConsole()) {
    // Redirect stdout
    FILE* fp;
    freopen_s(&fp, "CONOUT$", "w", stdout);
    setvbuf(stdout, nullptr, _IONBF, 0);

    // Redirect stderr
    freopen_s(&fp, "CONOUT$", "w", stderr);
    setvbuf(stderr, nullptr, _IONBF, 0);

    // Also redirect stdin (optional, but keeps console responsive)
    freopen_s(&fp, "CONIN$", "r", stdin);

    printf("=== VCR Debug Console ===\n");
    printf("Rust logs will appear here. Close this window to stop logging.\n\n");
  }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Always allocate a separate debug console window
  AllocateLogConsole();

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"VCR", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
