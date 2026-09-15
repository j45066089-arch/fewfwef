# VCamUSB-v2

Stream PC video/audio über USB als virtuelle Kamera auf ein gejailbreaktes iPhone.

## Features

- ✅ Preview-Modus (Live-Vorschau in Kamera-App)
- ✅ Foto-Aufnahme mit PC-Bild
- 🚧 Video-Recording (in Arbeit)
- 🚧 Audio-Stream (geplant)

## Hardware

- iPhone mit iOS 16.7.16 und Dopamine2-roothide Jailbreak
- Windows/macOS/Linux PC mit USB-Verbindung

## Installation

### iPhone

```bash
# DEB installieren
scp -P 2222 packages/*.deb root@127.0.0.1:/var/root/
ssh -p 2222 root@127.0.0.1
dpkg -i /var/root/com.shosh.vcaminject_*.deb
killall mediaserverd
```

### PC-Server

```bash
cd server
pip install opencv-python numpy websocket-client
python usb_tunnel_8767.py &  # USB-Tunnel starten
python server.py --source webcam  # oder --source file --video test.mp4
```

## Verwendung

1. Server auf PC starten
2. Kamera-App auf iPhone öffnen
3. Preview zeigt PC-Bild
4. Foto aufnehmen → PC-Bild wird gespeichert

## Status prüfen

```bash
echo "status" | nc 127.0.0.1 8769
```

## Architektur

```
PC: OBS/Webcam/Datei
  → H.264 Encoder (420f)
  → WebSocket :8767
  → USB-Tunnel
  → iPhone mediaserverd
  → VideoToolbox Decoder
  → BWNodeOutput emitSampleBuffer:
  → Preview/Foto/Recording
```

## Build

GitHub Actions baut automatisch bei jedem Push. Oder lokal mit Theos:

```bash
cd tweak
make clean package
```
