#pragma once
#include <windows.h>
#ifdef NYR_HEADLESS_BUILD
#define NYR_HEADLESS_API extern "C" __declspec(dllexport)
#else
#define NYR_HEADLESS_API extern "C" __declspec(dllimport)
#endif
// Explicit, process-local, one-shot installation. No injection or DllMain work.
// An existing absolute report directory is required; files are created uniquely.
NYR_HEADLESS_API int __cdecl NyrHeadlessInitialize(const wchar_t* report_directory, DWORD timeout_ms) noexcept;
NYR_HEADLESS_API DWORD __cdecl NyrHeadlessExitCode() noexcept;
