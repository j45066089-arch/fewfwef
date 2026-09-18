// AppIso — separates Mini-Tweak: ISO-Hook NUR in App-Prozessen.
// Zweck: bildbasierte ISO (vom Daemon via Darwin Notification) in Apps
// durchsetzen — ProCamera & Co. lesen die ISO NICHT über den
// AVCaptureDevice.ISO-Getter, sondern aus der userInfo der
// AVCaptureDeviceSubjectAreaDidChangeNotification (Key "AVCaptureISOCurrent").
// Loggt in den App-Container (NSHomeDirectory/Documents).
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
#import <execinfo.h>

#define VCAM_ISO_NOTIFY "com.nikeboy.vcam.iso"
#define VCAM_EXPT_NOTIFY "com.nikeboy.vcam.expt"

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
static _Atomic uint64_t g_notifCalls = 0;
static _Atomic uint64_t g_notifFaked = 0;
static _Atomic uint64_t g_exptUs = 0;      // Belichtung in Mikrosekunden (vom Daemon)

static void refreshIsoCache(void) {
    if (g_isoTokenApp < 0) return;
    uint64_t raw = 0;
    if (notify_get_state(g_isoTokenApp, &raw) != NOTIFY_STATUS_OK) return;
    // expt mitlesen
    {
        static int exptTok = -1;
        if (exptTok < 0) notify_register_check(VCAM_EXPT_NOTIFY, &exptTok);
        if (exptTok >= 0) {
            uint64_t e = 0;
            if (notify_get_state(exptTok, &e) == NOTIFY_STATUS_OK && e > 0) {
                atomic_store(&g_exptUs, e);
            }
        }
    }
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

// Liefert bildbasierte ISO, wenn Cache frisch (<=3s), sonst -1.
static int32_t validIsoValue(void) {
    uint32_t iso = atomic_load(&g_isoCacheValue);
    uint32_t seq = atomic_load(&g_isoCacheSeq);
    uint64_t age = monoNs() - atomic_load(&g_isoCacheAtNs);
    if (iso >= 25 && iso <= 3200 && seq != 0 && age < 3000000000ULL) {
        return (int32_t)iso;
    }
    return -1;
}

// ---- Getter-Hooks (float-ABI -> method_setImplementation) ----------------
static float (*orig_AVISO)(id self, SEL _cmd);

static float hook_AVISO(id self, SEL _cmd) {
    uint64_t n = atomic_fetch_add(&g_getterCalls, 1) + 1;
    if ((n & 0x3ff) == 1) APILOG("AVCaptureDevice.ISO call #%llu\n", (unsigned long long)n);
    int32_t iso = validIsoValue();
    if (iso > 0) return (float)iso;
    return orig_AVISO(self, _cmd);
}

// ---- Notification-Hook: userInfo-ISO fälschen ----------------------------
// ProCamera liest die Live-ISO aus AVCaptureDeviceSubjectAreaDidChangeNotification
// userInfo[AVCaptureISOCurrent] (String-Beweis: _AVCaptureISOCurrent in Binary).
// Hook auf die zentrale Methode postNotification: — dort wird das userInfo
// der ISO-Notification ersetzt. Kein IPC im Hook, nur atomarer Cache.
static void (*orig_postNotification)(id self, SEL _cmd, NSNotification *note);

static void hook_postNotification(id self, SEL _cmd, NSNotification *note) {
    if ([note.name isEqualToString:@"AVCaptureDeviceSubjectAreaDidChangeNotification"]) {
        NSDictionary *ui = note.userInfo;
        int32_t iso = validIsoValue();
        if (iso > 0 && ui.count) {
            BOOL changed = NO;
            NSMutableDictionary *mut = [ui mutableCopy];
            for (NSString *k in [ui allKeys]) {
                // alle ISO-relevanten Keys abdecken (AVCaptureISOCurrent, AVCaptureDeviceISOKey, ISO)
                if ([k rangeOfString:@"ISO" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    mut[k] = @((float)iso);
                    changed = YES;
                }
            }
            if (changed) {
                atomic_fetch_add(&g_notifFaked, 1);
                note = [NSNotification notificationWithName:note.name object:note.object userInfo:mut];
                if ((atomic_load(&g_notifFaked) & 0x3ff) == 1)
                    APILOG("Notification-ISO gefälscht auf %d (notifFaked=%llu)\n",
                           iso, (unsigned long long)atomic_load(&g_notifFaked));
            }
        }
        atomic_fetch_add(&g_notifCalls, 1);
    }
    orig_postNotification(self, _cmd, note);
}

// ---- KVO-Hook: ISO-Wert im Change-Dictionary ersetzen -------------------
static void (*orig_observeValue)(id self, SEL _cmd, NSString *keyPath, id object, NSDictionary *change, void *context);
static _Atomic uint64_t g_kvoObserved = 0;
static _Atomic uint64_t g_kvoFaked = 0;

static void hook_observeValue(id self, SEL _cmd, NSString *keyPath, id object,
                              NSDictionary *change, void *context) {
    // KeyPath-Log (nur ISO-relevante, gedrosselt)
    if ([keyPath rangeOfString:@"ISO" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [keyPath rangeOfString:@"exposure" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        atomic_fetch_add(&g_kvoObserved, 1);
        uint64_t n = atomic_load(&g_kvoObserved);
        if ((n & 0x3ff) == 1) {
            APILOG("KVO: keyPath=%@ obj=%@ change=%@\n", keyPath, [object class],
                   change ? change : @"{nil}");
        }
    }
    // ISO-KeyPath: NewKey-Wert fälschen
    if ([keyPath rangeOfString:@"ISO" options:NSCaseInsensitiveSearch].location != NSNotFound && change) {
        int32_t iso = validIsoValue();
        if (iso > 0 && change[NSKeyValueChangeNewKey]) {
            NSMutableDictionary *mut = [change mutableCopy];
            mut[NSKeyValueChangeNewKey] = @((float)iso);
            change = mut;
            atomic_fetch_add(&g_kvoFaked, 1);
            uint64_t f = atomic_load(&g_kvoFaked);
            if ((f & 0x3ff) == 1) {
                APILOG("KVO-ISO gefälscht auf %d (faked=%llu)\n", iso, (unsigned long long)f);
            }
        }
    }
    orig_observeValue(self, _cmd, keyPath, object, change, context);
}

// ---- CCCameraController-Wrapper-Hooks (Astra: erster Test) -----------------
static _Atomic uint64_t g_cccISOCalls = 0;
static _Atomic uint64_t g_cccMinCalls = 0;
static _Atomic uint64_t g_cccMaxCalls = 0;
static _Atomic uint64_t g_cccSetCalls = 0;
static _Atomic int g_cccHooked = 0;

// generischer Observe-Logger: ruft original, loggt Call + Wert + Backtrace
static void logCCC(const char *sel, id obj, const char *type, uint64_t n) {
    if ((n & 0x3ff) == 1 || n <= 3) {   // erste 3 + alle 1024
        void *frames[16];
        int cnt = backtrace(frames, 16);
        char **syms = backtrace_symbols(frames, cnt);
        NSMutableString *bt = [NSMutableString string];
        for (int i = 2; i < cnt && i < 7; i++) {
            [bt appendFormat:@"  #%d %s\n", i - 2, syms[i] ?: "?"];
        }
        free(syms);
        APILOG("CCCameraController %s call #%llu obj=%s class=%s super=%s type=%s\n%s",
               sel, (unsigned long long)n,
               [obj description].UTF8String ?: "?",
               object_getClassName(obj) ?: "?",
               class_getName(class_getSuperclass(object_getClass(obj))) ?: "?",
               type, bt.UTF8String ?: "?");
    }
}

// float-Getter-Hooks (ISO/minISO/maxISO)
static float (*orig_ccc_ISOFunc)(id, SEL);
static float hook_ccc_ISO(id self, SEL _cmd) {
    atomic_fetch_add(&g_cccISOCalls, 1);
    int32_t fake = validIsoValue();
    if (fake > 0) {
        if ((atomic_load(&g_cccISOCalls) & 0x3ff) == 1)
            APILOG("CCCameraController ISO -> FAKE %d (statt orig)\n", fake);
        return (float)fake;
    }
    logCCC("ISO", self, "f", atomic_load(&g_cccISOCalls));
    return orig_ccc_ISOFunc(self, _cmd);
}
static float (*orig_ccc_MinFunc)(id, SEL);
static float hook_ccc_MinISO(id self, SEL _cmd) {
    atomic_fetch_add(&g_cccMinCalls, 1);
    logCCC("minISO", self, "f", atomic_load(&g_cccMinCalls));
    return orig_ccc_MinFunc(self, _cmd);
}
static float (*orig_ccc_MaxFunc)(id, SEL);
static float hook_ccc_MaxISO(id self, SEL _cmd) {
    atomic_fetch_add(&g_cccMaxCalls, 1);
    logCCC("maxISO", self, "f", atomic_load(&g_cccMaxCalls));
    return orig_ccc_MaxFunc(self, _cmd);
}
// setISO: — void-return
static void (*orig_ccc_SetFunc)(id, SEL, float);
static void hook_ccc_SetISO(id self, SEL _cmd, float iso) {
    atomic_fetch_add(&g_cccSetCalls, 1);
    int32_t fake = validIsoValue();
    if (fake > 0) {
        if ((atomic_load(&g_cccSetCalls) & 0x3ff) == 1)
            APILOG("CCCameraController setISO: %.1f -> FAKE %d (erstattet)\n", iso, fake);
        iso = (float)fake;
    }
    orig_ccc_SetFunc(self, _cmd, iso);
}

static void installCCCHooks(Class cls) {
    // Methodeninventar (ISO/Exposure/Sample/Metadata/Frame) — Astra Schritt B
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    APILOG("CCCameraController Methodeninventar (%u Methoden):\n", count);
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = sel_getName(method_getName(methods[i]));
        if (strstr(nm, "ISO") || strstr(nm, "Exposure") || strstr(nm, "Sample") ||
            strstr(nm, "Metadata") || strstr(nm, "Frame") || strstr(nm, "iso")) {
            APILOG("  %s :: %s\n", nm, method_getTypeEncoding(methods[i]));
        }
    }
    free(methods);
    Method m;
    m = class_getInstanceMethod(cls, sel_registerName("ISO"));
    if (m && !orig_ccc_ISOFunc) {
        orig_ccc_ISOFunc = (float (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_ccc_ISO);
        APILOG("Hook installiert: CCCameraController ISO\n");
    }
    m = class_getInstanceMethod(cls, sel_registerName("minISO"));
    if (m && !orig_ccc_MinFunc) {
        orig_ccc_MinFunc = (float (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_ccc_MinISO);
        APILOG("Hook installiert: CCCameraController minISO\n");
    }
    m = class_getInstanceMethod(cls, sel_registerName("maxISO"));
    if (m && !orig_ccc_MaxFunc) {
        orig_ccc_MaxFunc = (float (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_ccc_MaxISO);
        APILOG("Hook installiert: CCCameraController maxISO\n");
    }
    m = class_getInstanceMethod(cls, sel_registerName("setISO:"));
    if (m && !orig_ccc_SetFunc) {
        orig_ccc_SetFunc = (void (*)(id, SEL, float))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_ccc_SetISO);
        APILOG("Hook installiert: CCCameraController setISO:\n");
    }
}

// ---- FOTO-EXIF: AVCapturePhotoSettings.metadata fälschen ------------------
// Apple schreibt settings.metadata ({Exif}-Keys) ins fertige Foto-EXIF.
// Beim capturePhoto-Aufruf befüllen wir es mit bildbasierter ISO + expt.
static void (*orig_capturePhotoDelegate)(id self, SEL _cmd, id settings, id delegate);
static void (*orig_capturePhotoCompletion)(id self, SEL _cmd, id settings, id delegate, id handler);

static void injectPhotoExif(id settings) {
    int32_t iso = validIsoValue();
    if (iso <= 0) return;
    uint64_t exptUs = atomic_load(&g_exptUs);
    if (exptUs == 0) exptUs = 8333;   // default 1/120s

    NSMutableDictionary *meta = [[settings valueForKey:@"metadata"] mutableCopy];
    if (!meta) meta = [NSMutableDictionary dictionary];
    NSMutableDictionary *exif = [meta[@"{Exif}"] mutableCopy];
    if (!exif) exif = [NSMutableDictionary dictionary];

    // ExposureTime: Apple erwartet hier die Sekunden als NSNumber (double)
    exif[@"ExposureTime"] = @(exptUs / 1000000.0);
    // ISOSpeedRatings: Array von NSNumbers
    exif[@"ISOSpeedRatings"] = @[ @(iso) ];

    meta[@"{Exif}"] = exif;
    [settings setValue:meta forKey:@"metadata"];

    static _Atomic uint64_t cnt = 0;
    uint64_t n = atomic_fetch_add(&cnt, 1) + 1;
    if ((n & 0xf) == 1) APILOG("Photo-EXIF injiziert: ISO=%d expt=%.6f\n", iso, exptUs / 1000000.0);
}

static void hook_capturePhotoDelegate(id self, SEL _cmd, id settings, id delegate) {
    injectPhotoExif(settings);
    orig_capturePhotoDelegate(self, _cmd, settings, delegate);
}
static void hook_capturePhotoCompletion(id self, SEL _cmd, id settings, id delegate, id handler) {
    injectPhotoExif(settings);
    orig_capturePhotoCompletion(self, _cmd, settings, delegate, handler);
}

static _Atomic int g_installed = 0;

static void installHooks(void) {
    if (atomic_exchange(&g_installed, 1)) return;
    NSString *proc = [[NSProcessInfo processInfo] processName];
    APILOG("ctor: proc=%s pid=%d\n", [proc UTF8String] ?: "?", getpid());

    startIsoListener();

    // 1) Getter-Hook (Apps, die den Getter nutzen)
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

    // 2) KVO-Hook (ProCamera-Pfad: ISO via KVO-Change-Dictionary)
    {
        Method m = class_getInstanceMethod([NSObject class], sel_registerName("observeValueForKeyPath:ofObject:change:context:"));
        if (m) {
            orig_observeValue = (void (*)(id, SEL, NSString *, id, NSDictionary *, void *))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_observeValue);
            APILOG("Hook installiert: NSObject observeValueForKeyPath\n");
        }
    }

    // 3) CCCameraController-Wrapper (Astra: der wahrscheinlichste ISO-Pfad).
    // CCMedia.framework ist App-gebündelt -> über Bundle-Pfad laden, sonst
    // findet NSClassFromString die Klasse nicht (dyld lädt evtl. lazy).
    {
        NSString *ccPath = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Frameworks/CCMedia.framework/CCMedia"];
        dlopen([ccPath UTF8String], RTLD_NOW);
        NSString *uiPath = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Frameworks/CameraUI.framework/CameraUI"];
        dlopen([uiPath UTF8String], RTLD_NOW);
        APILOG("CCMedia/CameraUI dlopen versucht (%s)\n",
               access([ccPath UTF8String], F_OK) == 0 ? "CCMedia da" : "CCMedia fehlt");
    }
    {
        Class cc = NSClassFromString(@"CCCameraController");
        if (!cc) cc = objc_getClass("CCCameraController");
        if (cc) {
            APILOG("CCCameraController gefunden: %s (super=%s)\n",
                   class_getName(cc), class_getName(class_getSuperclass(cc)));
            installCCCHooks(cc);
        } else {
            APILOG("CCCameraController NICHT gefunden — läuft sie in einem anderen Image?\n");
        }
    }

    // 4) AVCapturePhotoOutput-Hook: EXIF-Metadaten beim Foto-Capture injizieren
    {
        Class avPhoto = NSClassFromString(@"AVCapturePhotoOutput");
        if (!avPhoto) avPhoto = objc_getClass("AVCapturePhotoOutput");
        if (avPhoto) {
            Method m1 = class_getInstanceMethod(avPhoto, sel_registerName("capturePhotoWithSettings:delegate:"));
            if (m1) {
                orig_capturePhotoDelegate = (void (*)(id, SEL, id, id))method_getImplementation(m1);
                method_setImplementation(m1, (IMP)hook_capturePhotoDelegate);
                APILOG("Hook installiert: AVCapturePhotoOutput capturePhoto\n");
            }
            Method m2 = class_getInstanceMethod(avPhoto, sel_registerName("capturePhotoWithSettings:delegate:completionHandler:"));
            if (m2) {
                orig_capturePhotoCompletion = (void (*)(id, SEL, id, id, id))method_getImplementation(m2);
                method_setImplementation(m2, (IMP)hook_capturePhotoCompletion);
                APILOG("Hook installiert: AVCapturePhotoOutput capturePhoto(completion)\n");
            }
        } else {
            APILOG("Klasse nicht gefunden: AVCapturePhotoOutput\n");
        }
    }

    // 5) Notification-Hook (ProCamera-Pfad: userInfo-ISO)
    Class nc = NSClassFromString(@"NSNotificationCenter");
    if (!nc) nc = objc_getClass("NSNotificationCenter");
    if (nc) {
        Method m = class_getInstanceMethod(nc, sel_registerName("postNotification:"));
        if (m) {
            orig_postNotification = (void (*)(id, SEL, NSNotification *))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_postNotification);
            APILOG("Hook installiert: NSNotificationCenter postNotification:\n");
        } else {
            APILOG("KEINE Methode: postNotification:\n");
        }
    }
}

__attribute__((constructor))
static void appiso_ctor(void) {
    @autoreleasepool {
        installHooks();
    }
}
