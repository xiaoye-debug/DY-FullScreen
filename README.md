# DY-FullScreen v1.0

独立版抖音全屏 Theos 插件。

## v1.0

这是当前稳定发布版，核心全屏逻辑已整理完成。

### 功能

- 首页/视频流视频全屏
- 搜索视频全屏
- 相关搜索视频全屏
- 视频合集全屏
- 作品详情页全屏
- 个人主页及其他用户作品全屏
- 个人主页分页兼容
- 不同视频高度布局兼容，避免上下作品重叠或累计下移
- 图文/富内容页面布局修正
- 「汽水听」场景布局兼容
- 底部 TabBar 背景隐藏
- 播放进度及底部区域视觉修正
- 直播预览页底部控件位置修正
- 抖音内部设置页提供全屏开关
- 设置页提供 GitHub 开源项目入口
- GitHub 入口使用抖音内部图标并直接打开项目网页

### 发布信息

| 项目 | 信息 |
|---|---|
| 版本 | **1.0** |
| 架构 | arm64 |
| 打包方式 | Rootless |
| 最低 iOS | 15.0 |
| 进程 | Aweme |
| 包名 | com.xiaoye.dyfullscreen |
| DEB | com.xiaoye.dyfullscreen_1.0_iphoneos-arm64.deb |

### 安装

将 Release 中的 .deb 安装到支持 Rootless 的越狱/注入环境。

安装后重启抖音，使插件加载。

### 设置

在抖音设置页面找到 DY-FullScreen，可以开启或关闭全屏功能。

### GitHub

https://github.com/xiaoye-debug/DY-FullScreen

### 构建

项目使用 Theos + GitHub Actions 构建 Rootless DEB。

推送到 main 会执行构建检查；创建 v* 标签时会自动构建并创建 GitHub Release。

### 免责声明

本项目仅用于研究 iOS Runtime、Theos Tweak 及界面布局技术。使用者应自行承担使用相关修改所产生的风险。