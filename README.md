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

### v4.1（当前版本）
- 精简目标查找：删除慢速的NSUserDefaults全盘扫描和plist扫描
- 新增UIViewController viewWillDisappear hook：捕捉用户选择群聊/好友时的目标
- 选择器页面消失后0.5秒扫描PKC单例，获取用户选中的wxid
- 保留快速查找：PKC单例递归扫描 + 当前聊天VC扫描
- 代码更简洁，不卡顿不闪退

### v4.0
- 新增第4种目标查找方式：从当前聊天界面获取wxid
- 如果用户在聊天页点击测试，直接用当前聊天对象作为目标
- 遍历UIViewController栈，递归扫描ivar+尝试常见聊天属性(m_nsChatName/m_contact/session等)
- 结合v3.9的持久化+自动更新，目标获取能力大幅提升

### v3.9
- 目标wxid持久化到NSUserDefaults，APP重启后仍有目标
- pkcFindTargetAll每次都重新扫描，目标改变时自动发现并更新
- 统一pkcSetTarget函数：内存+持久化同时更新，所有赋值点统一调用
- CMessageMgr hook捕获发送时的目标并自动持久化

### v3.8
- 目标查找改为递归扫描：深入PKC实例的所有嵌套对象（最深4层），包括嵌套的数组、字典、自定义对象
- 新增CMessageMgr SendMessage:/sendMsg: hook，PKC定时发送成功时自动捕获并记录目标wxid
- 点击测试时，如果之前定时发送成功过，直接使用已记录的目标发送

### v3.7
- 新增Toast提示栈：黑色半透明背景(alpha 0.78)+白色字体+圆角12，每条显示2.5秒
- 所有关键步骤都有Toast提示：定时触发/开始获取/获取成功/获取失败/正在发送/发送成功/发送失败原因
- 提示系统设计为栈结构，任何模块调用PKCPushToast(@"消息")即可注入
- 发送失败时显示具体原因：目标为空/CMessageMgr不可用/CMessageWrap不存在/无发送方法
- 兼容iOS13+ UIScene和旧版keyWindow

### v3.6
- 新增NSUserDefaults全盘扫描目标wxid（PKC的目标很可能存在这里）
- 新增PKC plist文件扫描目标wxid
- pkcFindTargetInObject增强：扫描父类ivar+数组类型
- get60s备份发送前调用pkcFindTargetAll()从PKC单例/NSUserDefaults/plist全面查找目标
- 新增CMessageMgr AddMsg:MsgWrap:诊断hook（仅日志+调用原始），用于确认PKC是否真的调用了发送方法

### v3.5
- 修复：text格式API（viki.moe?format=text）实际返回JSON时，原代码把JSON当文本直接发送
- parseNewsData改为优先尝试JSON解析，只有非JSON才按纯文本处理
- 增加JSON字符串过滤：以{或[开头的文本直接拒绝，防止发送原始JSON
- parseJSON增加day_of_week和lunar_date字段，日期头显示"2026-10-10 星期六 丙午年九月初一"
- 新鲜度检查改为：只要响应是JSON就检查JSON日期，不再区分text/JSON API

### v3.4
- API逻辑重构：8个API立即切换下一个，不再"失败3次跳过30分钟"
- 8个API全部失败才等30分钟重试，成功1次当天停止获取
- 成功后当天不再重复获取，直到第二天设定时间才触发
- 本地保存新闻全文+日期，第二天获取到新的自动删除旧的
- 和昨天保存的全文对比，防止发送昨天的重复新闻
- 启动后15秒自动扫描PKC实例提取目标wxid（45秒后第二次尝试）
- 点击测试时用已存好的目标直接发送备份
- 今天已完成时返回保存的新闻给PKC（让PKC重试发送但不重复获取）

### v3.3
- 修复"提示成功却不发送"问题：PKC 发送链路在微信8.0.78/79失效
- 新增直接发送备份：get60s完成后2秒自动尝试通过CMessageMgr直接发送
- 新增4种方式获取CMessageMgr实例（sharedInstance/MMServiceCenter/AppDelegate ivar/PKC ivar）
- 新增从PKC实例ivars自动提取目标wxid（@chatroom/wxid_格式）
- pkc_forwardAddMsg增加sendMsg:/addMsg:回退方法+日志诊断
- %ctor增加启动诊断日志（检查关键类和方法是否存在）

### v3.2
- 修复花括号不平衡导致 `%hook does not make sense inside a block` 编译失败（PKC60sIsNewsFresh 函数缺少 @try 和函数闭合花括号）
- 修复 ARC 模式下 `retain`/`release` 编译错误（改用 ARC 自动管理）
- 修复 `tryNextAPI` 递归块调用缺少 `__block` 限定符导致 API 回退逻辑失效
- 修复 PKC60sIsNewsFresh 函数缺少默认返回值

### v3.1
- 修复编译错误：pkcForceActive 声明移到文件顶部，解决 Logos 预处理器 "%hook does not make sense inside a block" 错误

### v3.0
- 修复关键问题：API重试成功后调用completion时pkcForceActive已过期，现在在每次调用completion前重新设置
- 所有completion调用路径（成功/fallback/异常）都设置pkcForceActive=YES
- 全面审查确认：不闪退、不影响正常消息/语音发送、不影响PKC其他功能

### v2.2
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
