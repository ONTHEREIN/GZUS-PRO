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


def apply_school_sdk_import_patches() -> None:
    """Patch Python 3.14 compatibility gaps in the current school-sdk release."""

    if not hasattr(ast, "Bytes"):
        ast.Bytes = ast.Constant  # type: ignore[attr-defined]


def schedule_time_copy() -> dict[str, dict[str, str]]:
    return {key: value.copy() for key, value in DEFAULT_SCHEDULE_TIME.items()}


def apply_school_sdk_patches() -> bool:
    """Patch school-sdk schedule parser for GZUS 16-section timetables."""

    apply_school_sdk_import_patches()
    try:
        from school_sdk.client.api.schedule_parse import ScheduleParse
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
