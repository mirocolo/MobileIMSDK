//  ----------------------------------------------------------------------
//  Copyright (C) 2020  即时通讯网(52im.net) & Jack Jiang.
//  The MobileIMSDK_X (MobileIMSDK v4.x) Project.
//  All rights reserved.
//
//  > Github地址: https://github.com/JackJiang2011/MobileIMSDK
//  > 文档地址:    http://www.52im.net/forum-89-1.html
//  > 技术社区：   http://www.52im.net/
//  > 技术交流群： 320837163 (http://www.52im.net/topic-qqgroup.html)
//  > 作者公众号： “即时通讯技术圈】”，欢迎关注！
//  > 联系作者：   http://www.52im.net/thread-2792-1-1.html
//
//  "即时通讯网(52im.net) - 即时通讯开发者社区!" 推荐开源工程。
//  ----------------------------------------------------------------------

#import "QoS4SendDaemon.h"
#import "ClientCoreSDK.h"
#import "Protocal.h"
#import "NSMutableDictionary+Ext.h"
#import "LocalDataSender.h"
#import "ErrorCode.h"
#import "CompletionDefine.h"
#import "ToolKits.h"


static int CHECK_INTERVAL = 5000;
static int MESSAGES_JUST$NOW_TIME = 3 * 1000;
static int QOS_TRY_COUNT = 2;


@interface QoS4SendDaemon ()

@property (nonatomic, retain) NSMutableDictionary *sentMessages;
@property (nonatomic, retain) NSMutableDictionary *sendMessagesTimestamp;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL _excuting;
@property (nonatomic, retain) NSTimer *timer;
@property (nonatomic, copy) ObserverCompletion debugObserver_;

@end


@implementation QoS4SendDaemon

static QoS4SendDaemon *instance = nil;

+ (QoS4SendDaemon *)sharedInstance
{
    if (instance == nil)
    {
        instance = [[super allocWithZone:NULL] init];
    }
    return instance;
}

- (id)init
{
    if (![super init])
        return nil;
    
    NSLog(@"ProtocalQoS4SendProvider已经init了！");
    
    self.running = NO;
    self._excuting = NO;
    self.sentMessages = [[NSMutableDictionary alloc] init];
    self.sendMessagesTimestamp = [[NSMutableDictionary alloc] init];
    
    return self;
}

- (void) run
{
    if(!self._excuting)
    {
        NSMutableArray *lostMessages = [[NSMutableArray alloc] init];
        self._excuting = true;
        
        if([ClientCoreSDK isENABLED_DEBUG])
            NSLog(@"【IMCORE-UDP】【QoS】====== 消息发送质量保证线程运行中, 当前需要处理的列表长度为 %li ...", (unsigned long)[self.sentMessages count]);

        NSArray *keyArr = [self.sentMessages allKeys];
        for (NSString *key in keyArr)
        {
            Protocal *p = [self.sentMessages objectForKey:key];
            if(p != nil && p.QoS == YES)
            {
                if([p getRetryCount] >= QOS_TRY_COUNT)
                {
                    if([ClientCoreSDK isENABLED_DEBUG])
                        NSLog(@"【IMCORE-UDP】【QoS】指纹为 %@ 的消息包重传次数已达 %d (最多 %d 次)上限，将判定为丢包！", p.fp, [p getRetryCount], QOS_TRY_COUNT);
                    
                    [lostMessages addObject:[p clone]];
                    [self remove:p.fp];
                }
                else
                {
                    NSNumber *objectValue = [self.sendMessagesTimestamp objectForKey:key];
                    long delta = [ToolKits getTimeStampWithMillisecond_l] - (objectValue == nil ? 0: objectValue.longValue);
                    if(delta <= MESSAGES_JUST$NOW_TIME)
                    {
                        if([ClientCoreSDK isENABLED_DEBUG])
                            NSLog(@"【IMCORE-UDP】【QoS】指纹为%@的包距\"刚刚\"发出才%li ms(<=%d ms将被认定是\"刚刚\"), 本次不需要重传哦.", key, delta, MESSAGES_JUST$NOW_TIME);
                    }
                    else
                    {
                        int sendCode = [[LocalDataSender sharedInstance] sendCommonData:p];
                        if(sendCode == COMMON_CODE_OK)
                        {
                            [p increaseRetryCount];
                            
                            if([ClientCoreSDK isENABLED_DEBUG])
                                NSLog(@"【IMCORE-UDP】【QoS】指纹为%@的消息包已成功进行重传，此次之后重传次数已达%d(最多%d次).", p.fp, [p getRetryCount], QOS_TRY_COUNT);
                        }
                        else
                        {
                            NSLog(@"【IMCORE-UDP】【QoS】指纹为%@的消息包重传失败，它的重传次数之前已累计为%d(最多%d次).", p.fp, [p getRetryCount], QOS_TRY_COUNT);
                        }
                    }
                }
            }
            else
            {
                [self remove:key];
            }
        }
        
        if(lostMessages != nil && [lostMessages count] > 0)
            [self notifyMessageLost:lostMessages];
        
        self._excuting = NO;
        
        // form DEBUG
        if(self.debugObserver_ != nil)
            self.debugObserver_(nil, [NSNumber numberWithInt:2]);
    }
}

