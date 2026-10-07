"""Determine whether this Windows host has truly exhausted its pipe resources.

Dart's analyzer spawns dartaotruntime.exe and fails with:
    CreateFile failed 231 (All pipe instances are busy)
    ProcessException: All pipe instances are busy (process_win.cc:744)

Error 231 is ERROR_PIPE_BUSY. It is reported when CreateNamedPipe cannot create
another instance of a pipe NAME, or when CreateFile finds every existing instance
of that name busy. To tell "global OS pipe exhaustion" apart from "one specific
named pipe is saturated", create many uniquely-named pipes and see whether we can.
"""
import ctypes

ERROR_INVALID_NAME = 123
ERROR_PIPE_BUSY = 231
INVALID = 0xFFFFFFFFFFFFFFFF

k = ctypes.WinDLL("kernel32", use_last_error=True)
k.CreateNamedPipeW.restype = ctypes.c_void_p
k.CloseHandle.restype = ctypes.c_int
k.CloseHandle.argtypes = [ctypes.c_void_p]

PIPE_ACCESS_DUPLEX = 0x00000003

prefix = "\\\\.\\pipe\\she_pipe_probe_"
handles = []
fail_at = None
fail_err = None

for i in range(4000):
    name = prefix + str(i)
    h = k.CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX, 0, 1, 4096, 4096, 0, None)
    if h is None or h == INVALID or h == 0xFFFFFFFF:
        fail_at = i
        fail_err = ctypes.get_last_error()
        break
    handles.append(h)

print("created unique pipe instances:", len(handles))
if fail_at is None:
    print("no cap reached within 4000 unique pipes")
else:
    print("first failure at index", fail_at, "GetLastError =", fail_err)
    if fail_err == ERROR_INVALID_NAME:
        print("  -> ERROR_INVALID_NAME: the NAME was rejected (probe bug, not exhaustion)")
    elif fail_err == ERROR_PIPE_BUSY:
        print("  -> ERROR_PIPE_BUSY: pipe resources really are exhausted")
    else:
        print("  -> unexpected error")

for h in handles:
    k.CloseHandle(h)
print("closed all")
