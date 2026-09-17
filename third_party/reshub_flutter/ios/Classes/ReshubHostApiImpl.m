//
//  ReshubHostApiImpl.m
//  reshub_flutter
//
//  Created by mellow on 2023/3/1.
//

#import "ReshubHostApiImpl.h"
#ifdef SHIPLY_COMMERCIAL_VERSION
#import <ShiplyRDelivery/RDeliverySDK.h>
#import <ShiplyResHub/ResHub.h>
#import <ShiplyResHub/ResHubCenter.h>
#import <ShiplyResHub/ResHubParam.h>
#import <ShiplyResHub/ResHubParam+Private.h>
#else
#import <RDelivery/RDeliverySDK.h>
#import <ResHub/ResHub.h>
#import <ResHub/ResHubCenter.h>
#import <ResHub/ResHubParam.h>
#import <ResHub/ResHubParam+Private.h>
#endif

#import "ResHubDependImpl.h"
#import <Flutter/FlutterCodecs.h>
#import <sys/utsname.h>

@interface ReshubHostApiImpl()

@property (nonatomic, strong) ResHub *reshub;
@property (nonatomic, weak) id<ResHubDependProtocol> dependImpl;
@property (nonatomic, assign) BOOL hasInitReshubCenter;

@end

@implementation ReshubHostApiImpl

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id instance = nil;
    dispatch_once(&once, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)markHasInitReshubCenter {
    self.hasInitReshubCenter = YES;
}

- (void)injectDependImpl:(id<ResHubDependProtocol>)dependImpl {
    self.dependImpl = dependImpl;
}

#pragma mark - SHIPLYReshubCenterHostAction Protocol

- (void)initReshubCenterReshubParams:(nonnull SHIPLYReshubParams *)reshubParams
                               error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
    if (!reshubParams) {
        NSLog(@"initReshubCenter return for null reshubParams");
        return;
    }
    if (self.hasInitReshubCenter) {
        NSLog(@"initReshubCenter return for has initialed");
        return;
    }
    
    ResHubParam *param = [[ResHubParam alloc] init];
    param.appVersion = reshubParams.appVersion;
    param.variantMap = reshubParams.customParams;
    param.rdmTest = reshubParams.isDebugPackage;
    param.qimei = reshubParams.deviceId;
    
    param.deviceType = [self deviceType];
    param.systemVersion = [UIDevice currentDevice].systemVersion;
    param.callbackOnMainThread = YES;
    param.fetchProjectWhenAppOnly = YES;
    param.depends = self.dependImpl ?: [ResHubDependImpl defaultDepends];
    param.environment = ResHubEnvironmentRelease;
    param.customServerUrl = reshubParams.customServerUrl;
    [[ResHubCenter sharedInstance] initSDK:param];
    self.hasInitReshubCenter = YES;
}

- (void)initReshubAppId:(nonnull NSString *)appId
                 appKey:(nonnull NSString *)appKey
                    env:(nonnull NSString *)env
                  error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
    if (self.reshub || !appId || !appKey || !env) {
        return;
    }
    self.reshub = [[ResHubCenter sharedInstance] resHubWithAppId:appId appKey:appKey env:env];
}

- (NSString *)deviceType {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

#pragma mark - SHIPLYReshubHostAction Protocol
- (nullable SHIPLYResModel *)getLatestResId:(nonnull NSString *)resId
                                      error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
    return [self toShiplyResModel:[self.reshub latestResWithId:resId]];
}

- (nullable SHIPLYResModel *)getFetchedResConfigResId:(nonnull NSString *)resId
    error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [self toShiplyResModel:[self.reshub fetchedResConfigWithId:resId]];
}

- (nullable SHIPLYResModel *)getResId:(nonnull NSString *)resId
                                error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
    return [self toShiplyResModel:[self.reshub resWithId:resId]];
}

- (void)loadLatestResId:(NSString *)resId
             completion:(nonnull void (^)(SHIPLYLoadResult * _Nullable, FlutterError * _Nullable))completion {
    [self.reshub loadLatestWithId:resId
                         progress:nil
                        completed:^(BOOL success, NSError * _Nullable error, ResHubModel * _Nullable resModel) {
        [self doShiplyLoadCompletion:completion error:error resModel:resModel success:success];
    }];
}

- (void)loadResId:(NSString *)resId
       completion:(nonnull void (^)(SHIPLYLoadResult * _Nullable, FlutterError * _Nullable))completion {
    [self.reshub loadWithId:resId
                   progress:nil
                  completed:^(BOOL success, NSError * _Nullable error, ResHubModel * _Nullable resModel) {
        [self doShiplyLoadCompletion:completion error:error resModel:resModel success:success];
    }];
}

- (void)loadLatestWithOptionResId:(NSString *)resId 
         forceRequestRemoteConfig:(NSNumber *)forceRequestRemoteConfig
                       completion:(void (^)(SHIPLYLoadResult * _Nullable,
                                            FlutterError * _Nullable))completion {
    if (forceRequestRemoteConfig.boolValue) {
        [self.reshub loadRealtimeLatestWithId:resId
                             progress:nil
                            completed:^(BOOL success, NSError * _Nullable error, ResHubModel * _Nullable resModel) {
            [self doShiplyLoadCompletion:completion error:error resModel:resModel success:success];
        }];
    } else {
        [self.reshub loadLatestWithId:resId
                             progress:nil
                            completed:^(BOOL success, NSError * _Nullable error, ResHubModel * _Nullable resModel) {
            [self doShiplyLoadCompletion:completion error:error resModel:resModel success:success];
        }];
    }
}

- (void)reportBusinessEventEventName:(NSString *)eventName 
                                cost:(NSNumber *)cost
                             errCode:(NSNumber *)errCode
                             extInfo:(NSDictionary<NSString *,NSString *> *)extInfo
                   reportImmediately:(NSNumber *)reportImmediately
                               error:(FlutterError * _Nullable __autoreleasing *)error {
    [[self.reshub getConfigSDK] reportBusinessEvent:eventName
                                               cost:cost.doubleValue
                                            errCode:errCode.integerValue
                                            extInfo:extInfo
                                  reportImmediately:reportImmediately.boolValue];
}

- (void)doShiplyLoadCompletion:(void (^ _Nonnull)(SHIPLYLoadResult * _Nullable,
                                                  FlutterError * _Nullable))completion
                         error:(NSError * _Nullable)error
                      resModel:(ResHubModel * _Nullable)resModel
                       success:(BOOL)success {
    if (completion) {
        SHIPLYLoadResult *result = [SHIPLYLoadResult makeWithIsSuccess:@(success)
                                                              resModel:[self toShiplyResModel:resModel]
                                                                 error:[self toShiplyError:error]];
        completion(result, nil);
    }
}

#pragma mark - Util

- (SHIPLYResModel *)toShiplyResModel:(ResHubModel *)model {
    return [SHIPLYResModel makeWithResId:model.resId
                              resVersion:@(model.version)
                                 resSize:@(model.size)
                                  resMd5:model.md5
                                  taskId:model.taskId
                               localPath:model.localPath
                         originLocalPath:model.sourceLocalPath
                               fileExtra:model.fileExtra];
}

- (SHIPLYLoadError *)toShiplyError:(NSError *)error {
    if (!error) {
        return nil;
    }
    return [SHIPLYLoadError makeWithCode:@(error.code) msg:error.localizedDescription];
}

- (FlutterError *)toFlutterError:(NSError *)error {
    if (!error) {
        return nil;
    }
    return [FlutterError errorWithCode:@(error.code).stringValue
                               message:error.localizedDescription
                               details:error.userInfo];
}

@end
