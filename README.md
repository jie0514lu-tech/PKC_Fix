# PKC 60秒新闻修复补丁

修复 PKC_0.9-9-Beta1 插件在微信 8.0.78/79 中的以下问题：

## 修复的问题

### 1. 60秒新闻只发标题 / 空白 / 乱码

**原因**：PKC 使用的 `api.lbbb.cc/api/60s` API 已失效：
- `/api/60s` 端点超时或重定向过多
- `/api/60miao` 只返回标题字符串，没有实际新闻条目

**修复**：Hook `+[WenAnAPIManager get60s:]` 方法，替换为多 API 自动回退：
- `60s.viki.moe/v2/60s`（主源）
- `api.auth.top`、`qqsuu.cn`、`oioweb.cn`、`03c3.cn`（备用）
- `lbbb.cc`（最后兜底）

支持多种 JSON 结构解析、编码自动检测（UTF-8/GBK/Big5）、控制字符清洗。

### 2. 微信 8.0.78/79 消息发送方式变化导致发送失败/闪退

**原因**：PKC 调用 `[WeixinContentLogicController AddMsg:MsgWrap:]` 发送消息，但微信 8.0.78/79 中该类已没有此方法（父类只有 `OnAddMsg:MsgWrap:`），只有 `CMessageMgr` 才有 `AddMsg:MsgWrap:`。

**修复**：Hook `-[WeixinContentLogicController AddMsg:MsgWrap:]`，转发到 `CMessageMgr AddMsg:MsgWrap:`，并提供 `OnAddMsg:MsgWrap:` 和 `SendTextMessage:replyingMessage:isPasted:` 备用方案。

### 3. 注入后启动闪退（libsubstrate.dylib 缺失）

**原因**：原始 PKC dylib 依赖 `@rpath/libsubstrate.dylib`，但签名工具只注入有 plist 的 dylib，`libsubstrate.dylib` 没有 plist 不会被注入。

**修复**：用 `install_name_tool` 将 `PKCWeChatTools.dylib` 和 `PKC60sFix.dylib` 的依赖从 `@rpath/libsubstrate.dylib` 改为 `@rpath/CydiaSubstrate.framework/CydiaSubstrate`（CydiaSubstrate 已存在于 Frameworks 目录）。

## 不影响的功能

本补丁只 hook 以下 2 个方法，PKC 其他功能完全保持不变：
- `+[WenAnAPIManager get60s:]` — 仅 60秒新闻
- `-[WeixinContentLogicController AddMsg:MsgWrap:]` — 消息发送转发

鸡汤、文案、自动回复、设置 UI 等功能均由原始 PKC 提供，不受影响。

## 编译

