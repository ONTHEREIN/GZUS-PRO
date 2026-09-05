import 'package:flutter/material.dart';
import 'package:gzus_pro_mobile_web/live_activity_service.dart';

void main() {
  runApp(const _PreviewApp());
}

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  final LiveActivityController _controller = LiveActivityController.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showCourse());
  }

  @override
  void dispose() {
    _controller.dismissAll();
    super.dispose();
  }

  void _showCourse() {
    _controller.dismissAll();
    _controller.show(LiveActivityEvent(
      id: 'preview-course',
      type: 'course_reminder',
      title: '下课提醒',
      body: '下节课 14:00 · 操作系统 · 教学楼 B205',
      shortText: '数据结构 · 11:50 已结束',
      targetTab: 'schedule',
      ongoing: true,
    ));
  }

  void _showUtility() {
    _controller.dismissAll();
    _controller.show(LiveActivityEvent(
      id: 'preview-utility',
      type: 'ecard_reminder',
      title: '水电余额',
      body: '冷水 18.2 吨 · 热水 26.0 元 · 电费 42.6 度',
      shortText: '42.6 度',
      targetTab: 'ecard',
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
      ),
      home: Scaffold(
        backgroundColor: const Color(0xFFF5F7FA),
        body: Stack(
          children: [
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 148, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '软帮手即时动态',
                      style:
                          TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '点击顶部胶囊展开或收起；选择事件可查看不同状态。',
                      style: TextStyle(color: Color(0xFF6B7280)),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('preview-course'),
                            onPressed: _showCourse,
                            child: const Text('课程'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('preview-utility'),
                            onPressed: _showUtility,
                            child: const Text('水电'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            LiveActivityIsland(controller: _controller),
          ],
        ),
      ),
    );
  }
}
