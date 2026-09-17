// VCamHub — WS-Server + Floating-Status-Button in SpringBoard (Dopamine2-roothide)
//
// Architektur (final, nach Astra-Analyse):
//   - Scene-gebundenes Fullscreen-UIWindow (initWithWindowScene:)
//   - VCamOverlayWindow-Subklasse: hitTest:withEvent: gibt außerhalb des
//     Button-/Panel-Bereichs nil zurück -> ALLE Touches gehen durch
//   - Lockscreen-Sicherheitsnetz: bei Lock wird das Overlay sofort hidden
//     und passThrough=YES, erst nach Unlock wieder sichtbar
//   - Status-Server (8768) meldet auch locked=0/1 für Diagnose

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>
#import <pthread.h>

#define WS_PORT 8767
#define MAX_PENDING (16 * 1024 * 1024)

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.nikeboy.vcam", "hub"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Client-Liste
static int g_clients[16] = { -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
static pthread_mutex_t g_cliMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_clientCount = 0;

// ---------------------------------------------------------------- Overlay-Globals
static UIWindow *g_overlayWindow = nil;
static UIView *g_buttonContainer = nil;
static int g_overlayCreated = 0;
static int g_overlayCalls = 0;
static BOOL g_locked = NO;

// ---------------------------------------------------------------- Pass-Through Window
@interface VCamOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@property (nonatomic, weak) UIView *interactivePanel;
@property (nonatomic, assign) BOOL passThrough;
@end
@implementation VCamOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) return nil;
    if (self.passThrough) return nil;

    UIView *target = self.interactiveView;
    if (!target || target.hidden || target.alpha <= 0.01) return nil;

    CGRect buttonRect = [target.superview convertRect:target.frame toView:self];
    buttonRect = CGRectInset(buttonRect, -8.0, -8.0);   // Touch-Toleranz

    CGRect panelRect = CGRectNull;
    if (self.interactivePanel && !self.interactivePanel.hidden) {
        panelRect = [self.interactivePanel.superview convertRect:self.interactivePanel.frame toView:self];
    }

    if (CGRectContainsPoint(buttonRect, point) ||
        (!CGRectIsNull(panelRect) && CGRectContainsPoint(panelRect, point))) {
        return [super hitTest:point withEvent:event];
    }
    return nil;   // alles andere geht durch
}
@end

// ---------------------------------------------------------------- Hub: Client-Verwaltung
static void hubAddClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        if (g_clients[i] == -1) { g_clients[i] = fd; g_clientCount++; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
    L("client+ total=%d", g_clientCount);
}

static void hubRemoveClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        if (g_clients[i] == fd) { g_clients[i] = -1; g_clientCount--; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
    L("client- total=%d", g_clientCount);
}

static BOOL hubSendAll(int fd, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len > 0) {
        ssize_t n = send(fd, p, len > (size_t)INT_MAX ? INT_MAX : (int)len, 0);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static void hubBroadcastExcept(int fromFd, const uint8_t *data, size_t len) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        int fd = g_clients[i];
        if (fd != -1 && fd != fromFd) {
            uint8_t hdr[10];
            size_t hl = 2;
            hdr[0] = 0x82;
            if (len < 126) {
                hdr[1] = (uint8_t)len;
            } else if (len < 65536) {
                hdr[1] = 126;
                hdr[2] = (uint8_t)(len >> 8);
                hdr[3] = (uint8_t)(len & 0xff);
                hl = 4;
            } else {
                hdr[1] = 127;
                for (int b = 0; b < 8; b++) hdr[2 + b] = (uint8_t)(len >> (56 - b * 8));
                hl = 10;
            }
            if (!hubSendAll(fd, hdr, hl) || !hubSendAll(fd, data, len)) continue;
        }
    }
    pthread_mutex_unlock(&g_cliMutex);
}

