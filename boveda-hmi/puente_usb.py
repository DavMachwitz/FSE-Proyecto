import asyncio
import ctypes
import os
import struct
import sys
import usb.core
import usb.backend.libusb1
import websockets

BAUD_RATE = 9600
WS_PORT = 8765
LP_UBYTE = ctypes.POINTER(ctypes.c_ubyte)

class CP2102Termux:
    def __init__(self, fd):
        backend = usb.backend.libusb1.get_backend()
        backend.lib.libusb_set_option(backend.ctx, 2)

        backend.lib.libusb_wrap_sys_device.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ssize_t,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        backend.lib.libusb_wrap_sys_device.restype = ctypes.c_int

        dev_handle = ctypes.c_void_p()
        res = backend.lib.libusb_wrap_sys_device(
            backend.ctx, ctypes.c_ssize_t(fd), ctypes.byref(dev_handle)
        )
        if res != 0:
            raise RuntimeError(f"Error libusb_wrap_sys_device: {res}")
        self._lib = backend.lib
        self._dh = dev_handle

        self._lib.libusb_detach_kernel_driver(self._dh, 0)
        claim_res = self._lib.libusb_claim_interface(self._dh, 0)
        print(f"[USB] claim_interface(0) -> {claim_res}", flush=True)

        self._ctrl_transfer(0x41, 0x00, 0x0001, 0, b"")
        self._ctrl_transfer(0x41, 0x1E, 0x0000, 0, struct.pack("<I", BAUD_RATE))
        self._ctrl_transfer(0x41, 0x03, 0x0800, 0, b"")

    def _ctrl_transfer(self, req_type, req, val, idx, data: bytes):
        if data:
            arr = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
            ptr = ctypes.cast(arr, LP_UBYTE)
        else:
            ptr = LP_UBYTE()
        res = self._lib.libusb_control_transfer(
            self._dh, req_type, req, val, idx, ptr, len(data), 1000
        )
        if res < 0:
            print(f"[USB CTRL WARN] req={hex(req)} -> {res}", flush=True)

    def write(self, data: bytes):
        arr = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
        ptr = ctypes.cast(arr, LP_UBYTE)
        transferred = ctypes.c_int()
        res = self._lib.libusb_bulk_transfer(
            self._dh, 0x01, ptr, len(data), ctypes.byref(transferred), 500
        )
        print(f"[USB TX] res={res}, bytes={transferred.value}, data={data}", flush=True)

    def read_nonblocking(self) -> bytes:
        arr = (ctypes.c_ubyte * 64)()
        ptr = ctypes.cast(arr, LP_UBYTE)
        transferred = ctypes.c_int()
        res = self._lib.libusb_bulk_transfer(
            self._dh, 0x81, ptr, 64, ctypes.byref(transferred), 20
        )
        if res == 0 and transferred.value > 0:
            return bytes(arr[:transferred.value])
        return b""

cp2102 = None

async def manejar_conexion(websocket):
    print("[WEB] Interfaz HMI conectada al puente.", flush=True)

    async def leer_desde_usb():
        while True:
            if cp2102:
                try:
                    raw = cp2102.read_nonblocking()
                    if raw:
                        texto = raw.decode("utf-8", errors="ignore")
                        if texto:
                            print(f"[USB -> WEB]: {repr(texto)}", flush=True)
                            await websocket.send(texto)
                except Exception:
                    pass
            await asyncio.sleep(0.02)

    tarea_lectura = asyncio.create_task(leer_desde_usb())

    try:
        async for mensaje in websocket:
            print(f"[WEB -> USB]: {repr(mensaje)}", flush=True)
            if cp2102:
                cp2102.write(mensaje.encode("utf-8"))
    except websockets.exceptions.ConnectionClosed:
        print("[WEB] Interfaz desconectada.", flush=True)
    finally:
        tarea_lectura.cancel()

async def main():
    global cp2102
    fd_str = os.environ.get("TERMUX_USB_FD") or (sys.argv[1] if len(sys.argv) > 1 else "")
    print(f"[INIT] fd_str={repr(fd_str)}, argv={sys.argv}", flush=True)

    server = await websockets.serve(manejar_conexion, "0.0.0.0", WS_PORT)
    print(f"[WS] Servidor WebSocket escuchando en puerto {WS_PORT}", flush=True)

    if fd_str.isdigit():
        fd = int(fd_str)
        try:
            cp2102 = CP2102Termux(fd)
            print(f"[USB REAL] CP2102 listo a {BAUD_RATE} bps (FD={fd})", flush=True)
        except Exception as e:
            print(f"[USB ERROR] Fallo al abrir CP2102: {e}", flush=True)
    else:
        print("[MODO SIMULACION] Sin FD numerico.", flush=True)

    await server.wait_closed()

if __name__ == "__main__":
    asyncio.run(main())
