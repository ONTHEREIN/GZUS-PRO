from __future__ import annotations

import ast
from typing import Any

DEFAULT_SCHEDULE_TIME = {
    "1": {"start": "0900", "end": "0940"},
    "2": {"start": "0940", "end": "1020"},
    "3": {"start": "1040", "end": "1120"},
    "4": {"start": "1120", "end": "1200"},
    "5": {"start": "1230", "end": "1310"},
    "6": {"start": "1310", "end": "1350"},
    "7": {"start": "1400", "end": "1440"},
    "8": {"start": "1440", "end": "1520"},
    "9": {"start": "1530", "end": "1610"},
    "10": {"start": "1610", "end": "1650"},
    "11": {"start": "1700", "end": "1740"},
    "12": {"start": "1740", "end": "1820"},
    "13": {"start": "1900", "end": "1940"},
    "14": {"start": "1940", "end": "2020"},
    "15": {"start": "2030", "end": "2110"},
    "16": {"start": "2110", "end": "2150"},
}

_PATCH_MARKER = "_gzus_pro_schedule_patch_applied"
_INFO_PATCH_MARKER = "_gzus_pro_info_patch_applied"


def apply_school_sdk_import_patches() -> None:
    """Patch Python 3.14 compatibility gaps in the current school-sdk release."""

    if ast.__dict__.get("Bytes") is not ast.Constant:
        ast.Bytes = ast.Constant  # type: ignore[attr-defined]


def schedule_time_copy() -> dict[str, dict[str, str]]:
    return {key: value.copy() for key, value in DEFAULT_SCHEDULE_TIME.items()}


def apply_school_sdk_patches() -> bool:
    """Patch school-sdk schedule parser for GZUS 16-section timetables."""

    apply_school_sdk_import_patches()
    try:
        from app.vendor.school_sdk.client.api.schedule_parse import ScheduleParse
    except ModuleNotFoundError:
        return False

    if getattr(ScheduleParse, _PATCH_MARKER, False):
        return True

    original_init = getattr(ScheduleParse, "__init__", None)
    original_get_class_time = getattr(ScheduleParse, "get_class_time", None)

    def patched_init(self: Any, *args: Any, **kwargs: Any) -> None:
        if original_init is not None:
            original_init(self, *args, **kwargs)
        if not getattr(self, "SCHEDULE_TIME", None):
            self.SCHEDULE_TIME = schedule_time_copy()

    def patched_get_class_time(self: Any, jcs: Any, *args: Any, **kwargs: Any) -> Any:
        if not getattr(self, "SCHEDULE_TIME", None):
            self.SCHEDULE_TIME = schedule_time_copy()
        start = str(jcs).split("-", 1)[0].strip() if jcs is not None else ""
        if start and start not in self.SCHEDULE_TIME:
            self.SCHEDULE_TIME[start] = {"start": "0000", "end": "0000"}
        if original_get_class_time is None:
            return {"start": "0000", "end": "0000"}
        return original_get_class_time(self, jcs, *args, **kwargs)

    ScheduleParse.__init__ = patched_init
    ScheduleParse.get_class_time = patched_get_class_time
    ScheduleParse.SCHEDULE_TIME = schedule_time_copy()
    setattr(ScheduleParse, _PATCH_MARKER, True)
    return True


def apply_school_sdk_info_patch() -> bool:
    """Patch school-sdk Info._parse to use updated CSS selectors for GZUS JWXT V9.

    The JWXT V9 system uses different element IDs for some fields:
    - Major: #col_zyh_id instead of #col_zyfx_id
    - Department: #col_jg_id instead of #col_jg_id (same, but ensure fallback)

    Patches both ``app.vendor.school_sdk`` and ``school_sdk`` copies of Info
    because they may be loaded as separate modules.
    """
    apply_school_sdk_import_patches()

    info_classes: list[type] = []
    for module_path in (
        "app.vendor.school_sdk.client.api.user_info",
        "school_sdk.client.api.user_info",
    ):
        try:
            mod = __import__(module_path, fromlist=["Info"])
            cls = getattr(mod, "Info", None)
            if cls is not None:
                info_classes.append(cls)
        except ModuleNotFoundError:
            continue

    if not info_classes:
        return False

    # Only patch if at least one class hasn't been patched yet
    if all(getattr(cls, _INFO_PATCH_MARKER, False) for cls in info_classes):
        return True

    def patched_parse(self: Any, html: str) -> dict:
        from pyquery import PyQuery as pq

        doc = pq(html)
        info = {
            "student_number": doc("#col_xh > p").text() or doc("#ajaxForm > div > div.panel-heading > div > div:nth-child(1) > div > div > p").text(),
            "name": doc("#col_xm > p").text() or doc("#ajaxForm > div > div.panel-heading > div > div:nth-child(2) > div > div > p").text(),
            "department_name": doc("#col_jg_id > p").text() or doc("#col_jg > p").text(),
            "class_name": doc("#col_bh_id > p").text() or doc("#col_bh > p").text(),
            "grade": doc("#col_njdm_id > p").text() or doc("#col_nj > p").text(),
            "major": doc("#col_zyh_id > p").text() or doc("#col_zyfx_id > p").text() or doc("#col_zy > p").text(),
            "gender": doc("#col_xbm > p").text(),
            "zjhm": doc("#col_zjhm > p").text(),
            "csrq": doc("#col_csrq > p").text(),
            "mzm": doc("#col_mzm > p").text(),
            "zzmmm": doc("#col_zzmmm > p").text(),
            "rxrq": doc("#col_rxrq > p").text(),
            "jg": doc("#col_jg > p").text(),
            "xjztdm": doc("#col_xjztdm > p").text(),
            "pyccdm": doc("#col_pyccdm > p").text(),
            "sjhm": doc("#col_sjhm > p").text(),
            "dzyx": doc("#col_dzyx > p").text(),
            "jtdz": doc("#col_jtdz > p").text(),
        }
        return info

    for cls in info_classes:
        cls._parse = patched_parse  # type: ignore[attr-defined]
        setattr(cls, _INFO_PATCH_MARKER, True)
    return True
