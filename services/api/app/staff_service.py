from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.database import StaffMember, get_sync_session_factory, init_db


@dataclass(frozen=True)
class StaffCandidate:
    userid: str
    cn_name: str
    folder_name: str | None = None

    def to_dict(self) -> dict:
        return {
            "userid": self.userid,
            "cnName": self.cn_name,
            "folderName": self.folder_name,
        }


@dataclass(frozen=True)
class TeacherResolution:
    teacher: str
    status: str
    match: StaffCandidate | None = None
    candidates: list[StaffCandidate] | None = None


def sync_staff_from_ehall_cookie(cookie_header: str) -> int:
    settings = get_settings()
    if not settings.ehall_staff_sync_url:
        return 0
    with httpx.Client(timeout=settings.request_timeout_seconds, follow_redirects=True) as client:
        response = client.get(settings.ehall_staff_sync_url, headers={"Cookie": cookie_header})
    response.raise_for_status()
    return import_staff_records(_extract_records(response.json()))


def ensure_staff_loaded(cookie_header: str | None = None) -> int:
    init_db()
    imported = 0
    if cookie_header:
        try:
            imported = sync_staff_from_ehall_cookie(cookie_header)
        except Exception:
            imported = 0
    if imported:
        return imported

    factory = get_sync_session_factory()
    with factory() as session:
        existing = session.scalar(select(func.count()).select_from(StaffMember)) or 0
    if existing >= 100:
        return 0
    return import_staff_from_json_fallback()


def import_staff_from_json_fallback() -> int:
    path = _staff_json_path()
    if path is None:
        return 0
    with path.open("r", encoding="utf-8") as file:
        payload = json.load(file)
    return import_staff_records(_extract_records(payload))


def import_staff_records(records: list[dict]) -> int:
    init_db()
    factory = get_sync_session_factory()
    with factory() as session:
        return import_staff_records_to_session(session, records)


def import_staff_records_to_session(session: Session, records: list[dict]) -> int:
    count = 0
    for record in records:
        if record.get("JobTitle") != "教职工":
            continue
        userid = _text(record.get("Userid"))
        cn_name = _text(record.get("CnName"))
        if not userid or not cn_name:
            continue
        member = session.get(StaffMember, userid) or StaffMember(userid=userid)
        member.cn_name = cn_name
        member.job_title = _text(record.get("JobTitle"))
        member.folder_name = _text(record.get("FolderName"))
        member.wf_or_unid = _text(record.get("WF_OrUnid"))
        member.wf_last_modified = _text(record.get("WF_LastModified"))
        member.sort_number = _to_int(record.get("SortNumber"))
        session.add(member)
        count += 1
    session.commit()
    return count


def resolve_teacher(name: str, department: str | None = None) -> TeacherResolution:
    init_db()
    factory = get_sync_session_factory()
    with factory() as session:
        return resolve_teacher_in_session(session, name, department=department)


def resolve_teacher_in_session(
    session: Session,
    name: str,
    *,
    department: str | None = None,
) -> TeacherResolution:
    teacher = name.strip()
    if not teacher:
        return TeacherResolution(teacher=name, status="unmatched", candidates=[])

    exact = _query_staff(session, teacher, exact=True, department=department)
    if len(exact) == 1:
        return TeacherResolution(teacher=teacher, status="matched", match=exact[0])
    if len(exact) > 1:
        return TeacherResolution(teacher=teacher, status="multiple", candidates=exact)

    fuzzy = _query_staff(session, teacher, exact=False, department=department)
    if len(fuzzy) == 1:
        return TeacherResolution(teacher=teacher, status="matched", match=fuzzy[0])
    if len(fuzzy) > 1:
        return TeacherResolution(teacher=teacher, status="multiple", candidates=fuzzy)
    return TeacherResolution(teacher=teacher, status="unmatched", candidates=[])


def _query_staff(
    session: Session,
    teacher: str,
    *,
    exact: bool,
    department: str | None,
) -> list[StaffCandidate]:
    query = select(StaffMember)
    if exact:
        query = query.where(StaffMember.cn_name == teacher)
    else:
        query = query.where(StaffMember.cn_name.contains(teacher) | (StaffMember.cn_name == teacher))
    if department:
        query = query.where(StaffMember.folder_name.contains(department))
    query = query.order_by(StaffMember.sort_number, StaffMember.cn_name).limit(20)
    return [
        StaffCandidate(
            userid=str(member.userid),
            cn_name=str(member.cn_name),
            folder_name=member.folder_name,
        )
        for member in session.execute(query).scalars().all()
        if member.userid and member.cn_name
    ]


def _extract_records(payload: Any) -> list[dict]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []
    for key in ("records", "list", "items", "rows", "data", "result"):
        value = payload.get(key)
        records = _extract_records(value)
        if records:
            return records
    return []


def _staff_json_path() -> Path | None:
    settings = get_settings()
    candidates = []
    if settings.ehall_staff_json_path:
        candidates.append(Path(settings.ehall_staff_json_path))
    cwd = Path.cwd()
    candidates.extend(
        [
            cwd / "all_users.json",
            cwd.parent / "all_users.json",
            Path(__file__).resolve().parents[2] / "all_users.json",
        ]
    )
    for path in candidates:
        if path.is_file():
            return path
    return None


def _text(value: Any) -> str | None:
    if value in (None, ""):
        return None
    text = str(value).strip()
    return text or None


def _to_int(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None
