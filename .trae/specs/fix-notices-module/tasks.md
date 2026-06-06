# Tasks

- [x] Task 1: 在 AcademicClient Protocol 中添加 `get_notices` 方法声明
  - [x] 1.1: 在 `sessions.py` 的 `AcademicClient` Protocol 中添加 `def get_notices(self) -> list[dict]: ...`
  - [x] 1.2: 验证类型检查通过

- [x] Task 2: 在 `_query_notices` 及相关方法中添加 logging 日志
  - [x] 2.1: 在 `school_client.py` 顶部添加 `import logging` 和 `logger = logging.getLogger(__name__)`
  - [x] 2.2: 在 `_query_notices` 中添加关键步骤日志：请求首页、解析结果、跟随更多链接、异常
  - [x] 2.3: 在 `_proxy_response` 中添加日志记录请求方法和 URL
  - [x] 2.4: 在 `_response_text` 中添加日志记录响应文本长度

- [x] Task 3: 改进 `_query_notices` 的错误处理
  - [x] 3.1: 在 `_query_notices` 中检测 HTML 是否为登录页（包含 login_slogin 或表单），若是则抛出 `AuthenticationError`
  - [x] 3.2: 在 `_proxy_response` 中将 `MissingProxySlotError` 的错误信息改为更友好的"当前登录方式不支持获取通知"
  - [x] 3.3: 在 `_run_academic_call` 中区分 `MissingProxySlotError`，返回 501 而非 502

- [x] Task 4: 增强 HTML 解析鲁棒性
  - [x] 4.1: 在 `is_notice_section` 中增加对 "xwgg"、"gggl" 标记的匹配
  - [x] 4.2: 在 `section_title` 中增加对 `<div class="panel-title">`、`<div class="widget-title">` 和 `<span class="title">` 的识别
  - [x] 4.3: 在 `extract_notice_sections` 中增加对 `<div class="panel">` 和 `<div class="widget-box">` 结构的支持
  - [x] 4.4: 在 `extract_notice_items_from_node` 中增加对 `<table>` 内 `<a>` 链接的提取支持

- [x] Task 5: 补充测试用例
  - [x] 5.1: 添加 `panel` 结构 HTML 的解析测试
  - [x] 5.2: 添加登录页 HTML 的检测测试
  - [x] 5.3: 添加 `MissingProxySlotError` 场景的 API 路由测试
  - [x] 5.4: 添加 `AcademicClient` Protocol 包含 `get_notices` 的验证测试

- [x] Task 6: 运行全部测试并验证
  - [x] 6.1: 运行 `pytest tests/ -v` 确保所有测试通过
  - [x] 6.2: 运行类型检查确保无新增类型错误

# Task Dependencies
- Task 2 依赖 Task 1（日志需要在 Protocol 修复后添加，避免类型检查干扰）
- Task 3 依赖 Task 1（错误处理改进需要 Protocol 已修复）
- Task 4 独立，可与 Task 2/3 并行
- Task 5 依赖 Task 1-4（测试需要覆盖所有改动）
- Task 6 依赖 Task 1-5（最终验证）
