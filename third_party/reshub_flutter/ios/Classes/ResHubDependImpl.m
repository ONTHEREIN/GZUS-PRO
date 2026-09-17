//
//  ResHubDependImpl.m
//  ResHubDemo
//
//  Created by jeannieliu(刘锦) on 2021/8/24.
//  Copyright © 2021 Tencent. All rights reserved.
//

#import "ResHubDependImpl.h"
#ifdef SHIPLY_COMMERCIAL_VERSION
#import <ShiplyRDelivery/RDMMKVFactoryImpl.h>
#import <ShiplyRDelivery/RDNetworkImpl.h>
#import <ShiplyResHub/ResHubDownloadImpl.h>
#import <ShiplyResHub/ResHubFileImpl.h>
#import <ShiplyRDelivery/RDeliveryJsonModelImpl.h>
#else
#import <RDelivery/RDMMKVFactoryImpl.h>
#import <RDelivery/RDNetworkImpl.h>
#import <ResHub/ResHubDownloadImpl.h>
#import <ResHub/ResHubFileImpl.h>
#import <RDelivery/RDeliveryJsonModelImpl.h>
#endif

@implementation ResHubDependImpl

@synthesize fileImpl = _fileImpl;
@synthesize kvFactoryImpl = _kvFactoryImpl;
@synthesize netImpl = _netImpl;
@synthesize downloadImpl = _downloadImpl;
@synthesize threadImpl = _threadImpl;
@synthesize logImpl = _logImpl;
@synthesize verControlImpl = _verControlImpl;
@synthesize downloadStorageImpl = _downloadStorageImpl;
@synthesize autoUnzipImpl = _autoUnzipImpl;
@synthesize beaconImpl = _beaconImpl;
@synthesize yymodelImpl = _yymodelImpl;
@synthesize presetImpl = _presetImpl;
@synthesize remoteLoadInterceptImpl = _remoteLoadInterceptImpl;

+ (instancetype)defaultDepends {
    ResHubDependImpl *depends = [[ResHubDependImpl alloc] init];
    depends.netImpl = [RDNetworkImpl sharedInstance];
    depends.kvFactoryImpl = [RDMMKVFactoryImpl sharedInstance];
    depends.downloadImpl = [ResHubDownloadImpl sharedInstance];
    depends.fileImpl = [ResHubFileImpl sharedInstance];
    depends.yymodelImpl = [RDeliveryJsonModelImpl sharedInstance];
    return depends;
}

@end
