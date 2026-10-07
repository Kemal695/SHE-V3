"""Test whether CreateFile on pipes matching Dart's naming pattern is blocked.

Facts established so far:
  * The OS happily creates 4000 uniquely-named pipes -> not global exhaustion.
  * Only 214 pipe names exist, 1 instance each -> no name is saturated.
  * `dart analyze` still fails with ERROR_PIPE_BUSY (231) on CreateFile, both
    inside and outside the tool sandbox.

So something is *selectively* failing certain pipe opens. Dart's stdio uses
inheritable anonymous pipes (CreatePipe), whereas the analyzer handshake uses a
named pipe built from client-id + username. Approximate both here.
"""
import ctypes
import os
import getpass

k = ctypes.WinDLL("kernel32", use_last_error=True)
k.CreateFileW.restype = ctypes.c_void_p
k.CreateFileW.argtypes = [
    ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
    ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
]
k.CloseHandle.argtypes = [ctypes.c_void_p]

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID = 0xFFFFFFFFFFFFFFFF


def try_open(path, access=GENERIC_READ | GENERIC_WRITE):
    h = k.CreateFileW(path, access, 0, None, OPEN_EXISTING, 0, None)
    if h is None or h == INVALID or h == 0xFFFFFFFF:
        return None, ctypes.get_last_error()
    k.CloseHandle(h)
    return True, 0


# 1) Anonymous pipe via CreatePipe — the path Process.start uses for stdio.
k.CreatePipe.argtypes = [ctypes.POINTER(ctypes.c_void_p),
                         ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
k.CreatePipe.restype = ctypes.c_int
r = ctypes.c_void_p()
w = ctypes.c_void_p()
ok = k.CreatePipe(ctypes.byref(r), ctypes.byref(w), None)
print("CreatePipe (anonymous):", "OK" if ok else f"FAIL err={ctypes.get_last_error()}")
if ok:
    k.CloseHandle(r)
    k.CloseHandle(w)

# 2) Open an existing well-known pipe that is currently idle.
for name in ["lsass", "eventlog", "InitShutdown"]:
    res, err = try_open("\\\\.\\pipe\\" + name)
    print(f"open \\\\.\\pipe\\{name}:", "OK" if res else f"FAIL err={err}")

# 3) Dart's analyzer pipe shape (client-id + user), which does not exist yet.
user = getpass.getuser()
for cand in [
    f"\\\\.\\pipe\\dart_analyzer_{user}",
    f"\\\\.\\pipe\\dart_analyzer",
    f"\\\\.\\pipe\\sdk_analyzer_{user}",
]:
    res, err = try_open(cand)
    print(f"open {cand}:", "OK" if res else f"FAIL err={err} (expected: does not exist)")

# 4) Can we CREATE a server-side pipe with Dart's shape, then open it?
PIPE_ACCESS_DUPLEX = 0x3
k.CreateNamedPipeW.restype = ctypes.c_void_p
k.CreateNamedPipeW.argtypes = [
    ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
    ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
]
dartish = f"\\\\.\\pipe\\dart_analyzer_probe_{user}"
h = k.CreateNamedPipeW(dartish, PIPE_ACCESS_DUPLEX, 0, 1, 4096, 4096, 0, None)
if h is None or h == INVALID or h == 0xFFFFFFFF:
    print(f"CreateNamedPipe '{dartish}': FAIL err={ctypes.get_last_error()}")
else:
    print(f"CreateNamedPipe '{dartish}': OK")
    k.CloseHandle(h)

print("user:", user)
print("cwd:", os.getcwd())
