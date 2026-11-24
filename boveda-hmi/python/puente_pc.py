import asyncio
import serial
import serial.tools.list_ports
import websockets

BAUDIOS = 9600
PUERTO_WS = 8765
PUERTO_FORZADO = "COM12"  # Ej: "COM4" en Windows o "/dev/ttyUSB0" en Linux

def detectar_puerto():
    if PUERTO_FORZADO:
        return PUERTO_FORZADO
    for p in serial.tools.list_ports.comports():
        desc = (p.description or "").lower()
        if "cp210" in desc or "silicon labs" in desc or "uart" in desc or "usb" in desc:
            return p.device
    raise RuntimeError("No se encontró el CP2102. Conéctalo o pon el puerto en PUERTO_FORZADO.")

async def manejar_conexion(ws, ser):
    print("[WS] HMI conectada en ws://127.0.0.1:8765")

    async def leer_serial():
        while True:
            if ser.in_waiting > 0:
                dato = ser.read(ser.in_waiting).decode("ascii", errors="ignore")
                if dato:
                    print(f"[FPGA -> WEB]: {repr(dato)}")
                    await ws.send(dato)
            await asyncio.sleep(0.02)

    async def leer_ws():
        async for msg in ws:
            print(f"[WEB -> FPGA]: {repr(msg)}")
            ser.write(str(msg).encode("ascii"))

    t1 = asyncio.create_task(leer_serial())
    t2 = asyncio.create_task(leer_ws())
    done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()
    print("[WS] HMI desconectada.")

async def main():
    puerto = detectar_puerto()
    print(f"[SERIAL] Abriendo {puerto} @ {BAUDIOS} bps...")
    ser = serial.Serial(puerto, BAUDIOS, timeout=0.05)

    async with websockets.serve(lambda ws: manejar_conexion(ws, ser), "127.0.0.1", PUERTO_WS):
        print(f"[LISTO] Puente activo en ws://127.0.0.1:{PUERTO_WS}")
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())