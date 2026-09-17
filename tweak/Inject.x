// VCamInject — Frame-Swap in mediaserverd (Dopamine2-roothide)
//
// ---------------------------------------------------------------- Build-ID für Artefakt-Identifikation
#define VCAM_BUILD_ID "metafix-2026-09-17-01"

// Pipeline: WS-Client (8767) → NAL-Queue → H.264-Decode (VideoToolbox, AVCC)
//           → CVPixelBuffer → buildSwapSampleBuffer → FigCapture-Hook
//
// TELEMETRIE: Status-Server auf 127.0.0.1:8769 liefert atomare Zähler.
//   rxNal sps pps idr formatDesc decodeSubmit decodeOutput decodeError
//   emitCalls sendCalls buildCalls swapCount origCount hasLatestFrame
//
// WICHTIG (Decoder-Fix): Der PC sendet rohe NALs OHNE Startcode. Die
// Format-Description wird als AVCC erstellt (lengthSize=4). Deshalb müssen
// die Samples ebenfalls AVCC-formatiert sein: [4-Byte-Länge][NAL] — NICHT
// Annex-B (00 00 00 01). Vorher wurde Annex-B-Startcode an eine AVCC-Desc
// übergeben → Decoder lieferte nie Frames.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <stdatomic.h>
#import <time.h>
#import <os/log.h>
#import <pthread.h>

#define WS_PORT 8767
#define STATUS_PORT 8769

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.nikeboy.vcam", "inject"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Telemetrie (atomar)
static _Atomic uint64_t g_wsBinaryCount = 0;
static _Atomic uint64_t g_wsTextCount = 0;
static _Atomic uint64_t g_wsBytesReceived = 0;
static _Atomic uint64_t g_wsFramesDropped = 0;
static _Atomic uint64_t g_rxNalCount = 0;
static _Atomic uint64_t g_spsCount = 0;
static _Atomic uint64_t g_ppsCount = 0;
static _Atomic uint64_t g_idrCount = 0;
static _Atomic uint64_t g_formatDescCount = 0;
static _Atomic uint64_t g_decodeSubmitCount = 0;
static _Atomic uint64_t g_decodeOutputCount = 0;
static _Atomic uint64_t g_decodeErrorCount = 0;
static _Atomic uint64_t g_emitCalls = 0;
static _Atomic uint64_t g_sendCalls = 0;
static _Atomic uint64_t g_buildCalls = 0;
static _Atomic uint64_t g_swapCount = 0;
static _Atomic uint64_t g_swapSizeMismatch = 0;
static _Atomic uint64_t g_origCount = 0;
static _Atomic uint64_t g_hasLatestFrame = 0;
static _Atomic uint64_t g_vtSessionAttempts = 0;
static _Atomic int64_t g_vtSessionError = 0;
static char g_methodDump[4096] = {0};
static char g_methodDump2[4096] = {0};
static char g_copyClasses[4096] = {0};
static char g_sinkClasses[8192] = {0};
static char g_selectorDump[8192] = {0};

// Modus-Steuerung über WS-Textnachrichten (Marker-Dateien funktionieren nicht,
// weil mediaserverd eine andere /tmp-Sicht hat als die SSH-Shell!)
static _Atomic int g_modeBW = 1;
static _Atomic int g_replacementEnabled = 1;
static _Atomic int g_useCountDelay = 1;   // "urel=N": 1=66ms-Verzögerung, 0=sofort
static _Atomic int g_diag = 1;            // "diag=N": 0 = Tracking/Logging pro Frame aus
// VIDEO-DRIVEN METADATA (Schritt 1: Frame-Metadaten-Konsistenz für KYC-Checks)
static _Atomic int g_metaOn = 1;          // "mdon=N": MetadataDictionary-Umschreiben
static _Atomic int64_t g_videoLuma = 0;   // mittlere Luminanz des OBS-Frames (0-255)
static _Atomic int64_t g_videoLux = 0;    // daraus abgeleitetes LuxLevel
static float g_metaExposure = 0.008333f;  // "expt=" Belichtungszeit (Sekunden)
static float g_metaSnr = 24.0f;           // "snr=" Rauschmaß (dB-artig)
static _Atomic int64_t g_metaIso = 0;     // "iso=" (0 = auto aus LuxLevel)
static _Atomic int g_photoInProgress = 0;
static _Atomic int g_recordingInProgress = 0;
static _Atomic uint64_t g_swapSkippedPhoto = 0;
static _Atomic uint64_t g_swapSkippedRecording = 0;
static _Atomic int g_modeWrapOrig = 0;
static _Atomic int g_modeTestPattern = 0;
static _Atomic int g_modeFigEmit = 0;
static _Atomic int g_modeFigSend = 0;
static _Atomic uint64_t g_figEmitReplacements = 0;
static _Atomic uint64_t g_figSendReplacements = 0;
static _Atomic uint64_t g_photoSwaps = 0;
// GUARD (Recording): 420v-Buffer (Video-Range) werden NICHT geswappt.
// Zählt nur Treffer des neuen Early-Out in swapPixelsInPlace.
static _Atomic uint64_t g_skip420v = 0;
// GUARD (Preview): Porträt-Buffer (h>w) werden NICHT direkt geswappt —
// sie sind Post-Rotations-Ableitungen des geswappten Sensor-Feeds.
static _Atomic uint64_t g_skipPortrait = 0;
// ROT-MODUS (Status-Port "rot=N"): 0=aus (Center-Crop), 1=90°CW,
// 2=90°CCW, 3=180° — Fill-Rotation für alle Landscape-Ziele (420f).
static _Atomic int64_t g_rotMode = 1;
// VIDEO-PFAD (420v) nach Größenklasse getrennt:
//   g_rotVidMode: 420v AUßER 1920x1080 (Live-Preview-Feed 2304x1296) — CW.
//   g_rotEncMode: 420v 1920x1080 (Encoder-Feed) — CW (per Quadranten-Test
//   verifiziert: CW-Inhalt + App-Matrix/Spiegel = aufrecht).
static _Atomic int64_t g_rotVidMode = 1;
static _Atomic int64_t g_rotEncMode = 1;
// RANGE-KONVERTIERUNG (Status-Port "rng=N"): 0=aus (Pipeline behandelt die
// 420v-Buffer intern als Full-Range — Konvertieren wäscht Farben aus),
// 1=an (Full->Video wie früher).
static _Atomic int64_t g_rangeConv = 0;
static _Atomic uint64_t g_rotApplied = 0;
// ANTI-FLACKERN: mehrere Node-Outputs teilen sich dieselbe IOSurface.
static _Atomic int64_t g_lastSurfID = 0;
static _Atomic int64_t g_lastPts = 0;
static _Atomic uint64_t g_dupSkip = 0;

// ---------------------------------------------------------------- Stufen-Isolation (Astra)
// stage 0: passiv — nur Status-Server, Hook läuft NICHT aktiv, kein WS/Decoder
// stage 1: BWNodeOutput-Hook passiv (Pro-Objekt-Telemetrie, KEIN Pixel-Swap)
// stage 2: zusätzlich WS-Client + Decoder aktiv (weiterhin KEIN Swap)
// stage 3: voller in-place Pixel-Swap
// Steuerung über TCP-Status-Port 8769: "stage=N" (unabhängig von WS/Hub!)
static _Atomic int g_stage = 0;

// ---------------------------------------------------------------- Sink-Beobachtung (Astra: Video-/Recording-/Foto-Pfade)
// Aus syslog_full.txt verifizierte echte Sink-Klassen in mediaserverd:
//   BWImageQueueSinkNode           -> renderSampleBuffer:forInput:  (PREVIEW, "Did display first frame")
//   BWQuickTimeMovieFileSinkNode   -> Recording-Pfad
//   BWStillImageSampleBufferSinkNode -> Foto-Pfad
static _Atomic uint64_t g_iqCalls = 0;
static _Atomic uint64_t g_iqWithImage = 0;
static _Atomic uint64_t g_iqSwaps = 0;
static _Atomic int64_t g_iqWidth = 0, g_iqHeight = 0, g_iqFmt = 0, g_iqSurf = 0;
static _Atomic uint64_t g_qtCalls = 0;
static _Atomic int64_t g_qtWidth = 0, g_qtHeight = 0, g_qtFmt = 0, g_qtSurf = 0;
static _Atomic uint64_t g_stCalls = 0;
static _Atomic int64_t g_stWidth = 0, g_stHeight = 0, g_stFmt = 0, g_stSurf = 0;

// Orientierungs-/Attachment-Diagnose (Astra: am Original-SampleBuffer des
// BWImageQueueSinkNode auslesen, um Rotation/Transform zu verstehen).
static char g_orientDump[4096] = {0};
static _Atomic int64_t g_orientDumped = 0;
// Zwei getrennte Dumps: Porträt-Größen 750x1000 (Foto) und 750x1334 (Video).
static char g_orientDump_video[4096] = {0};
static _Atomic int64_t g_orientDumped_video = 0;

// ---------------------------------------------------------------- Globals
static NSMutableArray<NSData *> *g_nalQueue = nil;
static NSLock *g_queueLock = nil;
static VTDecompressionSessionRef g_vtSession = NULL;
static CMFormatDescriptionRef g_fmtDesc = NULL;
static CVPixelBufferRef g_latestFrame = NULL;
static NSLock *g_frameLock = nil;

static void enqueueNal(NSData *nal) {
    if (nal.length < 4) return;
    [g_queueLock lock];
    [g_nalQueue addObject:nal];
    if (g_nalQueue.count > 128) [g_nalQueue removeObjectsInRange:NSMakeRange(0, g_nalQueue.count - 128)];
    [g_queueLock unlock];
}

static NSData *dequeueNal(void) {
    NSData *nal = nil;
    [g_queueLock lock];
    if (g_nalQueue.count) {
        nal = g_nalQueue.firstObject;
        [g_nalQueue removeObjectAtIndex:0];
    }
    [g_queueLock unlock];
    return nal;
}
// ---------------------------------------------------------------- Decoder
static _Atomic int64_t g_decodedFormat = 0;
static _Atomic int64_t g_decodedWidth = 0;
static _Atomic int64_t g_decodedHeight = 0;
static _Atomic int64_t g_decodedStride0 = 0;
static _Atomic int64_t g_decodedStride1 = 0;

static void decompressionOutputCallback(void *refCon, void *srcRef,
    OSStatus status, VTDecodeInfoFlags info, CVPixelBufferRef imageBuffer,
    CMTime pts, CMTime duration) {
    if (status != noErr) {
        atomic_fetch_add(&g_decodeErrorCount, 1);
        return;
    }
    if (!imageBuffer) return;
    atomic_fetch_add(&g_decodeOutputCount, 1);

    // Einmalig: tatsächliches Decoder-Output-Format messen (nicht raten)
    if (atomic_load(&g_decodedFormat) == 0) {
        OSType fmt = CVPixelBufferGetPixelFormatType(imageBuffer);
        size_t w = CVPixelBufferGetWidth(imageBuffer);
        size_t h = CVPixelBufferGetHeight(imageBuffer);
        size_t s0 = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
        size_t s1 = CVPixelBufferGetPlaneCount(imageBuffer) > 1
            ? CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1) : 0;
        atomic_store(&g_decodedFormat, (int64_t)fmt);
        atomic_store(&g_decodedWidth, (int64_t)w);
        atomic_store(&g_decodedHeight, (int64_t)h);
        atomic_store(&g_decodedStride0, (int64_t)s0);
        atomic_store(&g_decodedStride1, (int64_t)s1);
        L("DECODED fmt=0x%08x (%c%c%c%c) %zux%zu stride=%zu/%zu",
          (unsigned)fmt, (int)(fmt>>24)&0xff, (int)(fmt>>16)&0xff,
          (int)(fmt>>8)&0xff, (int)fmt&0xff, w, h, s0, s1);
    }

    [g_frameLock lock];
    if (g_latestFrame) CVPixelBufferRelease(g_latestFrame);
    g_latestFrame = CVPixelBufferRetain(imageBuffer);
    [g_frameLock unlock];
    atomic_store(&g_hasLatestFrame, 1);

    // VIDEO-DRIVEN METADATA: mittlere Luminanz des dekodierten Frames messen
    // (Sample alle 8 Pixel der Y-Plane) → LuxLevel für die Frame-Metadaten.
    if (atomic_load(&g_metaOn)) {
        CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
        size_t w = CVPixelBufferGetWidth(imageBuffer);
        size_t h = CVPixelBufferGetHeight(imageBuffer);
        if (y) {
            uint64_t sum = 0, cnt = 0;
            for (size_t yy = 0; yy < h; yy += 8) {
                for (size_t xx = 0; xx < w; xx += 8) {
                    sum += y[yy * stride + xx];
                    cnt++;
                }
            }
            uint32_t avg = cnt ? (uint32_t)(sum / cnt) : 0;
            // Luminanz 0-255 → LuxLevel (ca. 0-2040, passt zu Kamera-Metadaten)
            atomic_store(&g_videoLuma, (int64_t)avg);
            atomic_store(&g_videoLux, (int64_t)(avg * 8));
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    }
}

