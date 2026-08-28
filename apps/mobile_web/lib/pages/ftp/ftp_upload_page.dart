import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' as path_provider;

import '../../ftp_upload_service.dart';
import '../../gzus_design.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/info_tile.dart';
import '../../widgets/page_panel.dart';

enum _FtpQueueStatus { pending, uploading, done, failed }

enum _FtpDownloadStatus { pending, downloading, done, failed }

class _FtpQueuedFile {
  _FtpQueuedFile({
    required this.name,
    required this.path,
    required this.size,
  });

  final String name;
  final String path;
  final int size;
  _FtpQueueStatus status = _FtpQueueStatus.pending;
  double progress = 0;
  String? error;
}

class _FtpDownloadingFile {
  _FtpDownloadingFile({
    required this.name,
    required this.remotePath,
    required this.size,
    required this.localPath,
  });

  final String name;
  final String remotePath;
  final int size;
  final String localPath;
  _FtpDownloadStatus status = _FtpDownloadStatus.pending;
  String? error;
}

class FtpUploadPage extends StatefulWidget {
  const FtpUploadPage({super.key});

  @override
  State<FtpUploadPage> createState() => _FtpUploadPageState();
}

class _FtpUploadPageState extends State<FtpUploadPage> {
  final _hostController = TextEditingController(text: 'ftp.school.local');
  final _portController = TextEditingController(text: '21');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final List<_FtpQueuedFile> _queue = [];
  final List<_FtpDownloadingFile> _downloads = [];
  List<FtpEntry> _entries = const [];
  String _currentDirectory = '/';
  bool _passiveMode = true;
  bool _settingsLoaded = false;
  bool _testing = false;
  bool _listing = false;
  bool _uploading = false;
  bool _downloading = false;
  bool _connected = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!FtpUploadService.isSupported) {
      return const PagePanel(
        title: '作业上传',
        icon: Icons.upload_file,
        expandChild: true,
        child: EmptyState(message: 'Web 端无法直连 FTP，请改用原生客户端并连接学校内网或 VPN。'),
      );
    }

    return PagePanel(
      title: '作业上传',
      icon: Icons.upload_file,
      expandChild: true,
      child: RefreshIndicator(
        onRefresh: _connected
            ? () async {
                await _listCurrentDirectory();
              }
            : _testConnection,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _buildStatusCards(),
            const SizedBox(height: 12),
            if (_message != null)
              _buildBanner(_message!, Icons.check_circle, false),
            if (_error != null)
              _buildBanner(_error!, Icons.error_outline, true),
            if (_message != null || _error != null) const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 760;
                final children = [
                  _buildMainColumn(),
                  _buildConfigColumn(),
                ];
                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      children[0],
                      const SizedBox(height: 12),
                      children[1],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: children[0]),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: children[1]),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCards() {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final cards = [
          _FtpStatusCard(
            title: '平台',
            value: FtpUploadService.platformLabel,
            detail: '客户端直连 FTP',
            icon: Icons.phone_android,
            color: scheme.primary,
          ),
          _FtpStatusCard(
            title: '连接',
            value: _connected ? '已连接' : '未连接',
            detail: _connected ? _hostController.text.trim() : '需连接学校内网/VPN',
            icon: _connected ? Icons.wifi_tethering : Icons.wifi_off,
            color: _connected ? GzusColors.green : GzusColors.amber,
          ),
          _FtpStatusCard(
            title: '队列',
            value:
                '${_queue.where((f) => f.status != _FtpQueueStatus.done).length} 个待处理',
            detail:
                '${_queue.where((f) => f.status == _FtpQueueStatus.done).length} 个已完成',
            icon: Icons.cloud_upload_outlined,
            color: scheme.secondary,
          ),
        ];
        if (compact) {
          return Column(
            children: [
              for (final card in cards) ...[card, const SizedBox(height: 10)],
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              Expanded(child: cards[i]),
              if (i != cards.length - 1) const SizedBox(width: 10),
            ],
          ],
        );
      },
    );
  }

  Widget _buildMainColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccentPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('上传文件',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.add),
                    label: const Text('添加文件'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _pickFiles,
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(112)),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.upload_file, size: 34),
                    SizedBox(height: 8),
                    Text('选择 PDF、Word、PPT、ZIP 等作业文件'),
                    SizedBox(height: 2),
                    Text('单个文件最大 100 MB'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _canUpload ? _uploadPendingFiles : null,
                icon: _uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload),
                label: Text(_uploading ? '上传中...' : '开始上传'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildDirectoryPanel(),
        const SizedBox(height: 12),
        _buildQueuePanel(),
        const SizedBox(height: 12),
        _buildDownloadPanel(),
      ],
    );
  }

  Widget _buildConfigColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('FTP 配置', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _hostController,
                  decoration: const InputDecoration(
                    labelText: '服务器',
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    prefixIcon: Icon(Icons.numbers),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: '账号',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: _passiveMode,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('被动模式'),
                  subtitle: const Text('校园网 FTP 通常建议开启'),
                  onChanged: (value) => setState(() => _passiveMode = value),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed:
                      !_settingsLoaded || _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt),
                  label: Text(_testing ? '测试中...' : '测试连接'),
                ),
                const SizedBox(height: 8),
                Text(
                  '密码仅保存在系统安全区，不发送到软帮手后端。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDirectoryPanel() {
    final scheme = Theme.of(context).colorScheme;
    final dirs = _entries.where((e) => e.isDirectory).toList();
    final files = _entries.where((e) => !e.isDirectory).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('远程目录',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  onPressed:
                      _connected && !_listing ? _listCurrentDirectory : null,
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新目录',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                InputChip(
                  label: Text(_currentDirectory),
                  avatar: const Icon(Icons.folder, size: 18),
                  onPressed: _connected ? () => _openDirectory('/') : null,
                ),
                if (_currentDirectory != '/')
                  ActionChip(
                    avatar: const Icon(Icons.arrow_upward, size: 18),
                    label: const Text('上一级'),
                    onPressed: _openParentDirectory,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_listing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (!_connected)
              const EmptyState(message: '测试连接后显示 FTP 目录')
            else if (dirs.isEmpty && files.isEmpty)
              const EmptyState(message: '当前目录为空')
            else ...[
              // 目录列表
              for (final entry in dirs) ...[
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined,
                      color: GzusColors.amber),
                  title: Text(entry.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openDirectory(entry.path),
                ),
                const Divider(height: 1),
              ],
              // 文件列表（带下载按钮）
              if (files.isNotEmpty) ...[
                if (dirs.isNotEmpty) const SizedBox(height: 4),
                for (final entry in files) ...[
                  ListTile(
                    dense: true,
                    leading: Icon(
                      _fileIcon(entry.name),
                      color: scheme.primary,
                      size: 22,
                    ),
                    title: Text(entry.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_formatFtpSize(entry.size)),
                    trailing: IconButton(
                      icon: const Icon(Icons.download_outlined, size: 20),
                      tooltip: '下载',
                      onPressed:
                          _downloading ? null : () => _downloadFile(entry),
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' => Icons.description_outlined,
      'xls' || 'xlsx' => Icons.table_chart_outlined,
      'ppt' || 'pptx' => Icons.slideshow_outlined,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'bmp' ||
      'webp' =>
        Icons.image_outlined,
      'mp4' || 'avi' || 'mkv' || 'mov' => Icons.videocam_outlined,
      'mp3' || 'wav' || 'flac' || 'aac' => Icons.audiotrack_outlined,
      'txt' || 'md' || 'log' => Icons.article_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Future<void> _downloadFile(FtpEntry entry) async {
    final config = _readConfig();
    if (config == null) return;

    // 使用应用的 Download 目录
    final downloadDir = await _getDownloadDirectory();
    if (downloadDir == null) {
      if (mounted) setState(() => _error = '无法访问下载目录');
      return;
    }
    final localPath = '$downloadDir/${entry.name}';

    final item = _FtpDownloadingFile(
      name: entry.name,
      remotePath: entry.path,
      size: entry.size,
      localPath: localPath,
    );
    setState(() {
      _downloads.insert(0, item);
      _downloading = true;
      _error = null;
      _message = '开始下载 ${entry.name}';
    });

    try {
      await FtpUploadService.downloadFile(
        config: config,
        remotePath: entry.path,
        localPath: localPath,
      );
      if (!mounted) return;
      setState(() {
        item.status = _FtpDownloadStatus.done;
        _message = '${entry.name} 下载完成';
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        item.status = _FtpDownloadStatus.failed;
        item.error = _messageForError(exc);
        _error = '${entry.name} 下载失败：${_messageForError(exc)}';
      });
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<String?> _getDownloadDirectory() async {
    try {
      // 优先使用 Android Download 目录
      final dir = await path_provider.getExternalStorageDirectories();
      if (dir != null && dir.isNotEmpty) {
        return dir.first.path;
      }
    } catch (_) {}
    try {
      final dir = await path_provider.getApplicationDocumentsDirectory();
      return dir.path;
    } catch (_) {}
    return null;
  }

  Widget _buildQueuePanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('上传队列', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_queue.isEmpty)
              const EmptyState(message: '还没有选择文件')
            else
              for (final file in _queue) ...[
                _FtpQueueTile(
                  file: file,
                  onRetry: file.status == _FtpQueueStatus.failed
                      ? () => _retryFile(file)
                      : null,
                  onRemove: _uploading ? null : () => _removeFile(file),
                ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadPanel() {
    if (_downloads.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('下载记录',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => setState(() => _downloads.clear()),
                  child: const Text('清空'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in _downloads) ...[
              _FtpDownloadTile(
                item: item,
                onRemove: () => setState(() => _downloads.remove(item)),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBanner(String text, IconData icon, bool isError) {
    final color =
        isError ? Theme.of(context).colorScheme.error : GzusColors.green;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(GzusRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
          IconButton(
            onPressed: () => setState(() {
              _message = null;
              _error = null;
            }),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  bool get _canUpload =>
      _connected &&
      !_uploading &&
      _queue.any((f) =>
          f.status == _FtpQueueStatus.pending ||
          f.status == _FtpQueueStatus.failed);

  FtpConfig? _readConfig() {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (host.isEmpty || port == null || username.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写 FTP 服务器、端口、账号和密码');
      return null;
    }
    return FtpConfig(
      host: host,
      port: port,
      username: username,
      password: password,
      passiveMode: _passiveMode,
    );
  }

  Future<void> _loadSettings() async {
    final settings = await FtpUploadService.loadSettings();
    if (!mounted) return;
    setState(() {
      _hostController.text = settings.host;
      _portController.text = settings.port.toString();
      _usernameController.text = settings.username;
      _passwordController.text = settings.password;
      _passiveMode = settings.passiveMode;
      _currentDirectory = settings.lastDirectory;
      _settingsLoaded = true;
    });
  }

  Future<void> _saveSettings(FtpConfig config) async {
    await FtpUploadService.saveSettings(
      host: config.host,
      port: config.port,
      username: config.username,
      password: config.password,
      passiveMode: config.passiveMode,
      lastDirectory: _currentDirectory,
    );
  }

  Future<void> _testConnection() async {
    final config = _readConfig();
    if (config == null) return;
    setState(() {
      _testing = true;
      _error = null;
      _message = null;
    });
    try {
      await FtpUploadService.testConnection(config);
      await _saveSettings(config);
      if (!mounted) return;
      setState(() {
        _connected = true;
        _message = 'FTP 连接成功';
      });
      await _listCurrentDirectory();
    } catch (exc) {
      _handleFtpError(exc);
      if (mounted) setState(() => _connected = false);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<bool> _listCurrentDirectory() async {
    final config = _readConfig();
    if (config == null) return false;
    setState(() {
      _listing = true;
      _error = null;
    });
    try {
      final entries =
          await FtpUploadService.listDirectory(config, _currentDirectory);
      await _saveSettings(config);
      if (!mounted) return false;
      setState(() {
        _connected = true;
        _entries = entries;
      });
      return true;
    } catch (exc) {
      _handleFtpError(exc);
      return false;
    } finally {
      if (mounted) setState(() => _listing = false);
    }
  }

  Future<void> _openDirectory(String path) async {
    final previousDirectory = _currentDirectory;
    final nextDirectory = path.isEmpty ? '/' : path;
    setState(() => _currentDirectory = nextDirectory);
    final opened = await _listCurrentDirectory();
    if (!opened && mounted) {
      setState(() => _currentDirectory = previousDirectory);
    }
  }

  void _openParentDirectory() {
    final normalized =
        _currentDirectory.endsWith('/') && _currentDirectory.length > 1
            ? _currentDirectory.substring(0, _currentDirectory.length - 1)
            : _currentDirectory;
    final index = normalized.lastIndexOf('/');
    final parent = index <= 0 ? '/' : normalized.substring(0, index);
    _openDirectory(parent);
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (!mounted || result == null) return;
    final added = <_FtpQueuedFile>[];
    final rejected = <String>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null || path.isEmpty) {
        rejected.add(file.name);
        continue;
      }
      if (file.size > FtpUploadService.maxFileBytes) {
        rejected.add(file.name);
        continue;
      }
      added.add(_FtpQueuedFile(name: file.name, path: path, size: file.size));
    }
    setState(() {
      _queue.addAll(added);
      _message = added.isEmpty ? null : '已添加 ${added.length} 个文件';
      _error = rejected.isEmpty ? null : '${rejected.length} 个文件无法添加或超过 100 MB';
    });
  }

  Future<void> _uploadPendingFiles() async {
    final config = _readConfig();
    if (config == null) return;
    setState(() {
      _uploading = true;
      _error = null;
      _message = null;
    });
    for (final file in _queue.where((f) =>
        f.status == _FtpQueueStatus.pending ||
        f.status == _FtpQueueStatus.failed)) {
      await _uploadOne(config, file);
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _message = '上传队列处理完成';
    });
  }

  Future<void> _retryFile(_FtpQueuedFile file) async {
    final config = _readConfig();
    if (config == null) return;
    setState(() => _uploading = true);
    await _uploadOne(config, file);
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _uploadOne(FtpConfig config, _FtpQueuedFile file) async {
    if (!mounted) return;
    setState(() {
      file.status = _FtpQueueStatus.uploading;
      file.progress = 0.12;
      file.error = null;
    });
    try {
      await FtpUploadService.uploadFile(
        config: config,
        localPath: file.path,
        remoteDirectory: _currentDirectory,
      );
      if (!mounted) return;
      setState(() {
        file.status = _FtpQueueStatus.done;
        file.progress = 1;
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        file.status = _FtpQueueStatus.failed;
        file.progress = 0;
        file.error = _messageForError(exc);
      });
    }
  }

  void _removeFile(_FtpQueuedFile file) {
    setState(() => _queue.remove(file));
  }

  void _handleFtpError(Object exc) {
    if (!mounted) return;
    setState(() => _error = _messageForError(exc));
  }

  String _messageForError(Object exc) {
    if (exc is FtpUploadException) {
      switch (exc.code) {
        case 'AUTH_FAILED':
          return '登录失败，请检查 FTP 账号或密码';
        case 'NETWORK_ERROR':
          return '无法连接 FTP，请确认已连接学校内网或 VPN';
        case 'PERMISSION_DENIED':
          return '当前目录无权限，请更换目录';
        case 'FILE_NOT_FOUND':
          return '远程文件不存在或本地路径无效';
        case 'DOWNLOAD_FAILED':
          return '下载失败，请稍后重试';
        case 'UNSUPPORTED':
        case 'unsupported':
          return '当前平台不支持客户端 FTP';
        default:
          return exc.message;
      }
    }
    return 'FTP 操作失败，请稍后重试';
  }
}

class _FtpStatusCard extends StatelessWidget {
  const _FtpStatusCard({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(GzusRadii.md),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 2),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FtpQueueTile extends StatelessWidget {
  const _FtpQueueTile({
    required this.file,
    this.onRetry,
    this.onRemove,
  });

  final _FtpQueuedFile file;
  final VoidCallback? onRetry;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final color = switch (file.status) {
      _FtpQueueStatus.done => GzusColors.green,
      _FtpQueueStatus.failed => Theme.of(context).colorScheme.error,
      _FtpQueueStatus.uploading => Theme.of(context).colorScheme.primary,
      _FtpQueueStatus.pending => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final label = switch (file.status) {
      _FtpQueueStatus.done => '完成',
      _FtpQueueStatus.failed => '失败',
      _FtpQueueStatus.uploading => '上传中',
      _FtpQueueStatus.pending => '待上传',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: gzusSurfaceSoft(context),
        borderRadius: BorderRadius.circular(GzusRadii.md),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file_outlined, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                    '${_formatFtpSize(file.size)} · $label${file.error == null ? '' : ' · ${file.error}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
                if (file.status == _FtpQueueStatus.uploading) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: file.progress),
                ],
              ],
            ),
          ),
          if (onRetry != null)
            IconButton(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              tooltip: '重试',
            ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close),
              tooltip: '移除',
            ),
        ],
      ),
    );
  }
}

class _FtpDownloadTile extends StatelessWidget {
  const _FtpDownloadTile({
    required this.item,
    this.onRemove,
  });

  final _FtpDownloadingFile item;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final color = switch (item.status) {
      _FtpDownloadStatus.done => GzusColors.green,
      _FtpDownloadStatus.failed => Theme.of(context).colorScheme.error,
      _FtpDownloadStatus.downloading => Theme.of(context).colorScheme.primary,
      _FtpDownloadStatus.pending =>
        Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final label = switch (item.status) {
      _FtpDownloadStatus.done => '已下载',
      _FtpDownloadStatus.failed => '失败',
      _FtpDownloadStatus.downloading => '下载中',
      _FtpDownloadStatus.pending => '等待中',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: gzusSurfaceSoft(context),
        borderRadius: BorderRadius.circular(GzusRadii.md),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Row(
        children: [
          Icon(Icons.download_done, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                    '${_formatFtpSize(item.size)} · $label${item.error == null ? '' : ' · ${item.error}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 18),
              tooltip: '移除',
            ),
        ],
      ),
    );
  }
}

String _formatFtpSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
