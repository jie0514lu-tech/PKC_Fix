#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

// PKC 60秒新闻修复插件
// 仅修复两个问题，不修改 PKC 其他任何功能：
//
// 问题1：60秒新闻只发送标题/空白/乱码
//   原因：原 PKC 使用的 api.lbbb.cc API 已不可靠（超时/只返回标题）
//   修复：hook +[WenAnAPIManager get60s:] 使用多 API 源 + 正确解析
//
// 问题2：微信 8.0.78/79 消息发送方式变化导致发送失败/闪退
//   原因：PKC 调用 WeixinContentLogicController AddMsg:MsgWrap: 发送消息，
//         但微信 8.0.78/79 中该方法已不存在（父类只有 OnAddMsg:MsgWrap:，
//         CMessageMgr 才有 AddMsg:MsgWrap:），导致消息发送失败或闪退
//   修复：为 WeixinContentLogicController 添加 AddMsg:MsgWrap: 方法，
//         转发到 CMessageMgr AddMsg:MsgWrap: 正确发送
//
// 所有操作包裹 @try/@catch 防止闪退

// === 多 API 源（按优先级排序，自动回退） ===
// 原 PKC 使用的 api.lbbb.cc/api/60s 和 /api/60miao 已不可靠：
// - /api/60s 经常超时或重定向过多
// - /api/60miao 只返回标题，没有新闻条目
// 这里使用多个免费 API 兜底
static NSArray *PKC60sGetAPIList(void) {
    static NSArray *list = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[
            @"https://60s.viki.moe/v2/60s",
            @"https://api.auth.top/api/60s?format=json&key=9bf3ef53ef0060b5",
            @"https://api.qqsuu.cn/api/dm-60s",
            @"https://api.oioweb.cn/api/common/60s",
            @"https://api.03c3.cn/api/zb",
            @"https://api.lbbb.cc/api/60s",
            @"https://api.lbbb.cc/api/60miao"
        ];
    });
    return list;
}

#pragma mark - 新闻获取与解析

@interface PKC60sNewsFetcher : NSObject
+ (void)fetchNewsWithCompletion:(void (^)(NSString *newsText))completion;
@end

@implementation PKC60sNewsFetcher

+ (void)fetchNewsWithCompletion:(void (^)(NSString *))completion {
    if (!completion) return;

    NSArray *apiList = PKC60sGetAPIList();
    __block NSInteger currentIndex = 0;

    void (^tryNextAPI)(void) = nil;
    tryNextAPI = ^{
        if (currentIndex >= apiList.count) {
            // 所有 API 都失败了，返回一条提示信息而不是 nil（防止 PKC 闪退）
            NSString *fallback = @"📰 每日60秒新闻\n\n抱歉，今日新闻获取失败，请稍后重试。";
            completion(fallback);
            return;
        }

        NSString *urlString = apiList[currentIndex];
        currentIndex++;

        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            tryNextAPI();
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 20.0;
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            @try {
                if (error || !data) {
                    NSLog(@"[PKC60sFix] API %@ failed: %@", urlString, error);
                    tryNextAPI();
                    return;
                }

                // 检查 HTTP 状态码
                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                if ([httpResp isKindOfClass:[NSHTTPURLResponse class]] && httpResp.statusCode != 200) {
                    NSLog(@"[PKC60sFix] API %@ HTTP status: %ld", urlString, (long)httpResp.statusCode);
                    tryNextAPI();
                    return;
                }

                // 解析数据
                NSString *newsText = [self parseNewsData:data];
                if (newsText.length > 0) {
                    completion(newsText);
                } else {
                    NSLog(@"[PKC60sFix] API %@ returned empty content", urlString);
                    tryNextAPI();
                }
            } @catch (NSException *exception) {
                NSLog(@"[PKC60sFix] Exception parsing %@: %@", urlString, exception);
                tryNextAPI();
            }
        }];
        [task resume];
    };

    tryNextAPI();
}

// 解析新闻数据，兼容多种 API 返回格式
+ (NSString *)parseNewsData:(NSData *)data {
    if (!data || data.length == 0) return nil;

    // 先尝试解析 JSON
    NSDictionary *json = nil;
    @try {
        json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } @catch (NSException *e) {
        json = nil;
    }

    if ([json isKindOfClass:[NSDictionary class]]) {
        return [self parseJSON:json];
    }

    // 如果不是 JSON，尝试作为纯文本
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
    }
    if (!text) return nil;

    // 去掉首尾引号和空白
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" \t\r\n"]];

    // 过滤 HTML 响应
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"<"] || [trimmed hasSuffix:@">"]) return nil;
    if (trimmed.length < 20) return nil;
    if ([trimmed containsString:@"error"] || [trimmed isEqualToString:@"no data"]) return nil;

    return text;
}