static void pumpDecoder(void) {
    @autoreleasepool {
        NSData *msg = dequeueNal();   // jetzt: SPS/PPS (roh) ODER komplette AU (AVCC)
        if (!msg) return;
        const uint8_t *bytes = (const uint8_t *)msg.bytes;
        uint8_t nalType = bytes[0] & 0x1f;

        atomic_fetch_add(&g_rxNalCount, 1);

        // SPS/PPS: rohe NAL, erstes Byte 0x67 (SPS) / 0x68 (PPS)
        if (nalType == 7 || nalType == 8) {
            if (nalType == 7) atomic_fetch_add(&g_spsCount, 1);
            else atomic_fetch_add(&g_ppsCount, 1);

            static NSMutableData *sps, *pps;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ sps = [NSMutableData data]; pps = [NSMutableData data]; });

            // Nur bei ÄNDERUNG speichern + Session neu aufbauen
            BOOL changed = NO;
            if (nalType == 7) {
                if (![sps isEqualToData:msg]) { [sps setData:msg]; changed = YES; }
            } else {
                if (![pps isEqualToData:msg]) { [pps setData:msg]; changed = YES; }
            }

            if (changed && sps.length && pps.length) {
                if (g_vtSession) { VTDecompressionSessionInvalidate(g_vtSession); CFRelease(g_vtSession); g_vtSession = NULL; }
                if (g_fmtDesc) { CFRelease(g_fmtDesc); g_fmtDesc = NULL; }

                const uint8_t *ptrs[2] = { (const uint8_t *)sps.bytes, (const uint8_t *)pps.bytes };
                size_t sizes[2] = { sps.length, pps.length };
                OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    kCFAllocatorDefault, 2, ptrs, sizes, 4, &g_fmtDesc);
                if (st == noErr && g_fmtDesc) {
                    atomic_fetch_add(&g_formatDescCount, 1);
                    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(g_fmtDesc);
                    L("FormatDescription OK %dx%d", (int)dims.width, (int)dims.height);
                } else {
                    L("FormatDescription FAIL: %d", (int)st);
                }
            }
            return;
        }

        // Komplette AU (AVCC: [4-byte len][NAL]...). NAL-Typ aus erster NAL nach Längenpräfix.
        if (g_fmtDesc == NULL) return;   // ohne SPS/PPS keine Decode möglich

        // --- VT-Session anlegen ---
        if (g_vtSession == NULL) {
            atomic_fetch_add(&g_vtSessionAttempts, 1);
            VTDecompressionOutputCallbackRecord cb;
            cb.decompressionOutputCallback = decompressionOutputCallback;
            cb.decompressionOutputRefCon = NULL;
            NSDictionary *attrs = @{
                (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, g_fmtDesc, NULL,
                (__bridge CFDictionaryRef)attrs, &cb, &g_vtSession);
            if (st != noErr || !g_vtSession) {
                atomic_store(&g_vtSessionError, st);
                L("VT-Session FAIL: %d", (int)st);
                return;
            }
            L("Decode-Session OK");
        }

        // AU ist bereits AVCC-formatiert -> direkt als BlockBuffer
        size_t auLen = (size_t)msg.length;
        uint8_t *blockBuf = malloc(auLen);
        if (!blockBuf) return;
        memcpy(blockBuf, msg.bytes, auLen);

        CMBlockBufferRef bb = NULL;
        OSStatus bbSt = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, blockBuf, auLen,
            kCFAllocatorDefault, NULL, 0, auLen, 0, &bb);
        if (bbSt != kCMBlockBufferNoErr || !bb) {
            L("BlockBuffer FAIL: %d", (int)bbSt);
            free(blockBuf);
            return;
        }

        // Samplegröße explizit angeben (Astras Korrektur)
        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = CMTimeMake((int64_t)atomic_load(&g_decodeSubmitCount), 30),
            .decodeTimeStamp = kCMTimeInvalid,
        };
        size_t sampleSize = auLen;
        CMSampleBufferRef sb = NULL;
        OSStatus sbSt = CMSampleBufferCreate(kCFAllocatorDefault, bb, true, NULL, NULL, g_fmtDesc,
            1, 1, &timing, 1, &sampleSize, &sb);
        CFRelease(bb);
        if (sbSt != noErr || !sb) {
            L("SampleBuffer FAIL: %d", (int)sbSt);
            return;
        }
        atomic_fetch_add(&g_decodeSubmitCount, 1);
        VTDecompressionSessionDecodeFrame(g_vtSession, sb, 0, NULL, NULL);
        CFRelease(sb);
    }
}

// ---------------------------------------------------------------- Frame-Swap (PASSTHROUGH)
// LordVCAM-Referenz: Decoder-Buffer DIREKT durchreichen, kein Kopieren/Skalieren.
// PC encodiert dafür nativ 1440x1080. Retain+Lock für sichere Lifetime.

static _Atomic int64_t g_passthroughAttempts = 0;
static _Atomic int64_t g_passthroughCreated = 0;
static _Atomic int64_t g_passthroughFailures = 0;
static _Atomic int64_t g_passthroughOrig = 0;

// ---------------------------------------------------------------- Testmuster
// Wenn /tmp/vcam_testpattern existiert, wird statt des Decoder-Frames ein
// konstantes 1440x1080-420f-Graubild (Y=100, Cb=128, Cr=128) eingespeist.
// Das isoliert den Handoff-Pfad vom Decoder/Bitstream.
static CVPixelBufferRef g_testPattern = NULL;
static _Atomic int64_t g_testPatternUsed = 0;

// makeTestPattern entfernt — war unused

// ---------------------------------------------------------------- Range-Shift (deaktiviert, entfernt)
// War ein In-Place-/Kopie-Shift, der den Decoder destabilisiert hat. Passthrough nutzt ihn nicht.

// ---------------------------------------------------------------- In-place Pixel-Swap (LordVCAM-Stil)
// Kopiert die Pixel von g_latestFrame in den ORIGINALEN CVPixelBuffer und lässt
// den original CMSampleBuffer (Timing/Attachments/Pool) komplett unangetastet.
// Das vermeidet den Crash, den ein NEUER SampleBuffer bei TikTok/WebRTC auslöst.
#import <Accelerate/Accelerate.h>

static _Atomic uint64_t g_inplaceSwap = 0;
static _Atomic uint64_t g_inplaceMismatch = 0;
static _Atomic uint64_t g_inplaceLockFail = 0;
static _Atomic uint64_t g_inplaceScaled = 0;
static _Atomic int64_t g_misDstFmt = 0, g_misDstW = 0, g_misDstH = 0;
static _Atomic int64_t g_misSrcFmt = 0, g_misSrcW = 0, g_misSrcH = 0;
static _Atomic int64_t g_fmtDumped = 0;

// Range-Helfer: Full->Video (219/224/255) und Video->Full.
// Ganzzahlig, keine Floats in der Hot-Loop.
static inline uint8_t fullToVideoY(uint8_t v)   { return (uint8_t)(((219u * v) / 255u) + 16u); }
static inline uint8_t fullToVideoC(uint8_t v)   { return (uint8_t)(((224u * v) / 255u) + 16u); }
static inline uint8_t videoToFullY(uint8_t v)   { return (uint8_t)((255u * (uint32_t)(v - 16u)) / 219u); }
static inline uint8_t videoToFullC(uint8_t v)   { return (uint8_t)((255u * (uint32_t)(v - 16u)) / 224u); }
typedef uint8_t (*ConvFn)(uint8_t);

// NV12 biplanar: Y-Plane + interleaved UV-Plane skalieren (Center-Crop).
// srcW/srcH = Quellgröße, dstW/dstH = Zielgröße. Stride-aware Zeilen-Kopie.
// NULL-safe: bei ungültigen Zeigern sofort abbrechen (kein Crash).
// conv: Range-Konvertierung pro Byte (NULL = 1:1 kopieren).
static void scaleNV12Plane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                           uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                           size_t cropX, size_t cropY, size_t cropW, size_t cropH,
                           ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    if (!cropW || !cropH) return;
    if (cropX + cropW > srcW || cropY + cropH > srcH) return;
    for (size_t y = 0; y < dstH; y++) {
        size_t sy = cropY + (y * cropH) / dstH;
        // KEIN cropX in der Zeilenbasis — sx addiert ihn exakt einmal.
        const uint8_t *srcRow = sp + sy * srcStride;
        uint8_t *dstRow = dp + y * dstStride;
        for (size_t x = 0; x < dstW; x++) {
            size_t sx = cropX + (x * cropW) / dstW;
            uint8_t v = srcRow[sx];
            dstRow[x] = conv ? conv(v) : v;
        }
    }
}

// UV-Plane in NV12 ist interleaved CbCr: 2 Bytes pro Pixel. Nicht byteweise skalieren!
// NULL-safe wie Y-Plane. conv für beide Bytes (Cb und Cr getrennt anwenden).
static void scaleNV12UVPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                             uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                             size_t cropX, size_t cropY, size_t cropW, size_t cropH,
                             ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    if (!cropW || !cropH) return;
    if (cropX + cropW > srcW || cropY + cropH > srcH) return;
    for (size_t y = 0; y < dstH; y++) {
        size_t sy = cropY + (y * cropH) / dstH;
        // KEIN cropX*2 in der Zeilenbasis — sx addiert exakt einmal.
        const uint8_t *srcRow = sp + sy * srcStride;
        uint8_t *dstRow = dp + y * dstStride;
        for (size_t x = 0; x < dstW; x++) {
            size_t sx = cropX + (x * cropW) / dstW;
            size_t srcOff = sx * 2;
            size_t dstOff = x * 2;
            uint8_t cb = srcRow[srcOff];
            uint8_t cr = srcRow[srcOff + 1];
            dstRow[dstOff] = conv ? conv(cb) : cb;           // Cb
            dstRow[dstOff + 1] = conv ? conv(cr) : cr;       // Cr
        }
    }
}

// 90°-Rotation via Accelerate/vImage — exakt LordVCAM-Pfad 2 (Disassembly verifiziert):
// Y:  vImageRotate90_Planar8  (bg 0)
// UV: vImageRotate90_Planar16U (bg 0x8080, CbCr-Paare bleiben zusammen!)
// Danach Scale, zuletzt LUT in-place auf dst (Range).
// Reihenfolge: Rotate90 -> Scale -> TableLookUp (LordVCAM 0x4d634/0x4d6c4/0x4d898)

// (makeLUT entfernt — Range-LUT wird direkt in rotateScalePlane erzeugt)

// Rotiert src (srcW x srcH) um 90° in einen TEMP-Buffer (srcH x srcW),
// skaliert dann auf dst (dstW x dstH), danach LUT in-place auf dst (Range).
// rotConst: vImage-Rotationskonstante (LordVCAM-Pfad 2):
//   rotDeg=90  -> 3 = kRotate270DegreesClockwise  (= 90° CCW)
//   rotDeg=180 -> 2 = kRotate180DegreesClockwise
//   rotDeg=270 -> 1 = kRotate90DegreesClockwise   (= 90° CW)
static void rotateScalePlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                             uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                             uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    // Nach 90°: output width=srcH, output height=srcW.
    size_t rotW = srcH;
    size_t rotH = srcW;
    size_t tmpRowBytes = rotW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(tmpRowBytes * rotH);
    if (!tmp) return;
    // LordVCAM: vImage_Buffer height/width vertauscht gepflegt — hier:
    // src.height=srcH, src.width=srcW, rowBytes=srcStride (echte Stride!).
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcStride };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, tmpRowBytes };
    vImage_Buffer dstBuf = { dp, dstH, dstW, dstStride };
    vImage_Error err = vImageRotate90_Planar8(&srcBuf, &tmpBuf, rotConst, 0, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    // Skalieren auf Ziel (LordVCAM: Scale NACH Rotate)
    err = vImageScale_Planar8(&tmpBuf, &dstBuf, NULL, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    // Range-Konvertierung zuletzt, in-place auf dst (LordVCAM: vImageTableLookUp in-place)
    if (conv) {
        static uint8_t lutY[256]; static BOOL lutYInit = NO;
        if (!lutYInit) { for (int i = 0; i < 256; i++) lutY[i] = conv((uint8_t)i); lutYInit = YES; }
        vImageTableLookUp_Planar8(&dstBuf, &dstBuf, lutY, kvImageNoFlags);
    }
    free(tmp);
}

// UV-Plane: interleaved CbCr, halbe Auflösung. LordVCAM rotiert sie als
// vImageRotate90_Planar16U mit background=0x8080 (neutrales CbCr-Paar) —
// dadurch bleiben CbCr-Paare zusammen. Danach byteweise Skalierung auf dst
// (2 Bytes/Pixel; Cb und Cr bekommen identische Behandlung).
static void rotateScaleUVPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                               uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                               uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    size_t rotW = srcH, rotH = srcW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(rotW * rotH * 2);
    if (!tmp) return;
    // 16-bit-Pixel: rowBytes muss gerade und >= width*2 sein
    size_t srcRow = srcStride & ~(size_t)1;
    size_t tmpRow = rotW * 2;
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcRow };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, tmpRow };
    // LordVCAM: background 0x8080 für UV (neutrales CbCr)
    vImage_Error err = vImageRotate90_Planar16U(&srcBuf, &tmpBuf, rotConst, 0x8080, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    // Skalieren auf dst (Integer, interleaved 2-Byte-Pixel, Range inline)
    for (size_t y = 0; y < dstH; y++) {
        size_t ry = y * rotH / dstH;
        uint8_t *dstRow = dp + y * dstStride;
        const uint8_t *srcRow = tmp + ry * tmpRow;
        for (size_t x = 0; x < dstW; x++) {
            size_t rx = x * rotW / dstW;
            uint8_t cb = srcRow[rx * 2];
            uint8_t cr = srcRow[rx * 2 + 1];
            dstRow[x * 2]     = conv ? conv(cb) : cb;
            dstRow[x * 2 + 1] = conv ? conv(cr) : cr;
        }
    }
    free(tmp);
}

