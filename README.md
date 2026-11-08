<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="120" alt="JMoe" />
</p>

# JMoe

一个使用 Flutter 重写的 JMComic 客户端，界面参考 [Kazumi](https://github.com/Predidit/Kazumi) 的设计语言。

> **数据源说明**：本项目仅支持 **JMComic** 单一数据源。
> 早期版本曾包含 E-Hentai 源，因稳定性与可用性问题已整体移除。

---

## 功能

### 内容浏览
- **发现页**：精选轮播、连载更新、C108 推荐、禁漫去码/全彩化、韩漫更新等分区
- **分类**：分类树 + 子分类筛选 + 排序（最新/人气/评分/新上架）
- **搜索**：支持标题、作者、标签、JM 号检索；历史与热搜
- **每周必看**、**动漫**、**小说**、**书库** 入口


### 阅读体验
- **统一阅读器**：竖向条漫 / 横向翻页可切换
- **整章缓存**
  - 可「等待缓存完成」后阅读，也可「边看边缓存」
  - 缓存任务后台持续，离开页面不中断

### 小说阅读器
- **全话无缝拼接**：预取后续章节并合并排版，翻页不中断，无需手动切话
- **两种模式**：上下滚动 / 横向翻页
- **排版可调**：字号、行距、字间距、段距、边距、首行缩进、字重、字体、对齐
- **主题跟随 App**：按 JMoe 的浅色/深色设置自动切换阅读配色
- **TTS 朗读**、内文搜索

### 离线与导入
- **我的下载**：整章下载，按「下载中 / 暂停中 / 已完成」分板块，支持断点续传、并发下载
- **加密章节包**：下载内容可选打包为 `.jmoe` 自有加密格式，分享时附带作品信息
- **我导入**：通过系统文件选择器导入 `.jmoe` 加密包，直接离线阅读
- **收藏导入导出**：收藏列表可导出为 JSON 并重新导入

### 账号与社交
- 登录 / 注册 / 找回密码
- 收藏（云端同步，失败自动降级为本地并提示）
- 阅读历史：按作品聚合，支持「最近观看 / 进度最高」排序
- **评论**：列表、点赞、回复、发送
- 签到：显示本月日历与连续天数


### 视频播放
- HLS 边下边播，缓存蒙层显示标题与进度
- **长按调倍速**：按滑动比例映射 0.5x ~ 3.0x，松手还原
- 双击左右跳转 10 秒，竖滑调亮度/音量
- 全屏、后台下载

### 其他
- **统计面板**：漫画 / 小说 / 视频三大板块各自独立统计
  - 各板块的累计时长、今日时长、篇章数、作品数、7 日曲线
  - 全局连续天数、缓存命中率、下载与存储占用
- **网络限速**：默认 10 Mbps，可调
- **存储管理**：占用饼图、分类明细、缓存策略
- **多语言**：简体中文 / 繁體中文 / English

---

## 界面预览

基于 [Kazumi](https://github.com/Predidit/Kazumi) 的设计语言：柔和圆角、层次化卡片、
沉浸式动画。

---

## 构建

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

环境要求：
- Flutter **3.47.9**
- JDK **21**
- Android SDK **platform 36** + build-tools **36.1.0**

---

## 目录结构

```
lib/
├── core/                        # 与 UI 无关的核心层
│   ├── jm_protocol.dart         # 签名 / 解密 / 线路发现与测速
│   ├── jm_service.dart          # JM 业务接口
│   ├── source.dart              # 数据源抽象契约
│   ├── jm_source.dart           # JM 适配器
│   ├── image_scrambler.dart     # 图片分片还原
│   ├── image_cache.dart         # 加密图片缓存 + CachedCover
│   ├── chapter_cache.dart       # 整章缓存任务管理
│   ├── jmoe_archive.dart        # .jmoe 自有加密章节包（逐页 AES-CBC）
│   ├── temp_store.dart          # 大章节临时目录与回收策略
│   ├── downloader.dart          # 整章下载器（断点续传 / 并发 / 分享）
│   ├── favorites_backup.dart    # 收藏 JSON 导入导出
│   ├── novel_cache.dart         # 小说正文加密缓存
│   ├── video_cache.dart         # HLS 分片缓存
│   ├── novel_reader_controller.dart  # 小说阅读会话（纯逻辑，可测）
│   ├── reader_paginator.dart    # 文本分页器
│   ├── reader_settings.dart     # 阅读器设置
│   ├── reader_store.dart        # 阅读进度存储
│   ├── reading_stats.dart       # 分板块统计
│   ├── net_throttle.dart        # 令牌桶限速
│   └── app_state.dart           # 全局状态与本地持久化
├── pages/                       # 界面层
├── widgets/                     # 复用组件
│   ├── app_toast.dart           # 自绘 Toast（进出场动画 + 动作按钮）
│   ├── cloud_upload_icon.dart   # 云上传图标
│   ├── novel_text_view.dart     # 小说正文渲染（分页/滚动）
│   ├── novel_menu_overlay.dart  # 小说菜单层
│   ├── novel_catalog_overlay.dart # 小说目录层
│   ├── novel_typography_sheet.dart # 排版面板
│   └── novel_theme_sheet.dart   # 主题面板
└── main.dart                    # 引导状态机
```

---

## 特别鸣谢

本项目的界面设计深受以下开源项目启发，在此致以诚挚感谢：

### [Kazumi](https://github.com/Predidit/Kazumi)

- **设计语言**：整体视觉参考 Kazumi —— 柔和圆角、层次化卡片
- **交互模式**：沉浸式详情页、封面动画、发现页海报轮播
- **项目结构**：`core` / `pages` / `widgets` 的分层方式借鉴其架构思路

> Kazumi 是一个优秀的番剧聚合播放器。JMoe 的阅读体验设计大量借鉴了它，
> 如果你喜欢这类界面的组织方式，推荐一并关注 Kazumi。

### 其他致谢

- [Flutter](https://flutter.dev) —— 跨平台 UI 框架
- [Dio](https://github.com/cfug/dio) —— HTTP 客户端
- [html](https://pub.dev/packages/html) —— HTML 解析
- [shared_preferences](https://pub.dev/packages/shared_preferences) / [path_provider](https://pub.dev/packages/path_provider) —— 本地存储
- [video_player](https://pub.dev/packages/video_player) —— 视频播放

---

## 免责声明

本项目仅供**技术学习与研究**使用。所有内容均来自第三方服务，本应用不存储、不托管任何内容。

请在下载后 **24 小时内**删除缓存内容，超出 24 小时的使用需获得相关权利人的授权。

使用本项目需遵守所在地法律法规，不得进行任何侵犯第三方知识产权的行为。
使用者需自行承担使用风险。

---

## 许可证

[MIT License](LICENSE) Copyright (c) 2026 Liuyue_awa