// 解析 JSON 格式的新闻
+ (NSString *)parseJSON:(NSDictionary *)json {
    if (!json) return nil;

    // 检查 API 错误码
    id codeVal = json[@"code"];
    if (codeVal && [codeVal respondsToSelector:@selector(integerValue)]) {
        NSInteger code = [codeVal integerValue];
        if (code != 200 && code != 0 && code != 1) {
            return nil;
        }
    }

    // 获取 data 字典（大多数 API 的结构）
    NSDictionary *dataDict = nil;
    id dataVal = json[@"data"];
    if ([dataVal isKindOfClass:[NSDictionary class]]) {
        dataDict = dataVal;
    } else if ([dataVal isKindOfClass:[NSString class]]) {
        // data 是字符串（有些 API 直接返回新闻文本）
        NSString *str = (NSString *)dataVal;
        if (str.length > 20) return str;
    }

    NSDictionary *searchDict = dataDict ? dataDict : json;

    // 查找标题
    NSString *title = nil;
    for (NSString *key in @[@"title", @"headline", @"news_title"]) {
        id val = searchDict[key];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            title = val;
            break;
        }
    }

    // 查找新闻列表
    NSArray *newsArray = nil;
    for (NSString *key in @[@"news", @"newslist", @"news_list", @"list", @"items"]) {
        id val = searchDict[key];
        if ([val isKindOfClass:[NSArray class]] && [val count] > 0) {
            newsArray = val;
            break;
        }
    }

    // 查找微语/每日一句
    NSString *tip = nil;
    for (NSString *key in @[@"tip", @"weiyu", @"quote", @"motto", @"note", @"每日一句"]) {
        id val = searchDict[key];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            tip = val;
            break;
        }
    }

    // 如果没有找到新闻数组，尝试直接用 content 字段
    if (newsArray.count == 0) {
        for (NSString *key in @[@"content", @"news_text", @"text"]) {
            id val = searchDict[key];
            if ([val isKindOfClass:[NSString class]] && [val length] > 20) {
                return [self cleanText:val];
            }
        }
    }

    // 组装新闻文本
    NSMutableString *result = [NSMutableString string];

    // 标题
    if (title.length > 0) {
        [result appendString:[self cleanText:title]];
        [result appendString:@"\n\n"];
    } else {
        [result appendString:@"📰 每日60秒新闻\n\n"];
    }

    // 新闻条目
    NSInteger index = 1;
    for (id item in newsArray) {
        NSString *newsItem = nil;
        if ([item isKindOfClass:[NSString class]]) {
            newsItem = (NSString *)item;
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            // 尝试从字典中提取新闻文本
            for (NSString *key in @[@"content", @"title", @"text", @"news", @"desc", @"message"]) {
                id val = item[key];
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                    newsItem = val;
                    break;
                }
            }
        }

        if (newsItem.length > 0) {
            NSString *cleaned = [self cleanText:newsItem];
            if (cleaned.length > 0) {
                [result appendFormat:@"%ld. %@\n", (long)index, cleaned];
                index++;
            }
        }
    }

    // 微语
    if (tip.length > 0) {
        [result appendString:@"\n💡 "];
        [result appendString:[self cleanText:tip]];
    }

    // 确保至少有新闻内容（否则返回 nil 让下一个 API 尝试）
    if (index == 1 && tip.length == 0) {
        return nil;
    }

    return result;
}

// 清理文本：去除控制字符、首尾空白
+ (NSString *)cleanText:(NSString *)text {
    if (!text || ![text isKindOfClass:[NSString class]]) return nil;
    if (text.length == 0) return nil;

    // 去除控制字符（保留换行和制表符）
    NSMutableString *cleaned = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\t' || c == '\r' || (c >= 0x20 && c != 0x7F)) {
            [cleaned appendFormat:@"%C", c];
        }
    }

    // 去除首尾空白
    NSString *result = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return result.length > 0 ? result : nil;
}

@end

#pragma mark - Hook WenAnAPIManager

// 原 PKC 的 +[WenAnAPIManager get60s:] 方法使用 api.lbbb.cc API，
// 该 API 已不可靠（超时/只返回标题），导致发送空白内容。
// 这里替换为使用多 API 源的可靠实现。
//
// 注意：我们只 hook 这一个方法，不影响 PKC 其他任何功能。
// 其他 WenAnAPIManager 方法（鸡汤、英语句子、文案等）保持不变。

%hook WenAnAPIManager

