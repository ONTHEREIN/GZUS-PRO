#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 返回字典的键常量
extern NSString * const kReshubDecryptResultKeySuccess;
extern NSString * const kReshubDecryptResultKeyErrorMessage;

/**
 * AES文件解密器
 * 用于解密补丁文件，支持AES/CTR模式
 */
@interface ReshubAESFileDecryptor : NSObject

/**
 * 解密补丁文件
 * @param encryptedFilePath 加密文件路径
 * @param decryptedFilePath 解密后文件保存路径
 * @param secureKey 加密密钥（需要转换）
 * @param expectedMD5 期望的MD5值（用于校验）
 * @return 返回字典，包含 kReshubDecryptResultKeySuccess (NSNumber BOOL) 和 kReshubDecryptResultKeyErrorMessage (NSString，失败时提供)
 */
+ (NSDictionary *)decryptFileAtPath:(NSString *)encryptedFilePath
                 toDestination:(NSString *)decryptedFilePath
                     secureKey:(NSString *)secureKey
                   expectedMD5:(NSString *)expectedMD5;

/**
 * 计算文件的MD5值
 * @param filePath 文件路径
 * @return 返回MD5字符串（小写），如果文件不存在或计算失败则返回空字符串
 */
+ (NSString *)calculateFileMD5:(NSString *)filePath;

@end

NS_ASSUME_NONNULL_END
