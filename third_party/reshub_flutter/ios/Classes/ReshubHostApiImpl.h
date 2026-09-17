//
//  ReshubHostApiImpl.h
//  reshub_flutter
//
//  Created by mellow on 2023/3/1.
//

#import <Foundation/Foundation.h>
#import "MsgProtocolGenerated.h"

#ifdef SHIPLY_COMMERCIAL_VERSION
#import <ShiplyResHub/ResHubDependProtocol.h>
#else
#import <ResHub/ResHubDependProtocol.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface ReshubHostApiImpl : NSObject<SHIPLYReshubCenterHostAction, SHIPLYReshubHostAction>

+ (instancetype)sharedInstance;

/// 标记已经初始化过ReshubCenter，主要用于oc层和flutter层都接入reshub sdk的场景
/// 业务方在oc层初始化完ReshubCenter后需要主动调用这个方法，避免flutter层又再次初始化ReshubCenter
- (void)markHasInitReshubCenter;

/// 建议继承 ResHubDependImpl 类，然后修改需要自定义实现的组件，如日志、下载器
/// @param dependImpl 注入的依赖
- (void)injectDependImpl:(id<ResHubDependProtocol>)dependImpl;
@end

NS_ASSUME_NONNULL_END
