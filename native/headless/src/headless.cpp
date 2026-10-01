#define NYR_HEADLESS_BUILD
#include "headless.h"
#include <DbgHelp.h>
#include <MinHook.h>
#include <cstdio>
#include <cwchar>
#include <intrin.h>

namespace {
constexpr DWORD EXIT_CODE=0xe04e5952;
constexpr UINT REQUIRED_MODE=SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX;
volatile LONG installed=0, crashing=0;
HANDLE requested=nullptr, completed=nullptr, dump_file=INVALID_HANDLE_VALUE, report_file=INVALID_HANDLE_VALUE;
DWORD deadline=3000, crash_thread=0;
EXCEPTION_RECORD record{};
CONTEXT context{};
EXCEPTION_POINTERS pointers{&record,&context};
const char* reason="unhandled_exception";
UINT dialog_flags=0;
decltype(&SetErrorMode) real_SetErrorMode=SetErrorMode;
decltype(&SetUnhandledExceptionFilter) real_SetUnhandledExceptionFilter=SetUnhandledExceptionFilter;
decltype(&MessageBoxW) real_MessageBoxW=MessageBoxW;
decltype(&MessageBoxA) real_MessageBoxA=MessageBoxA;

[[noreturn]] void terminate() noexcept {
    TerminateProcess(GetCurrentProcess(),EXIT_CODE);
    __fastfail(7);
}
void write_report(BOOL dumped,DWORD error) noexcept {
    char text[768];
    const int length=_snprintf_s(text,sizeof(text),_TRUNCATE,
        "{\"schema\":\"nyr.headless-crash/1\",\"reason\":\"%s\",\"process_id\":%lu,"
        "\"thread_id\":%lu,\"exception_code\":%lu,\"address\":\"%p\",\"dialog_flags\":%u,"
        "\"minidump_written\":%s,\"minidump_error\":%lu,\"exit_code\":%lu,"
        "\"gameplay_verified\":false}\n",
        reason,GetCurrentProcessId(),crash_thread,record.ExceptionCode,record.ExceptionAddress,
        dialog_flags,dumped?"true":"false",error,EXIT_CODE);
    DWORD written=0;
    if (length>0) WriteFile(report_file,text,static_cast<DWORD>(length),&written,nullptr);
    FlushFileBuffers(report_file);
}
DWORD WINAPI writer(void*) noexcept {
    if (WaitForSingleObject(requested,INFINITE)!=WAIT_OBJECT_0) return 1;
    MINIDUMP_EXCEPTION_INFORMATION exception{crash_thread,&pointers,FALSE};
    const BOOL dumped=MiniDumpWriteDump(GetCurrentProcess(),GetCurrentProcessId(),dump_file,
        MiniDumpNormal,&exception,nullptr,nullptr);
    const DWORD error=dumped?ERROR_SUCCESS:GetLastError();
    FlushFileBuffers(dump_file);
    write_report(dumped,error);
    SetEvent(completed);
    return 0;
}
[[noreturn]] void fatal(EXCEPTION_POINTERS* original,const char* why,UINT flags=0) noexcept {
    if (InterlockedCompareExchange(&crashing,1,0)==0) {
        crash_thread=GetCurrentThreadId(); reason=why; dialog_flags=flags;
        if (original && original->ExceptionRecord && original->ContextRecord) {
            record=*original->ExceptionRecord; context=*original->ContextRecord;
            record.ExceptionRecord=nullptr;
        } else {
            RtlCaptureContext(&context);
            record.ExceptionCode=EXIT_CODE;
            record.ExceptionAddress=_ReturnAddress();
        }
        // Handles and buffers already exist; the exception path allocates nothing.
        MemoryBarrier();
        SetEvent(requested);
    }
    WaitForSingleObject(completed,deadline);
    // A damaged loader or DbgHelp can deadlock the writer. Never leave the
    // headless host waiting indefinitely for a dump, modal dialog or cleanup.
    terminate();
}
LONG WINAPI filter(EXCEPTION_POINTERS* original) noexcept { fatal(original,"unhandled_exception"); }
UINT WINAPI hook_SetErrorMode(UINT mode) noexcept { return real_SetErrorMode(mode|REQUIRED_MODE); }
LPTOP_LEVEL_EXCEPTION_FILTER WINAPI hook_SetUnhandledExceptionFilter(LPTOP_LEVEL_EXCEPTION_FILTER) noexcept {
    return filter; // Explicit contract: later replacement attempts cannot restore modal failure handling.
}
int WINAPI hook_MessageBoxW(HWND,LPCWSTR,LPCWSTR,UINT flags) noexcept { fatal(nullptr,"message_box_w",flags); }
int WINAPI hook_MessageBoxA(HWND,LPCSTR,LPCSTR,UINT flags) noexcept { fatal(nullptr,"message_box_a",flags); }
struct Hook { HMODULE module; const char* name; void* callback; void** original; void* target=nullptr; };
void close_setup() noexcept {
    if (dump_file!=INVALID_HANDLE_VALUE) CloseHandle(dump_file);
    if (report_file!=INVALID_HANDLE_VALUE) CloseHandle(report_file);
    if (requested) CloseHandle(requested);
    if (completed) CloseHandle(completed);
    dump_file=report_file=INVALID_HANDLE_VALUE; requested=completed=nullptr;
}
}