// ---------------------------------------------------------------- Fill-Rotation (rot=N)
// Rotiert src (90°/180°) und skaliert BILDFÜLLEND (Crop, kein Letterbox)
// in dst — das Ziel ist IMMER das volle iPhone-Format (9:16 Video / 3:4 Foto),
// der OBS-Inhalt füllt es komplett, Überhang wird mittig abgeschnitten.
// 90°: rotW=srcH, rotH=srcW. 180°: rotW=srcW, rotH=srcH.
static void rotateFitPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                           uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                           uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    size_t rotW = (rotConst == 2) ? srcW : srcH;
    size_t rotH = (rotConst == 2) ? srcH : srcW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(rotW * rotH);
    if (!tmp) return;
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcStride };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, rotW };
    vImage_Error err = vImageRotate90_Planar8(&srcBuf, &tmpBuf, rotConst, 0, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    // Aspect-FILL: Ausschnitt des rotierten Bildes wählen, der dst-Format hat,
    // dann auf dst (voll) skalieren — keine Ränder, volle Fläche.
    size_t cropW, cropH;
    if (rotW * dstH >= dstW * rotH) { cropH = rotH; cropW = rotH * dstW / dstH; }
    else { cropW = rotW; cropH = rotW * dstH / dstW; }
    cropW &= ~(size_t)1; cropH &= ~(size_t)1;
    if (cropW < 2 || cropH < 2) { free(tmp); return; }
    size_t cropX = (rotW - cropW) / 2;
    size_t cropY = (rotH - cropH) / 2;
    vImage_Buffer tmpSub = { tmp + cropY * rotW + cropX, cropH, cropW, rotW };
    vImage_Buffer dstBuf = { dp, dstH, dstW, dstStride };
    err = vImageScale_Planar8(&tmpSub, &dstBuf, NULL, kvImageNoFlags);
    if (err == kvImageNoError && conv) {
        static uint8_t lutY[256]; static BOOL lutYInit = NO;
        if (!lutYInit) { for (int i = 0; i < 256; i++) lutY[i] = conv((uint8_t)i); lutYInit = YES; }
        vImageTableLookUp_Planar8(&dstBuf, &dstBuf, lutY, kvImageNoFlags);
    }
    free(tmp);
}

// UV-Plane: 16-bit-interleaved CbCr — Rotation als Planar16U (CbCr-Paare
// bleiben zusammen), danach Integer-Scale des FILL-Ausschnitts auf dst.
static void rotateFitUVPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                             uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                             uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    size_t rotW = (rotConst == 2) ? srcW : srcH;
    size_t rotH = (rotConst == 2) ? srcH : srcW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(rotW * rotH * 2);
    if (!tmp) return;
    size_t srcRow = srcStride & ~(size_t)1;
    size_t tmpRow = rotW * 2;
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcRow };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, tmpRow };
    vImage_Error err = vImageRotate90_Planar16U(&srcBuf, &tmpBuf, rotConst, 0x8080, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    size_t cropW, cropH;
    if (rotW * dstH >= dstW * rotH) { cropH = rotH; cropW = rotH * dstW / dstH; }
    else { cropW = rotW; cropH = rotW * dstH / dstW; }
    cropW &= ~(size_t)1; cropH &= ~(size_t)1;
    if (cropW < 2 || cropH < 2) { free(tmp); return; }
    size_t cropX = (rotW - cropW) / 2;
    size_t cropY = (rotH - cropH) / 2;
    for (size_t y = 0; y < dstH; y++) {
        size_t ry = cropY + y * cropH / dstH;
        uint8_t *dstRow = dp + y * dstStride;
        const uint8_t *srcRow = tmp + ry * tmpRow;
        for (size_t x = 0; x < dstW; x++) {
            size_t rx = cropX + x * cropW / dstW;
            uint8_t cb = srcRow[rx * 2];
            uint8_t cr = srcRow[rx * 2 + 1];
            dstRow[x * 2]     = conv ? conv(cb) : cb;
            dstRow[x * 2 + 1] = conv ? conv(cr) : cr;
        }
    }
    free(tmp);
}

