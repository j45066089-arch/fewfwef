// AppIso — separates Mini-Tweak: ISO-Hook NUR in App-Prozessen.
// Zweck: Diagnose + Fix des AVCaptureDevice.ISO-Werts in ProCamera.
// Loggt in den App-Container (NSHomeDirectory/Documents), wo die App
// garantiert Schreibrechte hat — im Gegensatz zum Daemon (/var/tmp gesperrt).
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <dlfcn.h>

#define VCAM_ISO_NOTIFY "com.nikeboy.vcam.iso"

static void APILOG(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    @autoreleasepool {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!doc) return;
        NSString *path = [doc stringByAppendingPathComponent:@"vcamappiso.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [@"--- AppIso Log ---\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithUTF8String:buf] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

static uint64_t monoNs(void) {
    static mach_timebase_info_data_t tb = {0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

// ---- Cache + Listener ----
static int g_isoTokenApp = -1;
static _Atomic uint32_t g_isoCacheValue = 0;
static _Atomic uint32_t g_isoCacheSeq = 0;
static _Atomic uint64_t g_isoCacheAtNs = 0;
static _Atomic uint64_t g_getterCalls = 0;
static _Atomic uint64_t g_figCalls = 0;

static void refreshIsoCache(void) {
    if (g_isoTokenApp < 0) return;
    uint64_t raw = 0;
    if (notify_get_state(g_isoTokenApp, &raw) != NOTIFY_STATUS_OK) return;
    uint32_t iso = (uint32_t)(raw & 0xffffffffu);
    uint32_t seq = (uint32_t)(raw >> 32);
    if (iso < 25 || iso > 3200) return;
    atomic_store(&g_isoCacheValue, iso);
    atomic_store(&g_isoCacheSeq, seq);
    atomic_store(&g_isoCacheAtNs, monoNs());
}

static void startIsoListener(void) {
    if (g_isoTokenApp >= 0) return;
    uint32_t r = notify_register_dispatch(VCAM_ISO_NOTIFY, &g_isoTokenApp,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^(int token) { refreshIsoCache(); });
    if (r != NOTIFY_STATUS_OK) {
        APILOG("notify_register_dispatch FAIL r=%u\n", r);
        g_isoTokenApp = -1;
        return;
    }
    refreshIsoCache();
    APILOG("notify listener registriert, initial state gelesen\n");
}

// ---- Getter-Hooks (float-ABI -> method_setImplementation) ----
static float (*orig_AVISO)(id self, SEL _cmd);
static float (*orig_FigISO)(id self, SEL _cmd);

static float hook_AVISO(id self, SEL _cmd) {
    uint64_t n = atomic_fetch_add(&g_getterCalls, 1) + 1;
    uint32_t iso = atomic_load(&g_isoCacheValue);
    uint32_t seq = atomic_load(&g_isoCacheSeq);
    uint64_t age = monoNs() - atomic_load(&g_isoCacheAtNs);
    if ((n & 0x3ff) == 1) {   // alle 1024 Calls loggen
        APILOG("AVCaptureDevice.ISO call #%llu cacheIso=%u seq=%u ageMs=%llu\n",
               (unsigned long long)n, iso, seq, (unsigned long long)(age / 1000000));
    }
    if (iso >= 25 && iso <= 3200 && seq != 0 && age < 3000000000ULL) {
        return (float)iso;
    }
    return orig_AVISO(self, _cmd);
}

static float hook_FigISO(id self, SEL _cmd) {
    uint64_t n = atomic_fetch_add(&g_figCalls, 1) + 1;
    uint32_t iso = atomic_load(&g_isoCacheValue);
    uint32_t seq = atomic_load(&g_isoCacheSeq);
    uint64_t age = monoNs() - atomic_load(&g_isoCacheAtNs);
    if ((n & 0x3ff) == 1) {
        APILOG("FigCaptureDevice.iso call #%llu cacheIso=%u seq=%u\n",
               (unsigned long long)n, iso, seq);
    }
    if (iso >= 25 && iso <= 3200 && seq != 0 && age < 3000000000ULL) {
        return (float)iso;
    }
    return orig_FigISO(self, _cmd);
}

static _Atomic int g_installed = 0;

static void installHooks(void) {
    if (atomic_exchange(&g_installed, 1)) return;
    NSString *proc = [[NSProcessInfo processInfo] processName];
    APILOG("ctor: proc=%s pid=%d\n", [proc UTF8String] ?: "?", getpid());

    startIsoListener();

    dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_NOW);
    Class avDev = NSClassFromString(@"AVCaptureDevice");
    if (!avDev) avDev = objc_getClass("AVCaptureDevice");
    if (avDev) {
        Method m = class_getInstanceMethod(avDev, sel_registerName("ISO"));
        if (m) {
            orig_AVISO = (float (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_AVISO);
            APILOG("Hook installiert: AVCaptureDevice ISO\n");
        } else {
            APILOG("KEINE Methode: AVCaptureDevice ISO\n");
        }
    } else {
        APILOG("Klasse nicht gefunden: AVCaptureDevice\n");
    }

    dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW);
    Class figDev = NSClassFromString(@"FigCaptureDevice");
    if (!figDev) figDev = objc_getClass("FigCaptureDevice");
    if (figDev) {
        Method m = class_getInstanceMethod(figDev, sel_registerName("iso"));
        if (m) {
            orig_FigISO = (float (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_FigISO);
            APILOG("Hook installiert: FigCaptureDevice iso\n");
        } else {
            APILOG("KEINE Methode: FigCaptureDevice iso\n");
        }
    } else {
        APILOG("Klasse nicht gefunden: FigCaptureDevice\n");
    }
}

__attribute__((constructor))
static void appiso_ctor(void) {
    @autoreleasepool {
        installHooks();
    }
}
