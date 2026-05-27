# GZUS-PRO

Flutter Web-first + FastAPI 教务助手。

## 项目结构

- `apps/mobile_web`：Flutter 前端，Fluent 2 风格，Web 优先。
- `services/api`：FastAPI 后端，封装教务系统登录和数据读取。
- `docs`：接口、隐私和抓取边界说明。

## 后端启动

```powershell
cd services/api
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e ".[dev]"
uvicorn app.main:app --reload
```

真实连接教务系统时安装 SDK：

```powershell
pip install -e ".[school]"
```

`school-sdk` 当前声明支持 Python 3.8-3.13；如需真实登录，请使用 Python 3.11-3.13。

后端只直接依赖 `FarmerChillax/new-school-sdk`。考试、考勤等 SDK 未覆盖能力已保留 `proxy_request` 扩展空位，等拿到学校接口文件后补 endpoint 和解析器。

## 前端启动

```powershell
cd apps/mobile_web
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

如果 Flutter 未加入当前进程 `PATH`，可直接使用：

```powershell
D:\REINs\Documents\flutter\bin\flutter.bat run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

## 移动端启动

移动端复用同一个 Flutter 工程，已生成 `android/` 和 `ios/` 平台目录。联奕单点登录在移动端走 App 内 WebView，登录完成后读取 WebView 中 `jwxt.seig.edu.cn` 的 cookie，再交给后端验证。

Android 模拟器访问本机后端时使用：

```powershell
cd apps/mobile_web
D:\REINs\Documents\flutter\bin\flutter.bat run -d android --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

真机或生产环境请使用可被手机访问的 HTTPS 后端地址：

```powershell
D:\REINs\Documents\flutter\bin\flutter.bat run -d android --dart-define=API_BASE_URL=https://your-api.example.com
```
