# Scraping Boundaries

- V1 只读取教务系统个人信息、课表、考试、成绩。
- V1 不自动填写办事大厅表单。
- 办事大厅 `https://ehall.gzus.edu.cn/#/index` 仅作为后续 connector 配置保留。
- 教务系统基址默认 `https://jwxt.seig.edu.cn/jwglxt`。
- 默认优先使用 `FarmerChillax/new-school-sdk` 已有能力；缺失功能只通过该 SDK 的 `proxy_request` 补齐。
