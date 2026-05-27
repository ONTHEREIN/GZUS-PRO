import 'package:fluent_ui/fluent_ui.dart';

class MobileCookieLoginResult {
  const MobileCookieLoginResult({required this.account, required this.cookies});

  final String account;
  final String cookies;
}

class MobileSsoLoginPage extends StatelessWidget {
  const MobileSsoLoginPage({super.key, required this.account});

  final String account;

  @override
  Widget build(BuildContext context) {
    return const ScaffoldPage(
      content: Center(child: Text('当前平台不支持办事大厅统一登录')),
    );
  }
}
