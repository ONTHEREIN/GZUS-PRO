# 登录页 MD3 风格重构 Spec

## Why
登录页是应用的第一印象，需要更符合 Material Design 3 的现代化设计规范。当前登录页虽然使用了 MD3 组件，但布局和细节可以进一步优化，以提供更好的用户体验。

## What Changes
- 优化登录页布局结构，使用 MD3 规范的组件和间距
- 改进表单字段的 MD3 样式
- 优化验证码图片展示
- 增强错误提示的视觉反馈
- 改进按钮的 MD3 样式

## Impact
- Affected specs: migrate-to-md3
- Affected code: `apps/mobile_web/lib/main.dart` 中的 LoginPage

## ADDED Requirements

### Requirement: 登录页布局优化
系统 SHALL 重构登录页布局，使其更符合 MD3 设计规范。

#### Scenario: 登录表单卡片
- **WHEN** 用户访问登录页
- **THEN** 使用 `Card` 组件展示登录表单，卡片使用 `elevation: 2`
- **AND** 卡片圆角使用 16dp，移动端和桌面端使用不同的 padding

#### Scenario: 头部品牌展示
- **WHEN** 展示应用品牌
- **THEN** 使用 `ListTile` 或 `Row` 布局，应用名称使用 `headlineSmall` 样式
- **AND** Logo 和文字使用正确的间距（12dp）

#### Scenario: 主要登录按钮
- **WHEN** 展示办事大厅统一登录按钮
- **WHEN** 按钮高度使用 56dp（MD3 FAB 高度）
- **AND** 使用 `FilledButton.tonal` 或 `FilledButton` 样式

#### Scenario: 教务系统登录区域
- **WHEN** 展开教务系统登录区域
- **THEN** 使用 `ExpansionTile` 组件
- **AND** 警告提示使用 `Card` 组件，颜色使用 `errorContainer`

#### Scenario: 表单字段
- **WHEN** 展示账号密码输入框
- **THEN** 使用 `TextField` 组件，启用 MD3 样式
- **AND** 输入框高度使用 56dp，前缀图标使用 MD3 规范

#### Scenario: 验证码区域
- **WHEN** 需要输入验证码
- **THEN** 验证码图片使用 `Card` 组件包裹
- **AND** 验证码输入框与图片水平对齐

### Requirement: 错误提示优化
系统 SHALL 优化登录错误的视觉反馈。

#### Scenario: 登录失败提示
- **WHEN** 登录失败
- **THEN** 使用 `Card` 组件展示错误信息，颜色使用 `errorContainer`
- **AND** 错误图标使用 `Icons.error_outline`，文字使用 `error` 颜色

#### Scenario: 加载状态
- **WHEN** 登录中
- **THEN** 按钮显示 `FilledButton` 的 loading 状态
- **AND** 使用 `CircularProgressIndicator` 指示器

## MODIFIED Requirements

### Requirement: LoginPage
原 LoginPage 布局可以优化。修改后：
- 使用 `Card` 组件替代 `AnimatedContainer`
- 表单字段使用 MD3 规范的 InputDecoration
- 按钮样式使用 MD3 规范的高度和间距

### Requirement: CaptchaImage
原 CaptchaImage 使用简单 Container。修改后：
- 使用 `Card` 组件包裹验证码图片
- 添加点击刷新功能

### Requirement: 警告提示卡片
原警告提示使用简单 Container。修改后：
- 使用 `Card` 组件，背景使用 `errorContainer`
- 图标使用 MD3 规范的 `Icons.warning_amber_rounded`
