// VCLoginClear — schwebender Button in SpringBoard, der den LordVCAM-Keychain-
// Eintrag "com.apple.avsd.auth" löscht (kSecClassGenericPassword). Läuft im
// SELBEN Prozess wie der LordVCAM-Tweak → gleiche Keychain-Access-Group, daher
// kein errSecMissingEntitlement (-34018) wie bei einer separaten App.
//
// Nach dem Löschen + SpringBoard-Respring startet LordVCAM frisch und fordert
// einen neuen Login → "Not authenticated" beim Currency-Menü ist damit weg.
//
// Button: gelb, ein Tipp löscht. Status kurz als Popup + Farbe (grün=kein Eintrag mehr/hinsichtlich gelöscht).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>

#define KC_SERVICE @"com.apple.avsd.auth"

// ---------------------------------------------------------------- Pass-Through Window
@interface VCLCOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end
@implementation VCLCOverlayWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) return nil;
    UIView *t = self.interactiveView;
    if (!t || t.hidden || t.alpha <= 0.01) return nil;
    CGRect r = [t.superview convertRect:t.frame toView:self];
    r = CGRectInset(r, -8, -8);
    if (CGRectContainsPoint(r, p)) return [super hitTest:p withEvent:e];
    return nil;
}
@end

// ---------------------------------------------------------------- Keychain-Delete
static OSStatus DeleteLoginState(void) {
    NSDictionary *q = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : KC_SERVICE,
    };
    return SecItemDelete((__bridge CFDictionaryRef)q);
}

// ---------------------------------------------------------------- Button-Target
static UIWindow *g_win = nil;
static UIButton *g_btn = nil;
static UIView *g_container = nil;

static void Pop(NSString *s) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0,0,220,44)];
        l.text = s; l.textAlignment = NSTextAlignmentCenter;
        l.textColor = [UIColor whiteColor]; l.font = [UIFont boldSystemFontOfSize:13];
        l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.9];
        l.layer.cornerRadius = 10; l.clipsToBounds = YES;
        l.numberOfLines = 0;
        UIView *rv = g_win.rootViewController.view;
        l.center = CGPointMake(CGRectGetMidX(rv.bounds), CGRectGetMidY(rv.bounds)-80);
        [rv addSubview:l];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
    });
}

@interface VCLCButton : NSObject
@end
@implementation VCLCButton
- (void)tapped {
    OSStatus st = DeleteLoginState();
    if (st == errSecSuccess) {
        Pop(@"Login gelöscht ✓ — LordVCAM neu starten");
        g_btn.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:0.95];
    } else if (st == errSecItemNotFound) {
        Pop(@"Kein Eintrag gefunden (schon leer)");
        g_btn.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:0.95];
    } else {
        Pop([NSString stringWithFormat:@"Fehler %d", (int)st]);
        g_btn.backgroundColor = [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:0.95];
    }
}
@end

// ---------------------------------------------------------------- Overlay aufbauen
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

static void Show(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIWindowScene *sc = ActiveScene();
        VCLCOverlayWindow *win;
        if (@available(iOS 13.0, *)) {
            win = sc ? [[VCLCOverlayWindow alloc] initWithWindowScene:sc]
                     : [[VCLCOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        } else {
            win = [[VCLCOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        if (@available(iOS 13.0, *)) win.frame = sc.coordinateSpace.bounds;
        win.windowLevel = UIWindowLevelAlert + 1.0;
        win.backgroundColor = [UIColor clearColor];
        win.hidden = NO; win.alpha = 1.0; win.userInteractionEnabled = YES;

        UIViewController *root = [UIViewController new];
        root.view.backgroundColor = [UIColor clearColor];

        CGFloat sz = 52.0;
        CGRect sb = [UIScreen mainScreen].bounds;
        g_container = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width - sz - 14, 210, sz, sz)];

        VCLCButton *target = [[VCLCButton alloc] init];
        g_btn = [UIButton buttonWithType:UIButtonTypeSystem];
        g_btn.frame = g_container.bounds;
        g_btn.backgroundColor = [UIColor colorWithRed:0.85 green:0.35 blue:0.1 alpha:0.95];
        g_btn.layer.cornerRadius = sz/2.0;
        g_btn.layer.borderWidth = 2.0;
        g_btn.layer.borderColor = [UIColor whiteColor].CGColor;
        [g_btn setTitle:@"C" forState:UIControlStateNormal];
        [g_btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_btn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [g_btn addTarget:target action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [g_container addSubview:g_btn];
        [root.view addSubview:g_container];

        win.rootViewController = root;
        win.interactiveView = g_container;
        g_win = win;
        [g_win makeKeyAndVisible];
    });
}

__attribute__((constructor))
static void init(void) {
    NSString *pn = [[NSProcessInfo processInfo] processName];
    if (![pn isEqualToString:@"SpringBoard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Show(); });
}
