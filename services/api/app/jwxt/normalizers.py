"""JWXT 数据归一化：把教务系统返回的各种结构统一为前端约定的 dict 列表。

从 school_client.py 拆出，保持纯函数、无 HTML 解析依赖。
"""
from __future__ import annotations

import re
from datetime import datetime
from typing import Any

def ensure_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("items", "data", "rows", "courses", "scores", "exams"):
            nested = value.get(key)
            if isinstance(nested, list):
                return nested
        return [value]
    return list(value) if isinstance(value, tuple) else [value]


def ensure_grade_list(value: Any) -> list[Any]:
    if isinstance(value, dict):
        if not value:
            return []
        if any(isinstance(item, dict) for item in value.values()):
            return list(value.values())
    return ensure_list(value)


def extract_credit_items(value: Any) -> list[Any]:
    if not isinstance(value, dict):
        return ensure_list(value)
    for key in ("items", "rows", "list", "data"):
        nested = value.get(key)
        if isinstance(nested, list):
            return nested
        if isinstance(nested, dict):
            items = extract_credit_items(nested)
            if items or credit_total_count(nested) == 0:
                return items
    if credit_total_count(value) == 0:
        return []
    return [value] if value else []


def credit_total_count(value: dict) -> int | None:
    try:
        total_value = value.get("totalResult")
        if total_value is None:
            total_value = value.get("totalCount")
        return int(total_value) if total_value is not None else None
    except (TypeError, ValueError):
        return None


def as_dict(value: Any) -> dict:
    if isinstance(value, dict):
        return value
    if hasattr(value, "model_dump"):
        return value.model_dump()
    if hasattr(value, "dict"):
        return value.dict()
    return vars(value)


def pick(data: dict, *keys: str) -> Any:
    for key in keys:
        if key in data and data[key] not in (None, ""):
            return data[key]
    return None


def normalize_student_info(value: Any) -> dict:
    data = as_dict(value)
    return {
        "studentId": str(
            pick(data, "studentId", "student_id", "student_number", "xh", "account", "id", "col_xh") or ""
        ),
        "name": str(pick(data, "name", "xm", "studentName", "col_xm") or ""),
        "college": pick(data, "college", "xy", "department", "department_name", "col_jg_id"),
        "major": pick(data, "major", "zy", "zymc", "majorName", "professionName", "col_zyh_id", "col_zyfx_id"),
        "className": pick(data, "className", "class_name", "bj", "class", "bjmc", "col_bh_id"),
        "grade": pick(data, "grade", "nj", "col_njdm_id"),
        "gender": pick(data, "gender", "xb", "xbm", "col_xbm"),
        "idNumber": pick(data, "idNumber", "id_number", "zjhm", "sfzh", "col_zjhm"),
        "birthDate": pick(data, "birthDate", "birth_date", "csrq", "col_csrq"),
        "ethnicity": pick(data, "ethnicity", "mz", "mzm", "col_mzm"),
        "politicalStatus": pick(data, "politicalStatus", "political_status", "zzmm", "zzmmm", "col_zzmmm"),
        "enrollDate": pick(data, "enrollDate", "enroll_date", "rxrq", "col_rxrq"),
        "nativePlace": pick(data, "nativePlace", "native_place", "jg", "col_jg"),
        "studentStatus": pick(data, "studentStatus", "student_status", "xjzt", "xjztdm", "col_xjztdm"),
        "educationLevel": pick(data, "educationLevel", "education_level", "pycc", "pyccdm", "col_pyccdm"),
        "phone": pick(data, "phone", "sjhm", "mobile", "col_sjhm"),
        "email": pick(data, "email", "dzyx", "col_dzyx"),
        "address": pick(data, "address", "jtdz", "col_jtdz"),
    }


def normalize_schedule_course(value: Any) -> dict:
    data = as_dict(value)
    original_raw = data.get("raw") if isinstance(data.get("raw"), dict) else data
    start_section, end_section = parse_section_range(
        pick(data, "startSection", "start_section", "jc_start", "ksjc", "jcs", "jc")
    )
    _, explicit_end_section = parse_section_range(
        pick(data, "endSection", "end_section", "jc_end", "jsjc")
    )
    return {
        "name": str(pick(data, "name", "courseName", "kcmc") or ""),
        "teacher": pick(data, "teacher", "jsxm", "teacherName", "xm"),
        "classroom": pick(data, "classroom", "location", "cdmc"),
        "weekday": pick(data, "weekday", "weekDay", "xqj"),
        "startSection": start_section,
        "endSection": explicit_end_section or end_section,
        "weeks": pick(data, "weeks", "zcd", "week"),
        "kcbmc": pick(data, "kcbmc"),
        "raw": original_raw,
    }


