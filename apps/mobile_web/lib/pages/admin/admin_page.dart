import 'package:flutter/material.dart';

import '../../api_client.dart';
import 'data_tab.dart';
import 'notices_tab.dart';
import 'overview_tab.dart';
import 'sessions_tab.dart';
import 'status_tab.dart';
import 'users_tab.dart';
import 'wechat_tab.dart';

/// 管理后台：管理员专属页面（仅 isAdmin 会话可进入，入口在「更多」页）。
///
/// 七个页签：总览 / 会话 / 管理员 / 数据统计 / 系统 / 校历 / 公众号。
class AdminPage extends StatelessWidget {
  const AdminPage({super.key, required this.api, this.isOwner = false});

  final ApiClient api;

  /// 当前管理员是否为 owner（决定管理员页是否显示增删按钮）。
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('管理后台'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '总览'),
              Tab(text: '会话'),
              Tab(text: '管理员'),
              Tab(text: '数据统计'),
              Tab(text: '系统'),
              Tab(text: '校历'),
              Tab(text: '公众号'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            OverviewTab(api: api),
            SessionsTab(api: api),
            UsersTab(api: api, isOwner: isOwner),
            DataTab(api: api),
            StatusTab(api: api),
            NoticesTab(api: api),
            WechatTab(api: api),
          ],
        ),
      ),
    );
  }
}
