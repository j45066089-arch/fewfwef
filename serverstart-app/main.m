// VCamServerStart — App-Icon auf dem Homescreen: ein Tipp startet den
// LordVCAM-Fake-Server (Port 443) per posix_spawn. Kein launchd, kein Root-Helper.
// Läuft als normale mobile-App (Server bindet hier als mobile, Port 443 ist offen).

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

extern char **environ;

#define SERVER_PORT 443

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
    pid_t kpid;
    char *kargv[] = { "/usr/bin/pkill", "-9", "-f", "fake_license_server", NULL };
    posix_spawn(&kpid, "/usr/bin/pkill", NULL, NULL, kargv, environ);

    const char *py = "/var/jb/usr/bin/python3";
    const char *srv = "/var/jb/var/tmp/lordvcam-server/fake_license_server.py";
    int logfd = open("/var/mobile/Library/lordvcam_server.log",
                     O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (logfd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, logfd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, logfd, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&fa, logfd);
    }
    const char *argv[] = { py, "-u", srv, NULL };
    pid_t pid;
    posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (logfd >= 0) close(logfd);
}

@interface ViewController : UIViewController
@end

@implementation ViewController {
    UIButton *_btn;
    UILabel *_status;
    BOOL _busy;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];

    _btn = [UIButton buttonWithType:UIButtonTypeSystem];
    _btn.frame = CGRectMake(40, 180, self.view.bounds.size.width - 80, 120);
    _btn.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:1.0];
    _btn.layer.cornerRadius = 20;
    [_btn setTitle:@"Server starten" forState:UIControlStateNormal];
    [_btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _btn.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    [_btn addTarget:self action:@selector(tapped)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_btn];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(40, 340, self.view.bounds.size.width - 80, 40)];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _status.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:_status];

    [self refresh];
}

- (void)refresh {
    BOOL running = ServerRunning();
    _btn.backgroundColor = running ? [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:1.0]
                                   : [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:1.0];
    _btn.enabled = YES;
    _status.text = running ? @"Server läuft ✓" : @"Server ist aus";
}

- (void)tapped {
    if (_busy) return;
    _busy = YES;
    [_btn setTitle:@"Starte…" forState:UIControlStateNormal];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (ServerRunning()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                _status.text = @"Läuft bereits ✓";
                _busy = NO;
                [self refresh];
            });
            return;
        }
        StartServer();
        sleep(1);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = ServerRunning();
            _status.text = ok ? @"Gestartet ✓" : @"Fehler — Log prüfen";
            _busy = NO;
            [self refresh];
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
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
