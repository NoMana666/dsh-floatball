# DSH 桌面悬浮球

在 Windows 桌面放一只小鲸鱼，随 DSH 一起启动、一起退出，DSH 等你确认时会亮起来。

## 外观

- 谷时（默认）：蓝色鲸鱼，镂空处为淡蓝蒙版
- 峰时（工作日 9-12 点、14-18 点）：粉色鲸鱼，镂空处淡粉
- DSH 已退出：灰色
- 有事等你确认（授权 / 提问）：镂空处变亮黄
- 周末与法定节假日全天按谷时（蓝色）计价配色

## 操作

| 操作 | 效果 |
| --- | --- |
| 左键单击 | 唤回 DSH 窗口（未启动时启动 DSH） |
| 按住拖动 | 移动位置，松手记住坐标 |
| 右键 | 打开 DSH 窗口 / 悬浮球大小（48-132）/ 随 DSH 自动启动 / 复位到右下角 / 始终置顶 / 退出悬浮球 |

## 提醒信号

DSH 在以下时刻让悬浮球亮起（镂空区变亮黄）：

- 工具执行需要你授权（`approval/request`）
- 向你发起结构化提问（`user-questions/request`）

状态经心跳文件 `%LOCALAPPDATA%\dsh-floatball\heartbeat.json` 的 `attention` 字段传递，处理完自动恢复。

## 生命周期

- DSH 启动时插件自动拉起悬浮球（`settings.json` 里 `autoStart` 为 `false` 时不拉起）
- DSH 退出时悬浮球跟着退出；最小化或后台运行时保持显示
- 心跳每 3 秒刷新，超过 20 秒没更新则悬浮球自行退出
- 右键「随 DSH 自动启动」写回 `settings.json`，下次启动生效

## 已知限制

- X 掉 DSH 主窗口后，点悬浮球无法把它恢复成可操作状态：DSH 的 X 是 `window.hide()`，窗口带 `WS_EX_NOREDIRECTIONBITMAP`，外部调用无法让 Chromium 重绘。请改用最小化，或点任务栏托盘图标
- 仅 Windows；球体由 PowerShell + WinForms 绘制，依赖系统自带 PowerShell 5.1
- 位置、尺寸、开关都保存在 `%LOCALAPPDATA%\dsh-floatball\settings.json`，日志在同目录 `ball.log`
