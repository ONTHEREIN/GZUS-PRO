//
//  ResHubDependImpl.h
//  ResHubDemo
//
//  Created by jeannieliu(刘锦) on 2021/8/24.
//  Copyright © 2021 Tencent. All rights reserved.
//

#import <Foundation/Foundation.h>
#ifdef SHIPLY_COMMERCIAL_VERSION
#import <ShiplyResHub/ResHubDependProtocol.h>
#else
#import <ResHub/ResHubDependProtocol.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// ResHub 默认实现
@interface ResHubDependImpl : NSObject <ResHubDependProtocol>

/// 获取默认实现
+ (instancetype)defaultDepends;

@end

NS_ASSUME_NONNULL_END