static BOOL swapPixelsInPlace(CMSampleBufferRef original) {
    if (!original) return NO;
    CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(original);
    if (!dst) return NO;

    // ANTI-FLACKERN: mehrere Node-Outputs teilen sich dieselbe IOSurface
    // (gleicher pts) und rufen den Swap nebenläufig auf — wiederholtes
    // Überschreiben derselben Surface erzeugt Races/Flackern im Video.
    // Nur EIN Swap pro Surface+pts; spätere Emissions desselben Frames
    // laufen unverändert durch (die Surface ist bereits getauscht).
    IOSurfaceRef dupSurf = CVPixelBufferGetIOSurface(dst);
    int64_t dupSid = dupSurf ? (int64_t)IOSurfaceGetID(dupSurf) : 0;
    CMTime dupT = CMSampleBufferGetPresentationTimeStamp(original);
    if (dupSid != 0 && atomic_load(&g_lastSurfID) == dupSid &&
        atomic_load(&g_lastPts) == dupT.value) {
        atomic_fetch_add(&g_dupSkip, 1);
        return NO;
    }
    atomic_store(&g_lastSurfID, dupSid);
    atomic_store(&g_lastPts, (int64_t)dupT.value);

    // RECORDING-FIX: 420v-Buffer NICHT mehr blind überspringen. Der
    // Movie-Sink (BWQuickTimeMovieFileSinkNode) erbt sein renderSampleBuffer:
    // von BWFileSinkNode und bekommt komprimierte Daten — der unkomprimierte
    // Feed davor sind genau diese 420v-Buffer. Mit korrekter Range-
    // Konvertierung (unten) werden sie jetzt geswappt. skip420v bleibt als
    // Zähler für die 420v-Treffer erhalten.
    CVPixelBufferRef src = NULL;
    [g_frameLock lock];
    if (g_latestFrame) src = CVPixelBufferRetain(g_latestFrame);
    [g_frameLock unlock];
    if (!src) return NO;

    BOOL ok = NO;
    size_t dw = CVPixelBufferGetWidth(dst);
    size_t dh = CVPixelBufferGetHeight(dst);
    OSType dfmt = CVPixelBufferGetPixelFormatType(dst);
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    OSType sfmt = CVPixelBufferGetPixelFormatType(src);

    // PREVIEW-FIX (LordVCAM-Stil): Porträt-Buffer (h>w) nicht direkt swappen —
    // sie sind Post-Rotations-Ableitungen (750x1334 Preview, 750x1000 Photo-
    // Thumbnails) des geswappten Sensor-Feeds (1440x1080). Das Rotations-Node
    // im Capture-Graph erzeugt sie korrekt aus unseren Pixeln; ein direkter
    // Swap hier presst das 16:9-Quellbild in ein Hochformat-Sliver (kaputte
    // Preview). LordVCAM rotiert hier ebenfalls nicht (needsCCW90=false für
    // h>w) — der Graph übernimmt die Orientierung.
    if (dh > dw) {
        atomic_fetch_add(&g_skipPortrait, 1);
        CVPixelBufferRelease(src);
        return NO;
    }

    // Einmalig das erste Mismatch-Format festhalten (Diagnose)
    if (!atomic_load(&g_fmtDumped) && (dw != sw || dh != sh || dfmt != sfmt)) {
        atomic_store(&g_fmtDumped, 1);
        atomic_store(&g_misDstFmt, (int64_t)dfmt);
        atomic_store(&g_misDstW, (int64_t)dw);
        atomic_store(&g_misDstH, (int64_t)dh);
        atomic_store(&g_misSrcFmt, (int64_t)sfmt);
        atomic_store(&g_misSrcW, (int64_t)sw);
        atomic_store(&g_misSrcH, (int64_t)sh);
    }

    // Nur NV12/420f/p420 biplanar unterstützen wir aktuell.
    // p420 wird als biplanarer 4:2:0-Kandidat akzeptiert, aber das Layout wird
    // ZUR LAUFZEIT pro Buffer verifiziert (PlaneCount, Strides, Plane-Höhen).
    // Quelle und Ziel müssen NICHT identisch sein (Decoder liefert 420f,
    // Preview-Sink nutzt p420) — beide müssen nur biplanar-420 sein.
    BOOL dst420 = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || dfmt == 0x70343230);   // 'p420' (big-endian FourCC)
    BOOL src420 = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || sfmt == 0x70343230);

    // Layout-Verifikation: beide Buffer müssen biplanar sein (2 Planes,
    // Y volle Höhe, UV halbe Höhe). Sonst Original durchlassen.
    BOOL layoutOK = NO;
    if (dst420 && src420) {
        size_t dstPlanes = CVPixelBufferGetPlaneCount(dst);
        size_t srcPlanes = CVPixelBufferGetPlaneCount(src);
        if (dstPlanes == 2 && srcPlanes == 2) {
            size_t dYH = CVPixelBufferGetHeightOfPlane(dst, 0);
            size_t dUVH = CVPixelBufferGetHeightOfPlane(dst, 1);
            size_t sYH = CVPixelBufferGetHeightOfPlane(src, 0);
            size_t sUVH = CVPixelBufferGetHeightOfPlane(src, 1);
            layoutOK = (dYH == dh && sYH == sh &&
                        dUVH == (dh + 1) / 2 && sUVH == (sh + 1) / 2);
            if (!layoutOK) {
                // Einmalig pro Format loggen (Diagnose)
                static _Atomic int64_t g_layoutDump = 0;
                if (!atomic_load(&g_layoutDump)) {
                    atomic_store(&g_layoutDump, 1);
                    L("LAYOUT-MISMATCH dst(planes=%zu Y=%zu/%zu UV=%zu/%zu) src(planes=%zu Y=%zu/%zu UV=%zu/%zu) fmt=0x%08x",
                      dstPlanes, dYH, CVPixelBufferGetBytesPerRowOfPlane(dst, 0),
                      dUVH, CVPixelBufferGetBytesPerRowOfPlane(dst, 1),
                      srcPlanes, sYH, CVPixelBufferGetBytesPerRowOfPlane(src, 0),
                      sUVH, CVPixelBufferGetBytesPerRowOfPlane(src, 1),
                      (unsigned)dfmt);
                }
            }
        }
    }

    if (dst420 && src420 && layoutOK) {
        // LOCK-ERFOLG prüfen: schlägt das Lock fehl (z.B. GPU-held Buffer
        // ohne CPU-Zugriff), NICHT auf die Pixel zugreifen — das war der
        // Respring-Crash.
        CVReturn lkDst = CVPixelBufferLockBaseAddress(dst, 0);
        CVReturn lkSrc = CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        if (lkDst != kCVReturnSuccess || lkSrc != kCVReturnSuccess) {
            if (lkDst == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(dst, 0);
            if (lkSrc == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            atomic_fetch_add(&g_inplaceLockFail, 1);
            CVPixelBufferRelease(src);
            atomic_fetch_add(&g_inplaceMismatch, 1);
            return NO;
        }

        // Base-Addresses NACH dem Lock holen und prüfen (NULL -> abbrechen)
        const uint8_t *srcY = CVPixelBufferGetBaseAddressOfPlane(src, 0);
        const uint8_t *srcUV = CVPixelBufferGetBaseAddressOfPlane(src, 1);
        uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
        uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
        if (!srcY || !srcUV || !dstY || !dstUV) {
            CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferUnlockBaseAddress(dst, 0);
            atomic_fetch_add(&g_inplaceLockFail, 1);
            CVPixelBufferRelease(src);
            atomic_fetch_add(&g_inplaceMismatch, 1);
            return NO;
        }

        // ANTI-FLACKERN (LordVCAM 1fd4c-Stil, verzögert): UseCount der
        // Ziel-Surface erhöhen und erst nach ~66ms (2 Frames) freigeben.
        // Der Pool kann die Surface so nicht sofort für den nächsten
        // Sensor-Frame recyceln — asynchrone Konsumenten (Preview-Ableitung,
        // Encoder) lesen nicht mehr in einen überschriebenen Buffer.
        // Diagnose: "urel=0" schaltet die Verzögerung ab (sofortige Freigabe).
        IOSurfaceRef wSurf = CVPixelBufferGetIOSurface(dst);
        if (wSurf) {
            if (atomic_load(&g_useCountDelay)) {
                IOSurfaceIncrementUseCount(wSurf);
                CFRetain(wSurf);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 66 * NSEC_PER_MSEC),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    IOSurfaceDecrementUseCount(wSurf);
                    CFRelease(wSurf);
                });
            }
        }

        if (dw == sw && dh == sh) {
            // Same-size: stride-aware Kopie. RECORDING-FIX: Wenn das Ziel
            // 420v (Video-Range) ist und die Quelle 420f (Full-Range),
            // MUSS konvertiert werden — memcpy 1:1 erzeugte den lila/grünen
            // Farbstich im aufgenommenen Video.
            BOOL dstVideoRange = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            BOOL srcFullRange  = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            BOOL srcVideoRange = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            BOOL dstFullRange  = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            ConvFn convY = NULL, convC = NULL;
            if (atomic_load(&g_rangeConv)) {
                if (srcFullRange && dstVideoRange) { convY = fullToVideoY; convC = fullToVideoC; }
                else if (srcVideoRange && dstFullRange) { convY = videoToFullY; convC = videoToFullC; }
            }

            // ENCODER-FEED-FIX: Der 1920x1080-420v-Feed (Movie-Encoder) trifft
            // HIER (gleiche Größe wie die Decoder-Quelle) — vorher wurde er
            // ohne Rotation 1:1 kopiert, und die App-Matrix (CW90) drehte das
            // Vollbild in der Galerie. Jetzt gilt dieselbe rot/rotv/rote-Logik
            // wie im Mismatch-Pfad, inkl. Fill-Rotation.
            int rmSame = (int)atomic_load(&g_rotMode);
            if (dstVideoRange) {
                if (dw == 1920 && dh == 1080) {
                    int re = (int)atomic_load(&g_rotEncMode);
                    if (re != 0) rmSame = re;
                } else {
                    int rv = (int)atomic_load(&g_rotVidMode);
                    if (rv != 0) rmSame = rv;
                }
            }
            uint8_t rotSame = 0;
            if (rmSame == 1) rotSame = 1;       // CW
            else if (rmSame == 2) rotSame = 3;  // CCW
            else if (rmSame == 3) rotSame = 2;  // 180

            if (rotSame && dstVideoRange) {
                rotateFitPlane(CVPixelBufferGetBaseAddressOfPlane(src, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(src, 0), sw, sh,
                               CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(dst, 0), dw, dh,
                               rotSame, convY);
                rotateFitUVPlane(CVPixelBufferGetBaseAddressOfPlane(src, 1),
                                 CVPixelBufferGetBytesPerRowOfPlane(src, 1), sw / 2, sh / 2,
                                 CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                                 CVPixelBufferGetBytesPerRowOfPlane(dst, 1), dw / 2, dh / 2,
                                 rotSame, convC);
                ok = YES;
                atomic_fetch_add(&g_rotApplied, 1);
            } else {
                if (convY) atomic_fetch_add(&g_skip420v, 1);   // 420v-Treffer weiter zählen (Diagnose)

                for (size_t p = 0; p < 2; p++) {
                    const uint8_t *sp = CVPixelBufferGetBaseAddressOfPlane(src, p);
                    uint8_t *dp = CVPixelBufferGetBaseAddressOfPlane(dst, p);
                    if (!sp || !dp) continue;
                    size_t sb = CVPixelBufferGetBytesPerRowOfPlane(src, p);
                    size_t db = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
                    size_t ph = CVPixelBufferGetHeightOfPlane(dst, p);
                    size_t copy = db < sb ? db : sb;
                    ConvFn conv = (p == 0) ? convY : convC;
                    if (conv) {
                        for (size_t y = 0; y < ph; y++) {
                            const uint8_t *srow = sp + y * sb;
                            uint8_t *drow = dp + y * db;
                            for (size_t x = 0; x < copy; x++) drow[x] = conv(srow[x]);
                        }
                    } else {
                        for (size_t y = 0; y < ph; y++) {
                            memcpy(dp + y * db, sp + y * sb, copy);
                        }
                    }
                }
                ok = YES;
            }
        } else {
            // Größen-Mismatch. Entscheidung anhand des Orientierungs-Attachments:
            // trägt der Ziel-Buffer "RotationDegrees" != 0, müssen wir rotieren.
            int rotDeg = 0;
            {
                // ShouldNotPropagate: nur DIESEN Buffer lesen, keine veralteten
                // Pool-Attachments (sonst rotiert Foto-Modus fälschlich).
                CFDictionaryRef pbAtts = CVBufferGetAttachments(dst, kCVAttachmentMode_ShouldNotPropagate);
                if (pbAtts) {
                    NSNumber *rd = (__bridge NSNumber *)CFDictionaryGetValue(
                        (CFDictionaryRef)pbAtts, (CFStringRef)@"RotationDegrees");
                    if (rd) rotDeg = [rd intValue];
                }
            }
            // LordVCAM-Fallback (arm64e-Datenfluss BELEGT, 14f90.asm:3936):
            //   needsCCW90 = (aspect > 1.5) && (width >= height)
            // Gemessen an der ZIEL-Buffer-Geometrie (der Buffer, den der
            // Capture-Graph liefert = unser dst). Passt zu den Messungen:
            // TikTok 1280x720 (16:9) -> CCW90, Kamera-App 1440x1080 (4:3) -> keine.
            // RECORDING-FIX: Für 420v-Ziele (Movie-Compressor-Feed) NICHT
            // rotieren — die Recording-Buffer (2304x1296/1920x1080) sind schon
            // in Sensor-Orientierung; der Fallback verzerrte das Video.
            BOOL dstIs420v = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            if (rotDeg == 0 && !dstIs420v) {
                double dstAspect = (double)dw / (double)dh;
                if (dstAspect > 1.5 && dw >= dh) rotDeg = 90;
            }
            // Range-Konvertierung: Quelle Full-Range (420f) -> Ziel Video-Range?
            // WICHTIG: p420 (0x70343230) ist NICHT Video-Range — es ist Apples
            // FourCC für 420YpCbCr8BiPlanarVideoRange, aber im PREVIEW-Pfad
            // wird es als Full-Range-Daten behandelt (der Decoder liefert 420f).
            // Nur echtes 420v (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            // darf konvertiert werden — sonst lila/grüne Preview-Farben.
            BOOL srcFullRange = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            BOOL dstFullRange = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            BOOL dstIsVideoRange = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            BOOL srcIsVideoRange = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            ConvFn convY = NULL, convC = NULL;
            if (atomic_load(&g_rangeConv)) {
                if (srcFullRange && dstIsVideoRange) {
                    convY = fullToVideoY;
                    convC = fullToVideoC;
                } else if (srcIsVideoRange && dstFullRange) {
                    convY = videoToFullY;
                    convC = videoToFullC;
                }
            }

            // ROT-MODUS (Status-Port "rot=N"): 1=90°CW, 2=90°CCW, 3=180°, 0=aus.
            // Fill-Rotation: rotieren + bildfüllend skalieren (Crop), das Ziel
            // ist immer das volle iPhone-Format. VIDEO-PFAD (420v) nutzt rotv=N
            // (eigene Richtung wegen der Rotationsmatrix im Movie-File).
            int rm = (int)atomic_load(&g_rotMode);
            if (dstIsVideoRange) {
                if (dw == 1920 && dh == 1080) {
                    int re = (int)atomic_load(&g_rotEncMode);
                    if (re != 0) rm = re;
                } else {
                    int rv = (int)atomic_load(&g_rotVidMode);
                    if (rv != 0) rm = rv;
                }
            }
            uint8_t rotConst = 0;
            if (rm == 1) rotConst = 1;       // kRotate90DegreesClockwise
            else if (rm == 2) rotConst = 3;  // kRotate270DegreesClockwise (CCW)
            else if (rm == 3) rotConst = 2;  // kRotate180DegreesClockwise

            if (rotConst) {
                rotateFitPlane(CVPixelBufferGetBaseAddressOfPlane(src, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(src, 0), sw, sh,
                               CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(dst, 0), dw, dh,
                               rotConst, convY);
                rotateFitUVPlane(CVPixelBufferGetBaseAddressOfPlane(src, 1),
                                 CVPixelBufferGetBytesPerRowOfPlane(src, 1), sw / 2, sh / 2,
                                 CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                                 CVPixelBufferGetBytesPerRowOfPlane(dst, 1), dw / 2, dh / 2,
                                 rotConst, convC);
                ok = YES;
                atomic_fetch_add(&g_rotApplied, 1);
            } else if (rotDeg != 0) {
                // LordVCAM-Pfad 2 (Disassembly 0x4d590-0x4d5ac, verifiziert):
                //   90°  -> Konstante 3 = kRotate270DegreesClockwise (effektiv CCW)
                //   180° -> Konstante 2 = kRotate180DegreesClockwise
                //   270° -> Konstante 1 = kRotate90DegreesClockwise  (CW)
                uint8_t rotConst = 1;
                if (rotDeg == 90)  rotConst = 3;
                if (rotDeg == 180) rotConst = 2;
                if (rotDeg == 270) rotConst = 1;
                rotateScalePlane(CVPixelBufferGetBaseAddressOfPlane(src, 0),
                              CVPixelBufferGetBytesPerRowOfPlane(src, 0), sw, sh,
                              CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                              CVPixelBufferGetBytesPerRowOfPlane(dst, 0), dw, dh,
                              rotConst, convY);
                rotateScaleUVPlane(CVPixelBufferGetBaseAddressOfPlane(src, 1),
                                CVPixelBufferGetBytesPerRowOfPlane(src, 1), sw / 2, sh / 2,
                                CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                                CVPixelBufferGetBytesPerRowOfPlane(dst, 1), dw / 2, dh / 2,
                                rotConst, convC);
                ok = YES;
                atomic_fetch_add(&g_inplaceScaled, 1);
            } else {
            // KEINE Rotation (gleiche Orientierung): Center-Crop + Skalierung.
            double srcAR = (double)sw / (double)sh;
            double dstAR = (double)dw / (double)dh;
            size_t cropW, cropH, cropX, cropY;
            if (srcAR > dstAR) {
                // Quelle breiter -> horizontal croppen
                cropH = sh;
                cropW = (size_t)(sh * dstAR);
                cropX = (sw - cropW) / 2;
                cropY = 0;
            } else {
                // Quelle höher -> vertikal croppen
                cropW = sw;
                cropH = (size_t)(sw / dstAR);
                cropX = 0;
                cropY = (sh - cropH) / 2;
            }
            // NV12-Chroma: Crop-Koordinaten auf gerade Werte runden (Astra)
            cropX &= ~(size_t)1;
            cropY &= ~(size_t)1;
            cropW &= ~(size_t)1;
            cropH &= ~(size_t)1;
            // Y-Plane (volle Auflösung)
            scaleNV12Plane(CVPixelBufferGetBaseAddressOfPlane(src, 0),
                           CVPixelBufferGetBytesPerRowOfPlane(src, 0), sw, sh,
                           CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                           CVPixelBufferGetBytesPerRowOfPlane(dst, 0), dw, dh,
                           cropX, cropY, cropW, cropH, convY);
            // UV-Plane (halbe Auflösung, interleaved CbCr)
            scaleNV12UVPlane(CVPixelBufferGetBaseAddressOfPlane(src, 1),
                           CVPixelBufferGetBytesPerRowOfPlane(src, 1), sw / 2, sh / 2,
                           CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                           CVPixelBufferGetBytesPerRowOfPlane(dst, 1), dw / 2, dh / 2,
                           cropX / 2, cropY / 2, cropW / 2, cropH / 2, convC);
            ok = YES;
            atomic_fetch_add(&g_inplaceScaled, 1);
            }   // Ende Center-Crop-Zweig
        }

        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(dst, 0);
    } else if (dfmt == sfmt && dw == sw && dh == sh) {
        // Fallback: Nicht-NV12, aber gleiche Größe/Format -> reine Byte-Kopie
        CVPixelBufferLockBaseAddress(dst, 0);
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        size_t planes = CVPixelBufferGetPlaneCount(dst);
        if (planes == 0) {
            void *dp = CVPixelBufferGetBaseAddress(dst);
            const void *sp = CVPixelBufferGetBaseAddress(src);
            size_t db = CVPixelBufferGetBytesPerRow(dst);
            size_t sb = CVPixelBufferGetBytesPerRow(src);
            size_t h = CVPixelBufferGetHeight(dst);
            size_t copy = db < sb ? db : sb;
            for (size_t y = 0; y < h; y++) {
                memcpy((uint8_t *)dp + y * db, (const uint8_t *)sp + y * sb, copy);
            }
            ok = YES;
        }
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(dst, 0);
    }

    // ROTATIONS-FIX: Nach erfolgreichem Swap das RotationDegrees-Attachment
    // auf 0 setzen. Unsere OBS-Pixel sind Querformat (16:9) — der Capture-
    // Graph/Encoder würde sonst anhand des alten 90°-Attachments rotieren,
    // und Foto/Video landen gedreht in der Galerie.
    // SICHER: reines CFNumber (kein ObjC im Echtzeit-Pfad), lazy init ohne
    // dispatch_once, und nur anfassen, wenn das Attachment existiert.
    if (ok) {
        CFDictionaryRef pbAtts = CVBufferGetAttachments(dst, kCVAttachmentMode_ShouldPropagate);
        if (pbAtts && CFDictionaryGetValue(pbAtts, (CFStringRef)@"RotationDegrees")) {
            static CFNumberRef zeroCF = NULL;
            if (!zeroCF) {
                int zero = 0;
                zeroCF = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
            }
            CVBufferSetAttachment(dst, (CFStringRef)@"RotationDegrees",
                zeroCF, kCVAttachmentMode_ShouldPropagate);
        }
        // VIDEO-DRIVEN METADATA (Schritt 1): MetadataDictionary konsistent
        // zum OBS-Feed setzen — ExposureTime aus Config, LuxLevel aus der
        // gemessenen Video-Helligkeit, SNR aus Config, SensorID vom Original.
        if (atomic_load(&g_metaOn)) {
            CFDictionaryRef meta = NULL;
            if (pbAtts) meta = CFDictionaryGetValue(pbAtts, (CFStringRef)@"MetadataDictionary");
            CFNumberRef sensorID = meta
                ? CFDictionaryGetValue(meta, (CFStringRef)@"SensorID") : NULL;

            int64_t lux = atomic_load(&g_videoLux);
            float expt = g_metaExposure;
            float snr = g_metaSnr;
            int64_t isoCfg = atomic_load(&g_metaIso);
            int64_t iso = isoCfg > 0 ? isoCfg
                        : (int64_t)(120000.0 / (double)(lux + 1));
            if (iso < 50) iso = 50;
            if (iso > 3200) iso = 3200;
            CFNumberRef exptN = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &expt);
            CFNumberRef luxN = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &lux);
            CFNumberRef isoN = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &iso);
            CFNumberRef snrN = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &snr);
            CFNumberRef snrNorm = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &snr);

            const void *keys[] = { CFSTR("ExposureTime"), CFSTR("LuxLevel"), CFSTR("ISO"),
                                   CFSTR("SNR"), CFSTR("NormalizedSNR") };
            const void *vals[] = { exptN, luxN, isoN, snrN, snrNorm };
            CFDictionaryRef newMeta = CFDictionaryCreate(
                kCFAllocatorDefault, keys, vals, 5,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CVBufferSetAttachment(dst, (CFStringRef)@"MetadataDictionary",
                newMeta, kCVAttachmentMode_ShouldPropagate);
            if (sensorID) {
                // SensorID erhalten (Geräte-spezifisch, harmlos)
                CFDictionaryRef m2 = CVBufferGetAttachments(dst, kCVAttachmentMode_ShouldPropagate);
                CFDictionaryRef cur = m2 ? CFDictionaryGetValue(m2, (CFStringRef)@"MetadataDictionary") : NULL;
                if (cur) {
                    CFMutableDictionaryRef mut = CFDictionaryCreateMutableCopy(
                        kCFAllocatorDefault, 0, cur);
                    CFDictionarySetValue(mut, (CFStringRef)@"SensorID", sensorID);
                    CVBufferSetAttachment(dst, (CFStringRef)@"MetadataDictionary",
                        mut, kCVAttachmentMode_ShouldPropagate);
                    CFRelease(mut);
                }
            }
            CFRelease(exptN); CFRelease(luxN); CFRelease(isoN);
            CFRelease(snrN); CFRelease(snrNorm); CFRelease(newMeta);
        }
    }

    CVPixelBufferRelease(src);
    if (ok) atomic_fetch_add(&g_inplaceSwap, 1);
    else atomic_fetch_add(&g_inplaceMismatch, 1);
    return ok;
}

