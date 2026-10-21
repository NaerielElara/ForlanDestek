import ctypes
from ctypes import wintypes

kernel = ctypes.WinDLL('kernel32', use_last_error=True)
kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
kernel.CreateFileW.restype = wintypes.HANDLE
kernel.GetNamedPipeServerProcessId.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.ULONG)]
kernel.GetNamedPipeServerProcessId.restype = wintypes.BOOL
kernel.CloseHandle.argtypes = [wintypes.HANDLE]

for name in ('query', 'query_service'):
    handle = kernel.CreateFileW('\\\\.\\pipe\\ForlanDestek\\' + name, 0x80000000 | 0x40000000, 0, None, 3, 0, None)
    if handle == wintypes.HANDLE(-1).value:
        print(name, 'open error', ctypes.get_last_error())
        continue
    pid = wintypes.ULONG()
    if kernel.GetNamedPipeServerProcessId(handle, ctypes.byref(pid)):
        print(name, 'server pid', pid.value)
    else:
        print(name, 'pid error', ctypes.get_last_error())
    kernel.CloseHandle(handle)
