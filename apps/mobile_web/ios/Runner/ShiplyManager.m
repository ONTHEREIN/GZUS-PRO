#import "ShiplyManager.h"
#import <UIKit/UIKit.h>
#import <reshub_flutter/ResHubDependImpl.h>
#import <reshub_flutter/ReshubHostApiImpl.h>
#import <ShiplyResHub/ResHub.h>
#import <ShiplyResHub/ResHubCenter.h>
#import <ShiplyResHub/ResHubParam+Private.h>
#import <ShiplyResHub/ResHubParam.h>
#import <sys/utsname.h>

@interface ShiplyManager ()
@property (nonatomic, strong) FlutterMethodChannel *channel;
@property (nonatomic, assign) BOOL initialized;
@end

@implementation ShiplyManager

+ (instancetype)sharedManager {
    static ShiplyManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[ShiplyManager alloc] init];
    });
    return manager;
}

- (void)initializeSDK {
    if (self.initialized) {
        return;
    }
    ResHubParam *param = [[ResHubParam alloc] init];
    param.appVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    param.qimei = [self deviceIdentifier];
    param.deviceType = [self deviceModel];
    param.systemVersion = UIDevice.currentDevice.systemVersion;
    param.callbackOnMainThread = YES;
    param.fetchProjectWhenAppOnly = YES;
    param.depends = [ResHubDependImpl defaultDepends];
    param.environment = ResHubEnvironmentRelease;
    [[ResHubCenter sharedInstance] initSDK:param];
    // Flutter Wrapper 后续只负责创建资源产品实例，避免重复初始化 ResHubCenter。
    [[ReshubHostApiImpl sharedInstance] markHasInitReshubCenter];
    self.initialized = YES;
}

- (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    [self initializeSDK];
    self.channel = [FlutterMethodChannel methodChannelWithName:@"cn.gzus.pro/shiply"
                                                binaryMessenger:messenger];
    __weak ShiplyManager *weakSelf = self;
    [self.channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
        ShiplyManager *strongSelf = weakSelf;
        if (strongSelf == nil) {
            result([FlutterError errorWithCode:@"SHIPLY_UNAVAILABLE"
                                       message:@"Shiply SDK 实例不可用"
                                       details:nil]);
            return;
        }
        if ([call.method isEqualToString:@"getResHubInstance"]) {
            result(@YES);
            return;
        }
        result(FlutterMethodNotImplemented);
    }];
}

- (NSString *)deviceIdentifier {
    NSString *identifier = UIDevice.currentDevice.identifierForVendor.UUIDString;
    return identifier.length > 0 ? identifier : [NSUUID UUID].UUIDString;
}

- (NSString *)deviceModel {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"iOS";
}

@end
