package com.tencent.reshub_flutter

import android.util.Base64
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object CryptoUtils {

    private const val TAG = "ReshubAESFileDecryptor"

    // 还原AES密钥：与Dart侧_patch_installer的_secureKeyTransform一致
    fun secureKeyTransform(secureKey: String): String {
        Log.i(TAG, "开始密钥转换")
        
        if (secureKey.length < 32) {
            Log.e(TAG, "密钥长度不足")
            return ""
        }
        val encodeString = secureKey.substring(0, 1) +
                secureKey.substring(2, 5) +
                secureKey.substring(8, 13) +
                secureKey.substring(18, 25) +
                secureKey.substring(32)
        val encryptKey = secureKey.substring(1, 2) +
                secureKey.substring(5, 8) +
                secureKey.substring(13, 18) +
                secureKey.substring(25, 32)
        return try {
            val decoded = Base64.decode(encodeString, Base64.DEFAULT)
            if (decoded == null || decoded.isEmpty()) {
                Log.e(TAG, "Base64解码失败")
                return ""
            }
            
            val plainBytes = decryptBytesWithAES(decoded, encryptKey)
            if (plainBytes.isEmpty()) {
                Log.e(TAG, "AES解密失败")
                return ""
            }
            
            val result = String(plainBytes, Charsets.UTF_8)
            Log.i(TAG, "密钥转换完成")
            result
        } catch (t: Throwable) {
            Log.e(TAG, "密钥转换异常: ${t.message}", t)
            ""
        }
    }

    // 解密字节数组：AES/CTR/NoPadding，IV为全0，长度与key字节长度一致
    private fun decryptBytesWithAES(encrypted: ByteArray, encryptKey: String): ByteArray {
        Log.i(TAG, "开始字节数组解密")
        
        if (encrypted.isEmpty()) {
            Log.e(TAG, "加密数据为空")
            return ByteArray(0)
        }
        
        return try {
            val keyBytes = encryptKey.toByteArray(Charsets.UTF_8)
            if (keyBytes.isEmpty()) {
                Log.e(TAG, "密钥数据无效")
                return ByteArray(0)
            }
            
            val keySpec = SecretKeySpec(keyBytes, "AES")
            val iv = IvParameterSpec(ByteArray(keyBytes.size)) // 全0IV
            val cipher = Cipher.getInstance("AES/CTR/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, keySpec, iv)
            val result = cipher.doFinal(encrypted)
            
            Log.i(TAG, "字节数组解密成功")
            result
        } catch (t: Throwable) {
            Log.e(TAG, "字节数组解密失败: ${t.message}", t)
            ByteArray(0)
        }
    }

    // 按1024字节分块进行文件解密：每块重建Cipher并使用相同的全0IV，保持与Dart端一致
    fun decryptFile(inFile: File, outFile: File, encryptKey: String): Boolean {
        Log.i(TAG, "开始文件解密: ${inFile.absolutePath}")
        
        if (!inFile.exists()) {
            Log.e(TAG, "文件不存在: ${inFile.absolutePath}")
            return false
        }
        
        return try {
            val keyBytes = encryptKey.toByteArray(Charsets.UTF_8)
            val keySpec = SecretKeySpec(keyBytes, "AES")
            val ivBytes = ByteArray(keyBytes.size) // 全0IV，长度与key相同
            val buffer = ByteArray(1024)
            
            val chunkSize = 1024
            val batchSize = 1024 // 一次处理1024个chunk
            val batchBufferSize = chunkSize * batchSize
            
            var totalProcessed = 0L
            var batchCount = 0
            val fileSize = inFile.length()
            
            Log.i(TAG, "文件大小: $fileSize bytes")

            FileInputStream(inFile).use { fis ->
                FileOutputStream(outFile).use { fos ->
                    while (true) {
                        val batchStartTime = System.currentTimeMillis()
                        var batchProcessed = 0
                        
                        // 处理一批数据
                        while (batchProcessed < batchBufferSize) {
                            val read = fis.read(buffer)
                            if (read <= 0) break
                            
                            val cipher = Cipher.getInstance("AES/CTR/NoPadding")
                            cipher.init(Cipher.DECRYPT_MODE, keySpec, IvParameterSpec(ivBytes))
                            val outBytes = cipher.doFinal(buffer, 0, read)
                            fos.write(outBytes)
                            
                            batchProcessed += read
                            totalProcessed += read
                        }
                        
                        if (batchProcessed == 0) break
                        
                        batchCount++
                        val batchDuration = System.currentTimeMillis() - batchStartTime
                        Log.i(TAG, "批次 $batchCount 处理完成: $totalProcessed/$fileSize bytes, 耗时: ${batchDuration}ms")
                    }
                    fos.flush()
                }
            }
            
            val decryptedSize = outFile.length()
            Log.i(TAG, "文件解密完成，解密后大小: $decryptedSize bytes")
            true
        } catch (t: Throwable) {
            Log.e(TAG, "文件解密失败: ${t.message}", t)
            // 失败时尝试清理输出文件避免脏数据
            runCatching { 
                if (outFile.exists()) {
                    outFile.delete()
                    Log.i(TAG, "已清理失败的输出文件")
                }
            }
            false
        }
    }

    fun md5ForFile(file: File): String {
        val md = MessageDigest.getInstance("MD5")
        FileInputStream(file).use { fis ->
            val buf = ByteArray(8192)
            while (true) {
                val read = fis.read(buf)
                if (read <= 0) break
                md.update(buf, 0, read)
            }
        }
        val bytes = md.digest()
        val sb = StringBuilder()
        for (b in bytes) {
            sb.append(String.format("%02x", b))
        }
        return sb.toString()
    }
}