// buildSwapSampleBuffer entfernt — nutzen jetzt swapPixelsInPlace (LordVCAM-Stil)

// ---------------------------------------------------------------- Handoff-Diagnose
static _Atomic int64_t g_handoffDumped = 0;
// Diagnose-Werte als Globals (über Status-Port abrufbar)
static _Atomic int64_t d_origValid = 0, d_origReady = 0, d_origSamples = 0;
static _Atomic int64_t d_origHasImg = 0, d_origHasData = 0, d_origHasFmt = 0;
static _Atomic int64_t d_origSurfId = 0, d_origSurfSeed = 0;
static _Atomic int64_t d_origFullRange = 0;
static _Atomic int64_t d_replValid = 0, d_replReady = 0, d_replSamples = 0;
static _Atomic int64_t d_replHasImg = 0, d_replHasData = 0, d_replHasFmt = 0;
static _Atomic int64_t d_replSurfId = 0, d_replSurfSeed = 0;
static _Atomic int64_t d_replFullRange = 0;
static char d_hookClass[128] = {0};
static char d_hookEncoding[128] = {0};

// dumpHandoff entfernt — war unused

static _Atomic int64_t g_hookClassChecked = 0;
// dumpHookClass entfernt — war unused
// FigCaptureClientSessionMonitor-Hooks entfernt (feuern nie, laut Verifikation)

static _Atomic int64_t g_origPixelFormat = 0;
static _Atomic int64_t g_origWidth = 0;
static _Atomic int64_t g_origHeight = 0;

// Objekt-Instanz-Tracking: struct-Array statt String (kein memmove-Bug)
// NEU (Astra): pro Objekt Format, Größe, IOSurface-ID, letzte PTS.
typedef struct {
    uintptr_t object;
    uint64_t calls;
    uint64_t swaps;
    int64_t lastPTS;
    int64_t width;
    int64_t height;
    int64_t pixelFormat;
    int64_t iosurfaceID;
    char className[96];
} OutputEntry;

static OutputEntry g_outputs[128] = {0};
static pthread_mutex_t g_objMutex = PTHREAD_MUTEX_INITIALIZER;

static void trackObject(id self) {
    uintptr_t object = (uintptr_t)self;
    pthread_mutex_lock(&g_objMutex);
    for (size_t i = 0; i < 128; i++) {
        if (g_outputs[i].object == object) {
            g_outputs[i].calls++;
            pthread_mutex_unlock(&g_objMutex);
            return;
        }
    }
    for (size_t i = 0; i < 128; i++) {
        if (g_outputs[i].object == 0) {
            g_outputs[i].object = object;
            g_outputs[i].calls = 1;
            snprintf(g_outputs[i].className, sizeof(g_outputs[i].className), "%s",
                     object_getClassName(self));
            break;
        }
    }
    pthread_mutex_unlock(&g_objMutex);
}

// Pro-Objekt-Format/-Buffer-Daten aktualisieren (Astra: welcher Output ist sichtbar?)
static void trackObjectFrame(id self, CMSampleBufferRef sb, BOOL didSwap) {
    if (!sb) return;
    uintptr_t object = (uintptr_t)self;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px) return;
    pthread_mutex_lock(&g_objMutex);
    for (size_t i = 0; i < 128; i++) {
        if (g_outputs[i].object == object) {
            g_outputs[i].width = (int64_t)CVPixelBufferGetWidth(px);
            g_outputs[i].height = (int64_t)CVPixelBufferGetHeight(px);
            g_outputs[i].pixelFormat = (int64_t)CVPixelBufferGetPixelFormatType(px);
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(px);
            g_outputs[i].iosurfaceID = surf ? (int64_t)IOSurfaceGetID(surf) : -1;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
            g_outputs[i].lastPTS = (int64_t)pts.value;
            if (didSwap) g_outputs[i].swaps++;
            break;
        }
    }
    pthread_mutex_unlock(&g_objMutex);
}

// ----------------------------------------------------------------
// LORDVCAM-STIL: MSHookMessageEx mit NSClassFromString-Guards.
// Kein Logos %hook (installiert blind -> SIGSEGV bei nil-Klasse).
// Jede Hook-Funktion ist eine normale C-Funktion; der Original-IMP
// wird selbst gespeichert und aufgerufen (statt %orig).
// ----------------------------------------------------------------
static void (*orig_emitSampleBuffer)(id self, SEL _cmd, id sampleBuffer);
static void (*orig_capturePhotoDelegate)(id self, SEL _cmd, id settings, id delegate);
static void (*orig_capturePhotoCompletion)(id self, SEL _cmd, id settings, id delegate, id handler);
static void (*orig_photoRender)(id self, SEL _cmd, id sbuf, id input);
static void (*orig_iqRender)(id self, SEL _cmd, id sampleBuffer, id input);
static void (*orig_qtRender)(id self, SEL _cmd, id sampleBuffer, id input);
static void (*orig_stRender)(id self, SEL _cmd, id sampleBuffer, id input);