- (void) notifyMessageLost:(NSMutableArray *)lostMsgs
{
    if([ClientCoreSDK sharedInstance].messageQoSEvent != nil)
    {
        [[ClientCoreSDK sharedInstance].messageQoSEvent messagesLost:lostMsgs];
    }
}

- (void) startup:(BOOL)immediately
{
    [self stop];
    
    self.timer = [NSTimer scheduledTimerWithTimeInterval:CHECK_INTERVAL / 1000 target:self selector:@selector(run) userInfo:nil repeats:YES];
    if(immediately)
        [self.timer fire];
    self.running = YES;
    
    // form DEBUG
    if(self.debugObserver_ != nil)
        self.debugObserver_(nil, [NSNumber numberWithInt:1]);
}

- (void) stop
{
    if(self.timer != nil)
    {
        if([self.timer isValid])
            [self.timer invalidate];
        
        self.timer = nil;
    }
    self.running = NO;
    
    // form DEBUG
    if(self.debugObserver_ != nil)
        self.debugObserver_(nil, [NSNumber numberWithInt:0]);
}

- (BOOL) isRunning
{
    return self.running;
}

- (BOOL) exist:(NSString *)fingerPrint
{
    return [self.sentMessages containsKey:fingerPrint];
}

- (void) put:(Protocal *)p
{
    if(p == nil)
    {
        NSLog(@"Invalid arg p==null.");
        return;
    }

    if(p.fp == nil)
    {
        NSLog(@"Invalid arg p.getFp() == null.");
        return;
    }
    
    if(!p.QoS)
    {
        NSLog(@"This protocal is not QoS pkg, ignore it!");
        return;
    }
    
    if([self.sentMessages containsKey:p.fp])
        NSLog(@"【IMCORE-UDP】【QoS】指纹为 %@ 的消息已经放入了发送质量保证队列，该消息为何会重复？（生成的指纹码重复？还是重复put？）", p.fp);
    
    [self.sentMessages setObject:p forKey:p.fp];
    [self.sendMessagesTimestamp setObject:[NSNumber numberWithLong:[ToolKits getTimeStampWithMillisecond_l]] forKey:p.fp];
}

- (void) remove:(NSString *) fingerPrint
{
    if([self.sentMessages containsKey:fingerPrint])
    {
        Protocal *p = [self.sentMessages objectForKey:fingerPrint];
        [self.sendMessagesTimestamp removeObjectForKey:fingerPrint];
        [self.sentMessages removeObjectForKey:fingerPrint];
        NSLog(@"【IMCORE-UDP】【QoS】指纹为%@的消息已成功从发送质量保证队列中移除(可能是收到接收方的应答也可能是达到了重传的次数上限)，重试次数=%d", fingerPrint, [p getRetryCount]);
    }
    else
    {
        NSLog(@"【IMCORE-UDP】【QoS】指纹为%@的消息已成功从发送质量保证队列中移除(可能是收到接收方的应答也可能是达到了重传的次数上限)，重试次数=none呵呵.", fingerPrint);
    }
}

- (void) clear
{
    [self.sentMessages removeAllObjects];
    [self.sendMessagesTimestamp removeAllObjects];
}

- (unsigned long) size
{
    return [self.sentMessages count];
}

- (void) setDebugObserver:(ObserverCompletion)debugObserver
{
    self.debugObserver_ = debugObserver;
}


@end
