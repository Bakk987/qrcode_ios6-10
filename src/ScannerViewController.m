//
//  ScannerViewController.m
//  QR Scanner — supports iOS 6.0 through iOS 10.x
//
//  iOS 7+:  uses AVCaptureMetadataOutput (Apple's built-in QR detector).
//  iOS 6:   AVCaptureMetadataOutput does not exist, so camera frames are
//           decoded with the bundled quirc library instead.
//  Photos:  images picked from the library are decoded with quirc on every
//           iOS version.
//
//  Only APIs that exist on iOS 6 are referenced directly; anything newer is
//  looked up at runtime (NSClassFromString / respondsToSelector:).
//

#import "ScannerViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#include "QRDecode.h"

#define kQRMetadataType @"org.iso.QRCode" /* == AVMetadataObjectTypeQRCode (iOS 7+) */
#define kMaxPayload 9000

static BOOL SystemVersionAtLeast(NSString *v)
{
    return [[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending;
}

static UIColor *AccentColor(void)
{
    return [UIColor colorWithRed:0.20 green:0.78 blue:0.47 alpha:1.0];
}

static NSString *StringFromPayload(const uint8_t *bytes, int len)
{
    NSString *s = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)len encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)len encoding:NSShiftJISStringEncoding];
    if (!s) s = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)len encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

@interface ScannerViewController () <AVCaptureVideoDataOutputSampleBufferDelegate,
                                     UIImagePickerControllerDelegate,
                                     UINavigationControllerDelegate,
                                     UIPopoverControllerDelegate>
@end

@implementation ScannerViewController {
    AVCaptureSession *_session;
    AVCaptureDevice *_device;
    AVCaptureVideoPreviewLayer *_previewLayer;
    dispatch_queue_t _sessionQueue;
    dispatch_queue_t _frameQueue;
    qr_decoder *_frameDecoder;
    volatile BOOL _paused;
    BOOL _cameraConfigured;

    CAShapeLayer *_dimLayer;
    CAShapeLayer *_cornersLayer;
    CALayer *_scanLine;
    CGRect _cutout;

    UILabel *_hintLabel;
    UIButton *_torchButton;
    UIButton *_photoButton;

    UIView *_messageView;
    UILabel *_messageLabel;
    UIButton *_settingsButton;

    UIView *_resultCard;
    UILabel *_resultTitle;
    UITextView *_resultText;
    UIButton *_openButton;
    UIButton *_copyButton;
    UIButton *_againButton;
    NSString *_resultString;
    NSURL *_resultURL;

    id _popover; /* UIPopoverController, iPad only */
}

#pragma mark - Lifecycle

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_frameDecoder) qr_decoder_free(_frameDecoder);
}

- (void)loadView
{
    UIView *v = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    v.backgroundColor = [UIColor blackColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = v;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _sessionQueue = dispatch_queue_create("qrscanner.session", DISPATCH_QUEUE_SERIAL);
    _frameQueue = dispatch_queue_create("qrscanner.frames", DISPATCH_QUEUE_SERIAL);

    [self buildOverlay];
    [self buildControls];
    [self buildMessageView];
    [self buildResultCard];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];

    [self checkPermissionAndStart];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self layoutAll];
}

- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)appDidBecomeActive:(NSNotification *)n
{
    [self startScanLineAnimation];
    [self updateTorchButton];
}

#pragma mark - UI construction

- (UIButton *)pillButtonWithTitle:(NSString *)title filled:(BOOL)filled
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.layer.cornerRadius = 22;
    b.layer.masksToBounds = YES;
    if (filled) {
        b.backgroundColor = AccentColor();
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.06];
        [b setTitleColor:[UIColor colorWithWhite:0.15 alpha:1] forState:UIControlStateNormal];
    }
    [b setTitleColor:[UIColor colorWithWhite:0.5 alpha:1] forState:UIControlStateHighlighted];
    return b;
}

