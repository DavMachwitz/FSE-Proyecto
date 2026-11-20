import asyncio
import glob
import serial
import websockets

BAUD_RATE = 9600
WS_PORT = 8765

def buscar_puerto_serial():
    puertos = glob.glob('/dev/ttyUSB*') + glob.glob('/dev/ttyACM*')
    return puertos[0] if puertos else None

async def manejar_conexion(websocket):
    puerto_path = buscar_puerto_serial()
    ser = None

    if puerto_path:
        try:
            ser = serial.Serial(puerto_path, BAUD_RATE, timeout=0.05)
            print(f"[USB] Conectado a {puerto_path} @ {BAUD_RATE} bps")
        except Exception as e:
            print(f"[USB ERROR] No se pudo abrir {puerto_path}: {e}")
    else:
        print("[MODO SIMULACIÓN] Sin cable USB conectado. Solo eco en consola.")

    async def leer_desde_usb():
        while True:
            if ser and ser.in_waiting > 0:
                data = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
                if data:
                    print(f"[USB -> WEB]: {repr(data)}")
                    await websocket.send(data)
            await asyncio.sleep(0.02)

    tarea_lectura = asyncio.create_task(leer_desde_usb())

    try:
        async for mensaje in websocket:
            print(f"[WEB -> USB]: {repr(mensaje)}")
            if ser and ser.is_open:
                ser.write(mensaje.encode('utf-8'))
    except websockets.exceptions.ConnectionClosed:
        print("[WEB] Interfaz desconectada.")
    finally:
        tarea_lectura.cancel()
        if ser and ser.is_open:
            ser.close()

async def main():
    print(f"Puente WebSocket activo en ws://127.0.0.1:{WS_PORT}")
    async with websockets.serve(manejar_conexion, "127.0.0.1", WS_PORT):
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())