NYR_HEADLESS_API DWORD __cdecl NyrHeadlessExitCode() noexcept { return EXIT_CODE; }
NYR_HEADLESS_API int __cdecl NyrHeadlessInitialize(const wchar_t* directory,DWORD timeout_ms) noexcept {
    if (InterlockedCompareExchange(&installed,1,0)!=0) return ERROR_ALREADY_INITIALIZED;
    if (!directory || !*directory || timeout_ms<100 || timeout_ms>10000) { installed=0; return ERROR_INVALID_PARAMETER; }
    wchar_t absolute[32768];
    const DWORD length=GetFullPathNameW(directory,32768,absolute,nullptr);
    const DWORD attributes=GetFileAttributesW(directory);
    if (!length || length>=32000 || attributes==INVALID_FILE_ATTRIBUTES || !(attributes&FILE_ATTRIBUTE_DIRECTORY) ||
        !(wcslen(directory)>=3 && directory[1]==L':' && (directory[2]==L'\\' || directory[2]==L'/'))) {
        installed=0; return ERROR_INVALID_PARAMETER;
    }
    wchar_t path[32768];
    FILETIME now; GetSystemTimeAsFileTime(&now);
    const auto stamp=(static_cast<unsigned long long>(now.dwHighDateTime)<<32)|now.dwLowDateTime;
    swprintf_s(path,L"%s\\nyr-crash-%lu-%llu.dmp",absolute,GetCurrentProcessId(),stamp);
    dump_file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    swprintf_s(path,L"%s\\nyr-crash-%lu-%llu.json",absolute,GetCurrentProcessId(),stamp);
    report_file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    requested=CreateEventW(nullptr,TRUE,FALSE,nullptr); completed=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    if (dump_file==INVALID_HANDLE_VALUE || report_file==INVALID_HANDLE_VALUE || !requested || !completed) {
        const int error=static_cast<int>(GetLastError()); close_setup(); installed=0; return error?error:ERROR_OPEN_FAILED;
    }
    deadline=timeout_ms;
    // Loading libraries and resolving APIs is initialization work, never crash work.
    HMODULE user=LoadLibraryW(L"user32.dll"), kernel=GetModuleHandleW(L"kernel32.dll");
    if (!user || !kernel || MH_Initialize()!=MH_OK) { close_setup(); installed=0; return ERROR_NOT_SUPPORTED; }
    Hook hooks[]={
        {kernel,"SetErrorMode",reinterpret_cast<void*>(hook_SetErrorMode),reinterpret_cast<void**>(&real_SetErrorMode)},
        {kernel,"SetUnhandledExceptionFilter",reinterpret_cast<void*>(hook_SetUnhandledExceptionFilter),reinterpret_cast<void**>(&real_SetUnhandledExceptionFilter)},
        {user,"MessageBoxW",reinterpret_cast<void*>(hook_MessageBoxW),reinterpret_cast<void**>(&real_MessageBoxW)},
        {user,"MessageBoxA",reinterpret_cast<void*>(hook_MessageBoxA),reinterpret_cast<void**>(&real_MessageBoxA)},
    };
    auto rollback=[&]() noexcept {
        for (auto& h:hooks) if (h.target) MH_RemoveHook(h.target);
        MH_Uninitialize(); close_setup();
        real_SetErrorMode=SetErrorMode; real_SetUnhandledExceptionFilter=SetUnhandledExceptionFilter;
        real_MessageBoxW=MessageBoxW; real_MessageBoxA=MessageBoxA;
        installed=0;
    };
    for (auto& h:hooks) {
        h.target=reinterpret_cast<void*>(GetProcAddress(h.module,h.name));
        if (!h.target || MH_CreateHook(h.target,h.callback,h.original)!=MH_OK || MH_QueueEnableHook(h.target)!=MH_OK) {
            rollback(); return ERROR_NOT_SUPPORTED;
        }
    }
    // Pin callback code for process lifetime. No unsafe unload or global teardown.
    HMODULE pinned;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&NyrHeadlessInitialize),&pinned)) { rollback(); return ERROR_INVALID_HANDLE; }
    real_SetErrorMode(GetErrorMode()|REQUIRED_MODE);
    real_SetUnhandledExceptionFilter(filter);
    MH_STATUS applied=MH_ApplyQueued();
#ifdef NYR_HEADLESS_TEST_APPLY_FAILURE
    // Separate owned-host build: simulate failure after hooks became live.
    applied=MH_ERROR_MEMORY_PROTECT;
#endif
    if (applied!=MH_OK) {
        // ApplyQueued can fail after enabling earlier hooks, and removal can
        // fail too. Never free live callback state or reset live trampolines.
        terminate();
    }
    HANDLE thread=CreateThread(nullptr,0,writer,nullptr,0,nullptr);
    if (!thread) {
        // Hooks are live: preserving pinned state is safer than freeing callbacks.
        terminate();
    }
    CloseHandle(thread);
    installed=2;
    return ERROR_SUCCESS;
}
BOOL APIENTRY DllMain(HMODULE module,DWORD event,LPVOID) {
    if (event==DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}