- (UIButton *)roundControlWithTitle:(NSString *)title action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.5] forState:UIControlStateHighlighted];
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.75];
    b.layer.cornerRadius = 24;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildOverlay
{
    _dimLayer = [CAShapeLayer layer];
    _dimLayer.fillRule = kCAFillRuleEvenOdd;
    _dimLayer.fillColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
    [self.view.layer addSublayer:_dimLayer];

    _cornersLayer = [CAShapeLayer layer];
    _cornersLayer.fillColor = [UIColor clearColor].CGColor;
    _cornersLayer.strokeColor = AccentColor().CGColor;
    _cornersLayer.lineWidth = 4;
    _cornersLayer.lineCap = kCALineCapRound;
    [self.view.layer addSublayer:_cornersLayer];

    _scanLine = [CALayer layer];
    _scanLine.backgroundColor = [AccentColor() colorWithAlphaComponent:0.85].CGColor;
    _scanLine.shadowColor = AccentColor().CGColor;
    _scanLine.shadowOpacity = 1;
    _scanLine.shadowRadius = 4;
    _scanLine.shadowOffset = CGSizeZero;
    [self.view.layer addSublayer:_scanLine];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.backgroundColor = [UIColor clearColor];
    _hintLabel.textColor = [UIColor whiteColor];
    _hintLabel.font = [UIFont boldSystemFontOfSize:17];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 2;
    _hintLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    _hintLabel.shadowOffset = CGSizeMake(0, 1);
    _hintLabel.text = @"Point the camera at a QR code";
    [self.view addSubview:_hintLabel];
}

- (void)buildControls
{
    _photoButton = [self roundControlWithTitle:@"Photos" action:@selector(pickPhoto:)];
    [self.view addSubview:_photoButton];

    _torchButton = [self roundControlWithTitle:@"Light" action:@selector(toggleTorch:)];
    _torchButton.hidden = YES;
    [self.view addSubview:_torchButton];
}

- (void)buildMessageView
{
    _messageView = [[UIView alloc] init];
    _messageView.backgroundColor = [UIColor blackColor];
    _messageView.hidden = YES;

    _messageLabel = [[UILabel alloc] init];
    _messageLabel.backgroundColor = [UIColor clearColor];
    _messageLabel.textColor = [UIColor whiteColor];
    _messageLabel.font = [UIFont systemFontOfSize:17];
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;
    [_messageView addSubview:_messageLabel];

    _settingsButton = [self pillButtonWithTitle:@"Open Settings" filled:YES];
    [_settingsButton addTarget:self action:@selector(openSettings:) forControlEvents:UIControlEventTouchUpInside];
    _settingsButton.hidden = YES;
    [_messageView addSubview:_settingsButton];

    [self.view addSubview:_messageView];
}

- (void)buildResultCard
{
    _resultCard = [[UIView alloc] init];
    _resultCard.backgroundColor = [UIColor whiteColor];
    _resultCard.layer.cornerRadius = 16;
    _resultCard.layer.shadowColor = [UIColor blackColor].CGColor;
    _resultCard.layer.shadowOpacity = 0.35;
    _resultCard.layer.shadowRadius = 12;
    _resultCard.layer.shadowOffset = CGSizeMake(0, -2);
    _resultCard.hidden = YES;

    _resultTitle = [[UILabel alloc] init];
    _resultTitle.backgroundColor = [UIColor clearColor];
    _resultTitle.font = [UIFont boldSystemFontOfSize:13];
    _resultTitle.textColor = AccentColor();
    [_resultCard addSubview:_resultTitle];

    _resultText = [[UITextView alloc] init];
    _resultText.editable = NO;
    _resultText.backgroundColor = [UIColor clearColor];
    _resultText.font = [UIFont systemFontOfSize:17];
    _resultText.textColor = [UIColor colorWithWhite:0.1 alpha:1];
    [_resultCard addSubview:_resultText];

    _openButton = [self pillButtonWithTitle:@"Open" filled:YES];
    [_openButton addTarget:self action:@selector(openResult:) forControlEvents:UIControlEventTouchUpInside];
    [_resultCard addSubview:_openButton];

    _copyButton = [self pillButtonWithTitle:@"Copy" filled:NO];
    [_copyButton addTarget:self action:@selector(copyResult:) forControlEvents:UIControlEventTouchUpInside];
    [_resultCard addSubview:_copyButton];

    _againButton = [self pillButtonWithTitle:@"Scan Again" filled:NO];
    [_againButton addTarget:self action:@selector(scanAgain:) forControlEvents:UIControlEventTouchUpInside];
    [_resultCard addSubview:_againButton];

    [self.view addSubview:_resultCard];
}

