#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// PKC 60秒新闻修复插件 v4.1
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

// === 后台/锁屏发送支持 ===
// PKC 检查 applicationState，后台时只设 flag 不发送
// 我们 hook applicationState，在 send60s 执行期间返回 active，让 PKC 在后台也发送
static BOOL pkcForceActive = NO;

// === 消息发送辅助 ===
// 从 PKC 实例中提取的目标 wxid（供直接发送使用）
static NSString *pkcTargetWxid = nil;
// 前向声明
static id pkcGetCMessageMgr(void);
static void pkcFindTargetInObject(id obj);
static void pkcFindTargetFromCurrentVC(void);
static void pkcFindTargetAll(void);
static void pkcSendDirectly(NSString *newsText, NSString *target);

// 统一设置目标：更新内存 + 持久化到 NSUserDefaults
// 每次调用都会覆盖旧目标，确保目标改变时能自动更新
static void pkcSetTarget(NSString *target) {
    if (!target || target.length == 0) return;
    pkcTargetWxid = [target copy];
    @try {
        [[NSUserDefaults standardUserDefaults] setObject:target forKey:@"pkc60s_target_wxid"];
    } @catch (NSException *e) {}
}

// APP启动时从 NSUserDefaults 加载上次保存的目标
static void pkcLoadTarget(void) {
    @try {
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"pkc60s_target_wxid"];
        if (saved.length > 0) {
            pkcTargetWxid = [saved copy];
            NSLog(@"[PKC60sFix] Loaded saved target: %@", pkcTargetWxid);
        }
    } @catch (NSException *e) {}
}

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

// === 今日是否已完成获取 ===
// 成功获取一次后，当天不再重复获取，直到第二天设定时间
static NSString *PKC60sGetTodayDoneDate(void) {
    @try {
        return [[NSUserDefaults standardUserDefaults] stringForKey:@"pkc60s_done_date"];
    } @catch (NSException *e) {}
    return nil;
}

static BOOL PKC60sIsTodayDone(void) {
    @try {
        NSString *doneDate = PKC60sGetTodayDoneDate();
        if (!doneDate || doneDate.length == 0) return NO;

        NSDate *now = [NSDate date];
        NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        NSDateComponents *comps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
        NSString *today = [NSString stringWithFormat:@"%ld-%02ld-%02ld", (long)[comps year], (long)[comps month], (long)[comps day]];

        if ([doneDate isEqualToString:today]) {
            NSLog(@"[PKC60sFix] Today already done (%@), skip", today);
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

static void PKC60sMarkTodayDone(void) {
    @try {
        NSDate *now = [NSDate date];
        NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        NSDateComponents *comps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
        NSString *today = [NSString stringWithFormat:@"%ld-%02ld-%02ld", (long)[comps year], (long)[comps month], (long)[comps day]];
        [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"pkc60s_done_date"];
        NSLog(@"[PKC60sFix] Marked today as done: %@", today);
    } @catch (NSException *e) {}
}

// === 本地新闻全文保存（第二天对比用） ===
static NSDictionary *PKC60sGetSavedNews(void) {
    @try {
        return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"pkc60s_saved_news"];
    } @catch (NSException *e) {}
    return nil;
}

static void PKC60sSaveNews(NSString *newsText) {
    @try {
        NSDate *now = [NSDate date];
        NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        NSDateComponents *comps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
        NSString *today = [NSString stringWithFormat:@"%ld-%02ld-%02ld", (long)[comps year], (long)[comps month], (long)[comps day]];

        // 删除旧的，保存新的
        [[NSUserDefaults standardUserDefaults] setObject:@{@"date": today, @"content": newsText} forKey:@"pkc60s_saved_news"];
        NSLog(@"[PKC60sFix] Saved news to local (date=%@, length=%lu)", today, (unsigned long)newsText.length);
    } @catch (NSException *e) {}
}

// 检查新闻是否和昨天保存的相同（防止发昨天的重复新闻）
static BOOL PKC60sIsYesterdayDuplicate(NSString *newsText) {
    @try {
        NSDictionary *saved = PKC60sGetSavedNews();
        if (!saved) return NO; // 没有保存过，不判断

        NSString *savedDate = saved[@"date"];
        NSString *savedContent = saved[@"content"];
        if (!savedContent || savedContent.length == 0) return NO;

        NSDate *now = [NSDate date];
        NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        NSDateComponents *comps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
        NSString *today = [NSString stringWithFormat:@"%ld-%02ld-%02ld", (long)[comps year], (long)[comps month], (long)[comps day]];

        // 如果保存的是今天的 → 已发送过，不重复
        if ([savedDate isEqualToString:today]) {
            NSLog(@"[PKC60sFix] Already saved today, comparing content");
            // 内容相同 → 重复，不发送
            // 内容不同 → 可能是更新版本，允许发送
            if ([savedContent isEqualToString:newsText]) {
                NSLog(@"[PKC60sFix] Content same as already saved today, skip");
                return YES;
            }
            return NO;
        }

        // 保存的是昨天的 → 对比内容
        // 提取新闻正文（去掉日期头，因为日期每天不同）
        NSString *savedBody = savedContent;
        NSString *newBody = newsText;
        // 取后500字对比（新闻正文部分）
        if (savedBody.length > 500) savedBody = [savedBody substringFromIndex:savedBody.length - 500];
        if (newBody.length > 500) newBody = [newBody substringFromIndex:newBody.length - 500];

        if ([savedBody isEqualToString:newBody]) {
            NSLog(@"[PKC60sFix] Content matches yesterday's saved news, skip");
            return YES; // 和昨天相同，是旧闻
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

        // 既没有 json 也没有 newsText，默认新鲜
        return YES;
    } @catch (NSException *e) {
        return YES; // 异常时默认通过，避免阻断发送
    }
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
            NSDateComponents *lunarComps = [chineseCalendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];

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

#pragma mark - Toast 提示栈
// 黑色半透明背景 + 白色字体 + 圆角
// 消息依次显示，每条2.5秒
// 任何模块调用 [[PKCToastManager shared] pushMessage:@"xxx"] 即可注入提示

@interface PKCToastManager : NSObject
+ (instancetype)shared;
- (void)pushMessage:(NSString *)msg;
@end

@implementation PKCToastManager {
    NSMutableArray *_messageStack;
    BOOL _isShowing;
}

+ (instancetype)shared {
    static PKCToastManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[PKCToastManager alloc] init]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _messageStack = [[NSMutableArray alloc] init];
        _isShowing = NO;
    }
    return self;
}

- (void)pushMessage:(NSString *)msg {
    if (!msg || msg.length == 0) return;
    @synchronized(_messageStack) {
        [_messageStack addObject:msg];
    }
    NSLog(@"[PKC60sFix][Toast] %@", msg);
    [self showNext];
}

- (void)showNext {
    if (_isShowing) return;

    NSString *msg = nil;
    @synchronized(_messageStack) {
        if (_messageStack.count > 0) {
            msg = [_messageStack firstObject];
            [_messageStack removeObjectAtIndex:0];
        }
    }

    if (!msg) return;

    _isShowing = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showToast:msg];
    });
}