def normalize_exam_item(value: Any) -> dict:
    data = as_dict(value)
    time_val = pick(data, "time", "kssj", "examTime")
    date_val = pick(data, "date", "examDate")
    if not date_val and time_val and isinstance(time_val, str):
        # Handle both "2026-07-10 09:30-11:00" (space) and
        # "2026-07-10(09:30-11:00)" (parenthesis) JWXT formats
        paren_idx = time_val.find("(")
        space_idx = time_val.find(" ")
        sep_idx = paren_idx if paren_idx > 0 else (space_idx if space_idx > 0 else -1)
        if sep_idx > 0:
            date_val = time_val[:sep_idx]
    weekday_val = pick(data, "weekday", "weekDay", "xqj")
    if not weekday_val and date_val and isinstance(date_val, str):
        try:
            dt = datetime.strptime(date_val, "%Y-%m-%d")
            weekday_names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            weekday_val = weekday_names[dt.weekday()]
        except ValueError:
            pass
    return {
        "courseName": str(pick(data, "courseName", "name", "kcmc") or ""),
        "date": date_val or "",
        "weekday": weekday_val or "",
        "time": time_val,
        "location": pick(data, "location", "cdmc", "examPlace"),
        "seat": pick(data, "seat", "zwh", "seatNo"),
        "type": pick(data, "type", "kslx", "ksfs", "ksmc"),
        "credit": str(pick(data, "credit", "xf") or ""),
        "campus": pick(data, "campus", "cdxqmc"),
        "remark": pick(data, "remark", "ksbz"),
    }


def normalize_grade_item(value: Any) -> dict:
    data = as_dict(value)
    return {
        "courseName": str(pick(data, "courseName", "course_name", "name", "kcmc") or ""),
        "score": str(pick(data, "score", "exam_score", "exam_result", "cj") or ""),
        "credit": str(pick(data, "credit", "xf") or ""),
        "gradePoint": str(pick(data, "gradePoint", "jd", "gpa", "grade_point") or ""),
        "term": pick(data, "term", "xq", "semester"),
    }


def normalize_attendance_item(value: Any) -> dict:
    data = as_dict(value)
    return {
        "courseId": str(pick(data, "courseId", "kch_id") or ""),
        "courseName": str(pick(data, "courseName", "kcmc", "name") or ""),
        "courseCode": pick(data, "courseCode", "kch"),
        "academicYear": pick(data, "academicYear", "xnmc", "xn"),
        "term": str(pick(data, "term", "xqmc", "xq") or ""),
        "normal": int(pick(data, "normal", "cs_01") or 0),
        "late": int(pick(data, "late", "cs_02") or 0),
        "leaveEarly": int(pick(data, "leaveEarly", "cs_03") or 0),
        "absent": int(pick(data, "absent", "cs_04") or 0),
        "leave": int(pick(data, "leave", "cs_05") or 0),
        "total": int(pick(data, "total", "totalresult") or 0),
        "records": normalize_attendance_records(data),
    }


