"""认证与请求事件的脱敏 JSON 日志；只序列化指定诊断字段。"""
import json
import logging
from datetime import datetime, timezone

_EVENTS = frozenset({
    'request_completed', 'cas_phase_completed', 'cas_login_completed',
    'cas_finalize_completed', 'cas_login_failed', 'device_restore_completed',
    'jwxt_session_unavailable', 'ehall_session_unavailable',
})
_FIELDS = (
    'trace_id', 'method', 'path', 'status_code', 'duration_ms', 'phase',
    'duration_seconds', 'elapsed_seconds', 'error_code', 'error_type',
    'ehall_available', 'login_method',
)


class AuthEventFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        return record.msg in _EVENTS


class AuthEventFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        values = {
            key: value for key in _FIELDS
            if (value := getattr(record, key, None)) is not None
        }
        return json.dumps({
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'event': record.msg, **values,
        }, ensure_ascii=False)


def configure_auth_observability() -> None:
    for name in ('app.request', 'app.cas_auto_login', 'app.routes.device_auth'):
        logger = logging.getLogger(name)
        if any(isinstance(handler.formatter, AuthEventFormatter) for handler in logger.handlers):
            continue
        handler = logging.StreamHandler()
        handler.setFormatter(AuthEventFormatter())
        handler.addFilter(AuthEventFilter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