// ---------------------------------------------------------------- WS Util
static NSString *wsAcceptKey(NSString *key) {
    NSString *magic = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([magic UTF8String], (CC_LONG)strlen([magic UTF8String]), digest);
    return [[NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH] base64EncodedStringWithOptions:0];
}

static ssize_t hubRecvHeaders(int fd, char *buf, size_t cap) {
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

static void *hubClientThread(void *arg) {
    int fd = (int)(intptr_t)arg;
    @autoreleasepool {
        uint8_t *buf = malloc(MAX_PENDING);
        ssize_t n = hubRecvHeaders(fd, (char *)buf, MAX_PENDING);
        if (n > 0) {
            buf[n] = 0;
            NSString *req = [NSString stringWithUTF8String:(const char *)buf];
            NSRange keyR = [req rangeOfString:@"Sec-WebSocket-Key: "];
            if (keyR.location != NSNotFound) {
                NSString *key = [req substringFromIndex:keyR.location + keyR.length];
                key = [[key componentsSeparatedByString:@"\r\n"].firstObject
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *resp = [NSString stringWithFormat:
                    @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
                    wsAcceptKey(key)];
                send(fd, [resp UTF8String], strlen([resp UTF8String]), 0);
                hubAddClient(fd);
                uint8_t hdr[2];
                while (recv(fd, hdr, 2, MSG_WAITALL) == 2) {
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
                    if (plen > MAX_PENDING) break;
                    uint8_t *payload = malloc((size_t)plen);
                    size_t got = 0;
                    while (got < plen) {
                        ssize_t r = recv(fd, payload + got, (size_t)(plen - got), 0);
                        if (r <= 0) break;
                        got += (size_t)r;
                    }
                    if (got < plen) { free(payload); break; }
                    if (masked) for (uint64_t i = 0; i < plen; i++) payload[i] ^= mask[i & 3];
                    if (opcode == 0x8) { free(payload); break; }
                    if (opcode == 0x9) {
                        uint8_t pong_hdr[2] = {0x8A, (uint8_t)(plen & 0x7f)};
                        send(fd, pong_hdr, 2, 0);
                        if (plen > 0) send(fd, payload, (int)plen, 0);
                        free(payload);
                        continue;
                    }
                    if (opcode == 0x2 || opcode == 0x1) {
                        hubBroadcastExcept(fd, payload, (size_t)plen);
                        free(payload);
                        continue;
                    }
                    free(payload);
                }
                hubRemoveClient(fd);
            }
        }
        free(buf);
    }
    close(fd);
    return NULL;
}

static void statusServerThread(void) {
    int srv2 = socket(AF_INET, SOCK_STREAM, 0);
    if (srv2 < 0) { L("status socket fail: %s", strerror(errno)); return; }
    int one2 = 1;
    setsockopt(srv2, SOL_SOCKET, SO_REUSEADDR, &one2, sizeof(one2));
    struct sockaddr_in a2 = {0};
    a2.sin_family = AF_INET;
    a2.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a2.sin_port = htons(8768);
    if (bind(srv2, (struct sockaddr *)&a2, sizeof(a2)) < 0) {
        L("status bind fail: %s", strerror(errno));
        close(srv2);
        return;
    }
    if (listen(srv2, 4) < 0) { close(srv2); return; }
    L("Status-Server auf 127.0.0.1:8768");
    while (1) {
        int c = accept(srv2, NULL, NULL);
        if (c < 0) continue;
        char msg[512];
        snprintf(msg, sizeof(msg),
            "overlayCalls=%d overlayCreated=%d window=%p clients=%d "
            "locked=%d hidden=%d passThrough=%d\n",
            g_overlayCalls, g_overlayCreated, g_overlayWindow, g_clientCount,
            (int)g_locked,
            g_overlayWindow ? (int)g_overlayWindow.hidden : -1,
            g_overlayWindow && [g_overlayWindow isKindOfClass:[VCamOverlayWindow class]]
                ? (int)((VCamOverlayWindow *)g_overlayWindow).passThrough : -1);
        send(c, msg, strlen(msg), 0);
        close(c);
    }
}

static void hubServerThread(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { L("socket fail: %s", strerror(errno)); return; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(WS_PORT);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        L("bind fail: %s", strerror(errno));
        close(srv);
        return;
    }
    if (listen(srv, 8) < 0) { close(srv); return; }
    L("WS-Server auf 127.0.0.1:%d", WS_PORT);
    while (1) {
        struct sockaddr_in cli = {0};
        socklen_t clen = sizeof(cli);
        int fd = accept(srv, (struct sockaddr *)&cli, &clen);
        if (fd < 0) continue;
        pthread_t t;
        pthread_create(&t, NULL, hubClientThread, (void *)(intptr_t)fd);
        pthread_detach(t);
    }
}

// ---------------------------------------------------------------- Overlay
static UIWindowScene *ActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive ||
                ws.activationState == UISceneActivationStateForegroundInactive) {
                return ws;
            }
        }
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.alpha > 0.0 && w.windowScene != nil) return w.windowScene;
        }
    }
    return nil;
}

