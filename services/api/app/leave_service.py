from __future__ import annotations

import json
import re
from collections import OrderedDict
from datetime import date, time, timedelta
from typing import Any

from app.academic_period import default_first_week_start  # noqa: F401 向后兼容 re-export
from app.school_client import pick


SECTION_TIMES = [
    (time(9, 0), time(9, 40)),
    (time(9, 40), time(10, 20)),
    (time(10, 40), time(11, 20)),
    (time(11, 20), time(12, 0)),
    (time(12, 30), time(13, 10)),
    (time(13, 10), time(13, 50)),
    (time(14, 0), time(14, 40)),
    (time(14, 40), time(15, 20)),
    (time(15, 30), time(16, 10)),
    (time(16, 10), time(16, 50)),
    (time(17, 0), time(17, 40)),
    (time(17, 40), time(18, 20)),
    (time(19, 0), time(19, 40)),
    (time(19, 40), time(20, 20)),
    (time(20, 30), time(21, 10)),
    (time(21, 10), time(21, 50)),
]


def build_leave_preview(
    courses: list[dict],
    *,
    start_date: date,
    end_date: date,
    year: int,
    term: int,
    first_week_start: date | None = None,
) -> dict:
    if end_date < start_date:
        raise ValueError("结束日期不能早于开始日期")

    semester_start = first_week_start or default_first_week_start(year, term)
    grouped: OrderedDict[tuple[str, str, str], dict] = OrderedDict()
    current = start_date
    while current <= end_date:
        week = ((current - semester_start).days // 7) + 1
        if 1 <= week <= 30:
            weekday = current.weekday() + 1
            for course in courses:
                if not _course_occurs_on(course, week, weekday):
                    continue
                normalized = _normalize_leave_course(course)
                key = (
                    normalized["courseName"],
                    normalized.get("courseCode") or "",
                    normalized.get("teacher") or "",
                )
                entry = grouped.setdefault(
                    key,
                    {
                        **normalized,
                        "absenceCount": 0,
                        "classTimes": [],
                    },
                )
                entry["absenceCount"] += 1
                entry["classTimes"].append(_class_time_text(current, course))
        current += timedelta(days=1)

    items = list(grouped.values())
    for item in items:
        item["classTime"] = "；".join(item["classTimes"])
        item["missingFields"] = _missing_fields(item)
    return {
        "status": "ok",
        "items": items,
        "hasMissingFields": any(item["missingFields"] for item in items),
    }


def leave_days(start_date: date, end_date: date) -> int:
    return (end_date - start_date).days + 1


def build_leave_fill_script(
    *,
    start_date: date,
    end_date: date,
    reason: str,
    courses: list[dict],
) -> str:
    payload = {
        "startDate": start_date.isoformat(),
        "endDate": end_date.isoformat(),
        "leaveDays": leave_days(start_date, end_date),
        "reason": reason,
        "courses": [
            {
                "courseName": course.get("courseName") or "",
                "courseCode": course.get("courseCode") or "",
                "teachingClassCode": course.get("teachingClassCode") or "",
                "courseNature": course.get("courseNature") or "",
                "credit": course.get("credit") or "",
                "classDate": _first_class_date(course),
                "absenceCount": course.get("absenceCount") or 1,
            }
            for course in courses
        ],
    }
    data = json.dumps(payload, ensure_ascii=False)
    return f"""(() => {{
  const data = {data};
  const $ = window.jQuery;
  const fields = [
    ['KCMC', '课程名称', 'input'],
    ['KCDM', '课程代码', 'input'],
    ['JXBDM', '班级编号', 'input'],
    ['KCXZ', '课程性质', 'select'],
    ['XF', '学分', 'input'],
    ['SKSJ', '上课时间', 'date'],
    ['CS', '将缺课次数', 'input']
  ];
  function fire(el) {{
    if (!el) return;
    el.dispatchEvent(new Event('input', {{ bubbles: true }}));
    el.dispatchEvent(new Event('change', {{ bubbles: true }}));
  }}
  function setField(id, value) {{
    const el = document.getElementById(id);
    if (!el) return;
    if ($ && typeof $(el).datebox === 'function' && String(el.className).includes('datebox')) {{
      try {{ $(el).datebox('setValue', value); }} catch (_) {{}}
    }}
    el.value = value;
    fire(el);
    const show = document.getElementById(id + '_show');
    if (show) show.textContent = value;
  }}
  function esc(value) {{
    return String(value ?? '').replace(/[&<>"']/g, ch => ({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;', "'": '&#39;'}}[ch]));
  }}
  function rowHtml(course, index) {{
    const values = {{
      KCMC: course.courseName,
      KCDM: course.courseCode,
      JXBDM: course.teachingClassCode,
      KCXZ: course.courseNature,
      XF: course.credit,
      SKSJ: course.classDate,
      CS: course.absenceCount
    }};
    return '<tr>' + fields.map(([id, label, type]) => {{
      const fieldId = `${{id}}_dt_${{index}}`;
      if (type === 'select') {{
        const selected = values[id] === '选修' ? '选修' : '必修';
        return `<td style="text-align:center"><select name="${{fieldId}}" id="${{fieldId}}" required="true" missingMessage="${{label}}必须选择"><option value="">请选择</option><option value="必修" ${{selected === '必修' ? 'selected' : ''}}>必修</option><option value="选修" ${{selected === '选修' ? 'selected' : ''}}>选修</option></select></td>`;
      }}
      const cls = type === 'date' ? 'easyui-datebox' : 'easyui-validatebox';
      return `<td style="text-align:center"><input name="${{fieldId}}" id="${{fieldId}}" value="${{esc(values[id])}}" size="12" required="true" missingMessage="${{label}}必须填写" class="${{cls}}"/></td>`;
    }}).join('') + '</tr>';
  }}
  setField('KSSJ', data.startDate);
  setField('JSSJ', data.endDate);
  setField('QJTS', String(data.leaveDays));
  setField('QJLY', data.reason);
  const table = document.getElementById('dynamicTable');
  if (table) {{
    [...table.querySelectorAll('tr')].slice(2).forEach(tr => tr.remove());
    data.courses.forEach((course, index) => table.insertAdjacentHTML('beforeend', rowHtml(course, index + 1)));
    if ($ && $.parser) {{
      try {{ $.parser.parse('#dynamicTable'); }} catch (_) {{}}
    }}
    data.courses.forEach((course, index) => setField(`SKSJ_dt_${{index + 1}}`, course.classDate));
    window.dynamicTableRow = data.courses.length + 1;
  }}
  if (data.courses.length) {{
    const teacherNode = document.getElementById('WF_NextNodeSelect_T10004');
    if (teacherNode) {{
      teacherNode.checked = true;
      fire(teacherNode);
    }}
  }}
  console.log('请假单已填入。');
}})();"""


def build_leave_handler_script(matched_teachers: list[dict]) -> str:
    unique: dict[str, dict] = {}
    for teacher in matched_teachers:
        userid = str(teacher.get("userid") or "").strip()
        cn_name = str(teacher.get("cnName") or teacher.get("teacher") or "").strip()
        if userid and cn_name:
            unique[userid] = {"userid": userid, "cnName": cn_name}
    data = json.dumps(list(unique.values()), ensure_ascii=False)
    return f"""(() => {{
  const teachers = {data};
  function fire(el) {{
    if (!el) return;
    el.dispatchEvent(new Event('input', {{ bubbles: true }}));
    el.dispatchEvent(new Event('change', {{ bubbles: true }}));
  }}
  const next = document.getElementById('WF_NextNodeSelect_T10004');
  if (next) {{
    next.checked = true;
    fire(next);
  }}
  const select = document.getElementById('WF_T10004');
  if (select) {{
    select.disabled = false;
    select.innerHTML = '';
    teachers.forEach((teacher) => {{
      const option = document.createElement('option');
      option.value = teacher.userid;
      option.textContent = teacher.cnName;
      option.selected = true;
      select.appendChild(option);
    }});
    fire(select);
  }}
  document.querySelectorAll('input[name="WF_NodeOption_T10004"]').forEach((el) => el.remove());
  const host = document.getElementById('ApprovalForm') || document.forms[0] || document.body;
  teachers.forEach((teacher) => {{
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.name = 'WF_NodeOption_T10004';
    checkbox.value = teacher.userid;
    checkbox.checked = true;
    checkbox.style.display = 'none';
    host.appendChild(checkbox);
  }});
  console.log('已选择任课教师经办人。');
}})();"""


def _course_occurs_on(course: dict, week: int, weekday: int) -> bool:
    if _to_int(course.get("weekday")) != weekday:
        return False
    if _to_int(course.get("startSection")) is None:
        return False
    return week_spec_contains(str(course.get("weeks") or ""), week)


def week_spec_contains(spec: str, week: int) -> bool:
    text = (
        spec.replace("（", "(")
        .replace("）", ")")
        .replace("，", ",")
        .replace("；", ";")
        .replace("、", ",")
        .strip()
    )
    if not text:
        return True
    found_number = False
    for segment in re.split(r"[,;]", text):
        segment = segment.strip()
        if not segment:
            continue
        if re.search(r"\d+", segment):
            found_number = True
        if "单" in segment and week % 2 == 0:
            continue
        if "双" in segment and week % 2 == 1:
            continue
        ranges = list(re.finditer(r"(\d+)\s*-\s*(\d+)", segment))
        if ranges:
            if any(int(m.group(1)) <= week <= int(m.group(2)) for m in ranges):
                return True
            continue
        for match in re.finditer(r"\d+", segment):
            if int(match.group(0)) == week:
                return True
    return not found_number


def _normalize_leave_course(course: dict) -> dict:
    raw = course.get("raw") if isinstance(course.get("raw"), dict) else course
    return {
        "courseName": str(course.get("name") or pick(raw, "name", "courseName", "kcmc") or ""),
        "courseCode": _text(pick(raw, "courseCode", "course_code", "kch", "KCDM")),
        "teachingClassCode": _text(
            pick(raw, "jxbmc", "teachingClassCode", "teaching_class_code", "jxbdm", "jxb_id", "JXBDM")
        ),
        "courseNature": _text(pick(raw, "courseNature", "course_nature", "kcxz", "kclb", "KCXZ")),
        "credit": _text(pick(raw, "credit", "xf", "XF")),
        "teacher": _text(
            course.get("teacher") or pick(raw, "teacher", "jsxm", "teacherName", "xm")
        ),
    }


def _missing_fields(item: dict) -> list[str]:
    fields = {
        "courseCode": "课程代码",
        "teachingClassCode": "班级编号",
        "courseNature": "课程性质",
        "credit": "学分",
    }
    return [label for key, label in fields.items() if not item.get(key)]


def _class_time_text(day: date, course: dict) -> str:
    start = _to_int(course.get("startSection")) or 1
    end = _to_int(course.get("endSection")) or start
    time_range = ""
    if 1 <= start <= len(SECTION_TIMES) and 1 <= end <= len(SECTION_TIMES):
        time_range = f" {SECTION_TIMES[start - 1][0].strftime('%H:%M')}-{SECTION_TIMES[end - 1][1].strftime('%H:%M')}"
    return f"{day.isoformat()} 第{start}-{end}节{time_range}"


def _first_class_date(course: dict) -> str:
    for value in course.get("classTimes") or [course.get("classTime")]:
        match = re.search(r"\d{4}-\d{2}-\d{2}", str(value or ""))
        if match:
            return match.group(0)
    return ""


def _to_int(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _text(value: Any) -> str | None:
    if value in (None, ""):
        return None
    return str(value).strip() or None
