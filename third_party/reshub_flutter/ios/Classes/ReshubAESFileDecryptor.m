#import "ReshubAESFileDecryptor.h"
#import <CommonCrypto/CommonCrypto.h>

// 定义返回字典的键常量
NSString * const kReshubDecryptResultKeySuccess = @"success";
NSString * const kReshubDecryptResultKeyErrorMessage = @"errorMessage";

@implementation ReshubAESFileDecryptor

#pragma mark - Public Methods

/**
 * 解密补丁文件（流式处理，边解密边写入，同时计算MD5）
 */
+ (NSDictionary *)decryptFileAtPath:(NSString *)encryptedFilePath
                 toDestination:(NSString *)decryptedFilePath
                     secureKey:(NSString *)secureKey
                   expectedMD5:(NSString *)expectedMD5 {
    // 创建文件管理器
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // 检查输入文件是否存在
    if (![fileManager fileExistsAtPath:encryptedFilePath]) {
        NSString *errorMsg = [NSString stringWithFormat:@"[ReshubAESFileDecryptor] 错误: 输入文件不存在: %@", encryptedFilePath];
        NSLog(@"%@", errorMsg);
        return @{kReshubDecryptResultKeySuccess: @NO, kReshubDecryptResultKeyErrorMessage: errorMsg};
    }
    
    // 检查输入文件是否可读
    if (![fileManager isReadableFileAtPath:encryptedFilePath]) {
        NSString *errorMsg = [NSString stringWithFormat:@"[ReshubAESFileDecryptor] 错误: 输入文件没有读权限: %@", encryptedFilePath];
        NSLog(@"%@", errorMsg);
        return @{kReshubDecryptResultKeySuccess: @NO, kReshubDecryptResultKeyErrorMessage: errorMsg};
    }
    
    // 密钥转换
    NSString *transformedKey = [self _secureKeyTransform:secureKey];
    if (!transformedKey || transformedKey.length == 0) {
        NSString *errorMsg = [NSString stringWithFormat:@"[ReshubAESFileDecryptor] 错误: 密钥转换失败，secureKey长度: %lu", (unsigned long)secureKey.length];
        NSLog(@"%@", errorMsg);
        return @{kReshubDecryptResultKeySuccess: @NO, kReshubDecryptResultKeyErrorMessage: errorMsg};
    }
    
    // 创建目标目录（如需要）
    NSString *directory = [decryptedFilePath stringByDeletingLastPathComponent];
    
    // 如果目录不存在，创建它
    if (![fileManager fileExistsAtPath:directory]) {
        NSError *dirError = nil;
        [fileManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&dirError];
        if (dirError) {
            NSString *errorMsg = [NSString stringWithFormat:@"[ReshubAESFileDecryptor] 错误: 创建目录失败: %@, 目录路径: %@", dirError.localizedDescription, directory];
            NSLog(@"%@", errorMsg);
            return @{kReshubDecryptResultKeySuccess: @NO, kReshubDecryptResultKeyErrorMessage: errorMsg};
        }
    }
    
    
    // 检查目标文件是否存在，如存删除
    if ([fileManager fileExistsAtPath:decryptedFilePath]) {
        // 删除旧文件
        NSError *removeError = nil;
        [fileManager removeItemAtPath:decryptedFilePath error:&removeError];
        if (removeError) {
            NSString *errorMsg = [NSString stringWithFormat:@"[ReshubAESFileDecryptor] 错误: 无法删除已存在的目标文件: %@, 原因: %@", 
                  decryptedFilePath, removeError.localizedDescription];
            NSLog(@"%@", errorMsg);
            return @{kReshubDecryptResultKeySuccess: @NO, kReshubDecryptResultKeyErrorMessage: errorMsg};
        }
        NSLog(@"[ReshubAESFileDecryptor] 信息: 已删除旧的目标文件: %@", decryptedFilePath);
    }
    
    // 执行解密操作
    NSString *actualMD5 = nil;
    BOOL decryptSuccess = [self _decryptFileStreamWithAES:encryptedFilePath
                                             toDestination:decryptedFilePath
                                                encryptKey:transformedKey
                                                 outputMD5:&actualMD5];
    
    if (!decryptSuccess) {
        NSDictionary *fileAttrs = [fileManager attributesOfItemAtPath:encryptedFilePath error:nil];
        unsigned long long fileSize = [fileAttrs fileSize];
        NSString *errorMsg = [NSString stringWithFormat:@"[ReshubAESFileDecryptor] 错误: 文件解密失败，输入文件: %@, 大小: %llu bytes, 输出文件: %@", encryptedFilePath, fileSize, decryptedFilePath];
        NSLog(@"%@", errorMsg);
        // 清理失败的输出文件
        [[NSFileManager defaultManager] removeItemAtPath:decryptedFilePath error:nil];
        return @{kReshubDecryptResultKeySuccess: @NO, kReshubDecryptResultKeyErrorMessage: errorMsg};
    }
    
    // 验证MD5
    if (expectedMD5 && expectedMD5.length > 0) {
        if (![actualMD5.lowercaseString isEqualToString:expectedMD5.lowercaseString]) {
            NSString *errorMsg = [NSString stringWithFormat:@"[ReshubAESFileDecryptor] 错误: MD5校验失败，文件: %@, 期望MD5: %@, 实际MD5: %@", decryptedFilePath, expectedMD5, actualMD5];
            NSLog(@"%@", errorMsg);
            // 清理校验失败的文件
            [[NSFileManager defaultManager] removeItemAtPath:decryptedFilePath error:nil];
            return @{kReshubDecryptResultKeySuccess: @NO, kReshubDecryptResultKeyErrorMessage: errorMsg};
        }
    }
    
    return @{kReshubDecryptResultKeySuccess: @YES};
}