#pragma mark - Layout

- (void)layoutAll
{
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width, h = b.size.height;

    _previewLayer.frame = b;

    CGFloat side = floorf(MIN(MIN(w, h) * 0.68f, 320.0f));
    _cutout = CGRectMake(floorf((w - side) / 2), floorf((h - side) / 2 - h * 0.05f), side, side);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _dimLayer.frame = b;
    UIBezierPath *dim = [UIBezierPath bezierPathWithRect:b];
    [dim appendPath:[UIBezierPath bezierPathWithRoundedRect:_cutout cornerRadius:14]];
    _dimLayer.path = dim.CGPath;

    _cornersLayer.frame = b;
    CGFloat L = 28, r = 14;
    CGFloat x0 = CGRectGetMinX(_cutout), y0 = CGRectGetMinY(_cutout);
    CGFloat x1 = CGRectGetMaxX(_cutout), y1 = CGRectGetMaxY(_cutout);
    UIBezierPath *c = [UIBezierPath bezierPath];
    [c moveToPoint:CGPointMake(x0, y0 + L)]; [c addLineToPoint:CGPointMake(x0, y0 + r)];
    [c addQuadCurveToPoint:CGPointMake(x0 + r, y0) controlPoint:CGPointMake(x0, y0)];
    [c addLineToPoint:CGPointMake(x0 + L, y0)];
    [c moveToPoint:CGPointMake(x1 - L, y0)]; [c addLineToPoint:CGPointMake(x1 - r, y0)];
    [c addQuadCurveToPoint:CGPointMake(x1, y0 + r) controlPoint:CGPointMake(x1, y0)];
    [c addLineToPoint:CGPointMake(x1, y0 + L)];
    [c moveToPoint:CGPointMake(x1, y1 - L)]; [c addLineToPoint:CGPointMake(x1, y1 - r)];
    [c addQuadCurveToPoint:CGPointMake(x1 - r, y1) controlPoint:CGPointMake(x1, y1)];
    [c addLineToPoint:CGPointMake(x1 - L, y1)];
    [c moveToPoint:CGPointMake(x0 + L, y1)]; [c addLineToPoint:CGPointMake(x0 + r, y1)];
    [c addQuadCurveToPoint:CGPointMake(x0, y1 - r) controlPoint:CGPointMake(x0, y1)];
    [c addLineToPoint:CGPointMake(x0, y1 - L)];
    _cornersLayer.path = c.CGPath;

    [CATransaction commit];
    if (![_scanLine animationForKey:@"scan"] ||
        fabs(_scanLine.frame.size.width - (_cutout.size.width - 32)) > 0.5 ||
        fabs(_scanLine.frame.origin.x - (CGRectGetMinX(_cutout) + 16)) > 0.5)
        [self startScanLineAnimation];

    _hintLabel.frame = CGRectMake(20, CGRectGetMinY(_cutout) - 70, w - 40, 50);

    CGFloat btnW = 110, btnH = 48;
    CGFloat btnY = MIN(CGRectGetMaxY(_cutout) + 40, h - btnH - 30);
    _photoButton.frame = CGRectMake(w / 2 - btnW - 10, btnY, btnW, btnH);
    _torchButton.frame = CGRectMake(w / 2 + 10, btnY, btnW, btnH);
    if (_torchButton.hidden) _photoButton.frame = CGRectMake((w - btnW) / 2, btnY, btnW, btnH);

    _messageView.frame = b;
    _messageLabel.frame = CGRectMake(30, h / 2 - 110, w - 60, 140);
    _settingsButton.frame = CGRectMake((w - 200) / 2, h / 2 + 50, 200, 44);

    [self layoutResultCard];
}

