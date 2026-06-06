from __future__ import annotations

import importlib.util
from pathlib import Path


SCRIPT_PATH = Path(r"E:\Downloads\auto_leave_application (13).py")


spec = importlib.util.spec_from_file_location("auto_leave_application_13", SCRIPT_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load {SCRIPT_PATH}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DryRunAutomation(module.LeaveApplicationAutomation):
    def final_submit(self):
        module.log.info("🧪 DRY RUN：已到最终提交步骤，停止，不点击“提交”。")
        try:
            self.driver.save_screenshot("auto_leave_before_final_submit.png")
            module.log.info("📸 已保存截图: auto_leave_before_final_submit.png")
        except Exception as exc:
            module.log.warning(f"截图失败: {exc}")
        return True


config = dict(module.CONFIG)
config["headless"] = False
config["page_load_timeout"] = 20
config["element_wait_timeout"] = 10

automation = DryRunAutomation(config)
automation.run()
