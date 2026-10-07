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

## 版本

- **v1.1** — 当前版本（修复启动闪退 + 60秒新闻 + 消息发送）