// BWNodeOutput -emitSampleBuffer: (Haupt-Swap)
static void hook_emitSampleBuffer(id self, SEL _cmd, id sampleBuffer) {
    atomic_fetch_add(&g_emitCalls, 1);
    if (atomic_load(&g_diag)) {
        trackObject(self);
        trackObjectFrame(self, (__bridge CMSampleBufferRef)sampleBuffer, NO);
    }

    int stage = atomic_load(&g_stage);
    if (stage == 0) {
        atomic_fetch_add(&g_origCount, 1);
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }
    if (stage < 3) {
        atomic_fetch_add(&g_origCount, 1);
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }
    if (!atomic_load(&g_modeBW)) {
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }
    if (!atomic_load(&g_replacementEnabled)) {
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }
    if (atomic_load(&g_photoInProgress)) {
        atomic_fetch_add(&g_swapSkippedPhoto, 1);
        atomic_fetch_add(&g_origCount, 1);
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }
    if (atomic_load(&g_recordingInProgress)) {
        atomic_fetch_add(&g_swapSkippedRecording, 1);
        atomic_fetch_add(&g_origCount, 1);
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    if (atomic_load(&g_origPixelFormat) == 0) {
        CMSampleBufferRef origSB = (__bridge CMSampleBufferRef)sampleBuffer;
        if (origSB) {
            CVPixelBufferRef px = CMSampleBufferGetImageBuffer(origSB);
            if (px) {
                OSType fmt = CVPixelBufferGetPixelFormatType(px);
                size_t w = CVPixelBufferGetWidth(px);
                size_t h = CVPixelBufferGetHeight(px);
                atomic_store(&g_origPixelFormat, (int64_t)fmt);
                atomic_store(&g_origWidth, (int64_t)w);
                atomic_store(&g_origHeight, (int64_t)h);
                L("ORIGINAL format=0x%08x (%c%c%c%c) %zux%zu",
                  (unsigned)fmt, (int)(fmt>>24)&0xff, (int)(fmt>>16)&0xff,
                  (int)(fmt>>8)&0xff, (int)fmt&0xff, w, h);
            }
        }
    }

    BOOL swapped = swapPixelsInPlace((__bridge CMSampleBufferRef)sampleBuffer);
    if (swapped) {
        if (atomic_load(&g_diag)) {
            trackObjectFrame(self, (__bridge CMSampleBufferRef)sampleBuffer, YES);
        }
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    atomic_fetch_add(&g_origCount, 1);
    orig_emitSampleBuffer(self, _cmd, sampleBuffer);
}

// ---------------------------------------------------------------- Foto-Capture-State-Erkennung
// Setzt g_photoInProgress, damit der Preview-Hook während Still Capture
// NICHT den Original-Buffer in-place überschreibt (Freeze-Vermeidung).
// Da AVCapturePhotoOutput im App-Prozess läuft (nicht mediaserverd), wird
// der Hook hier evtl. nicht feuern. Deshalb zusätzlich zeitbasierter Auto-Reset:
// das Flag bleibt max. 2s aktiv, danach wieder Replacement erlaubt.
static _Atomic int64_t g_photoResetAt = 0;

static void armPhotoGuard(void) {
    atomic_store(&g_photoInProgress, 1);
    atomic_store(&g_photoResetAt, (int64_t)time(NULL) + 2);
    L("Foto-Capture START (Guard 2s)");
}

static void maybeResetPhotoGuard(void) {
    if (atomic_load(&g_photoInProgress) &&
        time(NULL) >= atomic_load(&g_photoResetAt)) {
        atomic_store(&g_photoInProgress, 0);
    }
}

// buildReplacementSampleBuffer entfernt — nutzen jetzt swapPixelsInPlace (LordVCAM-Stil)

// AVCapturePhotoOutput -capturePhotoWithSettings:delegate: (+completionHandler:)
static void hook_capturePhotoDelegate(id self, SEL _cmd, id settings, id delegate) {
    armPhotoGuard();
    orig_capturePhotoDelegate(self, _cmd, settings, delegate);
}
static void hook_capturePhotoCompletion(id self, SEL _cmd, id settings, id delegate, id handler) {
    armPhotoGuard();
    orig_capturePhotoCompletion(self, _cmd, settings, delegate, handler);
}

// ---------------------------------------------------------------- BWPhotoEncoderNode
// Beobachtung-only: Photo-Replacement bleibt deaktiviert.
static void hook_photoRender(id self, SEL _cmd, id sbuf, id input) {
    orig_photoRender(self, _cmd, sbuf, input);
}

// ---------------------------------------------------------------- Status-Server (8769)
static void statusServerThread(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(STATUS_PORT);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(srv); return; }
    if (listen(srv, 4) < 0) { close(srv); return; }
    L("Status-Server auf 127.0.0.1:%d", STATUS_PORT);
    while (1) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        // Kommando lesen (nicht-blockierend): "stage=N", "fulldump", sonst lesen.
        char cmd[64] = {0};
        struct timeval tv = { .tv_sec = 0, .tv_usec = 150000 };
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        ssize_t cr = recv(c, cmd, sizeof(cmd) - 1, 0);
        int wantFullDump = 0;
        if (cr > 0) {
            if (strncmp(cmd, "stage=", 6) == 0) {
                int ns = atoi(cmd + 6);
                if (ns >= 0 && ns <= 3) {
                    atomic_store(&g_stage, ns);
                    L("STAGE jetzt %d", ns);
                }
            } else if (strncmp(cmd, "rot=", 4) == 0) {
                int nr = atoi(cmd + 4);
                if (nr >= 0 && nr <= 3) {
                    atomic_store(&g_rotMode, nr);
                    L("ROT-Modus jetzt %d", nr);
                }
            } else if (strncmp(cmd, "rotv=", 5) == 0) {
                int nv = atoi(cmd + 5);
                if (nv >= 0 && nv <= 3) {
                    atomic_store(&g_rotVidMode, nv);
                    L("ROTV-Modus jetzt %d", nv);
                }
            } else if (strncmp(cmd, "rote=", 5) == 0) {
                int ne = atoi(cmd + 5);
                if (ne >= 0 && ne <= 3) {
                    atomic_store(&g_rotEncMode, ne);
                    L("ROTE-Modus jetzt %d", ne);
                }
            } else if (strncmp(cmd, "rng=", 4) == 0) {
                int nr = atoi(cmd + 4);
                if (nr >= 0 && nr <= 1) {
                    atomic_store(&g_rangeConv, nr);
                    L("RANGE-Konvertierung jetzt %d", nr);
                }
            } else if (strncmp(cmd, "urel=", 5) == 0) {
                int nr = atoi(cmd + 5);
                if (nr >= 0 && nr <= 1) {
                    atomic_store(&g_useCountDelay, nr);
                    L("UseCount-Delay jetzt %d", nr);
                }
            } else if (strncmp(cmd, "diag=", 5) == 0) {
                int nr = atoi(cmd + 5);
                if (nr >= 0 && nr <= 1) {
                    atomic_store(&g_diag, nr);
                    L("Diag jetzt %d", nr);
                }
            } else if (strncmp(cmd, "mdon=", 5) == 0) {
                int nr = atoi(cmd + 5);
                if (nr >= 0 && nr <= 1) {
                    atomic_store(&g_metaOn, nr);
                    L("Metadata-Rewrite jetzt %d", nr);
                }
            } else if (strncmp(cmd, "expt=", 5) == 0) {
                float f = strtof(cmd + 5, NULL);
                if (f > 0.0001f && f <= 1.0f) {
                    g_metaExposure = f;
                    L("ExposureTime jetzt %.6f", f);
                }
            } else if (strncmp(cmd, "iso=", 4) == 0) {
                int ni = atoi(cmd + 4);
                if (ni >= 0 && ni <= 200000) {
                    atomic_store(&g_metaIso, ni);
                    L("ISO jetzt %d", ni);
                }
            } else if (strncmp(cmd, "snr=", 4) == 0) {
                float f = strtof(cmd + 4, NULL);
                if (f > 0.0f && f <= 100.0f) {
                    g_metaSnr = f;
                    L("SNR jetzt %.1f", f);
                }
            } else if (strncmp(cmd, "fulldump", 8) == 0) {
                wantFullDump = 1;
            }
        }
        char msg[16384];
        int w = snprintf(msg, sizeof(msg),
            "build=%s stage=%d\n"
            "rxNal=%llu sps=%llu pps=%llu idr=%llu "
            "wsBin=%llu wsText=%llu wsBytes=%llu "
            "formatDesc=%llu submit=%llu output=%llu errors=%llu "
            "emit=%llu send=%llu figEmitRep=%llu figSendRep=%llu build=%llu swap=%llu swapMismatch=%llu inplace=%llu inplaceMis=%llu inplaceScale=%llu orig=%llu hasFrame=%llu "
            "photoState=%d recState=%d skipPhoto=%llu skipRec=%llu repl=%d skip420v=%llu skipPort=%llu rot=%lld rotv=%lld rote=%lld rng=%lld rotApp=%llu dup=%llu urel=%d diag=%d mdon=%d luma=%lld lux=%lld expt=%.6f snr=%.1f iso=%lld "
            "vtAttempts=%llu vtError=%lld\n",
            VCAM_BUILD_ID,
            (int)atomic_load(&g_stage),
            (unsigned long long)atomic_load(&g_rxNalCount),
            (unsigned long long)atomic_load(&g_spsCount),
            (unsigned long long)atomic_load(&g_ppsCount),
            (unsigned long long)atomic_load(&g_idrCount),
            (unsigned long long)atomic_load(&g_wsBinaryCount),
            (unsigned long long)atomic_load(&g_wsTextCount),
            (unsigned long long)atomic_load(&g_wsBytesReceived),
            (unsigned long long)atomic_load(&g_formatDescCount),
            (unsigned long long)atomic_load(&g_decodeSubmitCount),
            (unsigned long long)atomic_load(&g_decodeOutputCount),
            (unsigned long long)atomic_load(&g_decodeErrorCount),
            (unsigned long long)atomic_load(&g_emitCalls),
            (unsigned long long)atomic_load(&g_sendCalls),
            (unsigned long long)atomic_load(&g_figEmitReplacements),
            (unsigned long long)atomic_load(&g_figSendReplacements),
            (unsigned long long)atomic_load(&g_buildCalls),
            (unsigned long long)atomic_load(&g_swapCount),
            (unsigned long long)atomic_load(&g_swapSizeMismatch),
            (unsigned long long)atomic_load(&g_inplaceSwap),
            (unsigned long long)atomic_load(&g_inplaceMismatch),
            (unsigned long long)atomic_load(&g_inplaceScaled),
            (unsigned long long)atomic_load(&g_origCount),
            (unsigned long long)atomic_load(&g_hasLatestFrame),
            (int)atomic_load(&g_photoInProgress),
            (int)atomic_load(&g_recordingInProgress),
            (unsigned long long)atomic_load(&g_swapSkippedPhoto),
            (unsigned long long)atomic_load(&g_swapSkippedRecording),
            (int)atomic_load(&g_replacementEnabled),
            (unsigned long long)atomic_load(&g_skip420v),
            (unsigned long long)atomic_load(&g_skipPortrait),
            (long long)atomic_load(&g_rotMode),
            (long long)atomic_load(&g_rotVidMode),
            (long long)atomic_load(&g_rotEncMode),
            (long long)atomic_load(&g_rangeConv),
            (unsigned long long)atomic_load(&g_rotApplied),
            (unsigned long long)atomic_load(&g_dupSkip),
            (int)atomic_load(&g_useCountDelay),
            (int)atomic_load(&g_diag),
            (int)atomic_load(&g_metaOn),
            (long long)atomic_load(&g_videoLuma),
            (long long)atomic_load(&g_videoLux),
            (double)g_metaExposure,
            (double)g_metaSnr,
            (long long)atomic_load(&g_metaIso),
            (unsigned long long)atomic_load(&g_vtSessionAttempts),
            (long long)atomic_load(&g_vtSessionError));
        int fw = snprintf(msg + w, sizeof(msg) - w, " origFmt=0x%08x origSize=%lldx%lld decodedFmt=0x%08x decodedSize=%lldx%lld dStride=%lld/%lld pt=%llu/%llu/%llu/%llu\n",
            (unsigned)(long long)atomic_load(&g_origPixelFormat),
            (long long)atomic_load(&g_origWidth),
            (long long)atomic_load(&g_origHeight),
            (unsigned)(long long)atomic_load(&g_decodedFormat),
            (long long)atomic_load(&g_decodedWidth),
            (long long)atomic_load(&g_decodedHeight),
            (long long)atomic_load(&g_decodedStride0),
            (long long)atomic_load(&g_decodedStride1),
            (unsigned long long)atomic_load(&g_passthroughAttempts),
            (unsigned long long)atomic_load(&g_passthroughCreated),
            (unsigned long long)atomic_load(&g_passthroughFailures),
            (unsigned long long)atomic_load(&g_passthroughOrig));
        if (fw > 0) w += fw;
        // Sink-Beobachtung (Preview/Recording/Foto-Pfade)
        fw = snprintf(msg + w, sizeof(msg) - w,
            " SINK iq=%llu iqSwaps=%llu iqFmt=%lldx%lld fmt=0x%08llx surf=%lld | qt=%llu qtFmt=%lldx%lld fmt=0x%08llx surf=%lld | st=%llu stFmt=%lldx%lld fmt=0x%08llx surf=%lld\n",
            (unsigned long long)atomic_load(&g_iqCalls),
            (unsigned long long)atomic_load(&g_iqSwaps),
            (long long)atomic_load(&g_iqWidth), (long long)atomic_load(&g_iqHeight),
            (unsigned long long)atomic_load(&g_iqFmt), (long long)atomic_load(&g_iqSurf),
            (unsigned long long)atomic_load(&g_qtCalls),
            (long long)atomic_load(&g_qtWidth), (long long)atomic_load(&g_qtHeight),
            (unsigned long long)atomic_load(&g_qtFmt), (long long)atomic_load(&g_qtSurf),
            (unsigned long long)atomic_load(&g_stCalls),
            (long long)atomic_load(&g_stWidth), (long long)atomic_load(&g_stHeight),
            (unsigned long long)atomic_load(&g_stFmt), (long long)atomic_load(&g_stSurf));
        if (fw > 0) w += fw;
        if (atomic_load(&g_orientDumped)) {
            int mw = snprintf(msg + w, sizeof(msg) - w, " %s\n", g_orientDump);
            if (mw > 0) w += mw;
        }
        if (atomic_load(&g_orientDumped_video)) {
            int mw = snprintf(msg + w, sizeof(msg) - w, " %s\n", g_orientDump_video);
            if (mw > 0) w += mw;
        }
        if (atomic_load(&g_fmtDumped)) {
            int mw = snprintf(msg + w, sizeof(msg) - w, " MIS dst=0x%08x %lldx%lld src=0x%08x %lldx%lld\n",
                (unsigned)(long long)atomic_load(&g_misDstFmt),
                (long long)atomic_load(&g_misDstW),
                (long long)atomic_load(&g_misDstH),
                (unsigned)(long long)atomic_load(&g_misSrcFmt),
                (long long)atomic_load(&g_misSrcW),
                (long long)atomic_load(&g_misSrcH));
            if (mw > 0) w += mw;
        }
        if (wantFullDump) {
            if (g_methodDump[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "BW: %s\n", g_methodDump);
                if (mw > 0) w += mw;
            }
            if (g_methodDump2[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "FigCap: %s\n", g_methodDump2);
                if (mw > 0) w += mw;
            }
            if (g_copyClasses[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "COPYNEXT: %s\n", g_copyClasses);
                if (mw > 0) w += mw;
            }
            if (g_sinkClasses[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "SINKS: %s\n", g_sinkClasses);
                if (mw > 0) w += mw;
            }
            if (g_selectorDump[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "SELOWNER:\n%s\n", g_selectorDump);
                if (mw > 0) w += mw;
            }
        }
        {
            pthread_mutex_lock(&g_objMutex);
            int used = 0;
            for (int i = 0; i < 128; i++) {
                if (g_outputs[i].object == 0) break;
                used++;
            }
            for (int i = 0; i < used && w < (int)sizeof(msg) - 300; i++) {
                int mw = snprintf(msg + w, sizeof(msg) - w,
                    "OUT[%d]=0x%lx:%s:emits=%llu swaps=%llu %lldx%lld fmt=0x%08llx surf=%lld pts=%lld\n",
                    i, (unsigned long)g_outputs[i].object,
                    g_outputs[i].className,
                    (unsigned long long)g_outputs[i].calls,
                    (unsigned long long)g_outputs[i].swaps,
                    (long long)g_outputs[i].width,
                    (long long)g_outputs[i].height,
                    (unsigned long long)g_outputs[i].pixelFormat,
                    (long long)g_outputs[i].iosurfaceID,
                    (long long)g_outputs[i].lastPTS);
                if (mw > 0) w += mw;
            }
            pthread_mutex_unlock(&g_objMutex);
        }
        if (wantFullDump && atomic_load(&g_handoffDumped)) {
            int mw = snprintf(msg + w, sizeof(msg) - w,
                "HANDOFF orig(v=%lld r=%lld s=%lld img=%lld data=%lld fmt=%lld surf=%lld/%lld fr=%lld) "
                "repl(v=%lld r=%lld s=%lld img=%lld data=%lld fmt=%lld surf=%lld/%lld fr=%lld)\n"
                "HOOKCLASS=%s ENC=%s\n",
                (long long)atomic_load(&d_origValid), (long long)atomic_load(&d_origReady),
                (long long)atomic_load(&d_origSamples),
                (long long)atomic_load(&d_origHasImg), (long long)atomic_load(&d_origHasData),
                (long long)atomic_load(&d_origHasFmt),
                (long long)atomic_load(&d_origSurfId), (long long)atomic_load(&d_origSurfSeed),
                (long long)atomic_load(&d_origFullRange),
                (long long)atomic_load(&d_replValid), (long long)atomic_load(&d_replReady),
                (long long)atomic_load(&d_replSamples),
                (long long)atomic_load(&d_replHasImg), (long long)atomic_load(&d_replHasData),
                (long long)atomic_load(&d_replHasFmt),
                (long long)atomic_load(&d_replSurfId), (long long)atomic_load(&d_replSurfSeed),
                (long long)atomic_load(&d_replFullRange),
                d_hookClass, d_hookEncoding);
            if (mw > 0) w += mw;
        }
        send(c, msg, w, 0);
        close(c);
    }
}

// ---------------------------------------------------------------- WS-Client
// Forward-Declarations (Diagnose-Funktionen liegen weiter unten)
static void dumpWildcardClasses(void);
static void dumpCopyNextClasses(void);
static void logMethodsOfClass(Class cls, const char *className, char *dump);

