package cn.gzus.pro

import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import org.apache.commons.net.ftp.FTPCmd
import org.apache.commons.net.ftp.FTPFile
import org.apache.commons.net.ftp.FTPReply
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.time.Duration

class FtpUploadException(val code: String, message: String) : Exception(message)

class FtpUploadClient {
    fun testConnection(args: Map<*, *>) {
        withClient(args) { ftp ->
            if (!ftp.printWorkingDirectory().isNullOrEmpty()) {
                true
            } else {
                throw FtpUploadException("NETWORK_ERROR", "FTP 服务器未返回当前目录")
            }
        }
    }

    fun listDirectory(args: Map<*, *>): List<Map<String, Any>> {
        val path = normalizeDirectory(args["path"]?.toString() ?: "/")
        return withClient(args) { ftp ->
            // 参考 FTPclient-android：优先使用 MLSD 命令（结构化数据，解析更可靠）
            val supportsMls = ftp.hasFeature(FTPCmd.MLST)
            val files = if (supportsMls) {
                ftp.mlistDir(path)
            } else {
                ftp.listFiles(path)
            }
            if (files == null || files.isEmpty()) {
                return@withClient emptyList()
            }
            files
                .filter { it.name != "." && it.name != ".." }
                .map { file ->
                    mapOf(
                        "name" to file.name,
                        "path" to childPath(path, file.name, file),
                        "isDirectory" to (file.isDirectory || file.isSymbolicLink),
                        "size" to safeSize(file)
                    )
                }
        }
    }

    fun uploadFile(args: Map<*, *>): Map<String, Any> {
        val localPath = args["localPath"]?.toString().orEmpty()
        val remoteDirectory = normalizeDirectory(args["path"]?.toString() ?: "/")
        val localFile = File(localPath)
        if (!localFile.exists() || !localFile.isFile) {
            throw FtpUploadException("FILE_NOT_FOUND", "本地文件不存在")
        }
        return withClient(args) { ftp ->
            val remotePath = childPath(remoteDirectory, localFile.name, null)
            FileInputStream(localFile).use { input ->
                val uploaded = ftp.storeFile(remotePath, input)
                if (!uploaded) {
                    val code = if (ftp.replyCode == 550) "PERMISSION_DENIED" else "UPLOAD_FAILED"
                    throw FtpUploadException(code, ftp.replyString?.trim().orEmpty().ifEmpty { "上传失败" })
                }
            }
            mapOf(
                "remotePath" to remotePath,
                "bytesSent" to localFile.length()
            )
        }
    }

    fun downloadFile(args: Map<*, *>): Map<String, Any> {
        val remotePath = args["remotePath"]?.toString().orEmpty()
        val localPath = args["localPath"]?.toString().orEmpty()
        if (remotePath.isEmpty()) {
            throw FtpUploadException("INVALID_ARGUMENT", "远程文件路径不能为空")
        }
        if (localPath.isEmpty()) {
            throw FtpUploadException("INVALID_ARGUMENT", "本地保存路径不能为空")
        }
        val localFile = File(localPath)
        val parentDir = localFile.parentFile
        if (parentDir != null && !parentDir.exists()) {
            parentDir.mkdirs()
        }
        return withClient(args) { ftp ->
            FileOutputStream(localFile).use { output ->
                val downloaded = ftp.retrieveFile(remotePath, output)
                if (!downloaded) {
                    localFile.delete()
                    val code = if (ftp.replyCode == 550) "FILE_NOT_FOUND" else "DOWNLOAD_FAILED"
                    throw FtpUploadException(code, ftp.replyString?.trim().orEmpty().ifEmpty { "下载失败" })
                }
            }
            mapOf(
                "localPath" to localFile.absolutePath,
                "bytesReceived" to localFile.length()
            )
        }
    }

    private fun <T> withClient(args: Map<*, *>, block: (FTPClient) -> T): T {
        val host = args["host"]?.toString()?.trim().orEmpty()
        val port = (args["port"] as? Number)?.toInt() ?: args["port"]?.toString()?.toIntOrNull() ?: 21
        val username = args["username"]?.toString().orEmpty()
        val password = args["password"]?.toString().orEmpty()
        val passiveMode = args["passiveMode"] as? Boolean ?: true
        val timeoutMillis = ((args["timeoutSeconds"] as? Number)?.toInt()
            ?: args["timeoutSeconds"]?.toString()?.toIntOrNull()
            ?: 15) * 1000

        if (host.isEmpty() || username.isEmpty() || password.isEmpty()) {
            throw FtpUploadException("INVALID_ARGUMENT", "FTP 参数不完整")
        }

        // 参考 FTPclient-android：使用 autodetectUTF8 自动检测编码
        val ftp = FTPClient()
        ftp.autodetectUTF8 = true
        ftp.connectTimeout = timeoutMillis
        ftp.defaultTimeout = timeoutMillis
        ftp.dataTimeout = Duration.ofMillis(timeoutMillis.toLong())
        try {
            ftp.connect(host, port)
            if (!FTPReply.isPositiveCompletion(ftp.replyCode)) {
                throw FtpUploadException("NETWORK_ERROR", ftp.replyString?.trim().orEmpty().ifEmpty { "无法连接 FTP" })
            }
            val loggedIn = ftp.login(username, password)
            if (!loggedIn) {
                throw FtpUploadException("AUTH_FAILED", ftp.replyString?.trim().orEmpty().ifEmpty { "FTP 登录失败" })
            }
            // 登录后再协商 UTF-8，部分 FTP 服务器要求认证后才能执行 OPTS
            val utf8Supported = ftp.sendCommand("OPTS", "UTF8 ON") == 200
            if (!utf8Supported) {
                // 服务器不支持 UTF-8，回退 GBK（中文 Windows FTP 常见编码）
                ftp.controlEncoding = "GBK"
            }
            ftp.setFileType(FTP.BINARY_FILE_TYPE)
            ftp.controlKeepAliveTimeout = 10
            if (passiveMode) {
                ftp.enterLocalPassiveMode()
            } else {
                ftp.enterLocalActiveMode()
            }
            return block(ftp)
        } catch (e: FtpUploadException) {
            throw e
        } catch (e: java.net.SocketTimeoutException) {
            throw FtpUploadException("NETWORK_ERROR", "FTP 连接超时")
        } catch (e: java.net.UnknownHostException) {
            throw FtpUploadException("NETWORK_ERROR", "无法解析 FTP 服务器")
        } catch (e: java.io.IOException) {
            throw FtpUploadException("NETWORK_ERROR", e.message ?: "FTP 网络错误")
        } finally {
            try {
                if (ftp.isConnected) {
                    ftp.logout()
                    ftp.disconnect()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun normalizeDirectory(path: String): String {
        val trimmed = path.trim()
        if (trimmed.isEmpty() || trimmed == "/") return "/"
        return if (trimmed.startsWith("/")) trimmed else "/$trimmed"
    }

    /**
     * 参考 FTPclient-android 的 File.joinPaths 和符号链接处理：
     * 符号链接的 link 如果是绝对路径则直接使用，否则拼接当前目录
     */
    private fun childPath(directory: String, name: String, file: FTPFile?): String {
        // 处理符号链接：如果 link 是绝对路径则直接使用
        if (file != null && file.isSymbolicLink) {
            val link = file.link
            if (!link.isNullOrEmpty() && link.startsWith("/")) {
                return link
            }
        }
        val normalized = normalizeDirectory(directory)
        return if (normalized == "/") "/$name" else "$normalized/$name"
    }

    private fun safeSize(file: FTPFile): Long {
        return if (file.isDirectory) 0L else file.size
    }
}
