from pathlib import Path


def _worker_source() -> str:
    repo_root = Path(__file__).resolve().parents[3]
    return (repo_root / "apps/mobile_web/web/_worker.js").read_text(encoding="utf-8")


def test_worker_credits_returns_before_flutter_timeout():
    worker = _worker_source()

    assert "const directTimeoutMs = path === 'credits' ? 4500 : 8000;" in worker
    assert "if (path === 'schedule' || path === 'credits')" in worker
    assert "学分服务响应较慢，请稍后下拉刷新" in worker


def test_worker_credits_single_object_is_normalized_as_list():
    worker = _worker_source()

    assert "const normalized = normalizeResultList([data], path);" in worker
    assert "return jsonResponse(normalized, 200, request);" in worker
