from json import JSONDecodeError

import requests

from app.school_client import (
    AuthenticationError,
    MissingProxySlotError,
    SchoolSdkClient,
    default_academic_period,
    ensure_grade_list,
    extract_credit_items,
    extract_notice_detail,
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
        if "index_cxNews" in url_or_endpoint:
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


class FakeBinaryResponse:
    def __init__(self, content, content_type="image/png"):
        self.content = content
        self.headers = {"content-type": content_type}


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
    result = normalize_student_info(
        {"student_number": "20240001", "name": "测试学生", "department_name": "软件学院"}
    )

    assert {
        key: result[key]
        for key in ("studentId", "name", "college", "major", "className", "grade")
    } == {
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
    assert result["endSection"] == 4


def test_normalize_exam_and_grade():
    assert normalize_exam_item({"kcmc": "英语", "zwh": "12"})["seat"] == "12"
    # date extracted from kssj
    exam_with_time = normalize_exam_item({"kcmc": "高数", "kssj": "2026-06-15 09:00-11:00"})
    assert exam_with_time["date"] == "2026-06-15"
    assert exam_with_time["weekday"] == "周一"
    assert exam_with_time["time"] == "2026-06-15 09:00-11:00"
    # explicit date takes priority
    exam_with_date = normalize_exam_item({"kcmc": "高数", "date": "2026-07-01", "kssj": "2026-07-01 14:00-16:00"})
    assert exam_with_date["date"] == "2026-07-01"
    assert exam_with_date["weekday"] == "周三"
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
    attendance = normalize_attendance_item(
        {
            "kcmc": "高数",
            "cs_01": 10,
            "cs_04": 1,
            "records": [{"kqrq": "2026-06-03", "kqzt": "旷课", "jc": "第1-2节"}],
        }
    )
    credit = normalize_credit_item({"xh": "20240001", "zdxf": "120", "sxxf_01": 40})
    assert attendance["normal"] == 10
    assert attendance["absent"] == 1
    assert attendance["records"][0]["date"] == "2026-06-03"
    assert attendance["records"][0]["status"] == "absent"
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


def test_extract_credit_items_accepts_wrapped_and_single_object():
    rows = extract_credit_items({"data": {"rows": [{"xh": "20240001", "zdxf": "120"}]}})
    single = extract_credit_items({"xh": "20240002", "zdxf": "160"})
    empty = extract_credit_items({"totalResult": 0})
    nested_empty = extract_credit_items({"data": {"totalResult": 0}})

    assert rows[0]["zdxf"] == "120"
    assert single[0]["xh"] == "20240002"
    assert empty == []
    assert nested_empty == []


def test_notices_use_index_and_more_page_proxy_request():
    user = ProxyOnlyUser()
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = user

    notices = client.get_notices()

    assert [item["title"] for item in notices] == ["全部通知一", "全部通知二", "选课提醒"]
    assert notices[0]["category"] == "通知公告"
    assert user.calls[0][1] == "/jwglxt/xtgl/index_cxNews.html"
    assert user.calls[1][1] == "/jwglxt/xtgl/xwgg_cxXwgg.html"


def test_notices_follow_more_page_even_when_index_has_multiple_items():
    class MultiIndexUser(ProxyOnlyUser):
        def proxy_request(self, method, url_or_endpoint, **kwargs):
            self.calls.append((method, url_or_endpoint, kwargs))
            if "index_cxNews" in url_or_endpoint:
                return FakeTextResponse(
                    """
                    <div id="newsnotice">
                      <h5 class="index_title"><span>通知公告</span><p class="title-more"
                        onclick="location.href='/jwglxt/xtgl/xwgg_cxXwgg.html'">更多</p></h5>
                      <ul>
                        <li><a href="/jwglxt/notice/1.html">首页通知一</a></li>
                        <li><a href="/jwglxt/notice/2.html">首页通知二</a></li>
                        <li><a href="/jwglxt/notice/3.html">首页通知三</a></li>
                      </ul>
                    </div>
                    """
                )
            if "xwgg_cxXwgg" in url_or_endpoint:
                return FakeTextResponse(
                    """
                    <table>
                      <tr><td><a href="/jwglxt/notice/4.html">完整通知一</a></td></tr>
                      <tr><td><a href="/jwglxt/notice/5.html">完整通知二</a></td></tr>
                    </table>
                    """
                )
            return FakeResponse({"items": []})

    user = MultiIndexUser()
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = user

    notices = client.get_notices()

    assert [item["title"] for item in notices] == ["完整通知一", "完整通知二"]
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


def test_get_info_fetches_photo_with_normalized_student_id(monkeypatch):
    class InfoProxyUser:
        def __init__(self):
            self.calls = []

        def get_info(self):
            return {"student_number": "NEY250101", "name": "测试学生"}

        def proxy_request(self, method, url_or_endpoint, **kwargs):
            self.calls.append((method, url_or_endpoint, kwargs))
            return FakeBinaryResponse(b"\x89PNG\r\n\x1a\navatar")

    user = InfoProxyUser()
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = user
    client._account = "phone-login-account"
    monkeypatch.setattr(
        "app.school_client._normalize_image_to_png",
        lambda content, content_type: (None, content_type),
    )

    info = client.get_info()

    assert info["studentId"] == "NEY250101"
    assert info["photoDataUrl"].startswith("data:image/png;base64,")
    photo_call = next(call for call in user.calls if "photo_cxXszp4" in call[1])
    assert photo_call[2]["params"]["xh_id"] == "NEY250101"


def test_proxy_json_decode_failure_becomes_authentication_error():
    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._proxy_response = lambda *args, **kwargs: InvalidJsonResponse()

    try:
        client._proxy_json("GET", "/jwglxt/kbcx/xskbcx_cxXsKb.html")
    except AuthenticationError as exc:
        assert str(exc) == "教务系统会话已失效，请重新登录"
    else:
        raise AssertionError("expected AuthenticationError")


def test_extract_notice_sections_panel_structure():
    sections = extract_notice_sections(
        """
        <div class="panel">
          <div class="panel-heading"><span class="panel-title">通知公告</span></div>
          <div class="panel-body">
            <ul><li><a href="/jwglxt/notice/1.html">Panel通知</a><span>2026-05-20</span></li></ul>
          </div>
        </div>
        """,
        "https://jwxt.seig.edu.cn/jwglxt/xtgl/index_initMenu.html",
    )

    assert len(sections) == 1
    assert sections[0]["category"] == "通知公告"
    assert sections[0]["items"][0]["title"] == "Panel通知"


def test_extract_notice_sections_widget_box_structure():
    sections = extract_notice_sections(
        """
        <div class="widget-box">
          <div class="widget-title"><span>新闻动态</span></div>
          <div class="widget-content">
            <a href="/jwglxt/news/1.html">Widget新闻</a><span>2026-05-21</span>
          </div>
        </div>
        """,
        "https://jwxt.seig.edu.cn/jwglxt/xtgl/index_initMenu.html",
    )

    assert len(sections) == 1
    assert sections[0]["category"] == "新闻动态"
    assert sections[0]["items"][0]["title"] == "Widget新闻"


def test_query_notices_detects_login_page():
    class LoginProxyUser:
        def proxy_request(self, method, url_or_endpoint, **kwargs):
            return FakeTextResponse(
                '<html><form action="login_slogin.html"><input name="password"/></form></html>'
            )

    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = LoginProxyUser()

    try:
        client.get_notices()
        raise AssertionError("expected AuthenticationError")
    except AuthenticationError as exc:
        assert "会话已失效" in str(exc)


def test_query_notices_raises_missing_proxy_slot():
    class NoProxyUser:
        pass

    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = NoProxyUser()

    try:
        client.get_notices()
        raise AssertionError("expected MissingProxySlotError")
    except MissingProxySlotError as exc:
        assert "不支持" in str(exc)


def test_academic_client_protocol_includes_get_notices():
    from app.sessions import AcademicClient

    method_names = [name for name in dir(AcademicClient) if not name.startswith("_")]
    assert "get_notices" in method_names
    assert "get_notice_detail" in method_names


def test_extract_notice_detail_parses_article_content():
    html = """
    <html>
    <body>
    <h1>关于期末考试安排的通知</h1>
    <span class="date">2026-05-28</span>
    <div class="article-content">
        <p>各位同学：</p>
        <p>本学期期末考试将于2026年6月15日开始，请做好复习准备。</p>
        <p>具体安排请查看教务系统。</p>
    </div>
    </body>
    </html>
    """
    result = extract_notice_detail(html, "https://jwxt.seig.edu.cn/jwglxt/notice/1.html")
    assert result["title"] == "关于期末考试安排的通知"
    assert result["date"] == "2026-05-28"
    assert "期末考试" in result["contentHtml"]
    assert "各位同学" in result["contentHtml"]
    assert result["url"] == "https://jwxt.seig.edu.cn/jwglxt/notice/1.html"


def test_get_notice_detail_uses_proxy_request():
    class DetailProxyUser:
        def proxy_request(self, method, url_or_endpoint, **kwargs):
            return FakeTextResponse(
                '<html><h2>测试通知详情</h2>'
                '<div id="content"><p>这是通知正文内容</p></div></html>'
            )

    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = DetailProxyUser()

    detail = client.get_notice_detail("https://jwxt.seig.edu.cn/jwglxt/notice/1.html")

    assert detail["title"] == "测试通知详情"
    assert "通知正文内容" in detail["contentHtml"]


def test_get_notice_detail_detects_login_page():
    class LoginProxyUser:
        def proxy_request(self, method, url_or_endpoint, **kwargs):
            return FakeTextResponse(
                '<html><form action="login_slogin.html"><input name="password"/></form></html>'
            )

    client = SchoolSdkClient("https://jwxt.seig.edu.cn/jwglxt")
    client._client = LoginProxyUser()

    try:
        client.get_notice_detail("https://jwxt.seig.edu.cn/jwglxt/notice/1.html")
        raise AssertionError("expected AuthenticationError")
    except AuthenticationError as exc:
        assert "会话已失效" in str(exc)