static BOOL IsLocked(void) {
    @try {
        id value = [[UIApplication sharedApplication] valueForKey:@"hasBlankedScreen"];
        return [value boolValue];
    } @catch (NSException *e) {
        return NO;
    }
}

static void HideOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_locked = YES;
        if (g_overlayWindow && [g_overlayWindow isKindOfClass:[VCamOverlayWindow class]]) {
            VCamOverlayWindow *w = (VCamOverlayWindow *)g_overlayWindow;
            w.passThrough = YES;
            w.hidden = YES;
        }
        L("Overlay versteckt (locked)");
    });
}

static void ShowOverlayIfUnlocked(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_locked) return;
        if (g_overlayWindow && [g_overlayWindow isKindOfClass:[VCamOverlayWindow class]]) {
            VCamOverlayWindow *w = (VCamOverlayWindow *)g_overlayWindow;
            w.passThrough = NO;
            w.hidden = NO;
        }
        L("Overlay sichtbar (unlocked)");
    });
}

// ---------------------------------------------------------------- Inject-Status (TCP 8769)
#define INJECT_PORT 8769

static NSString *InjectCmd(NSString *cmd) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(INJECT_PORT);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return nil; }
    if (cmd && cmd.length > 0) {
        send(fd, [cmd UTF8String], strlen([cmd UTF8String]), 0);
    }
    struct timeval tv = { .tv_sec = 0, .tv_usec = 300000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    NSMutableData *d = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) {
        [d appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    if (d.length == 0) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static NSString *StatusField(NSString *status, NSString *key) {
    NSString *prefix = [key stringByAppendingString:@"="];
    for (NSString *tok in [status componentsSeparatedByCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if ([tok hasPrefix:prefix]) {
            return [tok substringFromIndex:prefix.length];
        }
    }
    return nil;
}

// ---------------------------------------------------------------- Banner-Target + Panel
@interface VCamBannerTarget : NSObject
- (void)buttonTapped:(UIButton *)btn;
- (void)pan:(UIPanGestureRecognizer *)pan;
@end

static UIView *g_panelView = nil;
static UILabel *g_connDot = nil;
static UILabel *g_statusLabel = nil;
static NSArray<NSArray<UIButton *> *> *g_modeRows = nil;
static UIButton *g_rngRow[2] = { nil, nil };
static NSTimer *g_pollTimer = nil;
static BOOL g_pollRunning = NO;

static UIButton *mkBtn(CGRect r, NSString *title, int tag) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = r;
    b.tag = tag;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    return b;
}

static void setActive(NSArray<UIButton *> *row, int value) {
    for (UIButton *b in row) {
        BOOL on = (b.tag == value);
        b.backgroundColor = on ? [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:1.0]
                              : [UIColor colorWithWhite:0.22 alpha:1.0];
    }
}

static void updatePanelFromStatus(NSString *st) {
    if (!st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_connDot) g_connDot.backgroundColor = [UIColor redColor];
            if (g_statusLabel) g_statusLabel.text = @"Keine Verbindung zu mediaserverd";
        });
        return;
    }
    NSString *build = StatusField(st, @"build");
    NSString *stage = StatusField(st, @"stage");
    NSString *rot = StatusField(st, @"rot");
    NSString *rotv = StatusField(st, @"rotv");
    NSString *rote = StatusField(st, @"rote");
    NSString *rng = StatusField(st, @"rng");
    NSString *frame = StatusField(st, @"hasFrame");
    NSString *rxNal = StatusField(st, @"rxNal");
    NSString *swap = StatusField(st, @"inplace");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_connDot) g_connDot.backgroundColor = [UIColor greenColor];
        if (g_statusLabel) {
            g_statusLabel.text = [NSString stringWithFormat:
                @"stage=%@  frame=%@  NAL=%@  swaps=%@\nbuild=%@",
                stage ?: @"?", frame ?: @"0", rxNal ?: @"0", swap ?: @"0", build ?: @"?"];
        }
        if (g_modeRows.count >= 3) {
            setActive(g_modeRows[0], rot ? rot.intValue : 1);
            setActive(g_modeRows[1], rotv ? rotv.intValue : 1);
            setActive(g_modeRows[2], rote ? rote.intValue : 1);
        }
        BOOL rngOn = rng && rng.intValue == 1;
        if (g_rngRow[0]) g_rngRow[0].backgroundColor = !rngOn ? [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:1.0] : [UIColor colorWithWhite:0.22 alpha:1.0];
        if (g_rngRow[1]) g_rngRow[1].backgroundColor = rngOn ? [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:1.0] : [UIColor colorWithWhite:0.22 alpha:1.0];
    });
}