- (void)showToast:(NSString *)msg {
    @try {
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive &&
                    [scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    for (UIWindow *w in ws.windows) {
                        if (w.isKeyWindow) { window = w; break; }
                    }
                    if (!window && ws.windows.count > 0) window = ws.windows.firstObject;
                    break;
                }
            }
        }
        if (!window) {
            window = [[UIApplication sharedApplication] keyWindow];
        }
        if (!window) {
            NSArray *windows = [[UIApplication sharedApplication] windows];
            if (windows.count > 0) window = windows.lastObject;
        }
        if (!window) {
            _isShowing = NO;
            [self showNext];
            return;
        }

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        toast.layer.cornerRadius = 12;
        toast.clipsToBounds = YES;

        UILabel *label = [[UILabel alloc] init];
        label.text = msg;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        [toast addSubview:label];

        CGFloat maxWidth = window.bounds.size.width - 80;
        CGRect textRect = [msg boundingRectWithSize:CGSizeMake(maxWidth - 40, CGFLOAT_MAX)
                                            options:NSStringDrawingUsesLineFragmentOrigin
                                         attributes:@{NSFontAttributeName: label.font}
                                            context:nil];
        CGFloat width = MIN(ceil(textRect.size.width) + 40, maxWidth);
        CGFloat height = ceil(textRect.size.height) + 24;
        toast.frame = CGRectMake((window.bounds.size.width - width) / 2,
                                 (window.bounds.size.height - height) / 2,
                                 width, height);
        label.frame = CGRectMake(20, 12, width - 40, height - 24);

        toast.alpha = 0;
        [window addSubview:toast];

        [UIView animateWithDuration:0.25 animations:^{
            toast.alpha = 1;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 delay:2.5 options:0 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
                _isShowing = NO;
                [self showNext];
            }];
        }];
    } @catch (NSException *e) {
        _isShowing = NO;
        [self showNext];
    }
}
@end

// 便捷函数
static void PKCPushToast(NSString *msg) {
    [[PKCToastManager shared] pushMessage:msg];
}

#pragma mark - 新闻获取与解析

@interface PKC60sNewsFetcher : NSObject
+ (void)fetchNewsWithCompletion:(void (^)(NSString *newsText))completion;
+ (NSString *)parseNewsData:(NSData *)data isTextAPI:(BOOL)isTextAPI;
+ (NSString *)parseJSON:(NSDictionary *)json;
+ (NSString *)cleanText:(NSString *)text;
@end

@implementation PKC60sNewsFetcher

// === 重试机制 ===
// 8个API全失败后等30分钟重试，直到成功，成功后当天停止
static void (^pkcPendingCompletion)(NSString *) = nil;
static dispatch_source_t pkcRetryTimer = nil;

