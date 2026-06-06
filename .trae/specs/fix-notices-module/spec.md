# 修复消息（通知）模块 Spec

## Why
消息（通知）模块在应用中不起作用。经过代码分析，发现 `AcademicClient` Protocol 缺少 `get_notices` 方法声明，`_query_notices` 缺少日志和错误处理，且 HTML 解析逻辑可能与真实教务系统首页不匹配，导致模块无法正常工作或返回空数据。

## What Changes
- 在 `AcademicClient` Protocol 中添加 `get_notices` 方法声明
- 在 `_query_notices` 及相关方法中添加 `logging` 日志，便于定位运行时问题
- 改进 `_query_notices` 的错误处理：区分 `proxy_request` 不可用、HTTP 请求失败、HTML 解析返回空结果等不同场景，给出有意义的错误信息
- 增强 HTML 解析的鲁棒性：增加对教务系统首页可能存在的更多 HTML 结构模式的支持
- 添加 `_query_notices` 在 `proxy_request` 不可用时的降级处理（尝试使用 SDK 内置方法或返回友好错误）
- 补充测试用例，覆盖更多 HTML 结构和错误场景

## Impact
- Affected specs: 消息/通知功能
- Affected code:
  - `services/api/app/sessions.py` — AcademicClient Protocol
  - `services/api/app/school_client.py` — `_query_notices`、`get_notices`、HTML 解析函数
  - `services/api/app/routes/academic.py` — `_run_academic_call` 错误处理
  - `services/api/tests/test_school_client.py` — 测试用例

## ADDED Requirements

### Requirement: AcademicClient Protocol 完整性
系统 SHALL 在 `AcademicClient` Protocol 中声明所有被路由使用的方法，包括 `get_notices`。

#### Scenario: 类型检查通过
- **WHEN** 对 `session.client.get_notices` 进行类型检查
- **THEN** 不应报错，因为 `AcademicClient` Protocol 包含 `get_notices` 方法

### Requirement: 通知模块日志记录
系统 SHALL 在 `_query_notices` 方法的关键步骤中记录日志，包括：
- 请求首页 HTML 前后
- HTML 解析结果（发现多少个 section）
- 跟随"更多"链接时
- 任何异常发生时

#### Scenario: 通知获取失败时可追溯
- **WHEN** `_query_notices` 执行过程中发生错误
- **THEN** 日志中应包含足够的信息来定位问题（请求的 URL、响应状态、解析结果等）

### Requirement: 通知模块错误处理增强
系统 SHALL 在 `_query_notices` 中区分以下错误场景并给出有意义的错误信息：
1. `proxy_request` 不可用 → 提示"当前登录方式不支持获取通知"
2. HTTP 请求失败（网络错误、超时）→ 提示"教务系统请求失败"
3. HTML 解析返回空结果 → 返回空列表而非报错（可能是正常情况）
4. 会话过期（HTML 是登录页）→ 抛出 `AuthenticationError`

#### Scenario: proxy_request 不可用
- **WHEN** SDK user client 不支持 `proxy_request`
- **THEN** 应抛出 `NotImplementedError` 并附带消息"当前登录方式不支持获取通知"

#### Scenario: 会话过期返回登录页
- **WHEN** `_query_notices` 获取到的 HTML 包含登录表单
- **THEN** 应抛出 `AuthenticationError` 提示会话已过期

### Requirement: HTML 解析鲁棒性增强
系统 SHALL 增强教务系统首页 HTML 解析的鲁棒性：
1. 增加对 `<div class="panel">` + `<div class="panel-heading">` 结构的支持
2. 增加对 `<div class="widget-box">` 结构的支持
3. 在 `is_notice_section` 中增加对 "gg" (公告)、"tz" (通知)、"xx" (信息) 等短标记的匹配
4. 在 `section_title` 中增加对 `<div class="panel-title">` 和 `<span class="title">` 的识别
5. 增加对 `<table>` 内通知链接的提取支持（某些教务系统使用表格布局）

#### Scenario: 非标准 HTML 结构仍可解析
- **WHEN** 教务系统首页使用 `<div class="panel">` 结构而非 `<div id="newsnotice">`
- **THEN** 解析器仍能正确提取通知 section 和其中的通知条目

## MODIFIED Requirements

### Requirement: AcademicClient Protocol
原有 Protocol 缺少 `get_notices` 方法。修改后应包含：

```python
class AcademicClient(Protocol):
    def get_info(self) -> dict: ...
    def get_student_photo(self) -> str | None: ...
    def get_schedule(self, year: str | None, term: str | None) -> list[dict]: ...
    def get_exams(self, year: str | None, term: str | None) -> list[dict]: ...
    def get_grades(self, year: str | None, term: str | None) -> list[dict]: ...
    def get_attendance(self, year: str | None, term: str | None) -> list[dict]: ...
    def get_credits(self) -> list[dict]: ...
    def get_notices(self) -> list[dict]: ...
    def logout(self) -> None: ...
```

### Requirement: _run_academic_call 错误处理
`_run_academic_call` 应区分 `MissingProxySlotError` 和其他异常，给出更有针对性的错误信息：

```python
def _run_academic_call(call: Callable[[], T]) -> T:
    try:
        return call()
    except AuthenticationError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc
    except MissingProxySlotError as exc:
        raise HTTPException(
            status_code=status.HTTP_501_NOT_IMPLEMENTED,
            detail=str(exc),
        ) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="教务系统数据获取失败，请稍后重试",
        ) from exc
```

## REMOVED Requirements
无
