#!/data/data/com.termux/files/usr/bin/bash
exec python -u ~/FSE-Proyecto/boveda-hmi/puente_usb.py "$@" > ~/FSE-Proyecto/boveda-hmi/usb_debug.log 2>&1
