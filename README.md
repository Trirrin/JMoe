# JMoe

一个使用 Flutter 重写的 JMComic 客户端，界面参考 [Kazumi](https://github.com/Predidit/Kazumi) 的设计语言，
支持 **JMComic** 与 **E-Hentai** 双数据源，并提供加密离线缓存。

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="120" alt="JMoe" />
</p>

---

## 功能

### 内容浏览
- **发现页**：精选轮播、连载更新、C108 推荐、禁漫去码/全彩化、韩漫更新等分区
- **统一双源**：JM / E-Hentai 一键切换，界面与阅读器完全一致，切换不重新加载
- **分类**：分类树 + 子分类筛选 + 排序（最新/人气/评分/新上架）
- **搜索**：支持标题、作者、标签、JM 号检索；历史与热搜
- **每周必看**、**动漫**、**小说**、**书库**、**论坛** 入口

### 阅读体验
- **统一阅读器**：竖向条漫 / 横向翻页可切换
- **整章缓存**：以整章为粒度，统一进度蒙版（进度条 + `xx/xx`）
  - 可「等待缓存完成」后阅读，也可「边看边缓存」
  - 缓存任务后台持续，离开页面不中断
  - **从当前页向两侧扩散加载**，优先保证眼前这一页
  - 已完成章节显示离线标记
- **加密缓存**：磁盘缓存使用 AES-256-CBC 加密（随机 IV），无法用图片查看器直接读取
- **阅读时只进内存**：只有主动下载才落盘，避免缓存无限膨胀；整章读完后再异步补写一次

### 小说阅读器
- **全话无缝拼接**：预取后续章节并合并排版，翻页不中断，无需手动切话
- **两种模式**：上下滚动 / 横向翻页
- **排版可调**：字号、行距、字间距、段距、边距、首行缩进、字重、字体、对齐
- **主题跟随 App**：按 JMoe 的浅色/深色设置自动切换阅读配色
- **TTS 朗读**、书签、批注、内文搜索

### 账号与社交
- 登录 / 注册 / 找回密码
- 收藏（**本地优先 + 云端自动同步**，本地操作百分百成功）
- 阅读历史、追更
- **评论**：列表、点赞（乐观更新）、回复、发送
- 签到：显示本月日历与连续天数

### 视频播放
- HLS 边下边播，缓存蒙层显示标题与进度
- **长按调倍速**：按滑动比例映射 0.5x ~ 3.0x，松手还原
- 双击左右跳转 10 秒，竖滑调亮度/音量
- 全屏、后台下载（支持暂停/继续）

### 其他
- **统计面板**（底部独立 Tab）：漫画 / 小说 / 视频三大板块各自独立统计
  - 各板块的累计时长、今日时长、篇章数、作品数、7 日曲线
  - 全局连续天数、缓存命中率、下载与存储占用
- **网络限速**：默认 10 Mbps，可调（图片与视频下载限速，API 不受影响）
- **存储管理**：占用饼图（随主题自适应）、分类明细、缓存策略（上限 + 保留时长）
- **多语言**：简体中文 / 繁體中文 / English（JSON 语言文件，无硬编码）

---

## 界面预览

基于 [Kazumi](https://github.com/Predidit/Kazumi) 的设计语言：柔和圆角、层次化卡片、
沉浸式详情页 Hero 转场、发现页海报轮播。

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

> 本项目不含任何原生 C/C++ 代码。为避免构建期自动下载 NDK，
> `path_provider_android` 与 `shared_preferences_android` 已钉在不依赖 `jni` 的版本。

---

## 目录结构

```
lib/
├── core/                        # 与 UI 无关的核心层
│   ├── jm_protocol.dart         # 签名 / 解密 / 线路发现与测速
│   ├── jm_service.dart          # JM 业务接口
│   ├── ehentai_service.dart     # EH 抓取与解析
│   ├── source.dart              # 数据源抽象（JM/EH 统一契约）
│   ├── jm_source.dart           # JM 适配器
│   ├── eh_source.dart           # EH 适配器
│   ├── image_scrambler.dart     # 图片分片还原
│   ├── image_cache.dart         # 加密图片缓存 + CachedCover
│   ├── chapter_cache.dart       # 整章缓存任务管理
│   ├── novel_cache.dart         # 小说正文加密缓存
│   ├── video_cache.dart         # HLS 分片缓存
│   ├── novel_reader_controller.dart  # 小说阅读会话（纯逻辑，可测）
│   ├── reader_paginator.dart    # 文本分页器
│   ├── reader_settings.dart     # 阅读器设置
│   ├── reader_store.dart        # 书签 / 批注 / 进度
│   ├── reading_stats.dart       # 分板块统计
│   ├── net_throttle.dart        # 令牌桶限速
│   └── app_state.dart           # 全局状态与本地持久化
├── pages/                       # 界面层
├── widgets/                     # 复用组件
│   ├── novel_text_view.dart     # 小说正文渲染（分页/滚动）
│   ├── novel_menu_overlay.dart  # 小说菜单层
│   ├── novel_catalog_overlay.dart # 小说目录层
│   ├── novel_typography_sheet.dart # 排版面板
│   └── novel_theme_sheet.dart   # 主题面板
└── main.dart                    # 引导状态机
```

---

## 技术要点（逆向自 JMComic3 2.1.12）

| 项目 | 实现 |
|---|---|
| 请求签名 | `Tokenparam: <unix秒>,<版本>`、`Token: md5(时间戳 + "185Hcomic3PAPP7R")` |
| 响应解密 | AES-128-ECB/PKCS7，密钥 `md5(时间戳 + <key>)`；广告接口用固定 key |
| 线路表 | `newsvr-2025.txt`，AES-ECB，密钥 `md5("diosfjckwpqpdfjkvnqQjsik")` |
| 图片还原 | 纵向切段逆序拼接，段数由 `md5(章节ID + 文件名)末位` 决定（2/4/6…20 段） |
| 封面 | `{img_host}/media/albums/{id}_3x4.jpg?v={update_at}` |

> 官方 API 未提供横版海报，仅 `_3x4.jpg`（3:4 竖版）与无后缀原图可用。

---

## 特别鸣谢

本项目的界面设计深受以下开源项目启发，在此致以诚挚感谢：

### [Kazumi](https://github.com/Predidit/Kazumi)

- **设计语言**：整体视觉参考 Kazumi —— 柔和圆角、层次化卡片、留白节奏
- **交互模式**：沉浸式详情页、Hero 封面转场、发现页海报轮播
- **项目结构**：`core` / `pages` / `widgets` 的分层方式借鉴其组织思路
- **工程实践**：README 结构与开源文档风格参考其做法

> Kazumi 是一个优秀的番剧聚合播放器。JMoe 的阅读体验设计大量借鉴了它，
> 如果你喜欢这类界面的组织方式，推荐一并关注 Kazumi。

### 其他致谢

- [Flutter](https://flutter.dev) —— 跨平台 UI 框架
- [Dio](https://github.com/cfug/dio) —— HTTP 客户端
- [html](https://pub.dev/packages/html) —— HTML 解析（EH 源）
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

[MIT License](LICENSE) © 2026 Liuyue_awa
