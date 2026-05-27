from json import JSONDecodeError

import requests

from app.school_client import (
    AuthenticationError,
    SchoolSdkClient,
    default_academic_period,
    ensure_grade_list,
    extract_notice_sections,
    normalize_attendance_item,
    normalize_credit_item,
    normalize_exam_item,
    normalize_grade_item,
    normalize_schedule_course,
    normalize_student_info,
    prefixed_url_endpoints,
)


class ProxyOnlyUser:
    def __init__(self):
        self.calls = []

    def proxy_request(self, method, url_or_endpoint, **kwargs):
        self.calls.append((method, url_or_endpoint, kwargs))
        if "index_initMenu" in url_or_endpoint:
            return FakeTextResponse(
                """
                <div id="newsnotice">
                  <h5 class="index_title"><span>通知公告</span><p class="title-more"
                    onclick="location.href='/jwglxt/xtgl/xwgg_cxXwgg.html'">更多</p></h5>
                  <ul><li><a href="/jwglxt/notice/1.html">首页通知</a><span>2026-05-20</span></li></ul>
                </div>
                <div id="messageList">
                  <h5 class="index_title"><span>我的消息</span></h5>
                  <ul><li><a href="/jwglxt/message/1.html">选课提醒</a><span>2026-05-21</span></li></ul>
                </div>
                """
            )
        if "xwgg_cxXwgg" in url_or_endpoint:
            return FakeTextResponse(
                """
                <table>
                  <tr><td><a href="/jwglxt/notice/2.html">全部通知一</a></td><td>2026-05-22</td></tr>
                  <tr><td><a href="/jwglxt/notice/3.html">全部通知二</a></td><td>2026-05-23</td></tr>
                </table>
                """
            )
        if "funcData" in url_or_endpoint:
            return FakeResponse(
                {"items": [{"xh": "20240001", "zdxf": "120", "sxxf_01": 40, "yqxf_01": 100}]}
            )
        if "jxdmqkcx" in url_or_endpoint:
            return FakeResponse({"items": [{"kcmc": "高等数学", "cs_01": 8, "totalresult": 8}]})
        if "kbcx" in url_or_endpoint:
            return FakeResponse({"kbList": [{"kcmc": "高等数学", "jcs": "1-2", "xqj": 1}]})
        return FakeResponse({"items": [{"kcmc": "高等数学", "zwh": "10"}]})


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def json(self):
        return self.data


class FakeTextResponse:
    def __init__(self, text):
        self.text = text


class CookieUser:
    def __init__(self):
        self._http = requests.Session()

    def get_info(self):
        return {"xm": "测试学生"}


class CookieSchoolClient:
    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.initial_cookie = None
        self.user = CookieUser()

    def user_login_with_cookies(self, cookies, account):
        self.initial_cookie = cookies
        key, value = cookies.split("=", 1)
        self.user._http.cookies.set(key, value)
        return self.user


class InvalidJsonResponse:
    def json(self):
        raise JSONDecodeError("Expecting value", "Internal Server Error", 0)


def test_normalize_student_info_from_school_fields():
    assert normalize_student_info(
        {"student_number": "20240001", "name": "测试学生", "department_name": "软件学院"}
    ) == {
        "studentId": "20240001",
        "name": "测试学生",
        "college": "软件学院",
        "major": None,
        "className": None,
        "grade": None,
    }


def test_normalize_schedule_course_from_school_fields():
    result = normalize_schedule_course({"kcmc": "线性代数", "xqj": 2, "ksjc": 3, "jsjc": 4})
    assert result["name"] == "线性代数"
    assert result["weekday"] == 2
    assert result["startSection"] == 3


def test_normalize_exam_and_grade():
    assert normalize_exam_item({"kcmc": "英语", "zwh": "12"})["seat"] == "12"
    assert normalize_grade_item({"kcmc": "英语", "cj": "88", "jd": "3.8"})["gradePoint"] == "3.8"
    sdk_grade = normalize_grade_item(
        {"course_name": "高等数学", "exam_score": "51", "credit": "4.0", "grade_point": "0.00"}
    )
    assert sdk_grade["courseName"] == "高等数学"
    assert sdk_grade["score"] == "51"


def test_grade_mapping_dict_is_flattened_without_empty_placeholder():
    assert ensure_grade_list({}) == []
    assert ensure_grade_list({"高等数学": {"course_name": "高等数学"}}) == [
        {"course_name": "高等数学"}
    ]


def test_normalize_attendance_and_credit():
    attendance = normalize_attendance_item({"kcmc": "高数", "cs_01": 10, "cs_04": 1})
    credit = normalize_credit_item({"xh": "20240001", "zdxf": "120", "sxxf_01": 40})
    assert attendance["normal"] == 10
    assert attendance["absent"] == 1
    assert credit["studentId"] == "20240001"
    assert credit["requiredEarned"] == 40


