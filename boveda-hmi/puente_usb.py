import asyncio
import os
import struct
import sys
import usb.core
import usb.backend.libusb1
import websockets

BAUD_RATE = 9600
WS_PORT = 8765

class CP2102Termux:
    def __init__(self, fd):
        # Inicializa libusb sin enumerar el bus completo (restriccion Android sin root)
        backend = usb.backend.libusb1.get_backend()
        backend.lib.libusb_set_option(backend.ctx, 2)  # LIBUSB_OPTION_NO_DEVICE_DISCOVERY = 2
        self.dev = usb.core.find(backend=backend, custom_match=lambda d: True)
        # Wrap directo del file descriptor entregado por termux-usb
        self.handle = backend.lib.libusb_wrap_sys_device
        self._init_cp2102_raw(fd)

    def _init_cp2102_raw(self, fd):
        # Usa pyusb wrap_sys_device si está disponible en libusb1
        backend = usb.backend.libusb1.get_backend()
        self.dev = usb.core.Device(
            usb.backend.libusb1._Device(backend.ctx, None), backend
        )
        import ctypes
        dev_handle = ctypes.c_void_p()
        res = backend.lib.libusb_wrap_sys_device(backend.ctx, ctypes.c_intptr(fd), ctypes.byref(dev_handle))
        if res != 0:
            raise RuntimeError(f"Error libusb_wrap_sys_device: {res}")
        self._lib = backend.lib
        self._dh = dev_handle

        # Claim interface 0
        self._lib.libusb_claim_interface(self._dh, 0)

        # 1. Habilitar UART en CP2102 (bmRequestType=0x41, bRequest=0x00, wValue=0x0001)
        self._ctrl_transfer(0x41, 0x00, 0x0001, 0, b"")
        # 2. Configurar 9600 baudios (bRequest=0x1E, 4 bytes little-endian)
        baud_bytes = struct.pack("<I", BAUD_RATE)
        self._ctrl_transfer(0x41, 0x1E, 0x0000, 0, baud_bytes)
        # 3. 8N1 (bRequest=0x03, wValue=0x0800 -> 8 bits, sin paridad, 1 stop bit)
        self._ctrl_transfer(0x41, 0x03, 0x0800, 0, b"")

    def _ctrl_transfer(self, req_type, req, val, idx, data):
        import ctypes
        buf = ctypes.create_string_buffer(data, len(data))
        self._lib.libusb_control_transfer(
            self._dh, req_type, req, val, idx, buf, len(data), 1000
        )

    def write(self, data: bytes):
        import ctypes
        buf = ctypes.create_string_buffer(data, len(data))
        transferred = ctypes.c_int()
        # Endpoint Bulk OUT estándar del CP2102 = 0x01
        self._lib.libusb_bulk_transfer(
            self._dh, 0x01, buf, len(data), ctypes.byref(transferred), 500
        )

    def read_nonblocking(self) -> bytes:
        import ctypes
        buf = ctypes.create_string_buffer(64)
        transferred = ctypes.c_int()
        # Endpoint Bulk IN estándar del CP2102 = 0x81, timeout corto 20ms
        res = self._lib.libusb_bulk_transfer(
            self._dh, 0x81, buf, 64, ctypes.byref(transferred), 20
        )
        if res == 0 and transferred.value > 0:
            return buf.raw[:transferred.value]
        return b""

cp2102 = None

async def manejar_conexion(websocket):
    print("[WEB] Interfaz HMI conectada al puente.")

    async def leer_desde_usb():
        while True:
            if cp2102:
                try:
                    raw = cp2102.read_nonblocking()
                    if raw:
                        texto = raw.decode("utf-8", errors="ignore")
                        if texto:
                            print(f"[USB -> WEB]: {repr(texto)}")
                            await websocket.send(texto)
                except Exception:
                    pass
            await asyncio.sleep(0.02)

    tarea_lectura = asyncio.create_task(leer_desde_usb())

    try:
        async for mensaje in websocket:
            print(f"[WEB -> USB]: {repr(mensaje)}")
            if cp2102:
                cp2102.write(mensaje.encode("utf-8"))
    except websockets.exceptions.ConnectionClosed:
        print("[WEB] Interfaz desconectada.")
    finally:
        tarea_lectura.cancel()

async def main():
    global cp2102
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        fd = int(sys.argv[1])
        cp2102 = CP2102Termux(fd)
        print(f"[USB REAL] CP2102 inicializado a {BAUD_RATE} bps (FD={fd})")
    else:
        print("[MODO SIMULACION] Ejecuta via termux-usb para hardware real.")

    print(f"Puente WebSocket activo en ws://127.0.0.1:{WS_PORT}")
    async with websockets.serve(manejar_conexion, "127.0.0.1", WS_PORT):
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())