- (void)layoutResultCard
{
    CGRect b = self.view.bounds;
    CGFloat cardW = MIN(b.size.width - 20, 500);
    CGFloat cardH = 250;
    CGFloat x = floorf((b.size.width - cardW) / 2);
    _resultCard.frame = CGRectMake(x, b.size.height - cardH - 10, cardW, cardH);
    _resultCard.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_resultCard.bounds cornerRadius:16].CGPath;

    CGFloat pad = 16;
    _resultTitle.frame = CGRectMake(pad + 4, 12, cardW - 2 * pad, 20);
    _resultText.frame = CGRectMake(pad - 4, 34, cardW - 2 * pad + 8, cardH - 34 - 44 - 44 - 12 - 16);

    CGFloat rowY = cardH - 44 - 44 - 10 - 14;
    CGFloat gap = 10;
    if (_resultURL) {
        CGFloat half = (cardW - 2 * pad - gap) / 2;
        _openButton.hidden = NO;
        _openButton.frame = CGRectMake(pad, rowY, half, 44);
        _copyButton.frame = CGRectMake(pad + half + gap, rowY, half, 44);
    } else {
        _openButton.hidden = YES;
        _copyButton.frame = CGRectMake(pad, rowY, cardW - 2 * pad, 44);
    }
    _againButton.frame = CGRectMake(pad, rowY + 44 + 10, cardW - 2 * pad, 44);
}

- (void)startScanLineAnimation
{
    if (CGRectIsEmpty(_cutout)) return;
    [_scanLine removeAllAnimations];
    CGFloat inset = 16;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scanLine.frame = CGRectMake(CGRectGetMinX(_cutout) + inset, CGRectGetMinY(_cutout) + inset,
                                 _cutout.size.width - 2 * inset, 2);
    [CATransaction commit];

    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.y"];
    a.fromValue = @(CGRectGetMinY(_cutout) + inset);
    a.toValue = @(CGRectGetMaxY(_cutout) - inset);
    a.duration = 1.8;
    a.autoreverses = YES;
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_scanLine addAnimation:a forKey:@"scan"];
}

#pragma mark - Camera permission & setup

- (void)checkPermissionAndStart
{
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera] ||
        ![AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo]) {
        [self showMessage:@"No camera is available on this device.\n\nYou can still scan QR codes from photos." settings:NO];
        return;
    }

    /* Camera permission prompts exist from iOS 7 onward. */
    if ([AVCaptureDevice respondsToSelector:@selector(authorizationStatusForMediaType:)]) {
        NSInteger status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (status == 0 /* NotDetermined */) {
            __weak ScannerViewController *weakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) [weakSelf setupCamera];
                    else [weakSelf showDenied];
                });
            }];
            return;
        }
        if (status == 1 /* Restricted */ || status == 2 /* Denied */) {
            [self showDenied];
            return;
        }
    }
    [self setupCamera];
}

- (void)showDenied
{
    BOOL canOpenSettings = SystemVersionAtLeast(@"8.0");
    NSString *msg = canOpenSettings
        ? @"QR Scanner needs camera access.\n\nTurn on Camera for QR Scanner in Settings."
        : @"QR Scanner needs camera access.\n\nGo to Settings → Privacy → Camera and turn on QR Scanner.";
    [self showMessage:msg settings:canOpenSettings];
}

- (void)showMessage:(NSString *)msg settings:(BOOL)settings
{
    _messageLabel.text = msg;
    _settingsButton.hidden = !settings;
    _messageView.hidden = NO;
    [self.view bringSubviewToFront:_messageView];
    [self.view bringSubviewToFront:_photoButton];
    _hintLabel.hidden = YES;
}

- (void)openSettings:(id)sender
{
    /* UIApplicationOpenSettingsURLString (iOS 8+) is @"app-settings:" */
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"app-settings:"]];
}

