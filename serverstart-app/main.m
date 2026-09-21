// VCamServerStart — Homescreen-App-Icon mit zwei Knöpfen:
//   1) "Server starten"  — startet den LordVCAM-Fake-Server (Port 443)
//   2) "Login löschen"   — löscht den Keychain-Eintrag "com.apple.avsd.auth",
//                          damit LordVCAM beim nächsten Start frisch einloggt
//                          (behebt "Not authenticated" nach Respring/Neuinstallation)
//
// Keychain-Detail (aus der Dylib verifiziert):
//   kSecClass=GenericPassword, kSecAttrService="com.apple.avsd.auth",
//   kSecAttrAccount=<account>, kSecAttrAccessible=AfterFirstUnlockThisDeviceOnly
//
// Läuft als normale mobile-App → Keychain-Access-Group ist die App-Gruppe.
// WICHTIG (roothide): Der Tweak (in SpringBoard) nutzt die Access-Group, die vom
// Security-Framework des Prozesses abgeleitet wird. Ein einfacher SecItemDelete mit
// passendem Service+Account aus einer anderen App kann am Access-Group-Mismatch
// scheitern — deshalb versuchen wir mehrere Varianten.

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <Security/Security.h>

extern char **environ;

#define SERVER_PORT 443
#define KC_SERVICE @"com.apple.avsd.auth"

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

static int StartServer(void) {
    // DEBUG: sofort markieren, dass StartServer() aufgerufen wurde
    int dbg = open("/var/tmp/vcss_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (dbg >= 0) { write(dbg, "StartServer() called\n", 20); close(dbg); }

    const char *py = "/var/jb/usr/bin/python3";
    const char *srv = "/var/jb/var/tmp/lordvcam-server/fake_license_server.py";
    int logfd = open("/var/tmp/lordvcam_server.log",
                     O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (dbg >= 0) { dbg = open("/var/tmp/vcss_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
                    char b[64]; int n = snprintf(b, 64, "logfd=%d\n", logfd); write(dbg, b, n); close(dbg); }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (logfd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, logfd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, logfd, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&fa, logfd);
    }
    const char *argv[] = { py, "-u", srv, NULL };
    pid_t pid;
    // envp = NULL (leere Umgebung) statt `environ` — `environ` kann in einer
    // iOS-App NULL/undefiniert sein und posix_spawn dann crashen lassen.
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    if (logfd >= 0) close(logfd);
    dbg = open("/var/tmp/vcss_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (dbg >= 0) { char b[64]; int n = snprintf(b, 64, "spawn rc=%d pid=%d\n", rc, pid); write(dbg, b, n); close(dbg); }
    return rc;
}

// LÖSCHT alle Generic-Password-Einträge mit Service "com.apple.avsd.auth",
// egal welcher Account. Rückgabe: Zahl der gelöschten Einträge.
static OSStatus DeleteLoginState(void) {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = KC_SERVICE;
    // Account weglassen → löscht ALLE Einträge dieses Service.
    // (Security-Framework löscht bei SecItemDelete mit matchingQuery alle Treffer.)
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)query);
    return st;
}

@interface ViewController : UIViewController
@end

@implementation ViewController {
    UIButton *_btnServer;
    UIButton *_btnClear;
    UILabel *_status;
    BOOL _busy;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];

    CGFloat w = self.view.bounds.size.width;

    _btnServer = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnServer.frame = CGRectMake(40, 140, w - 80, 90);
    _btnServer.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:1.0];
    _btnServer.layer.cornerRadius = 18;
    [_btnServer setTitle:@"Server starten" forState:UIControlStateNormal];
    [_btnServer setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _btnServer.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [_btnServer addTarget:self action:@selector(tappedServer)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_btnServer];

    _btnClear = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnClear.frame = CGRectMake(40, 250, w - 80, 90);
    _btnClear.backgroundColor = [UIColor colorWithRed:0.85 green:0.35 blue:0.1 alpha:1.0];
    _btnClear.layer.cornerRadius = 18;
    [_btnClear setTitle:@"Login löschen" forState:UIControlStateNormal];
    [_btnClear setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _btnClear.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [_btnClear addTarget:self action:@selector(tappedClear)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_btnClear];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(40, 370, w - 80, 60)];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _status.font = [UIFont systemFontOfSize:15];
    _status.numberOfLines = 0;
    [self.view addSubview:_status];

    [self refresh];
}

- (void)refresh {
    BOOL running = ServerRunning();
    _btnServer.backgroundColor = running ? [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:1.0]
                                         : [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:1.0];
    _status.text = running ? @"Server läuft ✓" : @"Server ist aus";
}

- (void)tappedServer {
    if (_busy) return;
    _busy = YES;
    [_btnServer setTitle:@"Starte…" forState:UIControlStateNormal];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (ServerRunning()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                _status.text = @"Läuft bereits ✓";
                _busy = NO;
                [self refresh];
            });
            return;
        }
        int rc = StartServer();
        sleep(1);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = ServerRunning();
            if (ok) {
                _status.text = @"Gestartet ✓";
            } else {
                _status.text = [NSString stringWithFormat:@"Fehler rc=%d — Log prüfen", rc];
            }
            _busy = NO;
            [self refresh];
        });
    });
}

- (void)tappedClear {
    if (_busy) return;
    _busy = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        OSStatus st = DeleteLoginState();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st == errSecSuccess) {
                _status.text = @"Login gelöscht ✓\nJetzt LordVCAM neu starten → frischer Login";
            } else if (st == errSecItemNotFound) {
                _status.text = @"Kein Login-Eintrag gefunden (bereits gelöscht)";
            } else {
                _status.text = [NSString stringWithFormat:@"Fehler %d — Access-Group?\n(Tweak läuft in SpringBoard, andere Gruppe)", (int)st];
            }
            _busy = NO;
        });
    });
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    // DEBUG: Server sofort beim App-Start starten (testet spawn ohne Button)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int rc = StartServer();
        int dbg = open("/var/tmp/vcss_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (dbg >= 0) { char b[64]; int n = snprintf(b, 64, "autostart rc=%d\n", rc); write(dbg, b, n); close(dbg); }
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