static void pollInjectStatus(void) {
    if (g_pollRunning) return;
    g_pollRunning = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *st = InjectCmd(nil);
        updatePanelFromStatus(st);
        g_pollRunning = NO;
    });
}

static void sendCmdAndPoll(NSString *cmd) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *st = InjectCmd(cmd);
        updatePanelFromStatus(st);
        if (st) pollInjectStatus();   // zweiter Read für Sicherheit
    });
}

@implementation VCamBannerTarget {
    CGPoint _panStart;
}
- (void)buttonTapped:(UIButton *)btn {
    L("Button getippt — Panel togglen");
    VCamOverlayWindow *w = (VCamOverlayWindow *)g_overlayWindow;
    if (![w isKindOfClass:[VCamOverlayWindow class]]) return;

    if (g_panelView && !g_panelView.hidden) {
        g_panelView.hidden = YES;
        [g_pollTimer invalidate];
        g_pollTimer = nil;
        return;
    }

    if (!g_panelView) {
        // ---- Panel einmalig aufbauen ----
        CGFloat pw = 300.0;
        CGRect screenB = [UIScreen mainScreen].bounds;
        CGFloat px = screenB.size.width - pw - 14.0;
        CGFloat py = 196.0;
        CGFloat ph = 452.0;
        if (py + ph > screenB.size.height - 12) py = screenB.size.height - ph - 12;

        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
        panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
        panel.layer.cornerRadius = 16;
        panel.layer.borderWidth = 1.0;
        panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;

        // Header
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 22)];
        title.text = @"NikeCam";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:18];
        [panel addSubview:title];

        g_connDot = [[UILabel alloc] initWithFrame:CGRectMake(pw - 40, 12, 24, 24)];
        g_connDot.layer.cornerRadius = 12;
        g_connDot.clipsToBounds = YES;
        g_connDot.backgroundColor = [UIColor redColor];
        [panel addSubview:g_connDot];

        g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, pw - 32, 40)];
        g_statusLabel.text = @"Verbinde…";
        g_statusLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        g_statusLabel.font = [UIFont systemFontOfSize:11];
        g_statusLabel.numberOfLines = 2;
        [panel addSubview:g_statusLabel];

        // Stage
        CGFloat y = 86;
        UILabel *stageLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 100, 20)];
        stageLbl.text = @"STAGE";
        stageLbl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
        stageLbl.font = [UIFont boldSystemFontOfSize:12];
        [panel addSubview:stageLbl];
        CGFloat bw = 58, bh = 34, gap = 8;
        NSArray *stageTitles = @[@"AUS", @"FOTO", @"LIVE", @"VOLL"];
        for (int i = 0; i < 4; i++) {
            UIButton *b = mkBtn(CGRectMake(16 + i * (bw + gap), y + 22, bw, bh), stageTitles[i], i);
            [b addTarget:self action:@selector(stageBtn:)
                forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:b];
        }
        y += 62;

        // Drei Rotations-Zeilen
        NSArray *rowTitles = @[@"FOTO rot", @"VIDEO rotv", @"ENC rote"];
        NSMutableArray *rows = [NSMutableArray array];
        for (int r = 0; r < 3; r++) {
            UILabel *rl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 100, 20)];
            rl.text = rowTitles[r];
            rl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
            rl.font = [UIFont boldSystemFontOfSize:12];
            [panel addSubview:rl];
            NSMutableArray *row = [NSMutableArray array];
            for (int i = 0; i < 4; i++) {
                UIButton *b = mkBtn(CGRectMake(16 + i * (bw + gap), y + 22, bw, bh),
                                    [NSString stringWithFormat:@"%d", i], i);
                b.tag = r * 10 + i;   // Zeile im Tag kodieren
                [b addTarget:self action:@selector(rotBtn:)
                    forControlEvents:UIControlEventTouchUpInside];
                [panel addSubview:b];
                [row addObject:b];
            }
            [rows addObject:row];
            y += 62;
        }
        g_modeRows = rows;

        // Range
        UILabel *rnl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 100, 20)];
        rnl.text = @"RANGE rng";
        rnl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
        rnl.font = [UIFont boldSystemFontOfSize:12];
        [panel addSubview:rnl];
        g_rngRow[0] = mkBtn(CGRectMake(16, y + 22, bw, bh), @"AUS", 0);
        g_rngRow[1] = mkBtn(CGRectMake(16 + bw + gap, y + 22, bw, bh), @"AN", 1);
        [g_rngRow[0] addTarget:self action:@selector(rngBtn:)
            forControlEvents:UIControlEventTouchUpInside];
        [g_rngRow[1] addTarget:self action:@selector(rngBtn:)
            forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:g_rngRow[0]];
        [panel addSubview:g_rngRow[1]];
        y += 62;

        // Footer
        UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 2, pw - 32, 18)];
        foot.text = @"WS 127.0.0.1:8767  ·  Tip: grünen Kreis verschieben";
        foot.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
        foot.font = [UIFont systemFontOfSize:10];
        [panel addSubview:foot];

        [w.rootViewController.view addSubview:panel];
        w.interactivePanel = panel;
        g_panelView = panel;
    }
    g_panelView.hidden = NO;
    pollInjectStatus();
    if (!g_pollTimer) {
        g_pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            pollInjectStatus();
        }];
    }
}

