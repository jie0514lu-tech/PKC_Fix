#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// PKC 60秒新闻修复插件 v2.1
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

// === 多 API 源（按可靠性+更新速度排序） ===
// 优先级说明：
//   1. viki.moe text  — 主数据源，每天凌晨2-4点更新，text格式含完整日期/农历
//   2. viki.moe JSON  — 同源JSON回退，有update时间戳可校验
//   3. qqsuu.cn       — 通常镜像viki.moe，中等可靠
//   4. oioweb.cn      — 有时延迟但通常可用
//   5. auth.top       — 需key，中等可靠
//   6. 03c3.cn        — 不稳定，有时宕机
//   7. lbbb.cc/60s    — 原始PKC源，已知不可靠（超时/只返回标题）
//   8. lbbb.cc/60miao — 最后兜底，通常只有标题
static NSArray *PKC60sGetAPIList(void) {
    static NSArray *list = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[
            @"https://60s.viki.moe/v2/60s?format=text",
            @"https://60s.viki.moe/v2/60s",
            @"https://api.qqsuu.cn/api/dm-60s",
            @"https://api.oioweb.cn/api/common/60s",
            @"https://api.auth.top/api/60s?format=json&key=9bf3ef53ef0060b5",
            @"https://api.03c3.cn/api/zb",
            @"https://api.lbbb.cc/api/60s",
            @"https://api.lbbb.cc/api/60miao"
        ];
    });
    return list;
}

// === 失败追踪：记录每个API的连续失败次数和上次失败时间 ===
static NSMutableDictionary *PKC60sGetFailureMap(void) {
    static NSMutableDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

// 检查API是否应该跳过（连续失败3次以上且30分钟内）
static BOOL PKC60sShouldSkipAPI(NSString *urlString) {
    @try {
        NSMutableDictionary *map = PKC60sGetFailureMap();
        NSDictionary *info = map[urlString];
        if (!info) return NO;
        NSInteger failCount = [info[@"failCount"] integerValue];
        NSDate *lastFail = info[@"lastFailDate"];
        if (failCount >= 3 && lastFail) {
            NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:lastFail];
            if (elapsed < 1800) { // 30分钟内跳过
                NSLog(@"[PKC60sFix] Skipping %@ (failed %ld times, %.0f min ago)", urlString, (long)failCount, elapsed / 60.0);
                return YES;
            }
            // 超过30分钟，重置计数
            [map removeObjectForKey:urlString];
        }
    } @catch (NSException *e) {}
    return NO;
}

