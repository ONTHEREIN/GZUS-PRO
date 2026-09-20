/**
 * 开发者工具自动化用的接口夹具。
 *
 * 页面回归全部走 mock 请求，因此：
 *   - 不依赖测试环境在线，也不会把测试流量打到任何真实服务；
 *   - 不需要演示账号密码，日志里也就不会出现任何真实凭据。
 *
 * 真实接口链路由后端集成测试覆盖，真机验收再打真实测试域名，三者互补。
 *
 * ⚠️ mockWxMethod 的函数形式是通过「返回值」生效的：函数实参在跨进程传递时会被
 * 序列化，`options.success` / `options.fail` 这类回调会被丢弃。所以这里只
 * **返回** `{ statusCode, data }`，绝不调用 `options.success(...)`。
 */

/**
 * mock 的 wx.request：按「方法 + 路径」命中夹具。
 *
 * 注意请求地址形如 `https://test-api.onegzus.onrein.top/api/me`：
 * 接口基址本身以 `/api` 结尾（nginx 会剥掉该前缀），所以这里既要抹掉协议与主机，
 * 也要抹掉 `/api`，夹具键才能写成后端真实路由（如 `GET /me`）。
 *
 * `responses` 由 mockWxMethod 的额外实参传入（已实测可用）；未覆盖的接口返回 404，
 * 以便用例失败时能立刻看出是夹具缺项而不是页面逻辑问题。
 */
function requestMock(options, responses) {
  var url = String((options && options.url) || "")
  // 抹掉协议+主机、`/api` 前缀与查询串：夹具键写成后端真实路由即可，
  // 否则 `/ecard/rooms?q=A1&limit=50` 这类带参请求会对不上键。
  var path = url
    .replace(/^https?:\/\/[^/]+/, "")
    .replace(/^\/api(?=\/|$)/, "")
    .split("?")[0]
  var key = String((options && options.method) || "GET").toUpperCase() + " " + path
  var entry = responses[key]
  if (!entry) {
    return { statusCode: 404, data: { detail: "自动化未覆盖接口 " + key } }
  }
  return { statusCode: entry.statusCode || 200, data: entry.data }
}

/** 模拟服务端 5xx：用于验证页面错误态。 */
function serverErrorMock(options) {
  var url = String((options && options.url) || "")
  return { statusCode: 503, data: { detail: "服务暂时不可用：" + url } }
}

const LOGIN_OK = {
  status: "ok",
  sessionId: "automation-session-id",
  studentName: "演示同学",
  studentId: "DEMO-2026-001"
}

/**
 * 接口路径必须与后端根路由一致：教务路由没有 `/academic` 前缀。
 * 参见 services/api/app/routes/academic.py 的 `APIRouter(tags=["academic"])`。
 */
