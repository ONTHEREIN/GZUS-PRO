from __future__ import annotations

import importlib.util
import logging
import time
from pathlib import Path


SCRIPT_PATH = Path(r"E:\Downloads\auto_leave_application (13).py")
WORKSPACE = Path(r"D:\REINs\Documents\GZUS-PRO")


spec = importlib.util.spec_from_file_location("auto_leave_application_probe", SCRIPT_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load {SCRIPT_PATH}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SafeProbeAutomation(module.LeaveApplicationAutomation):
    def _shot(self, name: str) -> None:
        try:
            path = WORKSPACE / f"auto_leave_probe_{name}.png"
            self.driver.save_screenshot(str(path))
            module.log.info("📸 probe screenshot: %s", path)
        except Exception as exc:
            module.log.warning("screenshot failed: %s", exc)

    def open_form(self):
        result = super().open_form()
        self._shot("01_open_form")
        return result

    def fill_student_category(self):
        result = super().fill_student_category()
        self._shot("02_student_category")
        return result

    def fill_leave_dates(self):
        result = super().fill_leave_dates()
        self._shot("03_dates")
        return result

    def fill_leave_reason(self):
        result = super().fill_leave_reason()
        self._shot("04_reason")
        return result

    def upload_attachment(self):
        result = super().upload_attachment()
        self._shot("05_attachment")
        return result

    def fill_courses(self):
        result = super().fill_courses()
        self._shot("06_courses")
        return result

    def click_submit_button(self):
        result = super().click_submit_button()
        self._shot("07_handle_dialog")
        return result

    def select_approval_type(self):
        result = super().select_approval_type()
        self._shot("08_approval_type")
        return result

    def select_teacher_from_org_selector(self):
        result = super().select_teacher_from_org_selector()
        self._shot("09_teacher_selector")
        return result

    def final_submit(self):
        module.log.info("🛑 probe mode: stopped before final submit")
        self._shot("10_before_final_submit")
        time.sleep(20)
        return False


def main() -> None:
    logging.getLogger().setLevel(logging.INFO)
    config = dict(module.CONFIG)
    config.update(
        {
            "headless": False,
            "attachment_path": str(WORKSPACE / "leave_note.txt"),
            "page_load_timeout": 45,
            "element_wait_timeout": 15,
        }
    )
    SafeProbeAutomation(config).run()


if __name__ == "__main__":
    main()
