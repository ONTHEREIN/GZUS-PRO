from datetime import datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.routes.deps import SESSION_IDLE_STALE_THRESHOLD, require_session
from app.sessions import SessionStore


class _Client:
    def logout(self) -> None:
        pass


def _request_for(store: SessionStore):
    return SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(sessions=store)))


def test_require_session_rejects_idle_session_before_touching_it():
    store = SessionStore(ttl_seconds=7200)
    session = store.create(_Client())
    stale_at = datetime.now() - SESSION_IDLE_STALE_THRESHOLD - timedelta(seconds=1)
    session.last_active_at = stale_at

    with pytest.raises(HTTPException) as exc:
        require_session(_request_for(store), x_session_id=session.id)

    assert exc.value.status_code == 401
    assert session.last_active_at == stale_at


def test_require_session_touches_fresh_session_after_validation():
    store = SessionStore(ttl_seconds=7200)
    session = store.create(_Client())
    old_active_at = datetime.now() - timedelta(seconds=10)
    session.last_active_at = old_active_at

    result = require_session(_request_for(store), x_session_id=session.id)

    assert result is session
    assert session.last_active_at > old_active_at