- (void)setupCamera
{
    if (_cameraConfigured) return;
    _cameraConfigured = YES;

    NSError *error = nil;
    _device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:_device error:&error];
    if (!input) {
        [self showMessage:[NSString stringWithFormat:@"Could not start the camera.\n\n%@", error.localizedDescription ?: @""] settings:NO];
        return;
    }

    _session = [[AVCaptureSession alloc] init];
    if ([_session canSetSessionPreset:AVCaptureSessionPreset640x480])
        _session.sessionPreset = AVCaptureSessionPreset640x480;
    if ([_session canAddInput:input]) [_session addInput:input];

    [self configureFocus];

    BOOL usingMetadata = NO;
    Class metadataClass = NSClassFromString(@"AVCaptureMetadataOutput"); /* iOS 7+ */
    if (metadataClass) {
        id metaOut = [[metadataClass alloc] init];
        if ([_session canAddOutput:metaOut]) {
            [_session addOutput:metaOut];
            NSArray *available = [metaOut valueForKey:@"availableMetadataObjectTypes"];
            if ([available containsObject:kQRMetadataType]) {
                [metaOut setValue:@[kQRMetadataType] forKey:@"metadataObjectTypes"];
                SEL sel = NSSelectorFromString(@"setMetadataObjectsDelegate:queue:");
                NSMethodSignature *sig = [metaOut methodSignatureForSelector:sel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                id me = self;
                dispatch_queue_t q = dispatch_get_main_queue();
                [inv setSelector:sel];
                [inv setTarget:metaOut];
                [inv setArgument:&me atIndex:2];
                [inv setArgument:&q atIndex:3];
                [inv invoke];
                usingMetadata = YES;
            } else {
                [_session removeOutput:metaOut];
            }
        }
    }

    if (!usingMetadata) {
        /* iOS 6 path: grab raw frames and decode them with quirc. */
        _frameDecoder = qr_decoder_new();
        AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
        videoOut.alwaysDiscardsLateVideoFrames = YES;
        videoOut.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey :
                                        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) };
        [videoOut setSampleBufferDelegate:self queue:_frameQueue];
        if ([_session canAddOutput:videoOut]) [_session addOutput:videoOut];
    }

    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.frame = self.view.bounds;
    [self.view.layer insertSublayer:_previewLayer atIndex:0];

    [self updateTorchButton];
    [self.view setNeedsLayout];

    AVCaptureSession *session = _session;
    dispatch_async(_sessionQueue, ^{ [session startRunning]; });
}

- (void)configureFocus
{
    if (![_device lockForConfiguration:nil]) return;
    if ([_device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus])
        _device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
    /* iOS 7+: prefer near focus — QR codes are usually close. */
    SEL rangeSupported = NSSelectorFromString(@"isAutoFocusRangeRestrictionSupported");
    if ([_device respondsToSelector:rangeSupported] && [[_device valueForKey:@"autoFocusRangeRestrictionSupported"] boolValue])
        [_device setValue:@1 /* Near */ forKey:@"autoFocusRangeRestriction"];
    if ([_device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
        _device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
    [_device unlockForConfiguration];
}

#pragma mark - Torch

- (void)updateTorchButton
{
    BOOL hasTorch = _device && [_device hasTorch] && [_device isTorchModeSupported:AVCaptureTorchModeOn];
    _torchButton.hidden = !hasTorch;
    BOOL on = hasTorch && _device.torchMode == AVCaptureTorchModeOn;
    _torchButton.backgroundColor = on ? [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:0.95]
                                      : [UIColor colorWithWhite:0.15 alpha:0.75];
    [_torchButton setTitleColor:(on ? [UIColor blackColor] : [UIColor whiteColor]) forState:UIControlStateNormal];
    [_torchButton setTitle:(on ? @"Light On" : @"Light") forState:UIControlStateNormal];
    [self.view setNeedsLayout];
}

- (void)toggleTorch:(id)sender
{
    if (![_device hasTorch]) return;
    if ([_device lockForConfiguration:nil]) {
        _device.torchMode = (_device.torchMode == AVCaptureTorchModeOn) ? AVCaptureTorchModeOff : AVCaptureTorchModeOn;
        [_device unlockForConfiguration];
    }
    [self updateTorchButton];
}

- (void)turnTorchOff
{
    if ([_device hasTorch] && _device.torchMode == AVCaptureTorchModeOn && [_device lockForConfiguration:nil]) {
        _device.torchMode = AVCaptureTorchModeOff;
        [_device unlockForConfiguration];
    }
    [self updateTorchButton];
}

#pragma mark - Detection: iOS 7+ (AVCaptureMetadataOutput)

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray *)objects fromConnection:(AVCaptureConnection *)connection
{
    if (_paused) return;
    for (id obj in objects) {
        if (![[obj valueForKey:@"type"] isEqual:kQRMetadataType]) continue;
        if (![obj respondsToSelector:NSSelectorFromString(@"stringValue")]) continue;
        NSString *value = [obj valueForKey:@"stringValue"];
        if (value.length) {
            [self handleResult:value];
            return;
        }
    }
}

#pragma mark - Detection: iOS 6 (raw frames + quirc)

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (_paused || !_frameDecoder) return;

    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixels) return;
    if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;

    const uint8_t *y;
    size_t width, height, stride;
    if (CVPixelBufferIsPlanar(pixels)) {
        y = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixels, 0);
        width = CVPixelBufferGetWidthOfPlane(pixels, 0);
        height = CVPixelBufferGetHeightOfPlane(pixels, 0);
        stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0);
    } else {
        y = NULL; width = height = stride = 0;
    }

    static uint8_t payload[kMaxPayload];
    int n = -1;
    if (y) n = qr_decoder_scan(_frameDecoder, y, (int)width, (int)height, (int)stride, payload, sizeof(payload));
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);

    if (n > 0) {
        NSString *value = StringFromPayload(payload, n);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_paused) [self handleResult:value];
        });
    }
}

