package com.tencent.reshub_flutter

import android.content.Context
import android.util.Log
import com.tencent.rdelivery.reshub.util.zip.UnZipUtil
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.util.PathUtils
import java.io.File

class ConchLoaderHostImpl(private val context: Context) : MethodCallHandler {

    companion object {
        private const val TAG = "ReshubAESFileDecryptor"
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getApplicationDocumentsDirectory" -> {
                result.success(PathUtils.getDataDirectory(context))
            }

            "unzipFile" -> {
                val zipFilePath = call.argument<String>("zipFilePath")
                val destinationDir = call.argument<String>("destinationDir")
                val unzipResult = UnZipUtil.unzip(zipFilePath, destinationDir)
                result.success(unzipResult)
            }

            // 解密文件（AES/CTR/NoPadding），并可选进行MD5校验
            "decryptFile" -> {
                val encryptedFilePath = call.argument<String>("encryptedFilePath")
                val decryptedFilePath = call.argument<String>("decryptedFilePath")
                val secureKey = call.argument<String>("secureKey")
                val expectedMD5 = call.argument<String>("expectedMD5")

                Log.i(TAG, "开始解密文件: $encryptedFilePath")

                // 参数检查（提前到try外面）
                if (encryptedFilePath.isNullOrEmpty() || decryptedFilePath.isNullOrEmpty() || secureKey.isNullOrEmpty()) {
                    val errorMsg = "[$TAG] 错误: 参数不完整"
                    Log.e(TAG, errorMsg)
                    result.success(mapOf("success" to false, "errorMessage" to errorMsg))
                    return
                }

                // 文件路径检查（提前到try外面）
                val inFile = File(encryptedFilePath)
                if (!inFile.exists()) {
                    val errorMsg = "[$TAG] 错误: 加密文件不存在: $encryptedFilePath"
                    Log.e(TAG, errorMsg)
                    result.success(mapOf("success" to false, "errorMessage" to errorMsg))
                    return
                }

                val result_data = try {
                    val outFile = File(decryptedFilePath)
                    
                    // 确保目标目录存在
                    outFile.parentFile?.let { 
                        if (!it.exists()) {
                            it.mkdirs()
                            Log.i(TAG, "创建目标目录: ${it.absolutePath}")
                        }
                    }

                    // 1. 密钥转换
                    val transformedKey = CryptoUtils.secureKeyTransform(secureKey)
                    if (transformedKey.isEmpty()) {
                        val errorMsg = "[$TAG] 错误: 密钥转换失败，secureKey长度: ${secureKey.length}"
                        Log.e(TAG, errorMsg)
                        mapOf("success" to false, "errorMessage" to errorMsg)
                    } else {
                        Log.i(TAG, "密钥转换成功")

                        // 2. 文件解密
                        val fileSize = inFile.length()
                        Log.i(TAG, "文件大小: $fileSize bytes")
                        
                        val decOK = CryptoUtils.decryptFile(inFile, outFile, transformedKey)
                        if (!decOK) {
                            val errorMsg = "[$TAG] 错误: 文件解密失败，输入文件: $encryptedFilePath, 大小: $fileSize bytes, 输出文件: $decryptedFilePath"
                            Log.e(TAG, errorMsg)
                            // 清理失败的输出文件
                            runCatching { outFile.delete() }
                            mapOf("success" to false, "errorMessage" to errorMsg)
                        } else {
                            val decryptedSize = outFile.length()
                            Log.i(TAG, "文件解密成功，大小: $decryptedSize bytes")

                            // 3. 可选MD5校验
                            if (!expectedMD5.isNullOrEmpty()) {
                                val actualMD5 = CryptoUtils.md5ForFile(outFile)
                                Log.i(TAG, "实际MD5: $actualMD5")
                                Log.i(TAG, "期望MD5: $expectedMD5")
                                
                                val pass = expectedMD5.equals(actualMD5, ignoreCase = true)
                                if (!pass) {
                                    val errorMsg = "[$TAG] 错误: MD5校验失败，文件: $decryptedFilePath, 期望MD5: $expectedMD5, 实际MD5: $actualMD5"
                                    Log.e(TAG, errorMsg)
                                    // 清理校验失败的文件
                                    runCatching { outFile.delete() }
                                    mapOf("success" to false, "errorMessage" to errorMsg)
                                } else {
                                    Log.i(TAG, "MD5校验通过")
                                    mapOf("success" to true)
                                }
                            } else {
                                Log.i(TAG, "跳过MD5校验")
                                mapOf("success" to true)
                            }
                        }
                    }
                } catch (t: Throwable) {
                    val errorMsg = "[$TAG] 异常: 解密过程异常: ${t.message}"
                    Log.e(TAG, errorMsg, t)
                    mapOf("success" to false, "errorMessage" to errorMsg)
                }

                // 记录最终结果
                val success = result_data["success"] as? Boolean ?: false
                if (success) {
                    Log.i(TAG, "解密操作成功完成")
                } else {
                    val errorMessage = result_data["errorMessage"] as? String ?: "未知错误"
                    Log.e(TAG, "解密操作失败: $errorMessage")
                }
                result.success(result_data)
            }

            // 计算文件的MD5值
            "calculateFileMD5" -> {
                val filePath = call.argument<String>("filePath")
                val md5 = try {
                    if (filePath.isNullOrEmpty()) {
                        ""
                    } else {
                        val file = File(filePath)
                        if (file.exists()) {
                            CryptoUtils.md5ForFile(file)
                        } else {
                            ""
                        }
                    }
                } catch (t: Throwable) {
                    ""
                }
                result.success(md5)
            }

            else -> {
                result.notImplemented()
            }
        }
    }
}