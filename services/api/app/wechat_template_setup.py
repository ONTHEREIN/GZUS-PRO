"""选用已核对的四类一次性订阅模板，并写入本机 .env（不部署）。

运行：uv run --locked python -m app.wechat_template_setup
成绩需在微信公众平台申请新模板：课程成绩通知；关键词按顺序为课程名称
(thing)、成绩文本(thing)、发布时间(time)，适用场景为用户授权后的学校成绩更新。
批准后核对实际字段编号为 thing1/thing2/time3 再配置 WECHAT_GRADE_TEMPLATE_ID。
"""
from __future__ import annotations

import re

import httpx
from pydantic import BaseModel, ConfigDict, Field

from app.config import ENV_FILE, get_settings
from app.wechat_notifications import WechatSubscribeClient


class PrivateTemplate(BaseModel):
    model_config = ConfigDict(extra="ignore")
    template_id: str = Field(alias="priTmplId")
    title: str
    content: str


class PrivateTemplates(BaseModel):
    model_config = ConfigDict(extra="ignore")
    errcode: int
    data: list[PrivateTemplate]


class SelectedTemplate(BaseModel):
    model_config = ConfigDict(extra="ignore")
    errcode: int
    template_id: str = Field(alias="priTmplId")


def configure_templates() -> None:
    if get_settings().wechat_miniprogram_app_id != "wx2fb65b853ae73231":
        raise RuntimeError("本机 AppID 与软帮手不一致，停止模板配置")
    token = WechatSubscribeClient().token()
    candidates = [
        ("WECHAT_EXAM_TEMPLATE_ID", "76950", "考试相关时间节点通知", [7, 4, 5, 6],
         ["thing7", "time4", "thing5", "thing6"], "学校考试安排及考前提醒"),
        ("WECHAT_COURSE_TEMPLATE_ID", "77439", "上课提醒", [5, 3, 2],
         ["thing5", "time3", "thing2"], "学校课程上课前提醒"),
        ("WECHAT_ATTENDANCE_TEMPLATE_ID", "3214", "考勤异常通知", [7, 4, 8],
         ["thing7", "thing4", "time8"], "学校考勤异常更新提醒"),
        ("WECHAT_ECARD_TEMPLATE_ID", "28394", "账号余额不足提醒", [2, 6, 4, 10],
         ["thing2", "number6", "thing4", "time10"], "宿舍水电剩余用量不足提醒"),
    ]
    with httpx.Client(timeout=get_settings().request_timeout_seconds) as client:
        response = client.get("https://api.weixin.qq.com/wxaapi/newtmpl/gettemplate", params={"access_token": token})
        if response.status_code != 200:
            raise RuntimeError(f"获取私有模板失败，HTTP {response.status_code}")
        result = PrivateTemplates.model_validate(response.json())
        if result.errcode != 0:
            raise RuntimeError(f"获取私有模板失败，错误码 {result.errcode}")
        configured: dict[str, str] = {}
        for env_key, public_id, title, kids, fields, scene in candidates:
            existing = next((item for item in result.data if item.title == title and
                             all("{{" + field + ".DATA}}" in item.content for field in fields)), None)
            if existing is not None:
                configured[env_key] = existing.template_id
                print(f"{title}：复用已选用模板")
                continue
            # 配置接口无幂等键，响应未知时抛错，重新执行先读取私有列表再处理。
            response = client.post("https://api.weixin.qq.com/wxaapi/newtmpl/addtemplate",
                                   params={"access_token": token}, json={
                                       "tid": public_id, "kidList": kids, "sceneDesc": scene})
            if response.status_code != 200:
                raise RuntimeError(f"选用{title}结果未知，HTTP {response.status_code}，请核对后台模板列表")
            payload = response.json()
            if payload.get("errcode") != 0:
                raise RuntimeError(f"选用{title}失败，错误码 {payload.get('errcode')}，原因 {payload.get('errmsg')}，公共模板 {public_id}，关键词 {kids}")
            configured[env_key] = SelectedTemplate.model_validate(payload).template_id
            print(f"{title}：已选用")
    content = ENV_FILE.read_text()
    for key, value in configured.items():
        pattern = re.compile(rf"^{key}=.*$", re.MULTILINE)
        content = pattern.sub(f"{key}={value}", content) if pattern.search(content) else content.rstrip() + f"\n{key}={value}\n"
    ENV_FILE.write_text(content)
    print("四类私有模板 ID 已写入本机 .env；未部署，未发送消息。成绩模板仍待申请。")


if __name__ == "__main__":
    configure_templates()
