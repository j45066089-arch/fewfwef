// VCamServerStart — schwebender Button in SpringBoard zum manuellen Start des
// LordVCAM-Fake-Servers. Umgeht launchd komplett (direktes posix_spawn) und
// damit das Boot-Race, das den Server-Job nach Userspace-Reboot killte.
//
// Ein Tipp: startet den Server oder meldet, dass er läuft.
// Button: grün = Server läuft, rot = Server aus.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <os/log.h>

extern char **environ;

#define SERVER_PORT 443

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.nikeboy.vcamserverstart", "btn"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Pass-Through Window
@interface VCSSOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end
@implementation VCSSOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) return nil;
    UIView *target = self.interactiveView;
    if (!target || target.hidden || target.alpha <= 0.01) return nil;
    CGRect r = [target.superview convertRect:target.frame toView:self];
    r = CGRectInset(r, -8.0, -8.0);
    if (CGRectContainsPoint(r, point)) return [super hitTest:point withEvent:event];
    return nil;
}
@end

// ---------------------------------------------------------------- Server-Helfer
static NSString *ServerPy(void) {
    // /var/jb ist auf roothide ein Symlink auf das aktuelle jbroot -> immer korrekt.
    return @"/var/jb/usr/bin/python3";
}
static NSString *ServerScript(void) {
    // Der Fake-Server liegt im beschreibbaren jbroot-Pfad.
    return @"/var/jb/var/tmp/lordvcam-server/fake_license_server.py";
}

static BOOL ServerRunning(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(SERVER_PORT);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 400000 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    BOOL ok = (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0);
    close(fd);
    return ok;
}

static void StartServer(void) {
    // Hängende Instanzen beenden (Port-Konflikt vermeiden)
    pid_t kpid;
    char *kargv[] = { "/usr/bin/pkill", "-9", "-f", "fake_license_server", NULL };
    posix_spawn(&kpid, "/usr/bin/pkill", NULL, NULL, kargv, environ);

    NSString *py = ServerPy();
    NSString *srv = ServerScript();
    // Ausgabe in Log-Datei umleiten (Server loggt selbst nach server.log;
    // hier zusätzlich stdout/stderr in eine Datei, damit Startfehler sichtbar sind)
    NSString *logPath = @"/var/mobile/Library/lordvcam_server.log";
    int logfd = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (logfd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, logfd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, logfd, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&fa, logfd);
    }

    const char *argv[] = { py.UTF8String, "-u", srv.UTF8String, NULL };
    pid_t pid;
    int r = posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
    L("posix_spawn -> pid=%d r=%d py=%s", pid, r, py.UTF8String);
    posix_spawn_file_actions_destroy(&fa);
    if (logfd >= 0) close(logfd);
}

// ---------------------------------------------------------------- Button-Target
@class VCSSButtonTarget;
static VCSSButtonTarget *g_target = nil;

@interface VCSSButtonTarget : NSObject
- (void)buttonPressed:(UIButton *)sender;
@end

static UIWindow *g_win = nil;
static UIButton *g_btn = nil;
static UIView *g_container = nil;
static UILabel *g_status = nil;
static BOOL g_starting = NO;

static void PopStatus(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = g_win.rootViewController;
        if (!root) return;
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 40)];
        lbl.text = text;
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:14];
        lbl.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
        lbl.layer.cornerRadius = 10;
        lbl.clipsToBounds = YES;
        lbl.center = CGPointMake(CGRectGetMidX(root.view.bounds),
                                 CGRectGetMidY(root.view.bounds) - 80);
        [root.view addSubview:lbl];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [lbl removeFromSuperview]; });
    });
}

static void UpdateButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_btn) return;
        BOOL running = ServerRunning();
        g_btn.backgroundColor = running ? [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:0.95]
                                        : [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:0.95];
        if (g_status) g_status.text = running ? @"läuft" : @"starten";
    });
}

@implementation VCSSButtonTarget
- (void)buttonPressed:(UIButton *)sender {
    if (g_starting) return;
    g_starting = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (ServerRunning()) {
            PopStatus(@"Server läuft bereits ✓");
        } else {
            StartServer();
            sleep(1);
            if (ServerRunning()) PopStatus(@"Server gestartet ✓");
            else PopStatus(@"Fehler — Log prüfen");
        }
        UpdateButton();
        g_starting = NO;
    });
}
@end

// ---------------------------------------------------------------- Overlay
static UIWindowScene *ActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)s;
            if (ws.activationState == UISceneActivationStateForegroundActive ||
                ws.activationState == UISceneActivationStateForegroundInactive) return ws;
        }
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.alpha > 0.0 && w.windowScene) return w.windowScene;
        }
    }
    return nil;
}

static void ShowButton(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        L("Button aufbauen");
        UIWindowScene *scene = ActiveScene();
        VCSSOverlayWindow *win = nil;
        if (@available(iOS 13.0, *)) {
            win = scene ? [[VCSSOverlayWindow alloc] initWithWindowScene:scene]
                        : [[VCSSOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        } else {
            win = [[VCSSOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        if (@available(iOS 13.0, *)) win.frame = scene.coordinateSpace.bounds;
        win.windowLevel = UIWindowLevelAlert + 1.0;
        win.backgroundColor = [UIColor clearColor];
        win.hidden = NO;
        win.alpha = 1.0;
        win.userInteractionEnabled = YES;

        UIViewController *root = [UIViewController new];
        root.view.backgroundColor = [UIColor clearColor];
        root.view.userInteractionEnabled = YES;

        CGFloat size = 56.0;
        CGRect sb = [UIScreen mainScreen].bounds;
        g_container = [[UIView alloc] initWithFrame:
            CGRectMake(sb.size.width - size - 14, 150, size, size)];

        g_target = [[VCSSButtonTarget alloc] init];

        g_btn = [UIButton buttonWithType:UIButtonTypeSystem];
        g_btn.frame = g_container.bounds;
        g_btn.backgroundColor = [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:0.95];
        g_btn.layer.cornerRadius = size / 2.0;
        g_btn.layer.borderWidth = 3.0;
        g_btn.layer.borderColor = [UIColor whiteColor].CGColor;
        [g_btn setTitle:@"S" forState:UIControlStateNormal];
        [g_btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_btn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [g_btn addTarget:g_target action:@selector(buttonPressed:)
            forControlEvents:UIControlEventTouchUpInside];
        [g_container addSubview:g_btn];

        g_status = [[UILabel alloc] initWithFrame:CGRectMake(-30, size + 4, size + 60, 18)];
        g_status.text = @"starten";
        g_status.textAlignment = NSTextAlignmentCenter;
        g_status.textColor = [UIColor whiteColor];
        g_status.font = [UIFont boldSystemFontOfSize:11];
        g_status.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
        g_status.layer.cornerRadius = 4;
        g_status.clipsToBounds = YES;
        [g_container addSubview:g_status];

        [root.view addSubview:g_container];
        win.rootViewController = root;
        win.interactiveView = g_container;
        g_win = win;
        [g_win makeKeyAndVisible];
        L("Button sichtbar");
        UpdateButton();
    });
}

// ---------------------------------------------------------------- Entry
__attribute__((constructor))
static void vcss_init(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("ctor in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"SpringBoard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ShowButton(); });
}