def test_extract_notice_sections_reads_notice_and_message_blocks():
    sections = extract_notice_sections(
        """
        <div id="newsnotice">
          <h5 class="index_title"><span>通知公告</span><p class="title-more">更多</p></h5>
          <ul><li><a href="/n/1.html">通知标题</a><span>2026-05-20</span></li></ul>
        </div>
        <div id="messagePanel">
          <h5 class="index_title">我的消息</h5>
          <ul><li><a href="/m/1.html">消息标题</a><span>2026-05-21</span></li></ul>
        </div>
        """,
        "https://jwxt.seig.edu.cn/jwglxt/xtgl/index_initMenu.html",
    )

    assert [section["category"] for section in sections] == ["通知公告", "我的消息"]
    assert sections[0]["items"][0]["title"] == "通知标题"
    assert sections[1]["items"][0]["date"] == "2026-05-21"


def test_notice_extraction_ignores_menu_hash_links():
    sections = extract_notice_sections(
        """
        <div id="newsnotice">
          <h5 class="index_title">通知</h5>
          <a href="#">学生</a>
          <a href="javascript:void(0)">退出</a>
          <ul><li><a href="/notice/1.html">真实通知</a><span>2026-05-20</span></li></ul>
        </div>
        """,
        "https://jwxt.seig.edu.cn/jwglxt/xtgl/index_initMenu.html",
    )

    assert [item["title"] for item in sections[0]["items"]] == ["真实通知"]


def test_explicit_academic_period_is_converted_to_ints():
    assert default_academic_period("2025", "1") == (2025, 1)


def test_url_endpoints_are_prefixed_with_jwglxt():
    endpoints = prefixed_url_endpoints("/jwglxt")
    assert endpoints["LOGIN"]["INDEX"] == "/jwglxt/xtgl/login_slogin.html"
    assert endpoints["SCHEDULE"]["API"] == "/jwglxt/kbcx/xskbcx_cxXsKb.html"


def test_missing_exam_sdk_method_uses_proxy_request_slot():
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    user = ProxyOnlyUser()
    client._client = user

    items = client.get_exams("2025", "1")

    assert user.calls[0][1] == "/jwglxt/kwgl/kscx_cxXsksxxIndex.html"
    assert items[0]["courseName"] == "高等数学"


def test_attendance_and_credits_use_proxy_request():
    user = ProxyOnlyUser()
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = user
    client._account = "20240001"

    attendance = client.get_attendance("2025", "1")
    credits = client.get_credits()

    assert attendance[0]["normal"] == 8
    assert credits[0]["totalCredit"] == "120"
    assert len(user.calls) == 2


def test_notices_use_index_and_more_page_proxy_request():
    user = ProxyOnlyUser()
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = user

    notices = client.get_notices()

    assert [item["title"] for item in notices] == ["全部通知一", "全部通知二", "选课提醒"]
    assert notices[0]["category"] == "通知公告"
    assert user.calls[0][1] == "/jwglxt/xtgl/index_initMenu.html"
    assert user.calls[1][1] == "/jwglxt/xtgl/xwgg_cxXwgg.html"


def test_schedule_uses_proxy_kblist_and_xqm_code():
    user = ProxyOnlyUser()
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = user

    schedule = client.get_schedule("2025", "2")

    assert schedule[0]["name"] == "高等数学"
    assert schedule[0]["startSection"] == 1
    assert schedule[0]["endSection"] == 2
    assert user.calls[0][2]["data"]["xqm"] == "12"


def test_cookie_login_prefers_jsessionid_cookie():
    cookie = SchoolSdkClient._select_sdk_cookie("route=one; JSESSIONID=abc123; other=two")

    assert cookie == "JSESSIONID=abc123"


def test_cookie_login_applies_all_cookies_to_user_session(monkeypatch):
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    monkeypatch.setattr(client, "_load_school_client", lambda: CookieSchoolClient)

    name = client.login_with_cookies("route=one; JSESSIONID=abc123; token=two", "20240001")

    assert name == "测试学生"
    assert client._client._http.cookies.get("route", domain="jwxt.seig.edu.cn", path="/") == "one"
    assert (
        client._client._http.cookies.get("token", domain="jwxt.seig.edu.cn", path="/jwglxt")
        == "two"
    )


def test_proxy_json_decode_failure_becomes_authentication_error():
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._proxy_response = lambda *args, **kwargs: InvalidJsonResponse()

    try:
        client._proxy_json("GET", "/jwglxt/kbcx/xskbcx_cxXsKb.html")
    except AuthenticationError as exc:
        assert str(exc) == "教务系统会话已失效，请重新登录"
    else:
        raise AssertionError("expected AuthenticationError")
