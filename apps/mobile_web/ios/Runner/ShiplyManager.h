#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

/// ShiplyPro iOS 生命周期与 Flutter 通道桥接。
@interface ShiplyManager : NSObject

+ (instancetype)sharedManager;

/// 初始化 ShiplyPro，并创建 ResHub 实例。ResHub 会按启动策略自动拉取资源。
- (void)initializeSDK;

/// 注册 Flutter 通道；该方法可重复调用，后续调用只会复用已初始化的 SDK。
- (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

@end

NS_ASSUME_NONNULL_END