GitHub Actions 自动编译，在 [Actions](https://github.com/jie0514lu-tech/PKC_Fix/actions) 页面下载 artifact，或在 [Releases](https://github.com/jie0514lu-tech/PKC_Fix/releases) 下载完整 deb。

手动编译（需 macOS + Theos）：
```bash
make package
```

## 使用

将 `PKC_0.9-9-Beta1-Fixed.deb` 通过签名工具注入微信 IPA 即可。deb 内包含：
- `PKCWeChatTools.dylib` — 原始 PKC 全部功能
- `PKC60sFix.dylib` — 60秒新闻 + 消息发送修复
- `PKC60sFix.plist` — 注入过滤（com.tencent.xin）

## 版本历史

### v2.2（当前版本）
- 新增后台/锁屏发送支持：hook UIApplication applicationState，在 send60s 执行期间返回 active
- 时间到点 + 微信在后台/锁屏 → PKC 认为在前台 → 正常获取新闻并发送
- 10秒后恢复真实状态，不影响其他功能
- 配合25秒保活定时器，后台也能发送新闻

### v2.1
- 重试次数从12次提升到48次（覆盖24小时），确保一整天都能重试直到获取到今天的新闻
- 确认PKC发送逻辑：PKC需要微信在前台才能发送，后台只设置flag等回到前台再发

### v2.0
- 新增自动重试机制：所有API都没今天的新闻时，每30分钟自动重试
- 成功获取后重试计数归零
- 如果PKC定时器再次触发get60s:，取消旧的重试定时器，重新开始

### v1.9
- 修复内容比对导致重试失败的问题：哈希延迟5分钟保存
- 如果PKC发送失败5分钟内重试：哈希还没保存，相同内容不会被跳过
- 5分钟后保存哈希：防止同一天重复发送

### v1.8
- 去掉无效的 minuteInterval hook 代码（分析发现该属性在日期选择器上，不在保活类上）
- 去掉 NSUserDefaults synchronize 调用（已废弃，可能轻微卡顿）
- 性能优化确认：所有耗时操作只在新闻获取时执行（每天一次），正常聊天不受影响
- 保活定时器只调一个系统 API，耗时 <1 毫秒，不卡顿

### v1.7
- 新增内容比对：保存上次发送的新闻内容哈希，如果本次内容和上次相同 → 跳过试下一个 API
- 保活定时器从 5 秒改为 25 秒（iOS 给 30 秒，25 秒续上刚好，省电不卡顿）
- 去掉保活刷屏日志（只保留启动日志一条）

### v1.6
- 修复"今天日期+昨天新闻内容"问题：JSON 路径现在优先用 API 返回的日期，不自动生成今天日期
- 新鲜度检查提前到构建文本之前：先检查 JSON 日期，是昨天的直接跳过
- 修复 create_time 字段检查：不是今天的日期时也返回 NO（之前漏了）
- 新增保活定时器：dispatch_source_t 每 25 秒申请后台时间
- 尝试 hook PKC 的 minuteInterval 为 5（运行时遍历找到混淆类名）

### v1.5
- 修复新鲜度检查 bug：之前文本含昨天日期但找不到今天日期时默认通过，现在会检测昨天的日期并跳过
- 同时检查 JSON 的 date/update/create_time 字段和文本中的日期（月日/ISO格式）
- 如果 API 返回昨天的新闻 → 自动跳到下一个 API

### v1.4
- API 优先级重排：viki.moe text → viki.moe JSON → qqsuu → oioweb → auth.top → 03c3 → lbbb
- 新增日期新鲜度检查：检查 JSON date/update 字段和文本中的日期，防止发送昨天的重复新闻
- 新增失败追踪：API 连续失败 3 次后自动跳过 30 分钟，避免反复尝试不可用的 API
- 超时从 20 秗缩短到 10 秒，加快 API 回退速度
- 每步操作记录详细日志（哪个 API 成功/失败/跳过/旧闻检测）

### v1.3
- 优先使用 viki.moe text 格式 API，返回完整新闻格式（日期/星期/农历/新闻/微语/来源）
- JSON 回退路径补充：公历日期、星期、农历（天干地支+生肖+月日）、节日检测、来源标注
- 修复 lbbb.cc newslist 格式解析（提取 description/content 字段）
- 确保定时发送逻辑正确：PKC 定时器调用 get60s: → 获取新闻 → completion block 传回文本 → PKC 发送

### v1.2
- 修复消息和语音发送失败问题
- 改用 `class_addMethod` 在 `%ctor` 中检查，只在 `AddMsg:MsgWrap:` 方法不存在时才添加转发实现
- 如果微信已自带此方法，完全不干预，保证正常发消息/语音不受影响

### v1.1
- 修复 60秒新闻只发标题/空白/乱码（多 API 回退 + 正确 JSON 解析）
- 修复微信 8.0.78/79 消息发送方式变化导致发送失败（AddMsg:MsgWrap: 转发到 CMessageMgr）
- 修复注入后启动闪退（install_name_tool 将 libsubstrate.dylib 依赖改为 CydiaSubstrate.framework）
- 注意：此版本用 `%hook` 覆盖了 AddMsg:MsgWrap:，会影响正常消息/语音发送，已在 v1.2 修复

### v1.0
- 初始版本，仅修复 60秒新闻 API 和编码问题
