from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.database import Base, StaffMember
from app.staff_service import import_staff_records_to_session, resolve_teacher_in_session


def _session():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)()


def test_import_staff_records_filters_non_staff():
    session = _session()

    count = import_staff_records_to_session(
        session,
        [
            {"JobTitle": "教职工", "Userid": "u1", "CnName": "张老师"},
            {"JobTitle": "学生", "Userid": "u2", "CnName": "同学"},
        ],
    )

    assert count == 1
    assert session.get(StaffMember, "u1") is not None
    assert session.get(StaffMember, "u2") is None


def test_resolve_teacher_exact_match():
    session = _session()
    import_staff_records_to_session(
        session,
        [{"JobTitle": "教职工", "Userid": "u1", "CnName": "张老师"}],
    )

    result = resolve_teacher_in_session(session, "张老师")

    assert result.status == "matched"
    assert result.match is not None
    assert result.match.userid == "u1"


def test_resolve_teacher_multiple_candidates_needs_manual():
    session = _session()
    import_staff_records_to_session(
        session,
        [
            {"JobTitle": "教职工", "Userid": "u1", "CnName": "张老师"},
            {"JobTitle": "教职工", "Userid": "u2", "CnName": "张教授"},
        ],
    )

    result = resolve_teacher_in_session(session, "张")

    assert result.status == "multiple"
    assert result.match is None
    assert len(result.candidates or []) == 2


def test_resolve_teacher_unmatched():
    session = _session()
    import_staff_records_to_session(
        session,
        [{"JobTitle": "教职工", "Userid": "u1", "CnName": "张老师"}],
    )

    result = resolve_teacher_in_session(session, "李老师")

    assert result.status == "unmatched"
    assert result.match is None
    assert result.candidates == []
