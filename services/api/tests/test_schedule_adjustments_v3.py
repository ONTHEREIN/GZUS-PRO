"""同快照多门批量调课、冲突、幂等及兼容撤销的接口验证。"""
from fastapi.testclient import TestClient
from app.main import app
from test_schedule_adjustments_v2 import setup, effective

BASE = '/settings/schedule/adjustments/v3'


def pair(item, target, first):
    return {'itemId': item['itemKey'], 'sourceDate': item['date'], 'targetDate': target,
            'sourceStart': item['startSection'], 'sourceEnd': item['endSection'],
            'targetStart': first, 'sourceKeys': [item['itemKey']], 'action': 'choose'}


def payload(pairs):
    return {'schemaVersion': 3, 'year': 2026, 'term': 1, 'firstWeekStart': '2026-09-07',
            'operation': 'course', 'pairs': pairs}


def test_multi_course_same_day_and_restore(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as c:
        rows = effective(c, headers)
        selected = [r for r in rows if r['date'] == '2026-09-07' and r['name'] in {'数学', '重叠课程'}]
        data = payload([pair(r, '2026-09-08', 1 if r['name'] == '数学' else 5) for r in selected])
        preview = c.post(BASE + '/preview', headers=headers, json=data)
        assert preview.status_code == 200, preview.text
        assert preview.json()['ready']
        body = {**data, 'clientId': 'multi', 'fingerprint': preview.json()['fingerprint']}
        saved = c.post(BASE, headers=headers, json=body)
        assert saved.status_code == 201, saved.text
        assert c.post(BASE, headers=headers, json=body).json()['clientId'] == 'multi'
        result = effective(c, headers)
        assert len([r for r in result if r['date'] == '2026-09-08']) == 2
        assert {r['groupId'] for r in result if r['date'] == '2026-09-08'} == {r['groupId'] for r in selected}
        assert c.get('/settings/schedule/adjustments/v2?year=2026&term=1', headers=headers).status_code == 409
        restore = {'year': 2026, 'term': 1, 'firstWeekStart': '2026-09-07', 'expectedRevision': 1, 'fingerprint': None}
        restored = c.post(BASE + '/multi/restore-preview', headers=headers, json=restore)
        assert restored.status_code == 200, restored.text
        restore['fingerprint'] = restored.json()['fingerprint']
        assert c.post(BASE + '/multi/restore', headers=headers, json=restore).status_code == 200
        assert effective(c, headers) == rows


def test_batch_collision_and_atomicity(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as c:
        rows = effective(c, headers)
        selected = [r for r in rows if r['date'] == '2026-09-07' and r['name'] in {'数学', '重叠课程'}]
        data = payload([pair(r, '2026-09-08', 1) for r in selected])
        result = c.post(BASE + '/preview', headers=headers, json=data)
        assert result.status_code == 200, result.text
        assert not result.json()['ready'] and result.json()['batchConflicts']
        submitted = c.post(BASE, headers=headers, json={**data, 'clientId': 'bad', 'fingerprint': result.json()['fingerprint']})
        assert submitted.status_code == 422
        assert c.get(BASE + '?year=2026&term=1', headers=headers).json() == []
        assert effective(c, headers) == rows


def save_batch(client, headers, data, client_id):
    result = client.post(BASE + '/preview', headers=headers, json=data)
    assert result.status_code == 200, result.text
    response = client.post(BASE, headers=headers, json={**data, 'clientId': client_id, 'fingerprint': result.json()['fingerprint']})
    assert response.status_code == 201, response.text
    return response.json()


def test_swap_expansion_rejects_other_selected_course(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as c:
        rows = effective(c, headers)
        math = next(r for r in rows if r['name'] == '数学' and r['week'] == 1)
        other = next(r for r in rows if r['name'] == '重叠课程')
        swapping = {**pair(math, math['date'], 8), 'sourceStart': 4, 'sourceEnd': 4, 'action': 'swap'}
        data = payload([swapping, pair(other, '2026-09-08', 1)])
        result = c.post(BASE + '/preview', headers=headers, json=data)
        assert result.status_code == 200, result.text
        assert not result.json()['ready']
        assert set(result.json()['batchConflicts'][0]['itemIds']) == {math['itemKey'], other['itemKey']}
        assert c.post(BASE, headers=headers, json={**data, 'clientId': 'expanded', 'fingerprint': result.json()['fingerprint']}).status_code == 422
        assert effective(c, headers) == rows


def test_partial_day_split_and_same_snapshot_result(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as c:
        rows = effective(c, headers)
        math = next(r for r in rows if r['name'] == '数学' and r['week'] == 1)
        english = next(r for r in rows if r['name'] == '英语')
        moving = {**pair(math, '2026-09-07', 8), 'sourceStart': 4, 'sourceEnd': 4, 'action': 'replace'}
        # 覆盖目标第8节，英语第7、9节都留下；同日期另一课程第4节未选择也留下。
        data = {**payload([moving]), 'operation': 'partialDay'}
        saved = save_batch(c, headers, data, 'partial')
        result = effective(c, headers)
        assert result == saved['metadata']['preview']['after'] + [r for r in rows if r['date'] != '2026-09-07']
        assert {(r['name'], r['startSection'], r['endSection']) for r in result if r['week'] == 1} == {
            ('数学', 3, 3), ('数学', 8, 8), ('英语', 7, 7), ('英语', 9, 9), ('重叠课程', 4, 4)}
        assert saved['metadata']['preview']['affectedCount'] == 2
        assert {r['groupId'] for r in result if r['name'] == '英语'} == {english['groupId']}


def test_multiweek_stale_commit_and_independent_undo(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as c:
        rows = effective(c, headers)
        maths = [r for r in rows if r['name'] == '数学']
        data = payload([pair(r, {'2026-09-07': '2026-09-08', '2026-09-14': '2026-09-15', '2026-09-21': '2026-09-22'}[r['date']], 3) for r in maths])
        old = c.post(BASE + '/preview', headers=headers, json=data).json()
        save_batch(c, headers, data, 'weeks')
        other = next(r for r in rows if r['name'] == '重叠课程')
        unrelated = payload([pair(other, '2026-09-09', 6)])
        assert c.post(BASE, headers=headers, json={**unrelated, 'clientId': 'stale', 'fingerprint': old['fingerprint']}).status_code == 409
        save_batch(c, headers, unrelated, 'independent')
        restore = {'year': 2026, 'term': 1, 'firstWeekStart': '2026-09-07', 'expectedRevision': 1, 'fingerprint': None}
        preview = c.post(BASE + '/weeks/restore-preview', headers=headers, json=restore)
        assert preview.status_code == 200, preview.text
        assert preview.json()['blockers'] == []
        restore['fingerprint'] = preview.json()['fingerprint']
        assert c.post(BASE + '/weeks/restore', headers=headers, json=restore).status_code == 200
        remaining = effective(c, headers)
        assert [r for r in remaining if r['name'] == '数学'] == maths
        assert next(r for r in remaining if r['name'] == '重叠课程')['date'] == '2026-09-09'


def test_v2_history_and_dependent_v3_undo(monkeypatch):
    from test_schedule_adjustments_v2 import save, request
    headers = setup(monkeypatch)
    with TestClient(app) as c:
        math = next(r for r in effective(c, headers) if r['name'] == '数学' and r['week'] == 1)
        save(c, headers, request(math['itemKey'], 'replace'), 'v2-old')
        moved = next(r for r in effective(c, headers) if r['name'] == '数学' and r['startSection'] == 8)
        save_batch(c, headers, payload([pair(moved, '2026-09-08', 1)]), 'v3-new')
        history = c.get(BASE + '?year=2026&term=1', headers=headers).json()
        assert [r['schemaVersion'] for r in history] == [2, 3]
        restore = {'year': 2026, 'term': 1, 'firstWeekStart': '2026-09-07', 'expectedRevision': 1, 'fingerprint': None}
        assert c.post(BASE + '/v2-old/restore-preview', headers=headers, json=restore).json()['blockers'] == ['v3-new']


def test_first_week_config_uses_same_monday_as_timetable(monkeypatch):
    headers = setup(monkeypatch)
    with TestClient(app) as c:
        response = c.put('/settings/schedule', headers=headers, json={'firstWeeks': {'2026-1': '2026-09-08'}})
        assert response.status_code == 200, response.text
        course = next(r for r in effective(c, headers) if r['name'] == '数学' and r['week'] == 1)
        result = c.post(BASE + '/preview', headers=headers, json=payload([pair(course, '2026-09-09', 1)]))
        assert result.status_code == 200, result.text
        assert result.json()['ready']
