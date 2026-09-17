import 'shiply_public_content_models.dart';

class ShiplyPublicContentStore {
  static final ShiplyPublicContentStore instance = ShiplyPublicContentStore._();

  ShiplyPublicContentStore._();

  ShiplyPublicContent? get cached => null;

  Future<void> initialize() async {}

  Future<ShiplyPublicContent> loadLatest() async {
    throw const ShiplyPublicContentException('当前平台未启用 Shiply 公共资源');
  }
}
