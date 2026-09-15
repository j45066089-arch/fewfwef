"""Parser-Test: Annex-B-Stream aus der echten ffmpeg-Pipe korrekt in
SPS/PPS-Roh-NALs + AVCC-Access-Units zerlegen.

Simuliert exakt den FramePusher-Loop (chunked read + Startcode-Split).
Erwartung: SPS(24B)+PPS(4B) einmalig, danach AUs aus SEI+VCL-NALs.
"""
import glob
import os

TEMP = os.environ.get("TEMP", "/tmp")
pipes = sorted(glob.glob(os.path.join(TEMP, "vcam_out_*.h264")),
               key=os.path.getmtime)
pipe = pipes[-1]
print("Test-Pipe:", pipe, os.path.getsize(pipe), "Bytes")


def find_start_codes(buf):
    pos = []
    i = 0
    n = len(buf)
    while i < n - 2:
        if buf[i] == 0 and buf[i + 1] == 0:
            if buf[i + 2] == 1:
                pos.append((i, 3))
                i += 3
                continue
            elif i + 3 < n and buf[i + 2] == 0 and buf[i + 3] == 1:
                pos.append((i, 4))
                i += 4
                continue
        i += 1
    return pos


def nal_type(nal):
    return nal[0] & 0x1f if nal else 0


sps = pps = None
aus = 0
first_au_nals = []
buf = b""
cur_au = []

f = open(pipe, "rb")
processed = 0
while processed < 6_000_000:   # nur die ersten 6 MB
    chunk = f.read(64 * 1024)
    if not chunk:
        break
    buf += chunk
    positions = find_start_codes(buf)
    if len(positions) < 2:
        continue                      # unvollständiger Tail — warten
    last_start = positions[-1][0]
    complete = buf[:last_start]
    buf = buf[last_start:]
    # NALs aus complete extrahieren
    nals = []
    sc = find_start_codes(complete)
    for idx, (p, l) in enumerate(sc):
        end = sc[idx + 1][0] if idx + 1 < len(sc) else len(complete)
        nal = complete[p + l:end]
        if nal:
            nals.append(nal)
    for nal in nals:
        t = nal_type(nal)
        if t == 7:
            sps = nal
        elif t == 8:
            pps = nal
        elif t == 9:
            if cur_au:
                aus += 1
                if aus == 1:
                    first_au_nals = [nal_type(x) for x in cur_au]
                cur_au = []
        elif t in (1, 5, 6):
            cur_au.append(nal)
    processed += len(chunk)
f.close()

print(f"Ergebnis: sps={len(sps)}B pps={len(pps)}B aus={aus}")
print("Erste AU (NAL-Typen):", first_au_nals)
assert sps and len(sps) == 24, "SPS fehlt oder falsche Größe"
assert pps and len(pps) == 4, "PPS fehlt oder falsche Größe"
assert aus > 0, "keine Access Units erzeugt"
assert first_au_nals and first_au_nals[0] == 6, "erste AU sollte mit SEI beginnen"
print("PARSER TEST BESTANDEN")
