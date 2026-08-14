from pathlib import Path


def _worker_source() -> str:
    repo_root = Path(__file__).resolve().parents[3]
    return (repo_root / "apps/mobile_web/web/_worker.js").read_text(encoding="utf-8")


def test_worker_credits_returns_before_flutter_timeout():
    worker = _worker_source()

    assert "func_widget_guid=555A63AA3F6BB8E4E065CAE6002842BA" in worker
    assert "func_widget_guid=37234863CD24BB76E063860810AC3761" not in worker
    # 学分接口专用更短超时（fetchDashboardAcademic 按 module 区分）
    assert "CREDITS_DIRECT_TIMEOUT_MS = 4500" in worker
    assert "module === 'credits'\n        ? CREDITS_DIRECT_TIMEOUT_MS" in worker
    assert "学分服务响应较慢，请稍后下拉刷新" in worker


def test_worker_credits_single_object_is_normalized_as_list():
    worker = _worker_source()

    assert "const creditData = unwrapCreditObject(data);" in worker
    assert "normalizeResultList([creditData], module);" in worker
