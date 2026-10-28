"""护栏：在调用 LLM 之前拦截越权查询。

软帮手只服务登录者本人；查询他人的教务或生活数据一律拒答。规则只拦「他人 + 个人
数据」的组合，单独提到同学、或单独提到成绩都放行。
"""

from __future__ import annotations

import re
from dataclasses import dataclass

_OTHERS = r"(室友|舍友|同学|别人|他人|其他人|朋友|学长|学姐|学弟|学妹|他|她)"
_PRIVATE = r"(成绩|分数|绩点|课表|考勤|考试|余额|电费|水费)"

_RULES: list[tuple[str, re.Pattern[str]]] = [
    # 「室友的期末成绩」「室友成绩」拦；「我同学说期末考试改时间了」放行（既无「的」也不紧邻）
    ("others_private_data", re.compile(_OTHERS + r"(的[^，。？！,.?!\s]{0,4})?" + _PRIVATE)),
    ("student_id_lookup", re.compile(r"学号\s*[:：]?\s*\d{6,}")),
]

REFUSAL = "抱歉，我只能查询你本人的数据，无法查看其他同学的成绩、课表等个人信息。"


@dataclass
class PolicyDecision:
    action: str  # allow / refuse
    rule: str | None = None
    reason: str | None = None


def check(text: str) -> PolicyDecision:
    for name, pattern in _RULES:
        match = pattern.search(text)
        if match:
            return PolicyDecision("refuse", name, f"命中「{match.group(0)}」：疑似查询他人个人数据")
    return PolicyDecision("allow")
