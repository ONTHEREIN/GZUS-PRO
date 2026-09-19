import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/shiply_public_content.dart';

void main() {
  test('分别解析登录页和首页资源，并生成本地媒体路径', () {
    final login = ShiplyPublicContentParser.parseLogin(
      rootPath: '/tmp/gzus-login',
      files: {
        'manifest.json': jsonEncode({
          'schemaVersion': 1,
          'resourceKey': 'gzus_login_content',
          'resourceKind': 'login',
          'generatedAt': '2026-09-19T00:00:00Z',
          'files': {'loginSlides': 'login_slides.json'},
        }),
        'login_slides.json': jsonEncode([
          {
            'id': 2,
            'title': '登录图',
            'imagePath': 'media/login-slides/2.png',
            'imageMime': 'image/png',
          },
        ]),
      },
    );
    final home = ShiplyPublicContentParser.parseHome(
      rootPath: '/tmp/gzus-home',
      files: {
        'manifest.json': jsonEncode({
          'schemaVersion': 1,
          'resourceKey': 'gzus_public_content',
          'resourceKind': 'home',
          'generatedAt': '2026-09-19T00:00:00Z',
          'files': {
            'notices': 'notices.json',
            'wechatArticles': 'wechat_articles.json',
          },
        }),
        'notices.json': jsonEncode([
          {
            'id': 1,
            'category': '校历',
            'title': '校历',
            'coverPath': 'media/notices/1.png',
            'source': 'admin',
            'isPinned': true,
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

    expect(login.loginSlides.single.localImagePath,
        '/tmp/gzus-login/media/login-slides/2.png');
    expect(home.notices.single.localCoverPath,
        '/tmp/gzus-home/media/notices/1.png');
    expect(
        home.wechatArticles.single.articleUrl, 'https://mp.weixin.qq.com/s/3');
  });

  test('资源 Key、资源类型、文件和媒体路径错误均会被拒绝', () {
    final loginManifest = jsonEncode({
      'schemaVersion': 1,
      'resourceKey': 'gzus_login_content',
      'resourceKind': 'login',
      'generatedAt': 'now',
      'files': {'loginSlides': 'login_slides.json'},
    });
    expect(
      () => ShiplyPublicContentParser.parseHome(
        rootPath: '/tmp',
        files: {'manifest.json': loginManifest},
      ),
      throwsA(isA<ShiplyPublicContentException>()),
    );

    final homeManifest = jsonEncode({
      'schemaVersion': 1,
      'resourceKey': 'gzus_public_content',
      'resourceKind': 'home',
      'generatedAt': 'now',
      'files': {
        'notices': 'notices.json',
        'wechatArticles': 'wechat_articles.json',
      },
    });
    expect(
      () => ShiplyPublicContentParser.parseHome(
        rootPath: '/tmp',
        files: {
          'manifest.json': homeManifest,
          'notices.json': jsonEncode([
            {
              'id': 1,
              'category': '校历',
              'title': '异常资源',
              'coverPath': '../secret.png',
              'source': 'admin',
            },
          ]),
          'wechat_articles.json': '[]',
        },
      ),
      throwsA(isA<ShiplyPublicContentException>()),
    );
  });
}