#pragma mark - Photos

- (void)pickPhoto:(id)sender
{
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    _paused = YES;

    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        /* iPad on iOS 6/7 requires a popover for the photo picker. */
        Class popoverClass = NSClassFromString(@"UIPopoverController");
        UIPopoverController *pop = [[popoverClass alloc] initWithContentViewController:picker];
        pop.delegate = self;
        _popover = pop;
        [pop presentPopoverFromRect:_photoButton.frame inView:self.view
           permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    } else {
        [self presentViewController:picker animated:YES completion:nil];
    }
}

- (void)dismissPicker:(UIImagePickerController *)picker then:(void (^)(void))block
{
    if (_popover) {
        [(UIPopoverController *)_popover dismissPopoverAnimated:YES];
        _popover = nil;
        if (block) block();
    } else {
        [picker dismissViewControllerAnimated:YES completion:block];
    }
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController
{
    _popover = nil;
    if (_resultCard.hidden) _paused = NO;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self dismissPicker:picker then:^{ if (self->_resultCard.hidden) self->_paused = NO; }];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    [self dismissPicker:picker then:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *value = [ScannerViewController decodeImage:image];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (value) {
                    [self handleResult:value];
                } else {
                    self->_paused = NO;
                    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"No QR code found"
                                                                    message:@"Try a sharper photo where the QR code is clearly visible."
                                                                   delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                    [alert show];
                }
            });
        });
    }];
}

