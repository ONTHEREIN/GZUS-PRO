import 'package:flutter/services.dart';

class ConchLoaderHostAction {
  static const MethodChannel _channel = MethodChannel('conch_loader_host');

  /// 获取应用文档目录
  ///
  /// 可能抛出 [PlatformException] 当原生平台调用失败时
  static Future<String> getApplicationDocumentsDirectory() async {
    try {
      final result = await _channel.invokeMethod<String>('getApplicationDocumentsDirectory');
      return result ?? "";
    } on PlatformException catch (e) {
      throw PlatformException(
        code: e.code,
        message: '获取应用文档目录失败: ${e.message}',
        details: e.details,
      );
    } catch (e) {
      throw Exception('获取应用文档目录时发生未知错误: $e');
    }
  }

  /// 解压zip文件到指定目录
  ///
  /// 可能抛出 [PlatformException] 当原生平台调用失败时
  /// 可能抛出 [ArgumentError] 当参数无效时
  static Future<bool> unzipFile(String zipFilePath, String destinationDir) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'unzipFile',
        {
          'zipFilePath': zipFilePath,
          'destinationDir': destinationDir,
        },
      );
      return result ?? false;
    } on PlatformException catch (e) {
      throw PlatformException(
        code: e.code,
        message: '解压文件失败: ${e.message}',
        details: e.details,
      );
    } catch (e) {
      throw Exception('解压文件时发生未知错误: $e');
    }
  }

  /// 解密补丁文件（包含密钥转换和文件解密的完整流程）
  /// [encryptedFilePath] 加密文件路径
  /// [decryptedFilePath] 解密后文件保存路径
  /// [secureKey] 原始加密密钥（会在原生端自动转换）
  /// [expectedMD5] 期望的MD5值（可选）
  /// 返回 Map，包含 'success' (bool) 和 'errorMessage' (String，失败时提供)
  ///
  /// 可能抛出 [PlatformException] 当原生平台调用失败时
  /// 可能抛出 [ArgumentError] 当参数无效时
  static Future<Map<String, dynamic>> decryptFile({
    required String encryptedFilePath,
    required String decryptedFilePath,
    required String secureKey,
    String? expectedMD5,
  }) async {
    try {
      final result = await _channel.invokeMethod(
        'decryptFile',
        {
          'encryptedFilePath': encryptedFilePath,
          'decryptedFilePath': decryptedFilePath,
          'secureKey': secureKey,
          'expectedMD5': expectedMD5 ?? '',
        },
      );

      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      throw PlatformException(
        code: e.code,
        message: '解密文件失败: ${e.message}',
        details: e.details,
      );
    } catch (e) {
      throw Exception('解密文件时发生未知错误: $e');
    }
  }

  /// 计算文件的MD5值
  /// [filePath] 文件路径
  /// 返回 MD5字符串（小写），如果文件不存在或计算失败则返回空字符串
  ///
  /// 可能抛出 [PlatformException] 当原生平台调用失败时
  /// 可能抛出 [ArgumentError] 当文件路径无效时
  static Future<String> calculateFileMD5(String filePath) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'calculateFileMD5',
        {'filePath': filePath},
      );
      return result ?? '';
    } on PlatformException catch (e) {
      throw PlatformException(
        code: e.code,
        message: '计算文件MD5失败: ${e.message}',
        details: e.details,
      );
    } catch (e) {
      throw Exception('计算文件MD5时发生未知错误: $e');
    }
  }
}
