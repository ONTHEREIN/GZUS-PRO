import 'shiply_public_content_models.dart';

class ShiplyPublicContentStore {
  static final ShiplyPublicContentStore instance = ShiplyPublicContentStore._();

  ShiplyPublicContentStore._();

  ShiplyLoginContent? get cachedLogin => null;
  ShiplyHomeContent? get cachedHome => null;

  Future<void> initialize() async {}

  Future<ShiplyLoginContent> loadLoginLatest() async {
    throw const ShiplyPublicContentException('当前平台未启用 Shiply 登录页资源');
  }

  Future<ShiplyHomeContent> loadHomeLatest() async {
    throw const ShiplyPublicContentException('当前平台未启用 Shiply 公共资源');
  }
}
