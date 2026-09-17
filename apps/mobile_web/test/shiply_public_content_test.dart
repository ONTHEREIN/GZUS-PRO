import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/shiply_public_content.dart';

void main() {
  test('解析 manifest 与三类公共内容，并生成本地媒体路径', () {
    final content = ShiplyPublicContentParser.parse(
      rootPath: '/tmp/gzus-public',
      files: {
        'manifest.json': jsonEncode({
          'schemaVersion': 1,
          'resourceKey': 'gzus_public_content',
          'generatedAt': '2026-09-17T00:00:00Z',
          'files': {
            'notices': 'notices.json',
            'loginSlides': 'login_slides.json',
            'wechatArticles': 'wechat_articles.json',
          },
        }),
        'notices.json': jsonEncode([
          {
            'id': 1,
            'category': '校历',
            'title': '校历',
            'description': '说明',
            'coverPath': 'media/notices/1.png',
            'source': 'admin',
            'isPinned': true,
          },
        ]),
        'login_slides.json': jsonEncode([
          {
            'id': 2,
            'title': '登录图',
            'imagePath': 'media/login-slides/2.png',
            'imageMime': 'image/png',
          },
        ]),
        'wechat_articles.json': jsonEncode([
          {
            'id': 3,
            'title': '文章',
            'articleUrl': 'https://mp.weixin.qq.com/s/3',
            'coverPath': 'media/wechat/3.jpg',
            'coverMime': 'image/jpeg',
            'source': 'wechat',
          },
        ]),
      },
    );

    expect(content.generatedAt, '2026-09-17T00:00:00Z');
    expect(content.notices.single.localCoverPath,
        '/tmp/gzus-public/media/notices/1.png');
    expect(content.loginSlides.single.localImagePath,
        '/tmp/gzus-public/media/login-slides/2.png');
    expect(content.wechatArticles.single.articleUrl,
        'https://mp.weixin.qq.com/s/3');
  });

  test('缺少文件、schema 或不安全路径时明确失败', () {
    final files = <String, String>{
      'manifest.json': jsonEncode({
        'schemaVersion': 2,
        'resourceKey': 'gzus_public_content',
        'generatedAt': 'now',
        'files': {
          'notices': 'notices.json',
          'loginSlides': 'login_slides.json',
          'wechatArticles': 'wechat_articles.json',
        },
      }),
    };

    expect(
      () => ShiplyPublicContentParser.parse(rootPath: '/tmp', files: files),
      throwsA(isA<ShiplyPublicContentException>()),
    );
  });

  test('资源 key 错误和媒体路径穿越都会被拒绝', () {
    final files = <String, String>{
      'manifest.json': jsonEncode({
        'schemaVersion': 1,
        'resourceKey': 'other',
        'generatedAt': 'now',
        'files': {
          'notices': 'notices.json',
          'loginSlides': 'login_slides.json',
          'wechatArticles': 'wechat_articles.json',
        },
      }),
    };
    expect(
      () => ShiplyPublicContentParser.parse(rootPath: '/tmp', files: files),
      throwsA(isA<ShiplyPublicContentException>()),
    );

    final validManifest = jsonEncode({
      'schemaVersion': 1,
      'resourceKey': 'gzus_public_content',
      'generatedAt': 'now',
      'files': {
        'notices': 'notices.json',
        'loginSlides': 'login_slides.json',
        'wechatArticles': 'wechat_articles.json',
      },
    });
    expect(
      () => ShiplyPublicContentParser.parse(
        rootPath: '/tmp',
        files: {
          'manifest.json': validManifest,
          'notices.json': jsonEncode([
            {
              'id': 1,
              'category': '校历',
              'title': '异常资源',
              'coverPath': '../secret.png',
              'source': 'admin',
            },
          ]),
          'login_slides.json': '[]',
          'wechat_articles.json': '[]',
        },
      ),
      throwsA(isA<ShiplyPublicContentException>()),
    );
  });
}
