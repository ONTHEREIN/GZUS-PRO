import 'dart:convert';

import 'package:flutter/material.dart';

import '../avatar_open.dart' deferred as avatar_open;

class StudentAvatar extends StatelessWidget {
  const StudentAvatar(
      {super.key, required this.photoDataUrl, required this.name});

  final String? photoDataUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    final image = photoDataUrl;
    return GestureDetector(
      onTap: image != null && image.isNotEmpty
          ? () => _showAvatarOverlay(context, image)
          : null,
      child: Container(
        width: 112,
        height: 144,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: image == null || image.isEmpty
            ? Center(
                child: Text(
                  name.isEmpty ? '-' : name.characters.first,
                  style: const TextStyle(
                      fontSize: 32, fontWeight: FontWeight.w600),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    base64Decode(image.substring(image.indexOf(',') + 1)),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Center(child: Icon(Icons.person)),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.zoom_in,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  void _showAvatarOverlay(BuildContext context, String dataUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (dialogContext) => _AvatarOverlayDialog(
        photoDataUrl: dataUrl,
        name: name,
      ),
    );
  }
}

class _AvatarOverlayDialog extends StatelessWidget {
  const _AvatarOverlayDialog({
    required this.photoDataUrl,
    required this.name,
  });

  final String photoDataUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.photo_camera, size: 20, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    '📸 头像抓取成功',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: 160,
                height: 160,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.primary, width: 3),
                ),
                child: Image.memory(
                  base64Decode(
                      photoDataUrl.substring(photoDataUrl.indexOf(',') + 1)),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Center(child: Icon(Icons.person, size: 48)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => _openInNewTab(context),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('新标签页打开'),
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openInNewTab(BuildContext context) {
    avatar_open.loadLibrary().then((_) {
      avatar_open.openAvatarInNewTab(photoDataUrl, name);
    });
    Navigator.of(context).pop();
  }
}
