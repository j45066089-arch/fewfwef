#include <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Kamera-Test-App: prüft getrennt Vorschau / VideoDataOutput / Photo / Metadata / Depth.
// Kein Swappen — nur messen, welcher Ausgang Frames liefert.

@interface TestViewController : UIViewController
<AVCaptureVideoDataOutputSampleBufferDelegate,
 AVCaptureMetadataOutputObjectsDelegate,
 AVCaptureDepthDataOutputDelegate,
 AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOut;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOut;
@property (nonatomic, strong) AVCaptureMetadataOutput *metaOut;
@property (nonatomic, strong) AVCaptureDepthDataOutput *depthOut;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UISegmentedControl *camSwitch;
@property (nonatomic) NSUInteger vdFrames;
@property (nonatomic) NSUInteger metaCount;
@property (nonatomic) NSUInteger depthCount;
@property (nonatomic, copy) NSString *curDevicePos;
@end

@implementation TestViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.vdFrames = 0; self.metaCount = 0; self.depthCount = 0;

    // Kamera-Switch (Front/Rueck)
    self.camSwitch = [[UISegmentedControl alloc] initWithItems:@[@"Rück", @"Front"]];
    self.camSwitch.selectedSegmentIndex = 0;
    self.camSwitch.frame = CGRectMake(20, 40, 200, 40);
    [self.camSwitch addTarget:self action:@selector(switchCam) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.camSwitch];

    // Status-Label (alle Ausgaenge live)
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(20, 90, self.view.bounds.size.width - 40, 200)];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont systemFontOfSize:13];
    self.status.textColor = [UIColor greenColor];
    [self.view addSubview:self.status];

    // Foto-Button
    UIButton *photo = [UIButton buttonWithType:UIButtonTypeSystem];
    photo.frame = CGRectMake(self.view.bounds.size.width/2 - 60, self.view.bounds.size.height - 120, 120, 50);
    [photo setTitle:@"Foto" forState:UIControlStateNormal];
    [photo addTarget:self action:@selector(takePhoto) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:photo];

    [self setupSession];
}

- (void)setupSession {
    self.session = [[AVCaptureSession alloc] init];
    if (@available(iOS 13.0, *)) { self.session.sessionPreset = AVCaptureSessionPresetHigh; }

    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                              mediaType:AVMediaTypeVideo
                                                               position:AVCaptureDevicePositionBack];
    if (!dev) dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!input) { self.status.text = [NSString stringWithFormat:@"Input-Error: %@", err]; return; }
    if ([self.session canAddInput:input]) [self.session addInput:input];

    // Vorschau
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.previewLayer.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height);
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer insertSublayer:self.previewLayer atIndex:0];

    // VideoDataOutput (Analyse-/Videoframes)
    self.videoOut = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOut.alwaysDiscardsLateVideoFrames = NO;
    dispatch_queue_t q = dispatch_queue_create("vd", DISPATCH_QUEUE_SERIAL);
    [self.videoOut setSampleBufferDelegate:self queue:q];
    if ([self.session canAddOutput:self.videoOut]) [self.session addOutput:self.videoOut];

    // PhotoOutput (Fotos)
    self.photoOut = [[AVCapturePhotoOutput alloc] init];
    if ([self.session canAddOutput:self.photoOut]) [self.session addOutput:self.photoOut];

    // MetadataOutput (Gesicht/Barcode)
    self.metaOut = [[AVCaptureMetadataOutput alloc] init];
    if ([self.session canAddOutput:self.metaOut]) {
        [self.session addOutput:self.metaOut];
        dispatch_queue_t mq = dispatch_queue_create("meta", DISPATCH_QUEUE_SERIAL);
        [self.metaOut setMetadataObjectsDelegate:self queue:mq];
        NSArray *types = self.metaOut.availableMetadataObjectTypes;
        if (types.count) [self.metaOut setMetadataObjectTypes:types];
    }

    // DepthDataOutput (Tiefe, nur wenn verfuegbar)
    self.depthOut = [[AVCaptureDepthDataOutput alloc] init];
    if ([self.session canAddOutput:self.depthOut]) {
        [self.session addOutput:self.depthOut];
        dispatch_queue_t dq = dispatch_queue_create("depth", DISPATCH_QUEUE_SERIAL);
        [self.depthOut setDelegate:self callbackQueue:dq];
    }

    [self.session startRunning];
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t){ [self updateStatus]; }];
}

- (void)switchCam {
    AVCaptureDevicePosition pos = (self.camSwitch.selectedSegmentIndex == 1) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    [self.session beginConfiguration];
    for (AVCaptureDeviceInput *inp in self.session.inputs) { [self.session removeInput:inp]; }
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                              mediaType:AVMediaTypeVideo position:pos];
    if (!dev) dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (input && [self.session canAddInput:input]) [self.session addInput:input];
    [self.session commitConfiguration];
}

- (void)takePhoto {
    AVCapturePhotoSettings *s = [AVCapturePhotoSettings photoSettings];
    [self.photoOut capturePhotoWithSettings:s delegate:(id<AVCapturePhotoCaptureDelegate>)self];
}

- (void)updateStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger nc = self.videoOut.connections ? self.videoOut.connections.count : 0;
        NSInteger mtypes = self.metaOut.metadataObjectTypes ? self.metaOut.metadataObjectTypes.count : 0;
        NSString *depthAvail = (self.depthOut.connections.count > 0) ? @"JA" : @"nein";
        self.status.text = [NSString stringWithFormat:
            @"Ausgänge (getrennt):\n\n"
            @"Vorschau: aktiv (PreviewLayer)\n"
            @"VideoFrames (videoDataOutput): %lu Frames, %ld conn\n"
            @"Foto (photoOutput): bereit\n"
            @"Metadata (metaOutput): %ld Typen, %lu Objekte\n"
            @"Depth (depthOutput): verfügbar=%@, %lu Frames",
            (unsigned long)self.vdFrames, (long)nc,
            (long)mtypes, (unsigned long)self.metaCount,
            depthAvail, (unsigned long)self.depthCount];
    });
}

#pragma mark - VideoDataOutput
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    self.vdFrames++;
}

#pragma mark - Metadata
- (void)captureOutput:(AVCaptureOutput *)output
didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection {
    self.metaCount += metadataObjects.count;
}

#pragma mark - Depth
- (void)depthDataOutput:(AVCaptureDepthDataOutput *)output didOutputDepthData:(AVDepthData *)depthData timestamp:(CMTime)timestamp connection:(AVCaptureConnection *)connection {
    self.depthCount++;
}

@end


@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[TestViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
