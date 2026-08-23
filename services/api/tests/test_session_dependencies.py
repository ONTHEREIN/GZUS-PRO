from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.routes.deps import SESSION_IDLE_STALE_THRESHOLD, require_session
from app.sessions import AppSession


def test_require_session_rejects_idle_session() -> None:
    session = AppSession(
        id="session-id",
        client=object(),
        last_active_at=datetime.now(timezone.utc).replace(tzinfo=None)
        - SESSION_IDLE_STALE_THRESHOLD
        - timedelta(seconds=1),
    )
    store = SimpleNamespace(
        get=lambda *_args, **_kwargs: session,
        touch=lambda _session_id: None,
    )
    request = SimpleNamespace(
        app=SimpleNamespace(state=SimpleNamespace(sessions=store)),
        method="GET",
        url=SimpleNamespace(path="/grades"),
    )

    with pytest.raises(HTTPException) as exc_info:
        require_session(request, x_session_id=session.id)

    assert exc_info.value.status_code == 401


def test_require_session_touches_active_session() -> None:
    session = AppSession(id="session-id", client=object())
    touched: list[str] = []
    store = SimpleNamespace(
        get=lambda *_args, **_kwargs: session,
        touch=lambda session_id: touched.append(session_id),
    )
    request = SimpleNamespace(
        app=SimpleNamespace(state=SimpleNamespace(sessions=store)),
        method="GET",
        url=SimpleNamespace(path="/grades"),
    )

    assert require_session(request, x_session_id=session.id) is session
    assert touched == [session.id]
