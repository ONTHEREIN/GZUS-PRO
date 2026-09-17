#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

/// Shiply ResHub iOS 原生初始化与 Flutter 通道桥接。
@interface ShiplyManager : NSObject

+ (instancetype)sharedManager;

/// 初始化 ResHubCenter，并标记 reshub_flutter Wrapper 可复用该初始化。
- (void)initializeSDK;

/// 注册 Flutter 通道；该方法可重复调用，后续调用只会复用已初始化的 SDK。
- (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

@end

NS_ASSUME_NONNULL_END