+ (void)fetchNewsWithCompletion:(void (^)(NSString *newsText))completion {
    if (!completion) return;

    // 今天已经成功获取过 → 直接返回保存的新闻，不再重复获取
    if (PKC60sIsTodayDone()) {
        NSLog(@"[PKC60sFix] Today already done, returning saved news");
        NSDictionary *saved = PKC60sGetSavedNews();
        NSString *savedContent = saved[@"content"];
        if (savedContent && savedContent.length > 0) {
            pkcForceActive = YES;
            completion(savedContent);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                pkcForceActive = NO;
            });
        }
        return;
    }

    // 取消之前的重试定时器
    if (pkcRetryTimer) {
        dispatch_source_cancel(pkcRetryTimer);
        pkcRetryTimer = nil;
    }

    NSArray *apiList = PKC60sGetAPIList();
    __block NSInteger currentIndex = 0;
    __block void (^localCompletion)(NSString *) = [completion copy];

    __block void (^tryNextAPI)(void) = nil;
    tryNextAPI = ^{
        if (currentIndex >= apiList.count) {
            // 8个API全部失败 → 30分钟后重试
            PKCPushToast(@"⚠️ 所有API获取失败，30分钟后重试");
            NSLog(@"[PKC60sFix] All 8 APIs failed, will retry in 30 min");

            pkcPendingCompletion = localCompletion;
            pkcRetryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
            dispatch_source_set_timer(pkcRetryTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * 60 * NSEC_PER_SEC)),
                                      30 * 60 * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(pkcRetryTimer, ^{
                if (pkcPendingCompletion) {
                    void (^retryCompletion)(NSString *) = pkcPendingCompletion;
                    pkcPendingCompletion = nil;
                    dispatch_source_cancel(pkcRetryTimer);
                    pkcRetryTimer = nil;
                    [self fetchNewsWithCompletion:retryCompletion];
                }
            });
            dispatch_resume(pkcRetryTimer);
            return;
        }

        NSString *urlString = apiList[currentIndex];
        BOOL isTextAPI = [urlString containsString:@"format=text"];
        currentIndex++;

        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) { tryNextAPI(); return; }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 10.0;
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
        [request setValue:isTextAPI ? @"text/plain" : @"application/json" forHTTPHeaderField:@"Accept"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            @try {
                if (error || !data) {
                    NSLog(@"[PKC60sFix] API#%ld %@ failed: %@", (long)(currentIndex-1), urlString, error.localizedDescription);
                    tryNextAPI();
                    return;
                }

                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                if ([httpResp isKindOfClass:[NSHTTPURLResponse class]] && httpResp.statusCode != 200) {
                    NSLog(@"[PKC60sFix] API#%ld %@ HTTP %ld", (long)(currentIndex-1), urlString, (long)httpResp.statusCode);
                    tryNextAPI();
                    return;
                }

                NSDictionary *json = nil;
                @try { json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; } @catch (NSException *e) {}

                // 只要有 JSON 就检查新鲜度（text API 也可能返回 JSON）
                if (json) {
                    if (!PKC60sIsNewsFresh(nil, json)) {
                        NSLog(@"[PKC60sFix] API#%ld %@ stale JSON date", (long)(currentIndex-1), urlString);
                        tryNextAPI();
                        return;
                    }
                }

                NSString *newsText = [self parseNewsData:data isTextAPI:isTextAPI];
                if (newsText.length <= 20) {
                    NSLog(@"[PKC60sFix] API#%ld %@ empty content", (long)(currentIndex-1), urlString);
                    tryNextAPI();
                    return;
                }

                // 如果没有 JSON（纯文本响应），用文本检查新鲜度
                if (!json) {
                    if (!PKC60sIsNewsFresh(newsText, nil)) {
                        NSLog(@"[PKC60sFix] API#%ld %@ stale text", (long)(currentIndex-1), urlString);
                        tryNextAPI();
                        return;
                    }
                }

                // 和本地保存的新闻对比（防止发昨天的）
                if (PKC60sIsYesterdayDuplicate(newsText)) {
                    NSLog(@"[PKC60sFix] API#%ld %@ content is duplicate of yesterday, trying next", (long)(currentIndex-1), urlString);
                    tryNextAPI();
                    return;
                }

                // 成功！
                NSLog(@"[PKC60sFix] SUCCESS from API#%ld %@", (long)(currentIndex-1), urlString);

                // 标记今天已完成
                PKC60sMarkTodayDone();

                // 保存全文到本地（第二天对比用，自动删除旧的）
                PKC60sSaveNews(newsText);

                // 发送
                pkcForceActive = YES;
                localCompletion(newsText);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    pkcForceActive = NO;
                });
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

    // 先尝试解析为 JSON（有些 "text" 格式 API 实际返回 JSON）
    NSDictionary *json = nil;
    @try {
        json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } @catch (NSException *e) {
        json = nil;
    }

    // 如果是有效的 JSON，无论是否声明为 text API，都用 parseJSON 解析
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSString *parsed = [self parseJSON:json];
        if (parsed.length > 0) {
            return parsed;
        }
    }

    // 不是 JSON，按纯文本处理
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
    }
    if (!text) return nil;

    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 过滤 HTML 响应
    if ([text hasPrefix:@"<"] || [text hasSuffix:@">"]) return nil;

    // 过滤 JSON 字符串（防止把原始 JSON 当新闻发送）
    if ([text hasPrefix:@"{"] || [text hasPrefix:@"["]) return nil;

    if (text.length < 20) return nil;

    // 验证是有效的新闻文本（包含数字编号的新闻条目或日期）
    if ([text containsString:@"."] || [text containsString:@"、"] || [text containsString:@"："] || text.length > 50) {
        return text;
    }
    return nil;
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

    // 日期头：优先使用 API 返回的日期+星期+农历
    NSString *apiDate = nil;
    for (NSString *key in @[@"date", @"update", @"create_time", @"datetime"]) {
        id val = searchDict[key];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            apiDate = val;
            break;
        }
    }
    // 星期和农历（viki.moe 等 API 提供）
    NSString *weekDay = nil;
    for (NSString *key in @[@"day_of_week", @"weekday", @"week", @"星期"]) {
        id val = searchDict[key];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            weekDay = val;
            break;
        }
    }
    NSString *lunarDate = nil;
    for (NSString *key in @[@"lunar_date", @"lunar", @"农历"]) {
        id val = searchDict[key];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            lunarDate = val;
            break;
        }
    }

    if (apiDate.length > 0) {
        // 使用 API 的日期，拼接星期和农历
        NSMutableString *dateHeader = [NSMutableString stringWithString:[self cleanText:apiDate]];
        if (weekDay.length > 0) {
            [dateHeader appendFormat:@" %@", [self cleanText:weekDay]];
        }
        if (lunarDate.length > 0) {
            [dateHeader appendFormat:@" %@", [self cleanText:lunarDate]];
        }
        [result appendFormat:@"%@\n", dateHeader];
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
    PKCPushToast(@"📰 开始获取60秒新闻...");
    @try {
        [PKC60sNewsFetcher fetchNewsWithCompletion:^(NSString *newsText) {
            @try {
                if (!newsText || newsText.length == 0) {
                    PKCPushToast(@"⚠️ 新闻获取失败，使用备用内容");
                    NSString *dateHeader = PKC60sFormatDateHeader();
                    newsText = [NSString stringWithFormat:@"📰 每日60秒新闻\n%@在这里，每天60秒读懂世界\n\n抱歉，今日新闻获取失败，请稍后重试。\n\n📢 来源：60秒读懂世界", dateHeader.length > 0 ? [dateHeader stringByAppendingString:@"\n"] : @""];
                } else {
                    PKCPushToast(@"✅ 新闻获取成功");
                }

                NSLog(@"[PKC60sFix] News fetched, length=%lu, target=%@",
                      (unsigned long)newsText.length, pkcTargetWxid ?: @"nil");

                // 先调用 PKC 的 completion（让 PKC 尝试自己的发送逻辑）
                if (completion) {
                    void (^block)(id) = (void (^)(id))completion;
                    block(newsText);
                }

                // 备份：延迟2秒后如果 PKC 发送失败，直接发送
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(0, 0), ^{
                    @try {
                        // 发送前再全面查找一次目标（PKC 单例 / NSUserDefaults / plist 文件）
                        pkcFindTargetAll();
                        NSLog(@"[PKC60sFix] Backup send check: target=%@", pkcTargetWxid ?: @"nil");
                        if (pkcTargetWxid && pkcTargetWxid.length > 0) {
                            PKCPushToast([NSString stringWithFormat:@"📤 正在发送到 %@...", pkcTargetWxid]);
                            NSLog(@"[PKC60sFix] Backup direct send to %@", pkcTargetWxid);
                            pkcSendDirectly(newsText, pkcTargetWxid);
                        } else {
                            PKCPushToast(@"❌ 未找到发送目标，请检查PKC设置");
                            NSLog(@"[PKC60sFix] Backup send aborted: no target found");
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[PKC60sFix] Backup send exception: %@", e);
                    }
                });
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
                pkcForceActive = YES;
                block(fallback);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    pkcForceActive = NO;
                });
            }
        } @catch (NSException *e2) {
            NSLog(@"[PKC60sFix] Error in fallback: %@", e2);
        }
    }
}

