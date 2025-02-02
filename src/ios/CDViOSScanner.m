@import MLKitBarcodeScanning;

#import "CDViOSScanner.h"
#import "zlib.h"

@class UIViewController;

@interface CDViOSScanner ()
{
    NSInteger _previousStatusBarStyle;
    UIInterfaceOrientation _previousOrientation;
}
@end


@implementation CDViOSScanner

- (void)pluginInitialize
{
    _previousStatusBarStyle = -1;
    _previousOrientation = UIInterfaceOrientationUnknown;
    NSString *beepSoundPath = [[NSBundle mainBundle] pathForResource:@"beep" ofType:@"caf"];
    NSURL *beepSoundUrl = [NSURL fileURLWithPath:beepSoundPath];
    self->_player = [[AVAudioPlayer alloc] initWithContentsOfURL:beepSoundUrl
                                                               error:nil];
}

- (void)startScan:(CDVInvokedUrlCommand *)command
{
    _previousOrientation = [[UIApplication sharedApplication] statusBarOrientation];

    BOOL hasCamera = [UIImagePickerController isSourceTypeAvailable: UIImagePickerControllerSourceTypeCamera];

    if (hasCamera)
    {
        //Force portrait orientation.
        [[UIDevice currentDevice] setValue: [NSNumber numberWithInteger: UIInterfaceOrientationPortrait] forKey:@"orientation"];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"Arguments %@", command.arguments);
            if (self->_scannerOpen == YES)
            {
                //Scanner is currently open, throw error.
                NSArray *response = @[@"SCANNER_OPEN", @"", @""];
                CDVPluginResult *pluginResult=[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsArray:response];

                [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            }
            else
            {
                //Open scanner.
                self->_scannerOpen = YES;
                self.cameraViewController = [[CameraViewController alloc] init];
                self.cameraViewController.delegate = self;

                //Provide settings to the camera view.
                NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
                f.numberStyle = NSNumberFormatterDecimalStyle;
                NSDictionary* config = [command.arguments objectAtIndex:0];
                self->_beepOnSuccess = [[config valueForKey:@"beepOnSuccess"] boolValue] ?: NO;
                self->_vibrateOnSuccess = [[config valueForKey:@"vibrateOnSuccess"] boolValue] ?: NO;
                NSNumber* barcodeFormats = [config valueForKey:@"barcodeFormats"] ?: @1234;
                self.cameraViewController.barcodeFormats = barcodeFormats;
                self.cameraViewController.detectorSize = (CGFloat)[[config valueForKey:@"detectorSize"] ?: @0.5 floatValue];
                self.cameraViewController.modalPresentationStyle = UIModalPresentationFullScreen;

                NSLog(@"scanAreaSize: %f, barcodeFormats: %@", self.cameraViewController.detectorSize, self.cameraViewController.barcodeFormats);

                [self.viewController presentViewController:self.cameraViewController animated: NO completion:nil];
                self->_callback = command.callbackId;
            }
        });
    }
    else
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:NSLocalizedString(@"The device has no camera.", @"Message to the user if the device has no camera.") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *defaultAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
        [alert addAction:defaultAction];

        [self.viewController presentViewController:alert animated:YES completion:nil];
    }
}

- (void)sendResult:(MLKBarcode *)barcode
{
    [self.cameraViewController dismissViewControllerAnimated:NO completion:nil];
    _scannerOpen = NO;

    NSString* value = barcode.rawValue;

    // rawValue returns null if string is not UTF-8 encoded.
    // If that's the case, we will decode it as ASCII,
    // because it's the most common encoding for barcodes.
    // e.g. https://www.barcodefaq.com/1d/code-128/
    if(barcode.rawValue == nil)
    {
        value = [[NSString alloc] initWithData:barcode.rawData encoding:NSASCIIStringEncoding];
    }

    if(value.length > 100)
    {
      @try {
        NSData* unzippedData = [self gzipUncompressData:barcode.rawData];
        if (unzippedData) {
          NSLog(@"Unzip OK");
          NSString* unzippedValue = [[NSString alloc] initWithData:unzippedData encoding:NSUTF8StringEncoding];
          if (!unzippedValue) {
            unzippedValue = [[NSString alloc] initWithData:unzippedData encoding:NSASCIIStringEncoding];
          }
          if(unzippedValue.length > 0){
            value = unzippedValue;
          }
        } else {
          NSLog(@"Unzip not OK");
        }
      }
      @catch (NSException *ex) {
        NSLog(@"Unzip exception");
      }
    }

    NSArray* response = @[value, @(barcode.format), @(barcode.valueType)];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:response];

    [self playBeep];

    [self resetOrientation];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:_callback];
}

