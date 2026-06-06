# 课表导出为 ICS 功能 Spec

## Why
用户希望将课表一键导入手机/电脑日历应用（Apple Calendar、Google Calendar、Outlook 等），当前只能手动逐条添加，效率极低。导出为标准 ICS 文件是最通用的日历导入方式。

## What Changes
- 在 Flutter 前端新增 ICS 文件生成逻辑，将 `ScheduleCourse` 列表转换为符合 RFC 5545 的 ICS 日历文件
- 在课表工具弹窗中新增「导出日历」按钮，点击后生成 ICS 文件并触发系统分享/下载
- 后端无需改动——前端已持有完整的课表数据、上课时间段和学期起始周信息，纯前端即可完成

## Impact
- Affected code:
  - `apps/mobile_web/lib/main.dart` — 课表工具弹窗增加导出按钮
  - `apps/mobile_web/lib/api_client.dart` — 新增 ICS 生成工具函数
- 后端 `services/api/` 无变更

## ADDED Requirements

### Requirement: ICS 文件生成
系统 SHALL 提供将课表数据转换为 ICS 格式文件的能力。

#### Scenario: 正常导出
- **WHEN** 用户在课表页面点击「导出日历」按钮
- **THEN** 系统根据当前学期的课表数据、`scheduleTimes` 时间段配置和 `firstWeekStart` 学期起始日期，生成符合 RFC 5545 的 ICS 文件
- **AND** 每个 `ScheduleCourse` 在其 `weeks` 字段指定的每一周生成一个 VEVENT
- **AND** VEVENT 包含：SUMMARY（课程名）、LOCATION（教室）、DESCRIPTION（教师）、DTSTART/DTEND（根据 weekday + section + week 计算的实际日期时间）、UID（基于课程名+周次+星期生成的唯一标识）、RRULE 不使用（因单双周需展开为独立事件）

#### Scenario: 周次解析
- **WHEN** 课程的 `weeks` 字段包含 "1-16"、"1-8,10-16"、"1-16单"、"1-16双" 等格式
- **THEN** 系统正确解析所有周次，为每周生成独立事件
- **AND** "单" 表示仅奇数周，"双" 表示仅偶数周

#### Scenario: 时间计算
- **WHEN** 课程的 `weekday=1`、`startSection=1`、`endSection=2`、周次为第 3 周
- **AND** `firstWeekStart` 为 2026-02-23（周一）
- **THEN** 事件日期为 2026-03-09（第 3 周周一），开始时间 09:00、结束时间 10:20（对应 scheduleTimes 的第 1-2 节）

#### Scenario: 空课表
- **WHEN** 当前学期无课表数据
- **THEN** 导出按钮置灰不可点击，或点击后提示「当前学期暂无课表」

### Requirement: ICS 文件分享/下载
系统 SHALL 支持将生成的 ICS 文件通过系统分享或下载方式提供给用户。

#### Scenario: 移动端分享
- **WHEN** 用户在移动端点击「导出日历」
- **THEN** 系统生成 ICS 文件并调起系统分享面板，用户可选择日历应用直接导入

#### Scenario: Web 端下载
- **WHEN** 用户在 Web 端点击「导出日历」
- **THEN** 系统生成 ICS 文件并触发浏览器下载，文件名格式为 `课表_{学年}_{学期}.ics`

### Requirement: 导出按钮 UI
系统 SHALL 在课表工具弹窗中提供「导出日历」按钮。

#### Scenario: 按钮位置
- **WHEN** 用户打开课表工具弹窗
- **THEN** 在现有按钮（「仅本周/全部课程」、「JSON」）旁边显示「导出日历」按钮，使用日历导出图标

#### Scenario: 导出中状态
- **WHEN** ICS 文件正在生成
- **THEN** 按钮显示加载状态，防止重复点击