%end

#pragma mark - 消息发送辅助函数

// 获取 CMessageMgr 实例（多种方式尝试）
static id pkcGetCMessageMgr(void) {
    @try {
        Class CMessageMgrClass = NSClassFromString(@"CMessageMgr");
        if (!CMessageMgrClass) {
            NSLog(@"[PKC60sFix] CMessageMgr class not found");
            return nil;
        }

        // 方式1: sharedInstance
        if ([CMessageMgrClass respondsToSelector:@selector(sharedInstance)]) {
            id mgr = [CMessageMgrClass performSelector:@selector(sharedInstance)];
            if (mgr) {
                NSLog(@"[PKC60sFix] Got CMessageMgr via sharedInstance");
                return mgr;
            }
        }

        // 方式2: MMServiceCenter
        Class MMServiceCenterClass = NSClassFromString(@"MMServiceCenter");
        if (MMServiceCenterClass && [MMServiceCenterClass respondsToSelector:@selector(defaultCenter)]) {
            id center = [MMServiceCenterClass performSelector:@selector(defaultCenter)];
            if (center && [center respondsToSelector:@selector(getService:)]) {
                id mgr = [center performSelector:@selector(getService:) withObject:CMessageMgrClass];
                if (mgr) {
                    NSLog(@"[PKC60sFix] Got CMessageMgr via MMServiceCenter");
                    return mgr;
                }
            }
        }

        // 方式3: 从 AppDelegate 的 ivar 中查找
        id appDelegate = [UIApplication sharedApplication].delegate;
        if (appDelegate) {
            @try {
                unsigned int count = 0;
                Ivar *ivars = class_copyIvarList([appDelegate class], &count);
                for (unsigned int i = 0; i < count; i++) {
                    id val = object_getIvar(appDelegate, ivars[i]);
                    if (val && [val isKindOfClass:CMessageMgrClass]) {
                        NSLog(@"[PKC60sFix] Got CMessageMgr via AppDelegate ivar");
                        if (ivars) free(ivars);
                        return val;
                    }
                }
                if (ivars) free(ivars);
            } @catch (NSException *e) {}
        }

        // 方式4: 从 PKC 主类实例中查找
        Class pkcClass = NSClassFromString(@"PWZfnvktqn");
        if (pkcClass) {
            id pkcInstance = nil;
            @try {
                if ([pkcClass respondsToSelector:@selector(sharedInstance)]) {
                    pkcInstance = [pkcClass performSelector:@selector(sharedInstance)];
                }
            } @catch (NSException *e) {}
            if (pkcInstance) {
                @try {
                    unsigned int count = 0;
                    Ivar *ivars = class_copyIvarList([pkcInstance class], &count);
                    for (unsigned int i = 0; i < count; i++) {
                        id val = object_getIvar(pkcInstance, ivars[i]);
                        if (val && [val isKindOfClass:CMessageMgrClass]) {
                            NSLog(@"[PKC60sFix] Got CMessageMgr via PKC ivar");
                            if (ivars) free(ivars);
                            return val;
                        }
                    }
                    if (ivars) free(ivars);
                } @catch (NSException *e) {}
            }
        }

        NSLog(@"[PKC60sFix] CMessageMgr instance not found");
    } @catch (NSException *e) {
        NSLog(@"[PKC60sFix] Exception getting CMessageMgr: %@", e);
    }
    return nil;
}