- (NSData *)gzipUncompressData:(NSData *)compressedData {
    if (compressedData.length == 0) return nil;

    z_stream stream;
    bzero(&stream, sizeof(stream));
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;
    stream.avail_in = (uInt)compressedData.length;
    stream.next_in = (Bytef *)compressedData.bytes;

    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) {
        return nil;
    }

    NSMutableData *uncompressedData = [NSMutableData dataWithLength:compressedData.length * 4]; // Increased multiplier
    stream.avail_out = (uInt)uncompressedData.length;
    stream.next_out = (Bytef *)uncompressedData.mutableBytes;

    int status;
    int maxLoops = 20;
    do {
        maxLoops--;
        status = inflate(&stream, Z_NO_FLUSH);
        if (status == Z_STREAM_ERROR) {
            inflateEnd(&stream);
            return nil;
        }

        if (status == Z_BUF_ERROR || status == Z_OK) {
            // Resize buffer and continue
            [uncompressedData setLength:uncompressedData.length * 2];
            stream.avail_out = (uInt)(uncompressedData.length - stream.total_out);
            stream.next_out = (Bytef *)(uncompressedData.mutableBytes + stream.total_out);
        }
    } while (status != Z_STREAM_END && maxLoops > 0);

    inflateEnd(&stream);
    [uncompressedData setLength:stream.total_out];
    return uncompressedData;
}

- (void)playBeep
{
    if (self->_beepOnSuccess)
    {
        [self->_player prepareToPlay];
        [self->_player play];
    }

    if (self->_vibrateOnSuccess)
    {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }
}

- (void)closeScanner
{
    [self.cameraViewController dismissViewControllerAnimated:NO completion:nil];
    _scannerOpen = NO;

    NSArray *response = @[@"USER_CANCELLED", @"", @""];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsArray:response];

    [self resetOrientation];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:_callback];
}

- (void)resetOrientation
{
    if (_previousOrientation != UIInterfaceOrientationUnknown && _previousOrientation != UIInterfaceOrientationPortrait)
    {
        [[UIDevice currentDevice] setValue: [NSNumber numberWithInteger: _previousOrientation] forKey:@"orientation"];
        NSLog(@"Changing device orientation to previous orientation");
    }
}


- (void)show:(CDVInvokedUrlCommand*)command
{
    if (self.cameraViewController == nil)
    {
        NSLog(@"Tried to show scanner after it was closed.");
        return;
    }

    if (_previousStatusBarStyle != -1)
    {
        NSLog(@"Tried to show scanner while already shown");
        return;
    }

    _previousStatusBarStyle = [UIApplication sharedApplication].statusBarStyle;
    _previousOrientation = [[UIApplication sharedApplication] statusBarOrientation];

    __block UINavigationController* nav = [[UINavigationController alloc]
                                           initWithRootViewController:self.cameraViewController];

    nav.navigationBarHidden = YES;
    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    __weak CDViOSScanner* weakSelf = self;

    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.cameraViewController != nil)
        {
            CGRect frame = [[UIScreen mainScreen] bounds];
            UIWindow* tmpWindow = [[UIWindow alloc] initWithFrame:frame];
            UIViewController* tmpController = [[UIViewController alloc] init];
            [tmpWindow setRootViewController:tmpController];
            [tmpWindow setWindowLevel:UIWindowLevelNormal];
            [tmpWindow makeKeyAndVisible];
            [tmpController presentViewController:nav animated:NO completion:nil];
        }
    });
}

@end