def normalize_attendance_detail(value: Any) -> dict:
    data = as_dict(value)
    status = attendance_status_code(pick(data, "status", "dmlbmc", "dmlbm"))
    return {
        "academicYear": str(pick(data, "academicYear", "xnmc", "xn") or ""),
        "term": str(pick(data, "term", "xqmc", "xq") or ""),
        "status": status,
        "statusLabel": str(pick(data, "statusLabel", "dmlbmc") or attendance_status_label(status)),
        "offeringCollege": str(pick(data, "offeringCollege", "kkbm") or ""),
        "courseCode": str(pick(data, "courseCode", "kch") or ""),
        "courseName": str(pick(data, "courseName", "kcmc") or ""),
        "teachingClass": str(pick(data, "teachingClass", "jxbmc") or ""),
        "teacher": str(pick(data, "teacher", "jsxx") or ""),
        "rollCallTime": str(pick(data, "rollCallTime", "dmsj") or ""),
        "classDate": str(pick(data, "classDate", "skrq") or ""),
        "classTime": str(pick(data, "classTime", "jtsj") or ""),
        "sections": str(pick(data, "sections", "jcd") or ""),
        "studentId": str(pick(data, "studentId", "xh") or ""),
        "studentName": str(pick(data, "studentName", "xm") or ""),
        "gender": str(pick(data, "gender", "xb") or ""),
        "college": str(pick(data, "college", "jgmc") or ""),
        "grade": str(pick(data, "grade", "njmc") or ""),
        "major": str(pick(data, "major", "zymc") or ""),
        "className": str(pick(data, "className", "bj") or ""),
        "remark": str(pick(data, "remark", "bz") or ""),
    }


def normalize_attendance_records(data: dict) -> list[dict]:
    raw_records = pick(
        data,
        "records",
        "recordList",
        "details",
        "detailList",
        "history",
        "items",
        "mx",
        "list",
    )
    if raw_records is None:
        return []
    records = []
    for item in ensure_list(raw_records):
        record = as_dict(item)
        date = pick(record, "date", "attendanceDate", "kqrq", "rq", "day", "time", "createdAt")
        status = attendance_status_code(pick(record, "status", "type", "zt", "statusCode", "kqzt"))
        count = int(pick(record, "count", "times", "num") or 1)
        records.append(
            {
                "date": str(date or ""),
                "status": status,
                "statusLabel": attendance_status_label(status),
                "count": max(1, count),
                "time": str(pick(record, "time", "section", "jc", "classTime") or ""),
                "remark": str(pick(record, "remark", "bz", "reason") or ""),
            }
        )
    return records


def attendance_status_code(value: Any) -> str:
    text = str(value or "").strip()
    if text in {"late", "迟到", "cs_02", "2"}:
        return "late"
    if text in {"leaveEarly", "早退", "cs_03", "3"}:
        return "leaveEarly"
    if text in {"absent", "旷课", "缺勤", "cs_04", "4"}:
        return "absent"
    if text in {"leave", "请假", "cs_05", "5"}:
        return "leave"
    return "normal"


def attendance_status_label(status: str) -> str:
    return {
        "late": "迟到",
        "leaveEarly": "早退",
        "absent": "旷课",
        "leave": "请假",
    }.get(status, "正常")


def normalize_credit_item(value: Any) -> dict:
    data = as_dict(value)
    required_expected = float(pick(data, "requiredExpected", "yqxf_01") or 0)
    elective_expected = float(pick(data, "electiveExpected", "yqxf_02") or 0)
    other_expected = float(pick(data, "otherExpected", "yqxf_03") or 0)
    required_earned = float(pick(data, "requiredEarned", "sxxf_01") or 0)
    elective_earned = float(pick(data, "electiveEarned", "sxxf_02") or 0)
    other_earned = float(pick(data, "otherEarned", "sxxf_03") or 0)
    return {
        "studentId": pick(data, "studentId", "xh"),
        "name": pick(data, "name", "xm"),
        "college": pick(data, "college", "jgmc"),
        "major": pick(data, "major", "zymc"),
        "grade": str(pick(data, "grade", "nj") or ""),
        "totalCredit": str(pick(data, "totalCredit", "zdxf") or ""),
        "requiredCredit": str(pick(data, "requiredCredit", "bxxf") or ""),
        "selectedCredit": str(pick(data, "selectedCredit", "xkxf") or ""),
        "requiredExpected": required_expected,
        "electiveExpected": elective_expected,
        "otherExpected": other_expected,
        "requiredEarned": required_earned,
        "electiveEarned": elective_earned,
        "otherEarned": other_earned,
        "totalExpected": required_expected + elective_expected + other_expected,
        "totalEarned": required_earned + elective_earned + other_earned,
    }


def parse_section_range(value: Any) -> tuple[int | None, int | None]:
    if value in (None, ""):
        return None, None
    numbers = [int(match.group(0)) for match in re.finditer(r"\d+", str(value))]
    if not numbers:
        return None, None
    start = numbers[0]
    if len(numbers) == 1:
        return start, start
    return start, numbers[1]
