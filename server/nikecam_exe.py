"""NikeCam — All-in-one launcher: USB tunnel (thread) + streaming server.

PyInstaller entry point. Double-click the built NikeCam.exe:
- starts the USB tunnel (PC 8767 <-> iPhone 8767) with auto-retry
- starts the streaming server + dashboard (http://localhost:8080)
"""
import asyncio
import sys
import threading
import time


def run_tunnel():
    """USB-Tunnel mit Auto-Retry (ohne iPhone: klare Meldung, weiter versuchen)."""
    try:
        from pymobiledevice3.tcp_forwarder import UsbmuxTcpForwarder
    except ImportError:
        print("[Tunnel] pymobiledevice3 fehlt — iPhone-USB-Verbindung nicht moeglich.")
        return

    async def _run():
        fwd = UsbmuxTcpForwarder(None, 8767, 8767)
        print("[Tunnel] OK — PC 8767 <-> iPhone 8767")
        await fwd.start(address="127.0.0.1")

    while True:
        try:
            asyncio.run(_run())
        except Exception as e:
            print(f"[Tunnel] Kein iPhone gefunden ({type(e).__name__}) — Retry in 2s ...")
        time.sleep(2)


def main():
    print("=" * 46)
    print("  NikeCam — Virtual Camera for iPhone")
    print("=" * 46)
    threading.Thread(target=run_tunnel, daemon=True).start()

    import server
    try:
        asyncio.run(server.main())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