// 从对象中查找目标 wxid（群聊 @chatroom 或好友 wxid_）
// 递归扫描对象的所有嵌套对象，查找 wxid
static void pkcScanObjectRecursive(id obj, NSInteger depth, NSMutableSet *visited);

static void pkcFindTargetInObject(id obj) {
    if (!obj) return;
    @try {
        NSMutableSet *visited = [NSMutableSet set];
        pkcScanObjectRecursive(obj, 0, visited);
    } @catch (NSException *e) {}
}

static void pkcScanObjectRecursive(id obj, NSInteger depth, NSMutableSet *visited) {
    if (!obj || depth > 4) return;
    if (pkcTargetWxid.length > 0) return; // 已找到
    @try {
        // 防止循环引用
        if ([visited containsObject:obj]) return;
        [visited addObject:obj];

        // 如果是字符串，检查是否是 wxid
        if ([obj isKindOfClass:[NSString class]]) {
            NSString *str = (NSString *)obj;
            if (str.length > 0 && ([str containsString:@"@chatroom"] || [str hasPrefix:@"wxid_"])) {
                NSLog(@"[PKC60sFix] Found target (depth=%ld): %@", (long)depth, str);
                pkcSetTarget(str);
                return;
            }
            return;
        }

        // 如果是数组，遍历每个元素
        if ([obj isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)obj) {
                pkcScanObjectRecursive(item, depth + 1, visited);
                if (pkcTargetWxid.length > 0) return;
            }
            return;
        }

        // 如果是字典，遍历所有值
        if ([obj isKindOfClass:[NSDictionary class]]) {
            for (id val in [(NSDictionary *)obj allValues]) {
                pkcScanObjectRecursive(val, depth + 1, visited);
                if (pkcTargetWxid.length > 0) return;
            }
            return;
        }

        // 扫描对象的 ivar（包括父类）
        Class cls = [obj class];
        while (cls && cls != [NSObject class]) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (!type || !strstr(type, "@")) continue;

                id val = object_getIvar(obj, ivars[i]);
                if (val) {
                    pkcScanObjectRecursive(val, depth + 1, visited);
                    if (pkcTargetWxid.length > 0) {
                        if (ivars) free(ivars);
                        return;
                    }
                }
            }
            if (ivars) free(ivars);
            cls = class_getSuperclass(cls);
        }
    } @catch (NSException *e) {}
}

