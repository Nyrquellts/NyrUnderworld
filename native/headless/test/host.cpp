#include "headless.h"
#include <cstdio>
#include <cwchar>
LONG WINAPI pretend_filter(EXCEPTION_POINTERS*) { return EXCEPTION_CONTINUE_SEARCH; }
DWORD WINAPI fail_thread(void*) { RaiseException(0xe0424242,EXCEPTION_NONCONTINUABLE,0,nullptr); return 99; }
int wmain(int argc,wchar_t** argv) {
    if (argc!=3) return 2;
    if (!wcscmp(argv[2],L"invalid")) {
        if (NyrHeadlessInitialize(L".",3000)!=ERROR_INVALID_PARAMETER) return 9;
        if (NyrHeadlessInitialize(argv[1],99)!=ERROR_INVALID_PARAMETER) return 10;
    }
    const int result=NyrHeadlessInitialize(argv[1],3000);
    if (result) return result;
    if (NyrHeadlessInitialize(argv[1],3000)!=ERROR_ALREADY_INITIALIZED) return 3;
    SetErrorMode(0);
    if (!(GetErrorMode()&SEM_NOGPFAULTERRORBOX)) return 4;
    if (!wcscmp(argv[2],L"clean") || !wcscmp(argv[2],L"invalid")) { std::puts("HEADLESS_INITIALIZED"); return 0; }
    if (!wcscmp(argv[2],L"message_w")) MessageBoxW(nullptr,L"synthetic owned-host failure",L"test",MB_OK);
    else if (!wcscmp(argv[2],L"message_a")) MessageBoxA(nullptr,"synthetic owned-host failure","test",MB_OK);
    else if (!wcscmp(argv[2],L"replace_filter")) { SetUnhandledExceptionFilter(pretend_filter); RaiseException(0xe0424242,EXCEPTION_NONCONTINUABLE,0,nullptr); }
    else if (!wcscmp(argv[2],L"exception")) RaiseException(0xe0424242,EXCEPTION_NONCONTINUABLE,0,nullptr);
    else if (!wcscmp(argv[2],L"access_violation")) {
        auto* forbidden=static_cast<volatile unsigned char*>(VirtualAlloc(nullptr,4096,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS));
        if (!forbidden) return 12;
        *forbidden=1;
    }
    else if (!wcscmp(argv[2],L"thread_exception")) {
        HANDLE thread=CreateThread(nullptr,0,fail_thread,nullptr,0,nullptr);
        if (!thread) return 11;
        WaitForSingleObject(thread,5000); CloseHandle(thread);
    }
    else return 5;
    return 6; // A fatal path must never return and continue a damaged host.
}
