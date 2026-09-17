// VCamInject CANARY — minimaler Lade-Test
// Testet NUR: injiziert die Dylib sauber in mediaserverd? Startet der
// Status-Server? KEINE Hooks, KEIN WS, KEIN Decoder.
//
// Zweck: isoliert den SIGTRAP-Crash beim Start. Wenn DAS crasht,
// liegt es am Build/Link/Signatur/PAC, nicht an unserem Code.
#define VCAM_BUILD_ID "canary-2026-09-17-01"

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <stdatomic.h>
#import <os/log.h>
#import <unistd.h>

#define STATUS_PORT 8769

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcaminject", "canary"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

static _Atomic uint64_t g_startCount = 0;

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
    L("CANARY Status-Server auf 127.0.0.1:%d (pid=%d)", STATUS_PORT, getpid());
    while (1) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        char buf[256] = {0};
        recv(c, buf, sizeof(buf) - 1, 0);
        atomic_fetch_add(&g_startCount, 1);
        char resp[512] = {0};
        snprintf(resp, sizeof(resp),
                 "CANARY OK build=%s pid=%d starts=%llu\n",
                 VCAM_BUILD_ID, getpid(),
                 (unsigned long long)atomic_load(&g_startCount));
        send(c, resp, strlen(resp), 0);
        close(c);
    }
}

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("CANARY injiziert in %@ (pid=%d) build=%s", proc, getpid(), VCAM_BUILD_ID);
    if (![proc isEqualToString:@"mediaserverd"]) return;

    // Status-Server NUR in mediaserverd starten
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        statusServerThread();
    });
    L("CANARY bereit (kein Hook, kein WS, kein Decoder)");
}