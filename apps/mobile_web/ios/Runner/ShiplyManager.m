#import "ShiplyManager.h"

#import <ShiplyPro/Shiply.h>
#import <ShiplyPro/ShiplyLoggerProtocol.h>
#import <UIKit/UIKit.h>
#import <sys/utsname.h>

@interface ShiplyLogger : NSObject <ShiplyLoggerProtocol>
@end

@implementation ShiplyLogger

- (void)logMsg:(NSString *)msg level:(RAFTLogLevel)level {
    (void)level;
    NSLog(@"[Shiply] %@", msg);
}

@end

@interface ShiplyManager ()
@property (nonatomic, strong, nullable) Shiply *shiply;
@property (nonatomic, strong) ShiplyLogger *logger;
@property (nonatomic, strong) FlutterMethodChannel *channel;
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
    if (self.shiply != nil) {
        return;
    }

    ShiplyParams *params = [[ShiplyParams alloc] init];
    params.appId = @"29f3fb41fe";
    params.appKey = @"7332bf11-142b-44d0-8ea3-d45d3655f7de";
    params.deviceId = [self deviceIdentifier];
    // SharedPreferences 在 iOS 上使用 UserDefaults；优先带 flutter 前缀的键，兼容旧数据。
    params.userId = [self storedStudentId] ?: @"";
    params.devModel = [self deviceModel];
    params.hostAppVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    params.systemVersion = UIDevice.currentDevice.systemVersion;
    params.appChannel = @"gzus_pro";
    params.platform = ShiplyPlatformIOS;

    self.logger = [[ShiplyLogger alloc] init];
    self.shiply = [[Shiply alloc] initWithParams:params loggerDelegate:self.logger];

    // getResHubInstance() 内部使用 APP_START | SCHEDULED 更新策略，创建即启用启动时拉取。
    (void)[self.shiply getResHubInstance];
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
            [strongSelf initializeSDK];
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

- (NSString *)storedStudentId {
    NSString *studentId = [[NSUserDefaults standardUserDefaults] stringForKey:@"flutter.auth.studentId"];
    if (studentId.length == 0) {
        studentId = [[NSUserDefaults standardUserDefaults] stringForKey:@"auth.studentId"];
    }
    return studentId.length > 0 ? studentId : nil;
}

- (NSString *)deviceModel {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"iOS";
}

@end
