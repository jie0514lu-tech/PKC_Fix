#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

// PKC 60秒新闻修复插件 v1.3
// 仅修复两个问题，不修改 PKC 其他任何功能：
//
// 问题1：60秒新闻只发送标题/空白/乱码
//   原因：原 PKC 使用的 api.lbbb.cc API 已不可靠
//   修复：hook +[WenAnAPIManager get60s:] 使用多 API 源 + 正确解析
//         优先使用 text 格式 API（已包含日期/星期/农历/新闻/微语/来源）
//         JSON 格式作为回退，自行补充日期/星期/农历
//
// 问题2：微信 8.0.78/79 消息发送方式变化导致发送失败/闪退
//   修复：只在方法不存在时用 class_addMethod 添加转发，不覆盖已有方法
//
// 所有操作包裹 @try/@catch 防止闪退

// === 多 API 源（按优先级排序，自动回退） ===
// text 格式优先（已包含完整格式：日期/星期/农历/新闻/微语/来源）
static NSArray *PKC60sGetAPIList(void) {
    static NSArray *list = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[
            @"https://60s.viki.moe/v2/60s?format=text",   // text格式，完整内容
            @"https://60s.viki.moe/v2/60s",                 // JSON格式，回退
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

#pragma mark - 日期/星期/农历格式化

// 获取格式化的日期头（公历+星期+农历）
static NSString *PKC60sFormatDateHeader(void) {
    @try {
        NSDate *now = [NSDate date];
        NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        [gregorian setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"]];

        // 公历日期
        NSDateComponents *comps = [gregorian components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:now];
        NSInteger year = [comps year];
        NSInteger month = [comps month];
        NSInteger day = [comps day];
        NSInteger weekday = [comps weekday]; // 1=周日, 2=周一...

        // 星期
        NSArray *weekdays = @[@"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
        NSString *weekdayStr = weekdays[(weekday - 1) % 7];

        // 农历日期
        NSString *lunarStr = @"";
        @try {
            NSCalendar *chineseCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierChinese];
            [chineseCalendar setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"]];
            NSDateComponents *lunarComps = [chineseCalendar componentsFromDate:now];

            // 农历天干地支年份
            NSInteger lunarYear = [lunarComps year];
            NSArray *tiangan = @[@"甲", @"乙", @"丙", @"丁", @"戊", @"己", @"庚", @"辛", @"壬", @"癸"];
            NSArray *dizhi = @[@"子", @"丑", @"寅", @"卯", @"辰", @"巳", @"午", @"未", @"申", @"酉", @"戌", @"亥"];
            NSArray *shengxiao = @[@"鼠", @"牛", @"虎", @"兔", @"龙", @"蛇", @"马", @"羊", @"猴", @"鸡", @"狗", @"猪"];
            NSString *gan = tiangan[(lunarYear - 1) % 10];
            NSString *zhi = dizhi[(lunarYear - 1) % 12];
            NSString *sx = shengxiao[(lunarYear - 1) % 12];

            // 农历月日
            NSInteger lunarMonth = [lunarComps month];
            NSInteger lunarDay = [lunarComps day];
            // 是否闰月
            BOOL isLeap = [lunarComps isLeapMonth];

            NSArray *lunarMonths = @[@"正月", @"二月", @"三月", @"四月", @"五月", @"六月", @"七月", @"八月", @"九月", @"十月", @"十一月", @"十二月"];
            NSArray *lunarDays = @[
                @"初一", @"初二", @"初三", @"初四", @"初五", @"初六", @"初七", @"初八", @"初九", @"初十",
                @"十一", @"十二", @"十三", @"十四", @"十五", @"十六", @"十七", @"十八", @"十九", @"二十",
                @"廿一", @"廿二", @"廿三", @"廿四", @"廿五", @"廿六", @"廿七", @"廿八", @"廿九", @"三十"
            ];

            NSString *monthStr = @"";
            if (lunarMonth >= 1 && lunarMonth <= 12) {
                monthStr = lunarMonths[lunarMonth - 1];
            }
            if (isLeap) {
                monthStr = [@"闰" stringByAppendingString:monthStr];
            }
            NSString *dayStr = @"";
            if (lunarDay >= 1 && lunarDay <= 30) {
                dayStr = lunarDays[lunarDay - 1];
            }

            lunarStr = [NSString stringWithFormat:@"%@%@年%@月%@ %@", gan, zhi, sx, monthStr, dayStr];
        } @catch (NSException *e) {
            // 农历计算失败，跳过
        }

        // 节日检测（简单版）
        NSString *holiday = @"";
        NSDictionary *solarHolidays = @{
            @"1-1": @"元旦",
            @"2-14": @"情人节",
            @"3-8": @"妇女节",
            @"3-12": @"植树节",
            @"4-1": @"愚人节",
            @"5-1": @"劳动节",
            @"5-4": @"青年节",
            @"6-1": @"儿童节",
            @"7-1": @"建党节",
            @"8-1": @"建军节",
            @"9-10": @"教师节",
            @"10-1": @"国庆节",
            @"12-25": @"圣诞节",
        };
        NSString *monthDay = [NSString stringWithFormat:@"%ld-%ld", (long)month, (long)day];
        if (solarHolidays[monthDay]) {
            holiday = [NSString stringWithFormat:@" %@", solarHolidays[monthDay]];
        }

        return [NSString stringWithFormat:@"%@年%ld月%ld日 %@ %@%@",
                @(year), (long)month, (long)day, weekdayStr, lunarStr, holiday];
    } @catch (NSException *e) {
        return @"";
    }
}

#pragma mark - 新闻获取与解析

@interface PKC60sNewsFetcher : NSObject
+ (void)fetchNewsWithCompletion:(void (^)(NSString *newsText))completion;
+ (NSString *)parseNewsData:(NSData *)data isTextAPI:(BOOL)isTextAPI;
+ (NSString *)parseJSON:(NSDictionary *)json;
+ (NSString *)cleanText:(NSString *)text;
@end

@implementation PKC60sNewsFetcher

+ (void)fetchNewsWithCompletion:(void (^)(NSString *))completion {
    if (!completion) return;

    NSArray *apiList = PKC60sGetAPIList();
    __block NSInteger currentIndex = 0;

    void (^tryNextAPI)(void) = nil;
    tryNextAPI = ^{
        if (currentIndex >= apiList.count) {
            // 所有 API 都失败了
            NSString *dateHeader = PKC60sFormatDateHeader();
            NSString *fallback = [NSString stringWithFormat:@"📰 每日60秒新闻\n%@在这里，每天60秒读懂世界\n\n抱歉，今日新闻获取失败，请稍后重试。\n\n📢 来源：60秒读懂世界", dateHeader.length > 0 ? [dateHeader stringByAppendingString:@"\n"] : @""];
            completion(fallback);
            return;
        }

        NSString *urlString = apiList[currentIndex];
        BOOL isTextAPI = [urlString containsString:@"format=text"];
        currentIndex++;

        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            tryNextAPI();
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 20.0;
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
        [request setValue:isTextAPI ? @"text/plain" : @"application/json" forHTTPHeaderField:@"Accept"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            @try {
                if (error || !data) {
                    NSLog(@"[PKC60sFix] API %@ failed: %@", urlString, error);
                    tryNextAPI();
                    return;
                }

                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                if ([httpResp isKindOfClass:[NSHTTPURLResponse class]] && httpResp.statusCode != 200) {
                    NSLog(@"[PKC60sFix] API %@ HTTP status: %ld", urlString, (long)httpResp.statusCode);
                    tryNextAPI();
                    return;
                }

                NSString *newsText = [self parseNewsData:data isTextAPI:isTextAPI];
                if (newsText.length > 20) {
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

// 解析新闻数据
+ (NSString *)parseNewsData:(NSData *)data isTextAPI:(BOOL)isTextAPI {
    if (!data || data.length == 0) return nil;

    // text 格式 API：直接返回文本（已包含日期/星期/农历/新闻/微语/来源）
    if (isTextAPI) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) {
            text = [[NSString alloc] initWithData:data encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
        }
        if (!text) return nil;

        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // 过滤 HTML 响应
        if ([text hasPrefix:@"<"] || [text hasSuffix:@">"]) return nil;
        if (text.length < 20) return nil;

        // 验证是有效的新闻文本（包含数字编号的新闻条目）
        if ([text containsString:@"."] || [text containsString:@"、"] || [text containsString:@"："] || text.length > 50) {
            return text;
        }
        return nil;
    }

    // JSON 格式 API
    NSDictionary *json = nil;
    @try {
        json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } @catch (NSException *e) {
        json = nil;
    }

    if ([json isKindOfClass:[NSDictionary class]]) {
        return [self parseJSON:json];
    }

    // 纯文本回退
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
    }
    if (!text) return nil;

    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text hasPrefix:@"<"] || [text hasSuffix:@">"]) return nil;
    if (text.length < 20) return nil;

    return text;
}

// 解析 JSON 格式的新闻，组装完整格式
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

    // 获取 data 字典
    NSDictionary *dataDict = nil;
    id dataVal = json[@"data"];
    if ([dataVal isKindOfClass:[NSDictionary class]]) {
        dataDict = dataVal;
    } else if ([dataVal isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)dataVal;
        if (str.length > 20) return [self cleanText:str];
    }

    NSDictionary *searchDict = dataDict ? dataDict : json;

    // 查找标题
    NSString *title = nil;
    for (NSString *key in @[@"name", @"title", @"headline", @"news_title", @"subtitle"]) {
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
        for (NSString *key in @[@"content", @"news_text", @"text", @"description"]) {
            id val = searchDict[key];
            if ([val isKindOfClass:[NSString class]] && [val length] > 20) {
                // content 可能已经包含完整格式
                NSString *content = [self cleanText:val];
                if (content.length > 50) {
                    return content;
                }
            }
        }
    }

    // 如果还是没有新闻数组，检查 newslist 里的 description
    if (newsArray.count == 0) {
        for (NSString *key in @[@"newslist", @"news_list"]) {
            id val = searchDict[key];
            if ([val isKindOfClass:[NSArray class]] && [val count] > 0) {
                // lbbb.cc 格式：newslist[0].description 包含完整新闻文本
                id firstItem = [val firstObject];
                if ([firstItem isKindOfClass:[NSDictionary class]]) {
                    NSString *desc = firstItem[@"description"];
                    if (desc.length > 50) {
                        return [self cleanText:desc];
                    }
                    NSString *content = firstItem[@"content"];
                    if (content.length > 50) {
                        return [self cleanText:content];
                    }
                }
            }
        }
    }

    // 组装新闻文本
    NSMutableString *result = [NSMutableString string];

    // 日期头
    NSString *dateHeader = PKC60sFormatDateHeader();
    if (dateHeader.length > 0) {
        [result appendFormat:@"%@\n", dateHeader];
    }

    // 标题
    if (title.length > 0) {
        [result appendString:[self cleanText:title]];
        [result appendString:@"\n\n"];
    } else {
        [result appendString:@"在这里，每天60秒读懂世界\n\n"];
    }

    // 新闻条目
    NSInteger index = 1;
    for (id item in newsArray) {
        NSString *newsItem = nil;
        if ([item isKindOfClass:[NSString class]]) {
            newsItem = (NSString *)item;
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in @[@"content", @"title", @"text", @"news", @"desc", @"message", @"description"]) {
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
        [result appendString:@"\n【微语】"];
        [result appendString:[self cleanText:tip]];
        [result appendString:@"\n"];
    }

    // 来源
    [result appendString:@"\n📢 来源：60秒读懂世界"];

    // 确保至少有新闻内容
    if (index == 1 && tip.length == 0) {
        return nil;
    }

    return result;
}

// 清理文本：去除控制字符、首尾空白
+ (NSString *)cleanText:(NSString *)text {
    if (!text || ![text isKindOfClass:[NSString class]]) return nil;
    if (text.length == 0) return nil;

    NSMutableString *cleaned = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\t' || c == '\r' || (c >= 0x20 && c != 0x7F)) {
            [cleaned appendFormat:@"%C", c];
        }
    }

    NSString *result = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return result.length > 0 ? result : nil;
}

@end

#pragma mark - Hook WenAnAPIManager

// 原 PKC 的 +[WenAnAPIManager get60s:] 方法使用 api.lbbb.cc API，
// 该 API 已不可靠（超时/只返回标题），导致发送空白内容。
// 这里替换为使用多 API 源的可靠实现。
// PKC 的定时器在到点时调用此方法，传入 completion block，
// 我们获取新闻后调用 completion 传回文本，PKC 再发送。
// 不调用 %orig 避免原始 API 失效导致闪退。

%hook WenAnAPIManager

+ (void)get60s:(id)completion {
    @try {
        [PKC60sNewsFetcher fetchNewsWithCompletion:^(NSString *newsText) {
            @try {
                if (!newsText || newsText.length == 0) {
                    NSString *dateHeader = PKC60sFormatDateHeader();
                    newsText = [NSString stringWithFormat:@"📰 每日60秒新闻\n%@在这里，每天60秒读懂世界\n\n抱歉，今日新闻获取失败，请稍后重试。\n\n📢 来源：60秒读懂世界", dateHeader.length > 0 ? [dateHeader stringByAppendingString:@"\n"] : @""];
                }

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
        @try {
            if (completion) {
                NSString *dateHeader = PKC60sFormatDateHeader();
                NSString *fallback = [NSString stringWithFormat:@"📰 每日60秒新闻\n%@在这里，每天60秒读懂世界\n\n抱歉，今日新闻获取失败，请稍后重试。\n\n📢 来源：60秒读懂世界", dateHeader.length > 0 ? [dateHeader stringByAppendingString:@"\n"] : @""];
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
//
// 只在 WeixinContentLogicController 没有 AddMsg:MsgWrap: 方法时才添加
// 如果微信已自带此方法，完全不干预，避免影响正常消息/语音发送
// 用 class_addMethod 在 %ctor 中检查并添加，不会覆盖已有方法

static void pkc_forwardAddMsg(id self, SEL _cmd, id msgWrap, id msgWrap2) {
    @try {
        // 方式1：通过 CMessageMgr 发送
        Class CMessageMgrClass = NSClassFromString(@"CMessageMgr");
        if (CMessageMgrClass) {
            id cMessageMgr = nil;
            @try {
                if ([CMessageMgrClass respondsToSelector:@selector(sharedInstance)]) {
                    cMessageMgr = [CMessageMgrClass performSelector:@selector(sharedInstance)];
                }
            } @catch (NSException *e) {}

            if (!cMessageMgr) {
                @try {
                    Class MMServiceCenterClass = NSClassFromString(@"MMServiceCenter");
                    if (MMServiceCenterClass && [MMServiceCenterClass respondsToSelector:@selector(defaultCenter)]) {
                        id center = [MMServiceCenterClass performSelector:@selector(defaultCenter)];
                        if (center && [center respondsToSelector:@selector(getService:)]) {
                            cMessageMgr = [center performSelector:@selector(getService:) withObject:CMessageMgrClass];
                        }
                    }
                } @catch (NSException *e) {}
            }

            if (cMessageMgr && [cMessageMgr respondsToSelector:@selector(AddMsg:MsgWrap:)]) {
                ((void(*)(id, SEL, id, id))objc_msgSend)(cMessageMgr, @selector(AddMsg:MsgWrap:), msgWrap, nil);
                return;
            }
        }

        // 方式2：通过 OnAddMsg:MsgWrap:
        id selfId = self;
        if ([selfId respondsToSelector:@selector(OnAddMsg:MsgWrap:)]) {
            ((void(*)(id, SEL, id, id))objc_msgSend)(self, @selector(OnAddMsg:MsgWrap:), msgWrap, nil);
            return;
        }

        // 方式3：SendTextMessage
        @try {
            NSString *content = [msgWrap valueForKey:@"m_nsContent"];
            NSString *toUsr = [msgWrap valueForKey:@"m_nsToUsr"];
            if (content.length > 0 && toUsr.length > 0) {
                SEL sendSel = NSSelectorFromString(@"SendTextMessage:replyingMessage:isPasted:");
                if ([selfId respondsToSelector:sendSel]) {
                    ((void(*)(id, SEL, id, id, BOOL))objc_msgSend)(self, sendSel, content, nil, NO);
                    return;
                }
            }
        } @catch (NSException *e) {}
    } @catch (NSException *e) {}
}

%ctor {
    @autoreleasepool {
        // 只在方法不存在时添加，不覆盖微信原有方法
        Class wcClass = NSClassFromString(@"WeixinContentLogicController");
        if (wcClass) {
            SEL addMsgSel = NSSelectorFromString(@"AddMsg:MsgWrap:");
            if (![wcClass instancesRespondToSelector:addMsgSel]) {
                class_addMethod(wcClass, addMsgSel, (IMP)pkc_forwardAddMsg, "v@:@@");
                NSLog(@"[PKC60sFix] Added AddMsg:MsgWrap: to WeixinContentLogicController (was missing)");
            } else {
                NSLog(@"[PKC60sFix] AddMsg:MsgWrap: already exists, not touching");
            }
        }
    }
}