static BOOL sendAllFD(int fd, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len > 0) {
        ssize_t n = send(fd, p, len > (size_t)INT_MAX ? INT_MAX : (int)len, 0);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static ssize_t recvHTTPHeaders(int fd, char *buf, size_t cap) {
    size_t used = 0;
    while (used + 1 < cap) {
        ssize_t n = recv(fd, buf + used, cap - used - 1, 0);
        if (n <= 0) return n;
        used += (size_t)n;
        buf[used] = 0;
        if (strstr(buf, "\r\n\r\n")) return (ssize_t)used;
    }
    return -1;
}

static void wsClientThread(void) {
    L("wsClientThread gestartet");
    while (1) {
        L("WS-Verbindungsversuch");
        @autoreleasepool {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) { L("socket fehlgeschlagen errno=%d %s", errno, strerror(errno)); sleep(2); continue; }
            struct sockaddr_in addr = {0};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            addr.sin_port = htons(WS_PORT);
            L("vor connect fd=%d", fd);
            if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
                L("connect fehlgeschlagen errno=%d %s", errno, strerror(errno));
                close(fd);
                sleep(2);
                continue;
            }
            L("connect erfolgreich");
            char key[32];
            srand((unsigned)time(NULL));
            for (int i = 0; i < 24; i++) key[i] = "abcdefghijklmnopqrstuvwxyz0123456789"[rand() % 36];
            key[24] = 0;
            char req[512];
            snprintf(req, sizeof(req),
                "GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
                WS_PORT, key);
            if (!sendAllFD(fd, req, strlen(req))) { close(fd); sleep(2); continue; }
            L("Handshake gesendet — warte auf Antwort");
            char resp[2048];
            ssize_t n = recvHTTPHeaders(fd, resp, sizeof(resp));
            L("recvHTTPHeaders n=%zd err=%s", n, n < 0 ? strerror(errno) : "ok");
            if (n > 0) { resp[n < 2048 ? n : 2047] = 0; L("Antwort: %.120s", resp); }
            if (n <= 0 || strstr(resp, "101") == NULL) { close(fd); sleep(2); continue; }
            L("mit Hub verbunden");
            while (1) {
                uint8_t hdr[2];
                ssize_t g = recv(fd, hdr, 2, MSG_WAITALL);
                if (g != 2) break;
                uint8_t opcode = hdr[0] & 0x0f;
                uint8_t masked = (hdr[1] >> 7) & 1;
                uint64_t plen = hdr[1] & 0x7f;
                if (plen == 126) {
                    uint8_t ext[2];
                    if (recv(fd, ext, 2, MSG_WAITALL) != 2) break;
                    plen = ((uint64_t)ext[0] << 8) | ext[1];
                } else if (plen == 127) {
                    uint8_t ext[8];
                    if (recv(fd, ext, 8, MSG_WAITALL) != 8) break;
                    plen = 0;
                    for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
                }
                uint8_t mask[4] = {0};
                if (masked && recv(fd, mask, 4, MSG_WAITALL) != 4) break;
                if (plen > 8 * 1024 * 1024) break;
                uint8_t *payload = malloc((size_t)plen);
                size_t got = 0;
                while (got < plen) {
                    ssize_t r = recv(fd, payload + got, (size_t)(plen - got), 0);
                    if (r <= 0) break;
                    got += (size_t)r;
                }
                if (got < plen) { free(payload); break; }
                if (masked) for (uint64_t i = 0; i < plen; i++) payload[i] ^= mask[i & 3];
                if (opcode == 0x2) {
                    atomic_fetch_add(&g_wsBinaryCount, 1);
                    atomic_fetch_add(&g_wsBytesReceived, plen);
                    enqueueNal([NSData dataWithBytesNoCopy:payload length:(NSUInteger)plen freeWhenDone:YES]);
                } else if (opcode == 0x1) {
                    atomic_fetch_add(&g_wsTextCount, 1);
                    NSString *cmd = [[NSString alloc] initWithBytes:payload length:(NSUInteger)plen encoding:NSUTF8StringEncoding];
                    if (cmd) {
                        if ([cmd isEqualToString:@"mode:wrap_orig"]) {
                            atomic_store(&g_modeWrapOrig, 1);
                            atomic_store(&g_modeTestPattern, 0);
                            L("Modus: WRAP_ORIG");
                        } else if ([cmd isEqualToString:@"mode:testpattern"]) {
                            atomic_store(&g_modeTestPattern, 1);
                            atomic_store(&g_modeWrapOrig, 0);
                            L("Modus: TESTPATTERN");
                        } else if ([cmd isEqualToString:@"mode:bw_off"]) {
                            atomic_store(&g_modeBW, 0);
                            L("Modus: BW_OFF");
                        } else if ([cmd isEqualToString:@"mode:bw_on"]) {
                            atomic_store(&g_modeBW, 1);
                            atomic_store(&g_modeFigEmit, 0);
                            atomic_store(&g_modeFigSend, 0);
                            L("Modus: BW_ON");
                        } else if ([cmd isEqualToString:@"mode:fig_emit"]) {
                            atomic_store(&g_modeBW, 0);
                            atomic_store(&g_modeFigEmit, 1);
                            atomic_store(&g_modeFigSend, 0);
                            L("Modus: FIG_EMIT");
                        } else if ([cmd isEqualToString:@"mode:fig_send"]) {
                            atomic_store(&g_modeBW, 0);
                            atomic_store(&g_modeFigSend, 1);
                            L("Modus: FIG_SEND");
                        } else if ([cmd isEqualToString:@"mode:normal"]) {
                            atomic_store(&g_modeBW, 1);
                            atomic_store(&g_modeFigEmit, 0);
                            atomic_store(&g_modeFigSend, 0);
                            atomic_store(&g_modeWrapOrig, 0);
                            atomic_store(&g_modeTestPattern, 0);
                            L("Modus: NORMAL");
                        } else if ([cmd isEqualToString:@"mode:observe"]) {
                            atomic_store(&g_modeBW, 0);
                            atomic_store(&g_modeFigEmit, 0);
                            atomic_store(&g_modeFigSend, 0);
                            L("Modus: OBSERVE");
                        } else if ([cmd isEqualToString:@"mode:replacement_off"]) {
                            atomic_store(&g_replacementEnabled, 0);
                            L("Modus: REPLACEMENT_OFF");
                        } else if ([cmd isEqualToString:@"mode:replacement_on"]) {
                            atomic_store(&g_replacementEnabled, 1);
                            L("Modus: REPLACEMENT_ON");
                        } else if ([cmd isEqualToString:@"mode:redump"]) {
                            // Diagnose erneut ausführen (nach Kamera-Start, Klassen jetzt geladen)
                            dumpWildcardClasses();
                            logMethodsOfClass(NSClassFromString(@"BWNodeOutput"), "BWNodeOutput", g_methodDump);
                            dumpCopyNextClasses();
                            L("Modus: REDUMP");
                        } else if ([cmd hasPrefix:@"stage="]) {
                            int ns = [[cmd substringFromIndex:6] intValue];
                            if (ns >= 0 && ns <= 3) { atomic_store(&g_stage, ns); L("WS: STAGE %d", ns); }
                        } else if ([cmd hasPrefix:@"rot="]) {
                            int nr = [[cmd substringFromIndex:4] intValue];
                            if (nr >= 0 && nr <= 3) { atomic_store(&g_rotMode, nr); L("WS: ROT %d", nr); }
                        } else if ([cmd hasPrefix:@"rotv="]) {
                            int nv = [[cmd substringFromIndex:5] intValue];
                            if (nv >= 0 && nv <= 3) { atomic_store(&g_rotVidMode, nv); L("WS: ROTV %d", nv); }
                        } else if ([cmd hasPrefix:@"rote="]) {
                            int ne = [[cmd substringFromIndex:5] intValue];
                            if (ne >= 0 && ne <= 3) { atomic_store(&g_rotEncMode, ne); L("WS: ROTE %d", ne); }
                        } else if ([cmd hasPrefix:@"rng="]) {
                            int nr = [[cmd substringFromIndex:4] intValue];
                            if (nr >= 0 && nr <= 1) { atomic_store(&g_rangeConv, nr); L("WS: RNG %d", nr); }
                        } else if ([cmd hasPrefix:@"urel="]) {
                            int nr = [[cmd substringFromIndex:5] intValue];
                            if (nr >= 0 && nr <= 1) { atomic_store(&g_useCountDelay, nr); L("WS: UREL %d", nr); }
                        } else if ([cmd hasPrefix:@"diag="]) {
                            int nr = [[cmd substringFromIndex:5] intValue];
                            if (nr >= 0 && nr <= 1) { atomic_store(&g_diag, nr); L("WS: DIAG %d", nr); }
                        } else if ([cmd hasPrefix:@"expt="]) {
                            float f = [[cmd substringFromIndex:5] floatValue];
                            if (f > 0.0001f && f <= 1.0f) { g_metaExposure = f; L("WS: ExposureTime %.6f", f); }
                        } else if ([cmd hasPrefix:@"snr="]) {
                            float f = [[cmd substringFromIndex:4] floatValue];
                            if (f > 0.0f && f <= 100.0f) { g_metaSnr = f; L("WS: SNR %.1f", f); }
                        } else if ([cmd hasPrefix:@"iso="]) {
                            int ni = [[cmd substringFromIndex:4] intValue];
                            if (ni >= 0 && ni <= 200000) { atomic_store(&g_metaIso, ni); L("WS: ISO %d", ni); }
                        } else if ([cmd hasPrefix:@"mdon="]) {
                            int nm = [[cmd substringFromIndex:5] intValue];
                            if (nm >= 0 && nm <= 1) { atomic_store(&g_metaOn, nm); L("WS: MDON %d", nm); }
                        } else if ([cmd isEqualToString:@"status?"]) {
                            // Kompakten Status als maskierten WS-Text-Frame zuruecksenden
                            char sb[512];
                            snprintf(sb, sizeof(sb),
                                "build=%s stage=%lld mdon=%d luma=%lld lux=%lld expt=%.6f snr=%.1f iso=%lld "
                                "inplace=%llu errors=%llu hasFrame=%llu origFmt=0x%08x origSize=%lldx%lld "
                                "decodedFmt=0x%08x decodedSize=%lldx%lld",
                                VCAM_BUILD_ID, (long long)atomic_load(&g_stage),
                                (int)atomic_load(&g_metaOn),
                                (long long)atomic_load(&g_videoLuma),
                                (long long)atomic_load(&g_videoLux),
                                (double)g_metaExposure, (double)g_metaSnr,
                                (long long)atomic_load(&g_metaIso),
                                (unsigned long long)atomic_load(&g_inplaceSwap),
                                (unsigned long long)atomic_load(&g_decodeErrorCount),
                                (unsigned long long)atomic_load(&g_hasLatestFrame),
                                (unsigned)(long long)atomic_load(&g_origPixelFormat),
                                (long long)atomic_load(&g_origWidth),
                                (long long)atomic_load(&g_origHeight),
                                (unsigned)(long long)atomic_load(&g_decodedFormat),
                                (long long)atomic_load(&g_decodedWidth),
                                (long long)atomic_load(&g_decodedHeight));
                            NSString *s = [NSString stringWithUTF8String:sb];
                            if (s) {
                                NSData *sd = [s dataUsingEncoding:NSUTF8StringEncoding];
                                NSUInteger slen = sd.length;
                                uint8_t hdr[10];
                                size_t hl = 2;
                                hdr[0] = 0x81;
                                if (slen < 126) {
                                    hdr[1] = (uint8_t)slen;
                                } else if (slen < 65536) {
                                    hdr[1] = 126;
                                    hdr[2] = (uint8_t)(slen >> 8);
                                    hdr[3] = (uint8_t)(slen & 0xff);
                                    hl = 4;
                                } else {
                                    hdr[1] = 127;
                                    for (int b = 0; b < 8; b++) hdr[2 + b] = (uint8_t)(slen >> (56 - b * 8));
                                    hl = 10;
                                }
                                hdr[1] |= 0x80;   // Client->Server: maskiert
                                uint8_t mask[4];
                                for (int i = 0; i < 4; i++) mask[i] = (uint8_t)(rand() & 0xff);
                                size_t total = hl + 4 + slen;
                                uint8_t *out = malloc(total);
                                if (out) {
                                    memcpy(out, hdr, hl);
                                    memcpy(out + hl, mask, 4);
                                    const uint8_t *src = (const uint8_t *)sd.bytes;
                                    for (NSUInteger i = 0; i < slen; i++)
                                        out[hl + 4 + i] = src[i] ^ mask[i & 3];
                                    sendAllFD(fd, out, total);
                                    free(out);
                                    L("WS: Status zurueckgesendet (%zu Bytes)", slen);
                                }
                            }
                        }
                    }
                    free(payload);
                } else {
                    free(payload);
                }
            }
            close(fd);
            L("Hub-Verbindung verloren — Reconnect in 2s");
        }
        sleep(2);
    }
}

// ---------------------------------------------------------------- Methoden-Diagnose
static void logMethodsOfClass(Class cls, const char *className, char *dump) {
    if (!cls) {
        snprintf(dump, 4096, "%s: KLASSE FEHLT", className);
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    size_t off = 0;
    dump[0] = 0;
    off += snprintf(dump + off, 4096 - off, "%s (%u Methoden): ", className, count);
    for (unsigned int i = 0; i < count && off < 4096 - 200; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        int w = snprintf(dump + off, 4096 - off, "%s; ", name);
        if (w > 0) off += w;
    }
    if (methods) free(methods);
    L("Methoden von %s erfasst", className);
}

// ---------------------------------------------------------------- copyNext-Klassen finden
static Class ClassThatImplementsSelector(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        BOOL found = NO;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == sel) {
                found = YES;
                break;
            }
        }
        free(methods);
        if (found) return c;
    }
    return Nil;
}

static void dumpCopyNextClasses(void) {
    SEL sel = sel_registerName("copyNextSampleBuffer:");
    int count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    size_t off = 0;
    g_copyClasses[0] = 0;
    off += snprintf(g_copyClasses + off, sizeof(g_copyClasses) - off, "copyNext: ");
    int found = 0;
    for (int i = 0; i < count && off < sizeof(g_copyClasses) - 300; i++) {
        Class cls = classes[i];
        Method inherited = class_getInstanceMethod(cls, sel);
        if (inherited) {
            Class impl = ClassThatImplementsSelector(cls, sel);
            int w = snprintf(g_copyClasses + off, sizeof(g_copyClasses) - off,
                "%s(impl=%s)|%s; ", class_getName(cls),
                impl ? class_getName(impl) : "?",
                method_getTypeEncoding(inherited));
            if (w > 0) off += w;
            found++;
        }
    }
    free(classes);
    if (!found) {
        snprintf(g_copyClasses, sizeof(g_copyClasses), "copyNext: KEINE Klasse gefunden (auch nicht geerbt)");
    }
    L("copyNextSampleBuffer: %d Klassen (inkl. geerbt)", found);
}