#pragma mark - Private Methods

/**
 * 密钥转换
 * 从下发的secureKey中提取并解密真实的加密密钥
 */
+ (NSString *)_secureKeyTransform:(NSString *)secureKey {
    if (secureKey.length < 32) {
        return nil;
    }
    
    // 按照Dart代码的逻辑提取字符串
    // encodeString = secureKey[0:1] + secureKey[2:5] + secureKey[8:13] + secureKey[18:25] + secureKey[32:]
    NSMutableString *encodeString = [NSMutableString string];
    [encodeString appendString:[secureKey substringWithRange:NSMakeRange(0, 1)]];
    [encodeString appendString:[secureKey substringWithRange:NSMakeRange(2, 3)]];
    [encodeString appendString:[secureKey substringWithRange:NSMakeRange(8, 5)]];
    [encodeString appendString:[secureKey substringWithRange:NSMakeRange(18, 7)]];
    if (secureKey.length > 32) {
        [encodeString appendString:[secureKey substringFromIndex:32]];
    }
    
    // encryptKey = secureKey[1:2] + secureKey[5:8] + secureKey[13:18] + secureKey[25:32]
    NSMutableString *encryptKey = [NSMutableString string];
    [encryptKey appendString:[secureKey substringWithRange:NSMakeRange(1, 1)]];
    [encryptKey appendString:[secureKey substringWithRange:NSMakeRange(5, 3)]];
    [encryptKey appendString:[secureKey substringWithRange:NSMakeRange(13, 5)]];
    [encryptKey appendString:[secureKey substringWithRange:NSMakeRange(25, 7)]];
    
    // Base64解码
    NSData *decodeData = [[NSData alloc] initWithBase64EncodedString:encodeString options:0];
    if (!decodeData) {
        return nil;
    }
    
    // AES解密
    NSData *decryptedData = [self _decryptBytesWithAES:decodeData encryptKey:encryptKey];
    if (!decryptedData) {
        return nil;
    }
    
    // 转换为字符串
    NSString *transformedKey = [[NSString alloc] initWithData:decryptedData encoding:NSUTF8StringEncoding];
    return transformedKey;
}

/**
 * 字节数组AES解密
 * 使用AES/CTR模式，无padding
 */
+ (NSData *)_decryptBytesWithAES:(NSData *)encryptedData encryptKey:(NSString *)encryptKey {
    if (!encryptedData || encryptedData.length == 0) {
        return nil;
    }
    
    // 创建密钥
    NSData *keyData = [encryptKey dataUsingEncoding:NSUTF8StringEncoding];
    if (!keyData || keyData.length == 0) {
        return nil;
    }
    
    // 创建IV（全零，长度与密钥相同）
    NSMutableData *ivData = [NSMutableData dataWithLength:keyData.length];
    memset(ivData.mutableBytes, 0, ivData.length);
    
    // 执行AES/CTR解密
    return [self _performAESCTRDecryption:encryptedData
                                      key:keyData
                                       iv:ivData];
}

/**
 * 流式文件AES解密（边读边解密边写，同时计算MD5）
 * 采用1KB buffer，与Android端实现保持一致
 */