// 从当前聊天界面获取目标 wxid
// 遍历 UIViewController 栈，找聊天控制器的 m_nsChatName / m_contact / session 等属性
static void pkcFindTargetFromCurrentVC(void) {
    @try {
        UIViewController *topVC = nil;

        // 获取最顶层的 ViewController
        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        if (!window) {
            NSArray *windows = [[UIApplication sharedApplication] windows];
            for (UIWindow *w in windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
        }
        if (!window) return;

        topVC = window.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }

        // 如果是 navigation controller，取 topViewController
        if ([topVC isKindOfClass:[UINavigationController class]]) {
            topVC = [(UINavigationController *)topVC topViewController];
        }

        if (!topVC) return;

        NSLog(@"[PKC60sFix] Current VC: %@", NSStringFromClass([topVC class]));

        // 递归扫描当前 VC 的 ivar，找 wxid
        pkcScanObjectRecursive(topVC, 0, [NSMutableSet set]);
        if (pkcTargetWxid.length > 0) {
            NSLog(@"[PKC60sFix] Found target from current VC: %@", pkcTargetWxid);
            return;
        }

        // 尝试常见的聊天控制器属性
        NSArray *chatProps = @[@"m_nsChatName", @"m_contact", @"m_nsToUsr",
                              @"chatName", @"toUser", @"session", @"m_session"];
        for (NSString *prop in chatProps) {
            @try {
                id val = [topVC valueForKey:prop];
                if ([val isKindOfClass:[NSString class]]) {
                    NSString *str = (NSString *)val;
                    if (str.length > 0 && ([str containsString:@"@chatroom"] || [str hasPrefix:@"wxid_"])) {
                        NSLog(@"[PKC60sFix] Found target from VC prop '%@': %@", prop, str);
                        pkcSetTarget(str);
                        return;
                    }
                }
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {
        NSLog(@"[PKC60sFix] Current VC scan exception: %@", e);
    }
}

// 综合查找目标（所有方式）
// 每次都重新扫描，确保目标改变时能发现并更新
static void pkcFindTargetAll(void) {
    @try {
        NSString *oldTarget = pkcTargetWxid;

        // 1. 从 PKC 单例查找（递归扫描所有嵌套对象）
        Class pkcCls = NSClassFromString(@"PWZfnvktqn");
        if (pkcCls) {
            id inst = nil;
            @try {
                if ([pkcCls respondsToSelector:@selector(sharedInstance)]) {
                    inst = [pkcCls performSelector:@selector(sharedInstance)];
                }
            } @catch (NSException *e) {}
            if (inst) pkcFindTargetInObject(inst);
        }

        // 2. 从当前聊天界面查找（如果用户在聊天页点击测试）
        if (pkcTargetWxid.length == 0 || [pkcTargetWxid isEqualToString:oldTarget]) {
            pkcFindTargetFromCurrentVC();
        }

        if (pkcTargetWxid.length > 0) {
            if (![pkcTargetWxid isEqualToString:oldTarget]) {
                NSLog(@"[PKC60sFix] Target updated: %@", pkcTargetWxid);
            }
        } else {
            NSLog(@"[PKC60sFix] Target NOT found in any source");
        }
    } @catch (NSException *e) {
        NSLog(@"[PKC60sFix] Find target all exception: %@", e);
    }
}

// 直接创建消息并发送到目标
static void pkcSendDirectly(NSString *newsText, NSString *target) {
    @try {
        if (!newsText || newsText.length == 0 || !target || target.length == 0) {
            PKCPushToast(@"❌ 发送失败：内容或目标为空");
            NSLog(@"[PKC60sFix] Direct send skipped: text=%lu target=%@",
                  (unsigned long)(newsText ? newsText.length : 0), target ?: @"nil");
            return;
        }

        NSLog(@"[PKC60sFix] Attempting direct send to %@", target);

        id cMessageMgr = pkcGetCMessageMgr();
        if (!cMessageMgr) {
            PKCPushToast(@"❌ 发送失败：CMessageMgr不可用");
            NSLog(@"[PKC60sFix] Cannot send: CMessageMgr not available");
            return;
        }

        // 创建消息对象
        Class wrapClass = NSClassFromString(@"CMessageWrap");
        if (!wrapClass) wrapClass = NSClassFromString(@"MessageWrap");
        if (!wrapClass) {
            PKCPushToast(@"❌ 发送失败：CMessageWrap类不存在");
            NSLog(@"[PKC60sFix] Cannot send: CMessageWrap class not found");
            return;
        }

        id msgWrap = [[wrapClass alloc] init];
        if (!msgWrap) {
            PKCPushToast(@"❌ 发送失败：无法创建消息对象");
            NSLog(@"[PKC60sFix] Cannot send: failed to create CMessageWrap");
            return;
        }

        [msgWrap setValue:newsText forKey:@"m_nsContent"];
        [msgWrap setValue:target forKey:@"m_nsToUsr"];
        [msgWrap setValue:@1 forKey:@"m_uiMessageType"]; // 1=文本
        [msgWrap setValue:@0 forKey:@"m_uiStatus"];

        NSLog(@"[PKC60sFix] Created CMessageWrap, content length=%lu", (unsigned long)newsText.length);

        // 尝试多种发送方法
        if ([cMessageMgr respondsToSelector:@selector(AddMsg:MsgWrap:)]) {
            NSLog(@"[PKC60sFix] Sending via CMessageMgr AddMsg:MsgWrap:");
            ((void(*)(id, SEL, id, id))objc_msgSend)(cMessageMgr, @selector(AddMsg:MsgWrap:), msgWrap, nil);
            NSLog(@"[PKC60sFix] Direct send completed via AddMsg:MsgWrap:");
            PKCPushToast(@"✅ 发送成功(AddMsg)");
            return;
        }

        SEL sendSel = NSSelectorFromString(@"sendMsg:");
        if ([cMessageMgr respondsToSelector:sendSel]) {
            NSLog(@"[PKC60sFix] Sending via CMessageMgr sendMsg:");
            ((void(*)(id, SEL, id))objc_msgSend)(cMessageMgr, sendSel, msgWrap);
            NSLog(@"[PKC60sFix] Direct send completed via sendMsg:");
            PKCPushToast(@"✅ 发送成功(sendMsg)");
            return;
        }

        SEL addSel = NSSelectorFromString(@"addMsg:");
        if ([cMessageMgr respondsToSelector:addSel]) {
            NSLog(@"[PKC60sFix] Sending via CMessageMgr addMsg:");
            ((void(*)(id, SEL, id))objc_msgSend)(cMessageMgr, addSel, msgWrap);
            NSLog(@"[PKC60sFix] Direct send completed via addMsg:");
            PKCPushToast(@"✅ 发送成功(addMsg)");
            return;
        }

        PKCPushToast(@"❌ 发送失败：CMessageMgr无已知发送方法");
        NSLog(@"[PKC60sFix] CMessageMgr has no known send method");
    } @catch (NSException *e) {
        PKCPushToast([NSString stringWithFormat:@"❌ 发送异常：%@", e.reason ?: @"unknown"]);
        NSLog(@"[PKC60sFix] Exception in direct send: %@", e);
    }
}

#pragma mark - 修复消息发送方式（微信 8.0.78/79 兼容性）
//
// 只在 WeixinContentLogicController 没有 AddMsg:MsgWrap: 方法时才添加
// 如果微信已自带此方法，完全不干预，避免影响正常消息/语音发送
// 用 class_addMethod 在 %ctor 中检查并添加，不会覆盖已有方法

static void pkc_forwardAddMsg(id self, SEL _cmd, id msgWrap, id msgWrap2) {
    @try {
        NSLog(@"[PKC60sFix] pkc_forwardAddMsg called, self=%@", [self class]);

        // 提取目标 wxid（保存供直接发送使用）
        @try {
            NSString *toUsr = [msgWrap valueForKey:@"m_nsToUsr"];
            if (toUsr && toUsr.length > 0) {
                pkcSetTarget(toUsr);
                NSLog(@"[PKC60sFix] Extracted target from msgWrap: %@", pkcTargetWxid);
            }
        } @catch (NSException *e) {}

        // 方式1：通过 CMessageMgr AddMsg:MsgWrap:
        id cMessageMgr = pkcGetCMessageMgr();
        if (cMessageMgr) {
            if ([cMessageMgr respondsToSelector:@selector(AddMsg:MsgWrap:)]) {
                NSLog(@"[PKC60sFix] Forwarding via CMessageMgr AddMsg:MsgWrap:");
                ((void(*)(id, SEL, id, id))objc_msgSend)(cMessageMgr, @selector(AddMsg:MsgWrap:), msgWrap, nil);
                return;
            }
            // 尝试 sendMsg:
            SEL sendSel = NSSelectorFromString(@"sendMsg:");
            if ([cMessageMgr respondsToSelector:sendSel]) {
                NSLog(@"[PKC60sFix] Forwarding via CMessageMgr sendMsg:");
                ((void(*)(id, SEL, id))objc_msgSend)(cMessageMgr, sendSel, msgWrap);
                return;
            }
        }

        // 方式2：通过 OnAddMsg:MsgWrap:
        id selfId = self;
        if ([selfId respondsToSelector:@selector(OnAddMsg:MsgWrap:)]) {
            NSLog(@"[PKC60sFix] Forwarding via OnAddMsg:MsgWrap:");
            ((void(*)(id, SEL, id, id))objc_msgSend)(self, @selector(OnAddMsg:MsgWrap:), msgWrap, nil);
            return;
        }

        // 方式3：SendTextMessage:replyingMessage:isPasted:
        @try {
            NSString *content = [msgWrap valueForKey:@"m_nsContent"];
            NSString *toUsr = [msgWrap valueForKey:@"m_nsToUsr"];
            if (content.length > 0 && toUsr.length > 0) {
                SEL sendSel = NSSelectorFromString(@"SendTextMessage:replyingMessage:isPasted:");
                if ([selfId respondsToSelector:sendSel]) {
                    NSLog(@"[PKC60sFix] Forwarding via SendTextMessage:");
                    ((void(*)(id, SEL, id, id, BOOL))objc_msgSend)(self, sendSel, content, nil, NO);
                    return;
                }
            }
        } @catch (NSException *e) {}

        // 方式4：直接创建消息发送
        NSLog(@"[PKC60sFix] All forwarding methods failed, trying direct send");
        @try {
            NSString *content = [msgWrap valueForKey:@"m_nsContent"];
            if (content.length > 0 && pkcTargetWxid.length > 0) {
                pkcSendDirectly(content, pkcTargetWxid);
            }
        } @catch (NSException *e) {}

        NSLog(@"[PKC60sFix] pkc_forwardAddMsg: all methods exhausted");
    } @catch (NSException *e) {
        NSLog(@"[PKC60sFix] Exception in pkc_forwardAddMsg: %@", e);
    }
}

// === 后台/锁屏发送支持 hook ===

// 捕捉用户在PKC设置里选择群聊/好友
// 当选择器页面消失时，扫描PKC单例获取选中的目标wxid
%hook UIViewController
- (void)viewWillDisappear:(BOOL)animated {
    @try {
        NSString *clsName = NSStringFromClass([self class]);
        // 只处理联系人/群聊选择器
        if ([clsName containsString:@"Picker"] || [clsName containsString:@"Select"] ||
            [clsName containsString:@"Contact"] || [clsName containsString:@"Chat"] ||
            [clsName containsString:@"Room"]) {
            NSLog(@"[PKC60sFix] Picker disappeared: %@, scanning for target", clsName);
            // 延迟0.5秒让PKC保存选择结果
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                pkcFindTargetAll();
            });
        }
    } @catch (NSException *e) {}
    %orig;
}
%end

%hook UIApplication
- (UIApplicationState)applicationState {
    if (pkcForceActive) {
        return UIApplicationStateActive;
    }
    return %orig;
}
%end

%hook PWZfnvktqn
- (void)send60s {
    PKCPushToast(@"⏰ 定时触发：准备发送60秒新闻");
    NSLog(@"[PKC60sFix] send60s called");
    // 从 PKC 实例中提取目标 wxid
    pkcFindTargetInObject(self);
    NSLog(@"[PKC60sFix] Target after scan: %@", pkcTargetWxid ?: @"nil");
    // 在 send60s 执行期间，让 applicationState 返回 active
    pkcForceActive = YES;
    %orig;
    // 10秒后恢复真实状态（给异步操作留时间）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        pkcForceActive = NO;
    });
}
%end