const BASE_RESPONSES = {
  "POST /mini/auth/login": { statusCode: 200, data: LOGIN_OK },
  "POST /mini/auth/wechat-binding": { statusCode: 200, data: { status: "ok" } },
  "POST /mini/auth/wechat-login": { statusCode: 200, data: LOGIN_OK },
  "GET /mini/auth/wechat-binding": { statusCode: 200, data: { isBound: false } },
  "DELETE /mini/auth/wechat-binding": { statusCode: 200, data: { status: "ok" } },
  "GET /settings/academic-period": { statusCode: 200, data: { year: 2026, term: 1 } },
  "PUT /settings/academic-period": { statusCode: 200, data: { year: 2026, term: 1 } },
  "GET /settings/schedule": { statusCode: 200, data: { firstWeeks: { "2026-1": "2026-09-01" } } },
  "PUT /settings/schedule": { statusCode: 200, data: { firstWeeks: { "2026-1": "2026-09-01" } } },
  "GET /me": {
    statusCode: 200,
    data: {
      studentId: "DEMO-2026-001",
      name: "演示同学",
      college: "软件工程系",
      major: "软件工程",
      className: "软工2401",
      grade: "2024",
      phone: null,
      email: "demo@example.com"
    }
  },
  "GET /schedule": {
    statusCode: 200,
    data: [
      {
        name: "高等数学",
        teacher: "张老师",
        classroom: "A101",
        weekday: 1,
        startSection: 1,
        endSection: 2,
        weeks: "1-16"
      },
      {
        name: "大学英语",
        teacher: "李老师",
        classroom: "B203",
        weekday: 2,
        startSection: 3,
        endSection: 4,
        weeks: "1-16"
      },
      {
        name: "数据结构",
        teacher: "王老师",
        classroom: "C305",
        weekday: 3,
        startSection: 5,
        endSection: 6,
        weeks: "1-18"
      }
    ]
  },
  "GET /grades": {
    statusCode: 200,
    data: [
      {
        courseName: "高等数学",
        score: "92",
        credit: "4",
        gradePoint: "4.0",
        term: "2024-2025-1",
        gradePassed: true
      },
      {
        courseName: "大学英语",
        score: "88",
        credit: "3",
        gradePoint: "3.7",
        term: "2024-2025-1",
        gradePassed: true
      }
    ]
  },
  "GET /exams": {
    statusCode: 200,
    data: [
      {
        courseName: "高等数学",
        date: "2026-01-12",
        time: "09:00-11:00",
        location: "A101",
        seat: "12"
      },
      {
        courseName: "数据结构",
        date: "2026-01-15",
        time: "14:00-16:00",
        location: "C305",
        seat: null
      }
    ]
  },
  "GET /attendance": {
    statusCode: 200,
    data: {
      status: "ok",
      items: [
        {
          courseId: "course-1",
          courseName: "高等数学",
          courseCode: "MATH-101",
          normal: 10,
          late: 1,
          leaveEarly: 0,
          absent: 0,
          leave: 1,
          total: 12,
          records: [{ date: "2026-03-01", status: "late", statusLabel: "迟到", count: 1 }]
        },
        {
          courseId: "course-2",
          courseName: "大学英语",
          courseCode: "ENGLISH-101",
          normal: 8,
          late: 0,
          leaveEarly: 0,
          absent: 0,
          leave: 0,
          total: 8,
          records: []
        }
      ]
    }
  },
  "GET /notices": {
    statusCode: 200,
    data: [
      {
        category: "教务",
        title: "关于开展期末选课的通知",
        date: "2026-01-05",
        summary: "请在 1 月 10 日前完成选课确认。",
        source: "jwxt"
      },
      {
        category: "学工",
        title: "寒假宿舍安全检查安排",
        date: "2026-01-03",
        summary: null,
        source: "ehall"
      }
    ]
  },
  "GET /ecard/summary": {
    statusCode: 200,
    data: {
      status: "ok",
      roomDisplay: "学生公寓 3 栋 402",
      powerText: "68.4 度",
      coldWaterText: "12.5 元",
      hotWaterText: "30.2 元",
      stale: false
    }
  },
  "GET /ecard/consumption": {
    statusCode: 200,
    data: {
      status: "ok",
      cachedAt: "2026-09-19T08:00:00+08:00",
      items: [
        { title: "宿舍电费", amount: "-12.40", date: "2026-09-18", time: "08:12", usage: 4.2, unit: "度" }
      ]
    }
  },
  "GET /ecard/consumption/overview": {
    statusCode: 200,
    data: {
      status: "ok",
      months: [{ month: "2026-09", recordedDays: 1, totalUsage: 4.2, averageDailyUsage: 4.2, peakDate: "2026-09-18", peakUsage: 4.2, unit: "度", cachedAt: "2026-09-19T08:00:00+08:00" }],
      coldWaterMonths: [],
      hotWaterMonths: []
    }
  },
  "GET /ecard/rooms": {
    statusCode: 200,
    data: [
      {
        id: "1|演示校区|A1|101",
        schoolArea: "演示校区",
        building: "A1",
        room: "101",
        displayName: "演示宿舍 A1-101"
      },
      {
        id: "1|演示校区|A1|102",
        schoolArea: "演示校区",
        building: "A1",
        room: "102",
        displayName: "演示宿舍 A1-102"
      }
    ]
  },
  "POST /ecard/binding": {
    statusCode: 200,
    data: {
      status: "ok",
      roomId: "1|演示校区|A1|101",
      roomDisplay: "演示宿舍 A1-101",
      powerText: "88.8 度",
      coldWaterText: "8.8 吨",
      hotWaterText: "18.80元",
      stale: false
    }
  },
  "POST /auth/logout": { statusCode: 200, data: { status: "ok" } }
}

/** 未绑定宿舍的摘要，用于绑定流程用例的初始状态。 */
const ECARD_NOT_BOUND = {
  status: "not_bound",
  roomDisplay: null,
  powerText: null,
  coldWaterText: null,
  hotWaterText: null,
  stale: false
}

/** 基于基础夹具生成一套场景，overrides 按「方法 + 路径」整体替换。 */
function buildScenario(overrides) {
  return Object.assign({}, BASE_RESPONSES, overrides || {})
}

module.exports = {
  BASE_RESPONSES,
  ECARD_NOT_BOUND,
  LOGIN_OK,
  buildScenario,
  requestMock,
  serverErrorMock
}