+ (BOOL)_decryptFileStreamWithAES:(NSString *)inputPath
                    toDestination:(NSString *)outputPath
                       encryptKey:(NSString *)encryptKey
                        outputMD5:(NSString **)outputMD5 {
    
    //文件管理器
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // 创建密钥和IV
    NSData *keyData = [encryptKey dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *ivData = [NSMutableData dataWithLength:keyData.length];
    memset(ivData.mutableBytes, 0, ivData.length);
    
    // 打开输入文件
    NSFileHandle *inputHandle = [NSFileHandle fileHandleForReadingAtPath:inputPath];
    if (!inputHandle) {
        NSLog(@"[ReshubAESFileDecryptor] 错误: 无法打开输入文件");
        return NO;
    }
    
    // 创建输出文件
    [[NSFileManager defaultManager] createFileAtPath:outputPath contents:nil attributes:nil];
    NSFileHandle *outputHandle = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (!outputHandle) {
        NSLog(@"[ReshubAESFileDecryptor] 错误: 无法创建输出文件");
        [inputHandle closeFile];
        return NO;
    }
    
    // 初始化MD5计算
    CC_MD5_CTX md5Context;
    CC_MD5_Init(&md5Context);
    
    // 1KB buffer，与Android端保持一致
    const NSUInteger bufferSize = 1024;
    
    BOOL success = YES;
    
    while (YES) {
        @autoreleasepool {
            // 读取数据块
            NSData *chunkData = [inputHandle readDataOfLength:bufferSize];
            if (chunkData.length == 0) {
                break; // 文件读取完毕
            }
            
            // 解密数据块（每个chunk独立创建Cipher，保持与Android/Dart一致）
            NSData *decryptedChunk = [self _performAESCTRDecryption:chunkData
                                                                key:keyData
                                                                 iv:ivData];
            
            if (!decryptedChunk) {
                NSLog(@"[ReshubAESFileDecryptor] 错误: chunk解密失败");
                success = NO;
                break;
            }
            
            // 写入解密后的数据
            [outputHandle writeData:decryptedChunk];
            
            // 更新MD5计算
            CC_MD5_Update(&md5Context, decryptedChunk.bytes, (CC_LONG)decryptedChunk.length);
        }
    }
    
    // 完成MD5计算
    if (success && outputMD5) {
        unsigned char digest[CC_MD5_DIGEST_LENGTH];
        CC_MD5_Final(digest, &md5Context);
        
        NSMutableString *md5String = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
            [md5String appendFormat:@"%02x", digest[i]];
        }
        *outputMD5 = md5String;
    }
    
    // 关闭文件句柄
    [inputHandle closeFile];
    [outputHandle closeFile];
    
    // 如果解密失败，清理已写入的残余输出文件
    if (!success) {
        NSError *removeError = nil;
        if ([fileManager fileExistsAtPath:outputPath]) {
            [fileManager removeItemAtPath:outputPath error:&removeError];
            if (removeError) {
                NSLog(@"[ReshubAESFileDecryptor] 警告: 清理失败的输出文件时出错: %@", removeError.localizedDescription);
            }
        }
    }
    
    return success;
}

/**
 * 执行AES/CTR模式解密
 * 每次调用都创建新的Cipher实例，保持与Android/Dart端一致
 */
+ (NSData *)_performAESCTRDecryption:(NSData *)encryptedData
                                 key:(NSData *)keyData
                                  iv:(NSData *)ivData {
    if (!encryptedData || !keyData || !ivData) {
        return nil;
    }
    
    // 创建CCCryptor对象用于CTR模式
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus status = CCCryptorCreateWithMode(
        kCCDecrypt,                    // 操作：解密
        kCCModeCTR,                    // 模式：CTR
        kCCAlgorithmAES,               // 算法：AES
        ccNoPadding,                   // 无padding
        ivData.bytes,                  // IV（初始计数器）
        keyData.bytes,                 // 密钥
        keyData.length,                // 密钥长度
        NULL,                          // tweak（CTR模式不需要）
        0,                             // tweak长度
        0,                             // 轮数（使用默认）
        0,                             // 选项
        &cryptor                       // 输出：cryptor对象
    );
    
    if (status != kCCSuccess) {
        return nil;
    }
    
    // 创建输出缓冲区
    size_t bufferSize = encryptedData.length + kCCBlockSizeAES128;
    void *buffer = malloc(bufferSize);
    if (!buffer) {
        CCCryptorRelease(cryptor);
        return nil;
    }
    
    size_t dataOutMoved = 0;
    
    // 执行解密
    status = CCCryptorUpdate(
        cryptor,                       // cryptor对象
        encryptedData.bytes,           // 输入数据
        encryptedData.length,          // 输入数据长度
        buffer,                        // 输出缓冲区
        bufferSize,                    // 输出缓冲区大小
        &dataOutMoved                  // 实际输出的字节数
    );
    
    NSData *result = nil;
    if (status == kCCSuccess) {
        result = [NSData dataWithBytes:buffer length:dataOutMoved];
    }
    
    // 清理资源
    free(buffer);
    CCCryptorRelease(cryptor);
    
    return result;
}

/**
 * 计算文件的MD5值（公开方法，流式计算）
 */
+ (NSString *)calculateFileMD5:(NSString *)filePath {
    if (!filePath || filePath.length == 0) {
        return @"";
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:filePath]) {
        return @"";
    }
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!fileHandle) {
        
        return @"";
    }
    
    CC_MD5_CTX md5Context;
    CC_MD5_Init(&md5Context);
    
    const NSUInteger bufferSize = 8192;//8k
    
    while (YES) {
        @autoreleasepool {
            NSData *data = [fileHandle readDataOfLength:bufferSize];
            if (data.length == 0) {
                break;
            }
            CC_MD5_Update(&md5Context, data.bytes, (CC_LONG)data.length);
        }
    }
    
    [fileHandle closeFile];
    
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_Final(digest, &md5Context);
    
    NSMutableString *md5String = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [md5String appendFormat:@"%02x", digest[i]];
    }
    
    return md5String;
}

@end