+ (NSString *)decodeImage:(UIImage *)image
{
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;
    size_t srcW = CGImageGetWidth(cg), srcH = CGImageGetHeight(cg);
    if (!srcW || !srcH) return nil;

    /* Try a few sizes: small codes need resolution, large/noisy ones decode better downscaled. */
    const CGFloat targets[] = { 1600, 1000, 640 };
    qr_decoder *dec = qr_decoder_new();
    if (!dec) return nil;
    NSString *result = nil;
    static uint8_t payload[kMaxPayload];

    size_t lastW = 0;
    for (int t = 0; t < 3 && !result; t++) {
        CGFloat scale = MIN(1.0, targets[t] / (CGFloat)MAX(srcW, srcH));
        size_t w = MAX((size_t)1, (size_t)(srcW * scale));
        size_t h = MAX((size_t)1, (size_t)(srcH * scale));
        if (w == lastW) continue; /* same size as previous pass */
        lastW = w;
        uint8_t *gray = (uint8_t *)malloc(w * h);
        if (!gray) break;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = CGBitmapContextCreate(gray, w, h, 8, w, cs, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(cs);
        if (ctx) {
            CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
            CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
            CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
            CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
            int n = qr_decoder_scan(dec, gray, (int)w, (int)h, (int)w, payload, sizeof(payload));
            if (n > 0) result = StringFromPayload(payload, n);
            CGContextRelease(ctx);
        }
        free(gray);
    }
    qr_decoder_free(dec);
    return result;
}

#pragma mark - Result handling

- (NSURL *)actionableURLFor:(NSString *)raw
{
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length || [s rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
        return nil;
    NSString *lower = [s lowercaseString];
    if ([lower hasPrefix:@"www."]) s = [@"http://" stringByAppendingString:s];

    NSURL *url = [NSURL URLWithString:s];
    if (!url) url = [NSURL URLWithString:[s stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    NSString *scheme = [url.scheme lowercaseString];
    if (!scheme.length) return nil;

    NSArray *known = @[@"http", @"https", @"mailto", @"tel", @"sms", @"facetime", @"facetime-audio",
                       @"maps", @"itms", @"itms-apps", @"itms-services"];
    if ([known containsObject:scheme]) {
        if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && !url.host.length) return nil;
        return url;
    }
    return [[UIApplication sharedApplication] canOpenURL:url] ? url : nil;
}

- (NSString *)titleForResult:(NSString *)s url:(NSURL *)url
{
    NSString *upper = [s uppercaseString];
    if ([upper hasPrefix:@"WIFI:"]) return @"WI-FI NETWORK";
    if ([upper hasPrefix:@"BEGIN:VCARD"] || [upper hasPrefix:@"MECARD:"]) return @"CONTACT";
    if ([upper hasPrefix:@"BEGIN:VEVENT"] || [upper hasPrefix:@"BEGIN:VCALENDAR"]) return @"CALENDAR EVENT";
    if ([upper hasPrefix:@"GEO:"]) return @"LOCATION";
    NSString *scheme = [url.scheme lowercaseString];
    if ([scheme isEqualToString:@"mailto"]) return @"EMAIL ADDRESS";
    if ([scheme isEqualToString:@"tel"]) return @"PHONE NUMBER";
    if ([scheme isEqualToString:@"sms"]) return @"TEXT MESSAGE";
    if (url) return @"LINK";
    return @"TEXT";
}

- (void)handleResult:(NSString *)value
{
    if (_paused && !_resultCard.hidden) return;
    _paused = YES;

    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);

    _resultString = value;
    _resultURL = [self actionableURLFor:value];
    _resultTitle.text = [self titleForResult:value url:_resultURL];
    _resultText.text = value;
    [_resultText setContentOffset:CGPointZero animated:NO];
    [_copyButton setTitle:@"Copy" forState:UIControlStateNormal];

    NSString *scheme = [_resultURL.scheme lowercaseString];
    NSString *openTitle = @"Open";
    if ([scheme isEqualToString:@"tel"]) openTitle = @"Call";
    else if ([scheme isEqualToString:@"mailto"]) openTitle = @"Email";
    else if ([scheme isEqualToString:@"sms"]) openTitle = @"Message";
    else if ([scheme hasPrefix:@"http"]) openTitle = @"Open Link";
    [_openButton setTitle:openTitle forState:UIControlStateNormal];

    [self layoutResultCard];
    [self.view bringSubviewToFront:_resultCard];

    CGRect final = _resultCard.frame;
    CGRect start = final;
    start.origin.y = self.view.bounds.size.height;
    _resultCard.frame = start;
    _resultCard.hidden = NO;
    _photoButton.hidden = YES;
    _torchButton.alpha = 0;
    _scanLine.hidden = YES;
    _cornersLayer.strokeColor = [UIColor whiteColor].CGColor;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_resultCard.frame = final;
    } completion:nil];
}

- (void)openResult:(id)sender
{
    if (_resultURL) [[UIApplication sharedApplication] openURL:_resultURL];
}

- (void)copyResult:(id)sender
{
    if (!_resultString) return;
    [UIPasteboard generalPasteboard].string = _resultString;
    [_copyButton setTitle:@"Copied ✓" forState:UIControlStateNormal];
}

- (void)scanAgain:(id)sender
{
    CGRect end = _resultCard.frame;
    end.origin.y = self.view.bounds.size.height;
    [UIView animateWithDuration:0.25 animations:^{
        self->_resultCard.frame = end;
    } completion:^(BOOL finished) {
        self->_resultCard.hidden = YES;
        [self layoutResultCard];
        self->_photoButton.hidden = NO;
        self->_torchButton.alpha = 1;
        self->_scanLine.hidden = NO;
        self->_cornersLayer.strokeColor = AccentColor().CGColor;
        self->_resultString = nil;
        self->_resultURL = nil;
        /* small delay so the same code isn't re-read instantly */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_paused = NO;
        });
    }];
}

@end