+ (void)get60s:(id)completion {
    @try {
        // 使用可靠的多 API 获取新闻
        [PKC60sNewsFetcher fetchNewsWithCompletion:^(NSString *newsText) {
            @try {
                // 确保 newsText 不为 nil 且非空（防止 PKC 闪退）
                if (!newsText || newsText.length == 0) {
                    newsText = @"📰 每日60秒新闻\n\n抱歉，今日新闻获取失败，请稍后重试。";
                }

                // 调用 PKC 原始的 completion block
                // 注意：不调用 %orig，因为原始 API 已失效，且签名可能不匹配导致闪退
                if (completion) {
                    void (^block)(id) = (void (^)(id))completion;
                    block(newsText);
                }
            } @catch (NSException *e) {
                NSLog(@"[PKC60sFix] Error invoking completion: %@", e);
            }
        }];
    } @catch (NSException *e) {
        NSLog(@"[PKC60sFix] Error in get60s: %@", e);
        // 出错时直接调用 completion 传入兜底内容，不调用 %orig 避免签名不匹配闪退
        @try {
            if (completion) {
                NSString *fallback = @"📰 每日60秒新闻\n\n抱歉，今日新闻获取失败，请稍后重试。";
                void (^block)(id) = (void (^)(id))completion;
                block(fallback);
            }
        } @catch (NSException *e2) {
            NSLog(@"[PKC60sFix] Error in fallback: %@", e2);
        }
    }
}

%end

#pragma mark - 修复消息发送方式（微信 8.0.78/79 兼容性）

// 微信 8.0.78/79 中，WeixinContentLogicController 不再有 AddMsg:MsgWrap: 方法
// （父类 BaseMsgContentLogicController 只有 OnAddMsg:MsgWrap:）
// PKC 调用 [WeixinContentLogicController AddMsg:MsgWrap:] 发送消息时，
// 由于方法不存在，导致消息发送失败（空白/乱码）或闪退。
//
// 修复：为 WeixinContentLogicController 添加 AddMsg:MsgWrap: 方法，
// 转发到 CMessageMgr AddMsg:MsgWrap:（该方法在微信 8.0.78/79 中存在）
//
// 注意：此修复不影响 PKC 其他功能，只是让 PKC 的消息发送在新版微信中正常工作

%hook WeixinContentLogicController

// 添加/替换 AddMsg:MsgWrap: 方法
// 使用 objc_msgSend / performSelector 调用微信内部方法，避免编译器报错
// （编译器没有微信类的头文件，直接用 [] 语法会报 "no known method"）
- (void)AddMsg:(id)msgWrap MsgWrap:(id)msgWrap2 {
    @try {
        // 方式1：通过 CMessageMgr 发送（最可靠）
        Class CMessageMgrClass = NSClassFromString(@"CMessageMgr");
        if (CMessageMgrClass) {
            id cMessageMgr = nil;
            @try {
                if ([CMessageMgrClass respondsToSelector:@selector(sharedInstance)]) {
                    cMessageMgr = [CMessageMgrClass performSelector:@selector(sharedInstance)];
                }
            } @catch (NSException *e) {
                NSLog(@"[PKC60sFix] CMessageMgr sharedInstance failed: %@", e);
            }

            // 备用：通过 MMServiceCenter 获取
            if (!cMessageMgr) {
                @try {
                    Class MMServiceCenterClass = NSClassFromString(@"MMServiceCenter");
                    if (MMServiceCenterClass && [MMServiceCenterClass respondsToSelector:@selector(defaultCenter)]) {
                        id center = [MMServiceCenterClass performSelector:@selector(defaultCenter)];
                        if (center && [center respondsToSelector:@selector(getService:)]) {
                            cMessageMgr = [center performSelector:@selector(getService:) withObject:CMessageMgrClass];
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[PKC60sFix] MMServiceCenter getService failed: %@", e);
                }
            }

            if (cMessageMgr && [cMessageMgr respondsToSelector:@selector(AddMsg:MsgWrap:)]) {
                // 用 objc_msgSend 调用 AddMsg:MsgWrap:（第二参数传 nil）
                ((void(*)(id, SEL, id, id))objc_msgSend)(cMessageMgr, @selector(AddMsg:MsgWrap:), msgWrap, nil);
                return;
            }
        }

        // 方式2：通过父类 OnAddMsg:MsgWrap: 发送
        if ([self respondsToSelector:@selector(OnAddMsg:MsgWrap:)]) {
            ((void(*)(id, SEL, id, id))objc_msgSend)(self, @selector(OnAddMsg:MsgWrap:), msgWrap, nil);
            return;
        }

        // 方式3：通过 SendTextMessage 发送
        @try {
            NSString *content = [msgWrap valueForKey:@"m_nsContent"];
            NSString *toUsr = [msgWrap valueForKey:@"m_nsToUsr"];
            if (content.length > 0 && toUsr.length > 0) {
                SEL sendSel = NSSelectorFromString(@"SendTextMessage:replyingMessage:isPasted:");
                if ([self respondsToSelector:sendSel]) {
                    ((void(*)(id, SEL, id, id, BOOL))objc_msgSend)(self, sendSel, content, nil, NO);
                    return;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[PKC60sFix] SendTextMessage fallback failed: %@", e);
        }

        NSLog(@"[PKC60sFix] All message sending methods failed");
    } @catch (NSException *e) {
        NSLog(@"[PKC60sFix] Error in AddMsg:MsgWrap: %@", e);
    }
}

%end