- (void)stageBtn:(UIButton *)b {
    sendCmdAndPoll([NSString stringWithFormat:@"stage=%ld", (long)b.tag]);
}
- (void)rotBtn:(UIButton *)b {
    int row = (int)b.tag / 10;
    int val = (int)b.tag % 10;
    NSString *key = row == 0 ? @"rot" : (row == 1 ? @"rotv" : @"rote");
    sendCmdAndPoll([NSString stringWithFormat:@"%@=%d", key, val]);
}
- (void)rngBtn:(UIButton *)b {
    sendCmdAndPoll([NSString stringWithFormat:@"rng=%ld", (long)b.tag]);
}

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    if (pan.state == UIGestureRecognizerStateBegan) {
        _panStart = v.center;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:g_overlayWindow];
        v.center = CGPointMake(_panStart.x + t.x, _panStart.y + t.y);
    }
}
@end
static VCamBannerTarget *g_bannerTarget = nil;

static void showOverlay(void) {
    g_overlayCalls++;
    if (g_overlayWindow != nil) return;   // idempotent

    // Sicherheits-Check: bei gesperrtem Gerät nichts anzeigen
    if (IsLocked()) {
        L("Gerät gesperrt — Overlay nicht erstellen");
        return;
    }

    UIWindowScene *scene = ActiveScene();
    VCamOverlayWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        if (scene != nil) {
            win = [[VCamOverlayWindow alloc] initWithWindowScene:scene];
        } else {
            win = [[VCamOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
    } else {
        win = [[VCamOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }

    if (@available(iOS 13.0, *)) {
        win.frame = scene.coordinateSpace.bounds;
    }
    win.windowLevel = UIWindowLevelAlert + 1.0;
    win.backgroundColor = [UIColor clearColor];
    win.alpha = 1.0;
    win.hidden = NO;
    win.userInteractionEnabled = YES;
    win.passThrough = NO;

    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.userInteractionEnabled = YES;

    // Grüner Status-Button (Container 64x64 oben rechts)
    CGFloat size = 64.0;
    CGFloat margin = 16.0;
    CGRect screenB = [UIScreen mainScreen].bounds;
    g_buttonContainer = [[UIView alloc] initWithFrame:
        CGRectMake(screenB.size.width - size - margin, 120, size, size)];
    g_buttonContainer.backgroundColor = [UIColor clearColor];
    g_buttonContainer.userInteractionEnabled = YES;

    g_bannerTarget = [[VCamBannerTarget alloc] init];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = g_buttonContainer.bounds;
    button.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:0.95];
    button.layer.cornerRadius = size / 2.0;
    button.layer.borderWidth = 3.0;
    button.layer.borderColor = [UIColor whiteColor].CGColor;
    button.userInteractionEnabled = YES;
    [button addTarget:g_bannerTarget action:@selector(buttonTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [g_buttonContainer addSubview:button];

    // Drag-Geste auf dem Container (Pan verschiebt den Button)
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:g_bannerTarget action:@selector(pan:)];
    [g_buttonContainer addGestureRecognizer:pan];

    [root.view addSubview:g_buttonContainer];
    win.rootViewController = root;
    win.interactiveView = g_buttonContainer;

    g_overlayWindow = win;
    [g_overlayWindow makeKeyAndVisible];

    g_overlayCreated = 1;
    L("Overlay erstellt: window=%p scene=%p button=%p locked=%d",
      g_overlayWindow, (__bridge void *)scene, g_buttonContainer, (int)IsLocked());
}

// ---------------------------------------------------------------- Entry
__attribute__((constructor))
static void vcamhub_init(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("ctor in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"SpringBoard"]) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        hubServerThread();
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        statusServerThread();
    });

    // Lockscreen-Observer (mehrere Signale kombinieren)
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:@"SBDashBoardLockStateChangedNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            BOOL locked = [note.userInfo[@"locked"] boolValue];
            if (locked) HideOverlay();
            else { g_locked = NO; ShowOverlayIfUnlocked(); }
        }];
    [nc addObserverForName:@"SBLockScreenManagerLockCompleteNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { HideOverlay(); }];
    [nc addObserverForName:@"SBLockScreenManagerUnlockCompleteNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { g_locked = NO; ShowOverlayIfUnlocked(); }];

    // Overlay-Start (Notification + Fallback, idempotent)
    [nc addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            L("DidFinishLaunching empfangen");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showOverlay(); });
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ showOverlay(); });

    L("Hub bereit");
}
