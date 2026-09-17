#import "ReshubFlutterPlugin.h"
#import "MsgProtocolGenerated.h"
#import "ReshubHostApiImpl.h"
#import "ReshubAESFileDecryptor.h"
#import <SSZipArchive/SSZipArchive.h>
#import <CommonCrypto/CommonDigest.h>


@implementation ReshubFlutterPlugin

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id instance = nil;
    dispatch_once(&once, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"reshub_flutter"
                                     binaryMessenger:[registrar messenger]];
    ReshubFlutterPlugin* instance = [[ReshubFlutterPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
    SHIPLYReshubHostActionSetup([registrar messenger], [ReshubHostApiImpl sharedInstance]);
    SHIPLYReshubCenterHostActionSetup([registrar messenger], [ReshubHostApiImpl sharedInstance]);
    
    FlutterMethodChannel* conchLoaderHostChannel = [FlutterMethodChannel
                                     methodChannelWithName:@"conch_loader_host"
                                     binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:instance channel:conchLoaderHostChannel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"getPlatformVersion" isEqualToString:call.method]) {
        result([@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]]);
    } else if ([@"getApplicationDocumentsDirectory" isEqualToString:call.method]) {
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docPath = paths.firstObject;
        result(docPath);
    } else if ([@"unzipFile" isEqualToString:call.method]) {
        NSString *zipFilePath = call.arguments[@"zipFilePath"];
        NSString *destinationDir = call.arguments[@"destinationDir"];
        BOOL success = [self unzipFile:zipFilePath toDestination:destinationDir];
        result(@(success));
    } else if ([@"decryptFile" isEqualToString:call.method]) {
        NSString *encryptedFilePath = call.arguments[@"encryptedFilePath"];
        NSString *decryptedFilePath = call.arguments[@"decryptedFilePath"];
        NSString *secureKey = call.arguments[@"secureKey"];
        NSString *expectedMD5 = call.arguments[@"expectedMD5"];
        
        // 参数验证
        if (!encryptedFilePath || !decryptedFilePath || !secureKey) {
            result(@{
                kReshubDecryptResultKeySuccess: @NO,
                kReshubDecryptResultKeyErrorMessage: @"必需参数为空: encryptedFilePath, decryptedFilePath 或 secureKey"
            });
            return;
        }
        
        NSDictionary *decryptResult = [ReshubAESFileDecryptor decryptFileAtPath:encryptedFilePath
                                                         toDestination:decryptedFilePath
                                                             secureKey:secureKey
                                                           expectedMD5:expectedMD5];
        
        // nil 检查：防止返回 nil 导致 Flutter 端崩溃
        if (decryptResult == nil) {
            NSLog(@"[ReshubFlutterPlugin] 错误: decryptFileAtPath 返回了 nil");
            result(@{
                kReshubDecryptResultKeySuccess: @NO,
                kReshubDecryptResultKeyErrorMessage: @"解密操作返回了空结果，可能发生了未知错误"
            });
            return;
        }
        
        // 返回完整的结果字典，包含success和errorMessage
        result(decryptResult);
    } else if ([@"calculateFileMD5" isEqualToString:call.method]) {
        NSString *filePath = call.arguments[@"filePath"];
        
        // 参数验证
        if (!filePath) {
            result(@"");
            return;
        }
        
        NSString *md5 = [ReshubAESFileDecryptor calculateFileMD5:filePath];
        
        // nil 检查：防止返回 nil 导致 Flutter 端崩溃
        if (md5 == nil) {
            NSLog(@"[ReshubFlutterPlugin] 警告: calculateFileMD5 返回了 nil，文件路径: %@", filePath);
            result(@"");
            return;
        }
        
        result(md5);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (BOOL)unzipFile:(NSString *)zipPath toDestination:(NSString *)destinationPath {
  return [SSZipArchive unzipFileAtPath:zipPath toDestination:destinationPath];
}


@end