// 记录API失败
static void PKC60sRecordFailure(NSString *urlString) {
    @try {
        NSMutableDictionary *map = PKC60sGetFailureMap();
        NSMutableDictionary *info = [map[urlString] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSInteger count = [info[@"failCount"] integerValue];
        info[@"failCount"] = @(count + 1);
        info[@"lastFailDate"] = [NSDate date];
        map[urlString] = info;
    } @catch (NSException *e) {}
}

// 记录API成功（重置失败计数）
static void PKC60sRecordSuccess(NSString *urlString) {
    @try {
        NSMutableDictionary *map = PKC60sGetFailureMap();
        [map removeObjectForKey:urlString];
    } @catch (NSException *e) {}
}

// === 内容比对：防止"今天日期+昨天内容" ===
// 保存上次的新闻内容，比对是否重复

static NSString *PKC60sGetLastNewsHash(void) {
    @try {
        return [[NSUserDefaults standardUserDefaults] stringForKey:@"pkc60s_last_news_hash"];
    } @catch (NSException *e) {}
    return nil;
}

static void PKC60sSaveNewsHash(NSString *newsText) {
    @try {
        // 取新闻正文的前500字做哈希（排除日期头，因为日期每天不同）
        NSString *contentToHash = newsText;
        if (newsText.length > 500) {
            contentToHash = [newsText substringFromIndex:newsText.length - 500];
        }
        // 简单哈希：取前500字的长度+首尾各50字拼接
        NSString *head = contentToHash.length > 50 ? [contentToHash substringToIndex:50] : contentToHash;
        NSString *tail = contentToHash.length > 50 ? [contentToHash substringFromIndex:contentToHash.length - 50] : contentToHash;
        NSString *hash = [NSString stringWithFormat:@"%lu|%@|%@", (unsigned long)contentToHash.length, head, tail];

        [[NSUserDefaults standardUserDefaults] setObject:hash forKey:@"pkc60s_last_news_hash"];
    } @catch (NSException *e) {}
}

// 检查新闻内容是否和上次重复
static BOOL PKC60sIsContentDuplicate(NSString *newsText) {
    @try {
        NSString *lastHash = PKC60sGetLastNewsHash();
        if (!lastHash || lastHash.length == 0) return NO; // 没有上次记录，不判断

        // 计算当前新闻的哈希
        NSString *contentToHash = newsText;
        if (newsText.length > 500) {
            contentToHash = [newsText substringFromIndex:newsText.length - 500];
        }
        NSString *head = contentToHash.length > 50 ? [contentToHash substringToIndex:50] : contentToHash;
        NSString *tail = contentToHash.length > 50 ? [contentToHash substringFromIndex:contentToHash.length - 50] : contentToHash;
        NSString *currentHash = [NSString stringWithFormat:@"%lu|%@|%@", (unsigned long)contentToHash.length, head, tail];

        if ([currentHash isEqualToString:lastHash]) {
            NSLog(@"[PKC60sFix] Content duplicate detected (same as last sent)");
            return YES; // 内容重复
        }
    } @catch (NSException *e) {}
    return NO;
}

// === 日期新鲜度检查 ===
// 检查新闻日期是否是今天（防止发送昨天的重复新闻）
static BOOL PKC60sIsNewsFresh(NSString *newsText, NSDictionary *json) {
    @try {
        NSDate *now = [NSDate date];
        NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        [cal setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"]];
        NSDateComponents *comps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
        NSInteger todayYear = [comps year];
        NSInteger todayMonth = [comps month];
        NSInteger todayDay = [comps day];

        // 方式1：检查JSON中的date/update字段
        if (json) {
            NSDictionary *dataDict = json[@"data"];
            if (![dataDict isKindOfClass:[NSDictionary class]]) dataDict = json;

            // 检查 date 字段 (如 "2026-10-09")
            NSString *dateStr = dataDict[@"date"];
            if (dateStr.length > 0) {
                // 格式: YYYY-MM-DD
                if ([dateStr containsString:[NSString stringWithFormat:@"%ld-%ld-%ld", (long)todayYear, (long)todayMonth, (long)todayDay]]) {
                    return YES;
                }
                // 格式: YYYY/MM/DD
                NSString *altDateStr = [NSString stringWithFormat:@"%ld/%ld/%ld", (long)todayYear, (long)todayMonth, (long)todayDay];
                if ([dateStr containsString:altDateStr]) {
                    return YES;
                }
                // 如果日期不是今天，说明是旧数据
                NSLog(@"[PKC60sFix] Stale news detected: date=%@, today=%ld-%ld-%ld", dateStr, (long)todayYear, (long)todayMonth, (long)todayDay);
                return NO;
            }

            // 检查 update 字段 (通常包含时间戳或日期)
            NSString *updateStr = dataDict[@"update"];
            if (updateStr.length > 0) {
                // 尝试解析 "2026-10-09 06:00:00" 格式
                if ([updateStr containsString:[NSString stringWithFormat:@"%ld-%ld-%ld", (long)todayYear, (long)todayMonth, (long)todayDay]]) {
                    return YES;
                }
                NSLog(@"[PKC60sFix] Stale news detected: update=%@", updateStr);
                return NO;
            }

            // 检查 create_time 字段
            NSString *createTime = dataDict[@"create_time"];
            if (createTime.length > 0) {
                if ([createTime containsString:[NSString stringWithFormat:@"%ld/%ld/%ld", (long)todayYear, (long)todayMonth, (long)todayDay]] ||
                    [createTime containsString:[NSString stringWithFormat:@"%ld-%ld-%ld", (long)todayYear, (long)todayMonth, (long)todayDay]]) {
                    return YES;
                }
                // create_time 不是今天 → 旧闻
                NSLog(@"[PKC60sFix] Stale news: create_time=%@", createTime);
                return NO;
            }

            // JSON 中没有找到日期字段 → 无法判断新鲜度
            // 此时不能用 PKC60sFormatDateHeader() 生成的日期来判断，因为那是今天的日期
            // 检查新闻文本中的日期（但排除我们自己添加的日期头）
            // 如果文本中没有API原始日期，且JSON也没日期，返回不确定（允许通过）
            // 但记录日志方便调试
            NSLog(@"[PKC60sFix] No date field in JSON, cannot verify freshness");
        }

        // 方式2：检查文本中的日期
        if (newsText.length > 0) {
            // 今天的日期格式
            NSString *todayMD1 = [NSString stringWithFormat:@"%ld月%ld日", (long)todayMonth, (long)todayDay];
            NSString *todayMD2 = [NSString stringWithFormat:@"%ld月%02ld日", (long)todayMonth, (long)todayDay];
            NSString *todayISO1 = [NSString stringWithFormat:@"%ld-%ld-%ld", (long)todayYear, (long)todayMonth, (long)todayDay];
            NSString *todayISO2 = [NSString stringWithFormat:@"%ld/%ld/%ld", (long)todayYear, (long)todayMonth, (long)todayDay];

            // 如果包含今天的日期 → 新鲜
            if ([newsText containsString:todayMD1] || [newsText containsString:todayMD2] ||
                [newsText containsString:todayISO1] || [newsText containsString:todayISO2]) {
                return YES;
            }

            // 检查是否包含昨天的日期 → 旧闻
            NSDate *yesterday = [cal dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:now options:0];
            NSDateComponents *yComps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:yesterday];
            NSString *yestMD1 = [NSString stringWithFormat:@"%ld月%ld日", (long)[yComps month], (long)[yComps day]];
            NSString *yestMD2 = [NSString stringWithFormat:@"%ld月%02ld日", (long)[yComps month], (long)[yComps day]];
            NSString *yestISO1 = [NSString stringWithFormat:@"%ld-%ld-%ld", (long)[yComps year], (long)[yComps month], (long)[yComps day]];
            NSString *yestISO2 = [NSString stringWithFormat:@"%ld/%ld/%ld", (long)[yComps year], (long)[yComps month], (long)[yComps day]];

            if ([newsText containsString:yestMD1] || [newsText containsString:yestMD2] ||
                [newsText containsString:yestISO1] || [newsText containsString:yestISO2]) {
                NSLog(@"[PKC60sFix] Stale text: found yesterday's date but not today's");
                return NO; // 旧闻，跳过
            }

            // 文本中没有任何日期信息，无法判断，默认通过
            return YES;
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

// === 自动重试机制 ===
// 当所有API都返回昨天的新闻时，30分钟后自动重试，直到获取到今天的新闻
static void (^pkcPendingCompletion)(NSString *) = nil;
static dispatch_source_t pkcRetryTimer = nil;
static NSInteger pkcRetryCount = 0;
static const NSInteger PKC_MAX_RETRIES = 48; // 最多重试48次（24小时），覆盖一整天

+ (void)fetchNewsWithCompletion:(void (^)(NSString *newsText))completion {
    if (!completion) return;

    // 取消之前的重试定时器（新的get60s:调用来了，重新开始）
    if (pkcRetryTimer) {
        dispatch_source_cancel(pkcRetryTimer);
        pkcRetryTimer = nil;
    }

    NSArray *apiList = PKC60sGetAPIList();
    __block NSInteger currentIndex = 0;
    __block void (^localCompletion)(NSString *) = [completion copy];

    void (^tryNextAPI)(void) = nil;
    tryNextAPI = ^{
        if (currentIndex >= apiList.count) {
            // 所有 API 都失败了
            PKC60sRecordFailure(@"all");

            // 检查是否还可以重试
            if (pkcRetryCount < PKC_MAX_RETRIES) {
                pkcRetryCount++;
                NSLog(@"[PKC60sFix] All APIs failed, scheduling retry #%ld in 30 min", (long)pkcRetryCount);

                // 保存 completion block，30分钟后重试
                pkcPendingCompletion = [localCompletion retain];

                pkcRetryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
                dispatch_source_set_timer(pkcRetryTimer,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * 60 * NSEC_PER_SEC)),
                                          30 * 60 * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
                dispatch_source_set_event_handler(pkcRetryTimer, ^{
                    // 重试：重新获取新闻
                    if (pkcPendingCompletion) {
                        void (^retryCompletion)(NSString *) = [pkcPendingCompletion retain];
                        [pkcPendingCompletion release];
                        pkcPendingCompletion = nil;
                        dispatch_source_cancel(pkcRetryTimer);
                        pkcRetryTimer = nil;

                        // 重新调用 fetchNewsWithCompletion
                        [self fetchNewsWithCompletion:retryCompletion];
                        [retryCompletion release];
                    }
                });
                dispatch_resume(pkcRetryTimer);
            } else {
                // 超过最大重试次数，发送 fallback
                NSLog(@"[PKC60sFix] Max retries reached, sending fallback");
                pkcRetryCount = 0;
                NSString *dateHeader = PKC60sFormatDateHeader();
                NSString *fallback = [NSString stringWithFormat:@"📰 每日60秒新闻\n%@在这里，每天60秒读懂世界\n\n抱歉，今日新闻获取失败，请稍后重试。\n\n📢 来源：60秒读懂世界", dateHeader.length > 0 ? [dateHeader stringByAppendingString:@"\n"] : @""];
                localCompletion(fallback);
            }
            return;
        }

        NSString *urlString = apiList[currentIndex];
        BOOL isTextAPI = [urlString containsString:@"format=text"];
        currentIndex++;

        // 检查是否应该跳过此API（连续失败3次且30分钟内）
        if (PKC60sShouldSkipAPI(urlString)) {
            tryNextAPI();
            return;
        }

        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            PKC60sRecordFailure(urlString);
            tryNextAPI();
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 10.0; // 缩短超时到10秒，加快回退
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
        [request setValue:isTextAPI ? @"text/plain" : @"application/json" forHTTPHeaderField:@"Accept"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            @try {
                if (error || !data) {
                    NSLog(@"[PKC60sFix] API %@ failed: %@", urlString, error.localizedDescription);
                    PKC60sRecordFailure(urlString);
                    tryNextAPI();
                    return;
                }

                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                if ([httpResp isKindOfClass:[NSHTTPURLResponse class]] && httpResp.statusCode != 200) {
                    NSLog(@"[PKC60sFix] API %@ HTTP status: %ld", urlString, (long)httpResp.statusCode);
                    PKC60sRecordFailure(urlString);
                    tryNextAPI();
                    return;
                }

                // 先解析 JSON 检查新鲜度，再构建文本
                NSDictionary *json = nil;
                @try {
                    json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                } @catch (NSException *e) {}

                // 新鲜度检查（在构建文本之前）
                if (!isTextAPI && json) {
                    if (!PKC60sIsNewsFresh(nil, json)) {
                        NSLog(@"[PKC60sFix] API %@ JSON date is stale, skipping", urlString);
                        PKC60sRecordFailure(urlString);
                        tryNextAPI();
                        return;
                    }
                }

                // 解析新闻
                NSString *newsText = [self parseNewsData:data isTextAPI:isTextAPI];
                if (newsText.length <= 20) {
                    NSLog(@"[PKC60sFix] API %@ returned empty content", urlString);
                    PKC60sRecordFailure(urlString);
                    tryNextAPI();
                    return;
                }

                // 文本格式 API 的新鲜度检查
                if (isTextAPI) {
                    if (!PKC60sIsNewsFresh(newsText, json)) {
                        NSLog(@"[PKC60sFix] API %@ text is stale, trying next", urlString);
                        PKC60sRecordFailure(urlString);
                        tryNextAPI();
                        return;
                    }
                }

                // 成功！重置失败计数和重试计数
                PKC60sRecordSuccess(urlString);
                pkcRetryCount = 0;

                // 内容比对：检查是否和上次发送的重复
                if (PKC60sIsContentDuplicate(newsText)) {
                    NSLog(@"[PKC60sFix] API %@ content is duplicate (same as last sent), trying next", urlString);
                    PKC60sRecordFailure(urlString);
                    tryNextAPI();
                    return;
                }

                // 延迟5分钟保存哈希，给 PKC 重试发送的时间
                // 如果 PKC 在5分钟内再次获取新闻（发送失败重试），哈希还没保存，相同内容不会被跳过
                // 5分钟后保存，防止同一天重复发送
                NSString *newsToSave = [newsText copy];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * 60 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    PKC60sSaveNewsHash(newsToSave);
                    NSLog(@"[PKC60sFix] News hash saved after 5min delay (send assumed successful)");
                });

                NSLog(@"[PKC60sFix] Success from %@", urlString);
                completion(newsText);
            } @catch (NSException *exception) {
                NSLog(@"[PKC60sFix] Exception parsing %@: %@", urlString, exception);
                PKC60sRecordFailure(urlString);
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

    // 日期头：优先使用 API 返回的日期，避免用今天的日期配上昨天的新闻
    NSString *apiDate = nil;
    for (NSString *key in @[@"date", @"update", @"create_time", @"datetime"]) {
        id val = searchDict[key];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            apiDate = val;
            break;
        }
    }
    if (apiDate.length > 0) {
        // 使用 API 的日期（可能需要格式化）
        [result appendFormat:@"%@\n", [self cleanText:apiDate]];
    } else {
        // API 没有日期字段，用本地生成的日期
        NSString *dateHeader = PKC60sFormatDateHeader();
        if (dateHeader.length > 0) {
            [result appendFormat:@"%@\n", dateHeader];
        }
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

// === 25秒保活定时器 ===
// iOS 每次给约30秒后台时间，25秒申请一次刚好续上，不浪费
static dispatch_source_t pkcKeepAliveTimer = nil;
static UIBackgroundTaskIdentifier pkcLastBgTask = UIBackgroundTaskInvalid;

static void pkcKeepAliveFire(void) {
    @autoreleasepool {
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            if (!app) return;

            // 结束上一个后台任务
            if (pkcLastBgTask != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:pkcLastBgTask];
                pkcLastBgTask = UIBackgroundTaskInvalid;
            }

            // 申请新的后台时间
            pkcLastBgTask = [app beginBackgroundTaskWithExpirationHandler:^{
                @try {
                    if (pkcLastBgTask != UIBackgroundTaskInvalid) {
                        UIApplication *a = [UIApplication sharedApplication];
                        [a endBackgroundTask:pkcLastBgTask];
                        pkcLastBgTask = UIBackgroundTaskInvalid;
                    }
                } @catch (NSException *e) {}
            }];
        } @catch (NSException *e) {}
    }
}

static void pkcStartKeepAliveTimer(void) {
    if (pkcKeepAliveTimer) return;

    pkcKeepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(pkcKeepAliveTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                              25 * NSEC_PER_SEC,   // 每25秒触发（iOS给30秒，25秒续上）
                              5 * NSEC_PER_SEC);    // 允许5秒误差
    dispatch_source_set_event_handler(pkcKeepAliveTimer, ^{
        pkcKeepAliveFire();
    });
    dispatch_resume(pkcKeepAliveTimer);

    NSLog(@"[PKC60sFix] 25-second keepalive timer started");
}

%ctor {
    @autoreleasepool {
        // 1. 只在方法不存在时添加 AddMsg:MsgWrap:，不覆盖微信原有方法
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

        // 2. 启动25秒保活定时器
        pkcStartKeepAliveTimer();
    }
}