// ---------------------------------------------------------------- LordVCAM-Selector-Besitzer finden
static void __attribute__((unused)) dumpSelectorOwners(void) {
    const char *sels[] = {
        "emitSampleBuffer:",
        "sendMediaServerdSampleAtPoint:",
        "setOriginalDelegate:",
        "emitStillImageReferenceFrameBracketedCaptureSequenceNumberMessageWithSequenceNumber:",
        "emitStillImagePrewarmMessageWithSettings:"
    };
    int nsels = sizeof(sels) / sizeof(sels[0]);
    int count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    size_t off = 0;
    g_selectorDump[0] = 0;

    for (int s = 0; s < nsels; s++) {
        SEL sel = sel_registerName(sels[s]);
        off += snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off,
                        "[%s] -> ", sels[s]);
        int found = 0;
        for (int i = 0; i < count && off < sizeof(g_selectorDump) - 400; i++) {
            Class cls = classes[i];
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                Class impl = ClassThatImplementsSelector(cls, sel);
                int w = snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off,
                    "%s; ", impl ? class_getName(impl) : class_getName(cls));
                if (w > 0) off += w;
                found++;
            }
        }
        if (!found) off += snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off, "(keine)");
        off += snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off, "\n");
    }
    free(classes);
    L("Selector-Besitzer-Diagnose fertig");
}

// ---------------------------------------------------------------- Foto/Video-Klassen finden
static void dumpWildcardClasses(void) {
    // In lokalen Puffer bauen, am Ende atomar in g_sinkClasses kopieren (kein Race).
    int count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    char tmp[8192];
    size_t off = 0;
    tmp[0] = 0;
    off += snprintf(tmp + off, sizeof(tmp) - off, "Sinks: ");

    const char *patterns[] = {
        "BWStillImage", "StillImage", "BWPhoto", "Photo", "Movie", "Recording",
        "BWVideo", "Capture", "Sink", "Scaler", "BWNode", "FigCapture", "FigStillImage"
    };
    int npat = sizeof(patterns) / sizeof(patterns[0]);
    int classCount = 0;

    for (int i = 0; i < count && off < sizeof(tmp) - 400; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        BOOL match = NO;
        for (int p = 0; p < npat; p++) {
            if (strstr(name, patterns[p])) { match = YES; break; }
        }
        if (!match) continue;
        classCount++;

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            const char *mn = sel_getName(method_getName(methods[j]));
            if (strstr(mn, "ample") || strstr(mn, "ixel") || strstr(mn, "emit")
                || strstr(mn, "utput") || strstr(mn, "eliver") || strstr(mn, "encode")
                || strstr(mn, "hotos") || strstr(mn, "humbnail")) {
                int w = snprintf(tmp + off, sizeof(tmp) - off,
                    "%s::%s; ", name, mn);
                if (w > 0) off += w;
            }
        }
        free(methods);
    }
    free(classes);
    if (off == (size_t)snprintf(tmp, 8, "Sinks: ")) {
        snprintf(tmp, sizeof(tmp),
            "Sinks: KEINE Klassen (%d Klassen insgesamt, %d gematcht)", count, classCount);
    }
    memcpy(g_sinkClasses, tmp, sizeof(tmp));
    L("Sink-Klassen-Diagnose fertig (%d gematcht)", classCount);
}

// ---------------------------------------------------------------- Sink-Beobachtung (Astra: Video-/Recording-/Foto-Pfade)
// Globals stehen oben bei der Telemetrie. Hier nur der Mess-Helper.

static void measureSinkAtomic(_Atomic uint64_t *calls, _Atomic int64_t *w,
                              _Atomic int64_t *h, _Atomic int64_t *fmt,
                              _Atomic int64_t *surf, CMSampleBufferRef sb) {
    atomic_fetch_add(calls, 1);
    if (!sb) return;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px) return;
    atomic_store(w, (int64_t)CVPixelBufferGetWidth(px));
    atomic_store(h, (int64_t)CVPixelBufferGetHeight(px));
    atomic_store(fmt, (int64_t)CVPixelBufferGetPixelFormatType(px));
    IOSurfaceRef s = CVPixelBufferGetIOSurface(px);
    atomic_store(surf, s ? (int64_t)IOSurfaceGetID(s) : -1);
}

// Von Astra gefordert: Orientierung/Transform-Attachments des ORIGINAL-
// SampleBuffers UND dessen CVPixelBuffer-Attachments auslesen.
// Getrennte Dumps: 750x1000 (Foto) und 750x1334 (Video).
static void dumpOrientationAttachments(CMSampleBufferRef sb) {
    if (!sb) return;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px) return;
    int w = (int)CVPixelBufferGetWidth(px);
    int h = (int)CVPixelBufferGetHeight(px);

    char *buf;
    _Atomic int64_t *guard;
    if (w == 750 && h == 1334) { buf = g_orientDump_video; guard = &g_orientDumped_video; }
    else { buf = g_orientDump; guard = &g_orientDumped; }
    if (atomic_load(guard)) return;
    atomic_store(guard, 1);

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    size_t off = 0;
    off += snprintf(buf + off, 4096 - off, "ORIENT w=%d h=%d fmt=0x%08x ", w, h,
                    (unsigned)CVPixelBufferGetPixelFormatType(px));

    // 1) CVPixelBuffer-Attachments (dort steckt meist die Orientierung!)
    CFDictionaryRef pbAtts = CVBufferGetAttachments(px, kCVAttachmentMode_ShouldPropagate);
    if (pbAtts) {
        NSDictionary *d = (__bridge NSDictionary *)pbAtts;
        for (NSString *k in d) {
            id v = d[k];
            off += snprintf(buf + off, 4096 - off, "PB[%s]=%s; ",
                            [k UTF8String], [[v description] UTF8String]);
        }
    }

    // 2) SampleBuffer-Attachments
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef att0 = CFArrayGetValueAtIndex(attachments, 0);
        if (att0) {
            NSDictionary *d = (__bridge NSDictionary *)att0;
            for (NSString *k in d) {
                id v = d[k];
                off += snprintf(buf + off, 4096 - off, "SB[%s]=%s; ",
                                [k UTF8String], [[v description] UTF8String]);
            }
        }
    }

    // 3) Clean Aperture + Pixel Aspect Ratio + Rotation aus Format-Extensions
    if (fmt) {
        CFDictionaryRef ext = CMFormatDescriptionGetExtensions(fmt);
        if (ext) {
            CFDictionaryRef cleanAperture = CFDictionaryGetValue(
                ext, kCMFormatDescriptionExtension_CleanAperture);
            if (cleanAperture) {
                NSString *s = [(__bridge NSDictionary *)cleanAperture description];
                off += snprintf(buf + off, 4096 - off, "CleanAperture=%s; ", [s UTF8String]);
            }
            CFDictionaryRef par = CFDictionaryGetValue(
                ext, kCMFormatDescriptionExtension_PixelAspectRatio);
            if (par) {
                NSString *s = [(__bridge NSDictionary *)par description];
                off += snprintf(buf + off, 4096 - off, "PixelAspectRatio=%s; ", [s UTF8String]);
            }
            // Rotation key ausprobieren (kCMFormatDescriptionKey und alte iOS-Schlüssel)
            NSNumber *rot = (__bridge NSNumber *)CFDictionaryGetValue(ext, @"Rotation");
            if (!rot) rot = (__bridge NSNumber *)CFDictionaryGetValue(ext, @"Orientation");
            if (rot) {
                off += snprintf(buf + off, 4096 - off, "Rot=%s; ", [[rot stringValue] UTF8String]);
            }
        }
    }
    L("Orient-Dump(%dx%d): %s", w, h, buf);
}

// ---- BWImageQueueSinkNode (PREVIEW-Pfad!) ----
static void hook_iqRender(id self, SEL _cmd, id sampleBuffer, id input) {
    CMSampleBufferRef sb = (__bridge CMSampleBufferRef)sampleBuffer;
    if (atomic_load(&g_diag)) {
        measureSinkAtomic(&g_iqCalls, &g_iqWidth, &g_iqHeight, &g_iqFmt, &g_iqSurf, sb);
        dumpOrientationAttachments(sb);
    }
    if (atomic_load(&g_stage) >= 3 && atomic_load(&g_replacementEnabled) &&
        !atomic_load(&g_photoInProgress) && !atomic_load(&g_recordingInProgress)) {
        if (swapPixelsInPlace(sb)) {
            atomic_fetch_add(&g_iqSwaps, 1);
            orig_iqRender(self, _cmd, sampleBuffer, input);
            return;
        }
    }
    orig_iqRender(self, _cmd, sampleBuffer, input);
}

// ---- BWQuickTimeMovieFileSinkNode (Recording-Pfad) ----
static void hook_qtRender(id self, SEL _cmd, id sampleBuffer, id input) {
    measureSinkAtomic(&g_qtCalls, &g_qtWidth, &g_qtHeight, &g_qtFmt, &g_qtSurf,
                      (__bridge CMSampleBufferRef)sampleBuffer);
    orig_qtRender(self, _cmd, sampleBuffer, input);
}

// ---- BWStillImageSampleBufferSinkNode (Foto-Pfad) ----
static void hook_stRender(id self, SEL _cmd, id sampleBuffer, id input) {
    measureSinkAtomic(&g_stCalls, &g_stWidth, &g_stHeight, &g_stFmt, &g_stSurf,
                      (__bridge CMSampleBufferRef)sampleBuffer);
    orig_stRender(self, _cmd, sampleBuffer, input);
}

// ---------------------------------------------------------------- ctor
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("injiziert in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"mediaserverd"]) return;

    // LORDVCAM-STIL (1): Private Frameworks VOR dem Hooken laden.
    // Sonst existieren die BW*-Klassen beim Hooken evtl. noch nicht.
    dlopen("/System/Library/PrivateFrameworks/CMCaptureCore.framework/CMCaptureCore", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    L("Frameworks geladen");

    // LORDVCAM-STIL (2): NSClassFromString-Guard vor JEDEM Hook.
    // Nur objc_getClass auf bereits verifizierte Klassen; nil-Klassen
    // werden NICHT gehookt (das war der SIGSEGV mit Logos-%hook).
    Class bwOutput = NSClassFromString(@"BWNodeOutput");
    if (!bwOutput) bwOutput = objc_getClass("BWNodeOutput");
    if (bwOutput && !orig_emitSampleBuffer) {
        MSHookMessageEx(bwOutput, sel_registerName("emitSampleBuffer:"),
                        (IMP)hook_emitSampleBuffer, (IMP*)&orig_emitSampleBuffer);
        L("Hook: BWNodeOutput emitSampleBuffer:");
    } else {
        L("SKIP: BWNodeOutput nicht vorhanden");
    }

    Class avPhoto = NSClassFromString(@"AVCapturePhotoOutput");
    if (!avPhoto) avPhoto = objc_getClass("AVCapturePhotoOutput");
    if (avPhoto) {
        MSHookMessageEx(avPhoto, sel_registerName("capturePhotoWithSettings:delegate:"),
                        (IMP)hook_capturePhotoDelegate, (IMP*)&orig_capturePhotoDelegate);
        MSHookMessageEx(avPhoto, sel_registerName("capturePhotoWithSettings:delegate:completionHandler:"),
                        (IMP)hook_capturePhotoCompletion, (IMP*)&orig_capturePhotoCompletion);
        L("Hook: AVCapturePhotoOutput capturePhoto*");
    }

    Class bwPhoto = NSClassFromString(@"BWPhotoEncoderNode");
    if (!bwPhoto) bwPhoto = objc_getClass("BWPhotoEncoderNode");
    if (bwPhoto) {
        MSHookMessageEx(bwPhoto, sel_registerName("renderSampleBuffer:forInput:"),
                        (IMP)hook_photoRender, (IMP*)&orig_photoRender);
        L("Hook: BWPhotoEncoderNode renderSampleBuffer:forInput:");
    }

    Class bwIQ = NSClassFromString(@"BWImageQueueSinkNode");
    if (!bwIQ) bwIQ = objc_getClass("BWImageQueueSinkNode");
    if (bwIQ) {
        MSHookMessageEx(bwIQ, sel_registerName("renderSampleBuffer:forInput:"),
                        (IMP)hook_iqRender, (IMP*)&orig_iqRender);
        L("Hook: BWImageQueueSinkNode renderSampleBuffer:forInput:");
    }

    Class bwQT = NSClassFromString(@"BWQuickTimeMovieFileSinkNode");
    if (!bwQT) bwQT = objc_getClass("BWQuickTimeMovieFileSinkNode");
    if (bwQT) {
        MSHookMessageEx(bwQT, sel_registerName("renderSampleBuffer:forInput:"),
                        (IMP)hook_qtRender, (IMP*)&orig_qtRender);
        L("Hook: BWQuickTimeMovieFileSinkNode renderSampleBuffer:forInput:");
    }

    Class bwST = NSClassFromString(@"BWStillImageSampleBufferSinkNode");
    if (!bwST) bwST = objc_getClass("BWStillImageSampleBufferSinkNode");
    if (bwST) {
        MSHookMessageEx(bwST, sel_registerName("renderSampleBuffer:forInput:"),
                        (IMP)hook_stRender, (IMP*)&orig_stRender);
        L("Hook: BWStillImageSampleBufferSinkNode renderSampleBuffer:forInput:");
    }

    g_nalQueue = [NSMutableArray array];
    g_queueLock = [NSLock new];
    g_frameLock = [NSLock new];

    L("VCamInject build=%s", VCAM_BUILD_ID);
    L("START stage=0 (MSHookMessageEx + Guards). Steuerung: Port 8769 'stage=N'");

    // WS-Client + Decoder nur ab stage 2 (wird zur Laufzeit umgeschaltet).
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (atomic_load(&g_stage) < 2) sleep(1);
        L("WS-Block betreten (stage>=2)");
        wsClientThread();
        L("WS-Thread beendet");
    });

    L("nach WS-Dispatch");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (1) {
            if (atomic_load(&g_stage) >= 2) pumpDecoder();
            maybeResetPhotoGuard();
            usleep(2500);
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        statusServerThread();
    });
    L("bereit — stage 0 aktiv");
}