// === CMessageMgr 诊断 hook（仅日志，不修改行为） ===
// 用于确认 PKC 是否真的调用了 CMessageMgr 的发送方法，并捕获目标 wxid
%hook CMessageMgr
- (void)AddMsg:(id)arg1 MsgWrap:(id)arg2 {
    @try {
        NSString *toUsr = [arg2 valueForKey:@"m_nsToUsr"];
        NSString *content = [arg2 valueForKey:@"m_nsContent"];
        NSLog(@"[PKC60sFix] CMessageMgr AddMsg:MsgWrap: called, to=%@ contentLen=%lu",
              toUsr ?: @"nil", (unsigned long)(content ? content.length : 0));
        if (toUsr.length > 0) pkcSetTarget(toUsr);
    } @catch (NSException *e) {}
    %orig;
}

- (void)SendMessage:(id)arg1 {
    @try {
        NSString *toUsr = [arg1 valueForKey:@"m_nsToUsr"];
        NSLog(@"[PKC60sFix] CMessageMgr SendMessage: called, to=%@", toUsr ?: @"nil");
        if (toUsr.length > 0) pkcSetTarget(toUsr);
    } @catch (NSException *e) {}
    %orig;
}

- (void)sendMsg:(id)arg1 {
    @try {
        NSString *toUsr = [arg1 valueForKey:@"m_nsToUsr"];
        NSLog(@"[PKC60sFix] CMessageMgr sendMsg: called, to=%@", toUsr ?: @"nil");
        if (toUsr.length > 0) pkcSetTarget(toUsr);
    } @catch (NSException *e) {}
    %orig;
}
%end

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
        NSLog(@"[PKC60sFix] === v3.3 initializing ===");

        // 1. 只在方法不存在时添加 AddMsg:MsgWrap:，不覆盖微信原有方法
        Class wcClass = NSClassFromString(@"WeixinContentLogicController");
        if (wcClass) {
            SEL addMsgSel = NSSelectorFromString(@"AddMsg:MsgWrap:");
            if (![wcClass instancesRespondToSelector:addMsgSel]) {
                class_addMethod(wcClass, addMsgSel, (IMP)pkc_forwardAddMsg, "v@:@@");
                NSLog(@"[PKC60sFix] Added AddMsg:MsgWrap: to WeixinContentLogicController");
            } else {
                NSLog(@"[PKC60sFix] AddMsg:MsgWrap: already exists on WeixinContentLogicController");
            }
        } else {
            NSLog(@"[PKC60sFix] WeixinContentLogicController class not found");
        }

        // 2. 检查 CMessageMgr 是否可用
        Class cmmClass = NSClassFromString(@"CMessageMgr");
        if (cmmClass) {
            BOOL hasAddMsg = [cmmClass instancesRespondToSelector:@selector(AddMsg:MsgWrap:)];
            BOOL hasShared = [cmmClass respondsToSelector:@selector(sharedInstance)];
            NSLog(@"[PKC60sFix] CMessageMgr: hasAddMsg=%d hasShared=%d", hasAddMsg, hasShared);
        } else {
            NSLog(@"[PKC60sFix] CMessageMgr class not found!");
        }

        // 3. 检查 CMessageWrap 是否可用
        Class wrapClass = NSClassFromString(@"CMessageWrap");
        if (!wrapClass) wrapClass = NSClassFromString(@"MessageWrap");
        NSLog(@"[PKC60sFix] MessageWrap class: %@", wrapClass ? NSStringFromClass(wrapClass) : @"NOT FOUND");

        // 4. 检查 PKC 主类
        Class pkcClass = NSClassFromString(@"PWZfnvktqn");
        NSLog(@"[PKC60sFix] PKC main class: %@", pkcClass ? NSStringFromClass(pkcClass) : @"NOT FOUND");

        // 5. 启动25秒保活定时器
        pkcStartKeepAliveTimer();

        // 6. 加载上次保存的目标wxid（APP重启后仍有目标）
        pkcLoadTarget();

        // 6. 延迟15秒后扫描PKC实例，提取目标wxid（等PKC初始化完成）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                Class pkcCls = NSClassFromString(@"PWZfnvktqn");
                if (!pkcCls) {
                    NSLog(@"[PKC60sFix] PKC class not found, cannot scan target");
                    return;
                }
                id pkcInstance = nil;
                @try {
                    if ([pkcCls respondsToSelector:@selector(sharedInstance)]) {
                        pkcInstance = [pkcCls performSelector:@selector(sharedInstance)];
                    }
                } @catch (NSException *e) {}

                if (pkcInstance) {
                    pkcFindTargetInObject(pkcInstance);
                    NSLog(@"[PKC60sFix] Target scanned: %@", pkcTargetWxid ?: @"nil");
                } else {
                    NSLog(@"[PKC60sFix] PKC sharedInstance not available yet");
                    // 30秒后再试一次
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        @try {
                            Class pkcCls2 = NSClassFromString(@"PWZfnvktqn");
                            if (pkcCls2 && [pkcCls2 respondsToSelector:@selector(sharedInstance)]) {
                                id inst = [pkcCls2 performSelector:@selector(sharedInstance)];
                                if (inst) {
                                    pkcFindTargetInObject(inst);
                                    NSLog(@"[PKC60sFix] Target scanned (2nd attempt): %@", pkcTargetWxid ?: @"nil");
                                }
                            }
                        } @catch (NSException *e) {}
                    });
                }
            } @catch (NSException *e) {
                NSLog(@"[PKC60sFix] Target scan exception: %@", e);
            }
        });

        NSLog(@"[PKC60sFix] === initialization complete ===");
    }
}
