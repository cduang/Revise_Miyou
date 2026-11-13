#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Engine.h"
#import "BuildInfo.h"
#include <string.h>
// This source does not link or invoke MiYou. Private WeChat APIs are an unverified adapter.
static NSString *const ConfigKey=@"ReviseKeywordStandalone.Config.v1";
static NSString *statusText=@"等待适配微信接口（尚未实机验证）";
static BOOL receiveReady;
static NSTimeInterval loadedAt;
static NSMutableDictionary<NSString *,NSNumber *> *lastReply;
static NSMutableSet<NSString *> *seen;
static NSMutableArray<NSString *> *seenOrder;
static NSDictionary *config(void) {
    id c=[NSUserDefaults.standardUserDefaults dictionaryForKey:ConfigKey];
    return c?:@{@"enabled":@NO,@"schedule":@NO,@"start":@480,@"end":@1380,@"rules":@[]};
}
static void save(NSDictionary *c) {[NSUserDefaults.standardUserDefaults setObject:c forKey:ConfigKey];}
static BOOL conflict(void) {return NSClassFromString(@"MYReplyConfig")!=Nil;}
static const char *plain(const char *t) {while(*t && strchr("rnNoORV",*t))t++;return t;}
static BOOL signature(Class cls, SEL sel, BOOL meta, const char *ret, NSArray<NSString *> *args) {
    if(!cls)return NO;
    Method m=meta?class_getClassMethod(cls,sel):class_getInstanceMethod(cls,sel);
    if(!m || method_getNumberOfArguments(m)!=args.count+2)return NO;
    char t[128]={0};method_getReturnType(m,t,sizeof(t));if(strcmp(plain(t),ret))return NO;
    for(NSUInteger i=0;i<args.count;i++) {method_getArgumentType(m,(unsigned)i+2,t,sizeof(t));if(strcmp(plain(t),args[i].UTF8String))return NO;}
    return YES;
}
static id readValue(id o, NSString *key) {@try {return [o valueForKey:key];}@catch(NSException *e){return nil;}}
static id service(NSString *name) {
    Class center=NSClassFromString(@"MMServiceCenter"),target=NSClassFromString(name);
    SEL shared=NSSelectorFromString(@"defaultCenter"),get=NSSelectorFromString(@"getService:");
    if(!target || !signature(center,shared,YES,"@",@[]) || !signature(center,get,NO,"@",@[@"#"]))return nil;
    id c=((id(*)(id,SEL))objc_msgSend)(center,shared);
    return ((id(*)(id,SEL,Class))objc_msgSend)(c,get,target);
}
static NSString *selfName(void) {
    id mgr=service(@"CContactMgr");SEL s=NSSelectorFromString(@"getSelfContact");
    if(!signature([mgr class],s,NO,"@",@[]))return nil;
    id contact=((id(*)(id,SEL))objc_msgSend)(mgr,s);
    id name=readValue(contact,@"m_nsUsrName");return [name isKindOfClass:NSString.class]?name:nil;
}
static BOOL eligiblePeer(NSString *peer) {
    if(![peer isKindOfClass:NSString.class] || !peer.length || [peer containsString:@"@"] || [peer hasPrefix:@"gh_"])return NO;
    return ![@[@"filehelper",@"weixin",@"newsapp",@"fmessage",@"medianote",@"floatbottle",@"qqmail",@"notification_messages"] containsObject:peer];
}
static BOOL sendText(NSString *peer, NSString *text, NSString *me) {
    Class wrap=NSClassFromString(@"CMessageWrap");SEL init=NSSelectorFromString(@"initWithMsgType:"),add=NSSelectorFromString(@"AddMsg:MsgWrap:");
    id mgr=service(@"CMessageMgr");
    if(!signature(wrap,init,NO,"@",@[@"I"]) || !signature([mgr class],add,NO,"v",@[@"@",@"@"]))return NO;
    // Require public runtime setters with the expected ABI; do not write raw ivar offsets.
    for(NSString *s in @[@"setM_nsFromUsr:",@"setM_nsToUsr:",@"setM_nsContent:"])
        if(!signature(wrap,NSSelectorFromString(s),NO,"v",@[@"@"]))return NO;
    for(NSString *s in @[@"setM_uiStatus:",@"setM_uiCreateTime:"])
        if(!signature(wrap,NSSelectorFromString(s),NO,"v",@[@"I"]))return NO;
    id msg=((id(*)(id,SEL,unsigned int))objc_msgSend)([wrap alloc],init,1);
    if(!msg)return NO;
    [msg setValue:me forKey:@"m_nsFromUsr"];[msg setValue:peer forKey:@"m_nsToUsr"];
    [msg setValue:text forKey:@"m_nsContent"];[msg setValue:@1 forKey:@"m_uiStatus"];
    [msg setValue:@((unsigned int)NSDate.date.timeIntervalSince1970) forKey:@"m_uiCreateTime"];
    // Last check is immediately before sending. No delayed-send queue is used.
    if(conflict() || !RKWAllowed(config(),NSDate.date) || ![selfName() isEqual:me])return NO;
    ((void(*)(id,SEL,id,id))objc_msgSend)(mgr,add,peer,msg);return YES;
}
static void process(NSDictionary *m) {
    @try {
        if(conflict()) {statusText=@"检测到旧原插件：已停用独立版回复，请移除原库和旧补丁";return;}
        NSDictionary *c=config();if(!RKWAllowed(c,NSDate.date))return;
        NSString *peer=m[@"from"],*me=selfName();
        if(!me.length || !eligiblePeer(peer) || [peer isEqual:me] || ![m[@"to"] isEqual:me] || ![m[@"session"] isEqual:peer])return;
        double created=[m[@"time"] doubleValue],now=NSDate.date.timeIntervalSince1970;
        if(created<loadedAt || now-created>120 || created>now+5 || [m[@"type"] unsignedIntValue]!=1)return;
        NSString *msgID=m[@"id"];if(!msgID.length || [seen containsObject:msgID])return;
        [seen addObject:msgID];[seenOrder addObject:msgID];
        if(seenOrder.count>2048){[seen removeObject:seenOrder.firstObject];[seenOrder removeObjectAtIndex:0];}
        NSDictionary *rule=RKWMatch(c[@"rules"],m[@"text"]);if(!rule)return;
        NSString *key=[NSString stringWithFormat:@"%@|%@",me,peer];
        if(lastReply[key] && now-[lastReply[key] doubleValue]<60)return;
        // At most 1000 active cooldown entries, without evicting a live cooldown.
        for(NSString *k in lastReply.allKeys)if(now-[lastReply[k] doubleValue]>=60)[lastReply removeObjectForKey:k];
        if(lastReply.count>=1000)return;
        lastReply[key]=@(now); // reserve before invoking WeChat (prevents reentrant loops)
        if(sendText(peer,rule[@"reply"],me))statusText=@"已调用微信发送接口；送达状态未验证";
        else statusText=@"发送已跳过：时间、账号或微信接口检查未通过";
    }@catch(NSException *e){statusText=@"适配异常：本条回复已停止（不记录聊天内容）";}
}
static void (*originalReceive)(id,SEL,id,id);
static void receiveMessage(id self,SEL cmd,id session,id wrap) {
    originalReceive(self,cmd,session,wrap);
    @try {
        if(![session isKindOfClass:NSString.class])return;
        id from=readValue(wrap,@"m_nsFromUsr"),to=readValue(wrap,@"m_nsToUsr"),text=readValue(wrap,@"m_nsContent");
        id time=readValue(wrap,@"m_uiCreateTime"),type=readValue(wrap,@"m_uiMessageType");
        id svr=readValue(wrap,@"m_n64MesSvrID"),local=readValue(wrap,@"m_uiMesLocalID");
        if(![from isKindOfClass:NSString.class] || ![to isKindOfClass:NSString.class] || ![text isKindOfClass:NSString.class] || ![time isKindOfClass:NSNumber.class] || ![type isKindOfClass:NSNumber.class])return;
        NSString *ident=nil;
        if([svr isKindOfClass:NSNumber.class] && [svr unsignedLongLongValue])ident=[NSString stringWithFormat:@"%@|%@|s%@",to,from,svr];
        else if([local isKindOfClass:NSNumber.class] && [local unsignedLongLongValue])ident=[NSString stringWithFormat:@"%@|%@|l%@|%@",to,from,local,time];
        if(!ident)return;
        NSDictionary *m=@{@"from":[from copy],@"to":[to copy],@"text":[text copy],@"session":[session copy],@"time":time,@"type":type,@"id":ident};
        dispatch_async(dispatch_get_main_queue(),^{process(m);});
    }@catch(NSException *e) { /* Do not leak message content to logs. */ }
}
static BOOL installReceive(void) {
    Class cls=NSClassFromString(@"CMessageMgr");SEL s=NSSelectorFromString(@"AsyncOnAddMsg:MsgWrap:");
    if(!signature(cls,s,NO,"v",@[@"@",@"@"]))return NO;
    Method m=class_getInstanceMethod(cls,s);originalReceive=(void *)method_getImplementation(m);
    if(!class_addMethod(cls,s,(IMP)receiveMessage,method_getTypeEncoding(m)))method_setImplementation(m,(IMP)receiveMessage);
    receiveReady=YES;statusText=@"接收 Hook 已安装；私聊收发及后台行为尚待实机验证";return YES;
}
@interface RKWSettings : UITableViewController
@end
@implementation RKWSettings
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"关键词自动回复（独立版）";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addRule)];
    UILabel *footer=[[UILabel alloc]initWithFrame:CGRectMake(16,0,300,190)];footer.numberOfLines=0;footer.textAlignment=NSTextAlignmentCenter;footer.font=[UIFont systemFontOfSize:12];footer.textColor=UIColor.secondaryLabelColor;
    footer.text=[NSString stringWithFormat:@"ReviseKeywordStandalone %s\n编译：%s\n提交：%s\n独立开源实现，不依赖 MiYou；非原作者发布。\n仅新收到的私聊文本；区分大小写；首条匹配。\n每个联系人最多每60秒回复一次。\n在线区间内不回复；相同起止不暂停。\n进程挂起/被杀后无法回复；不保证后台在线。\n实验版本，请先用测试账号验证。",RKW_VERSION,RKW_BUILD,RKW_COMMIT];self.tableView.tableFooterView=footer;
}
- (void)close {[self dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {return 3;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {return s==0?3:s==1?[config()[@"rules"] count]:1;}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {return @[@"开关与在线时间",@"关键词规则（右上角添加，左滑删除）",@"运行状态"][s];}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];NSDictionary *c=config();
    if(p.section==0 && p.row<2) {
        cell.textLabel.text=p.row==0?@"启用关键词自动回复":@"启用在线时间限制";
        UISwitch *s=[[UISwitch alloc]init];s.tag=p.row;s.on=[c[p.row==0?@"enabled":@"schedule"] boolValue];[s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=s;
    } else if(p.section==0) {
        cell.textLabel.text=@"在线时间段（期间不回复）";cell.detailTextLabel.text=[NSString stringWithFormat:@"%@-%@",RKWTime([c[@"start"] integerValue]),RKWTime([c[@"end"] integerValue])];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if(p.section==1) {
        NSDictionary *r=c[@"rules"][p.row];cell.textLabel.text=[NSString stringWithFormat:@"%@ · %@",[r[@"mode"] isEqual:@"exact"]?@"精确":@"包含",r[@"keyword"]];cell.detailTextLabel.text=r[@"reply"];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else {cell.textLabel.text=conflict()?@"检测到原插件，独立回复已停用":(receiveReady?@"接收适配已安装":@"微信接收接口未匹配，无法自动回复");cell.detailTextLabel.text=statusText;cell.detailTextLabel.numberOfLines=0;}
    return cell;
}
- (void)toggle:(UISwitch *)s {NSMutableDictionary *c=[config() mutableCopy];c[s.tag==0?@"enabled":@"schedule"]=@(s.on);save(c);[self.tableView reloadData];}
- (void)notice:(NSString *)s {UIAlertController *a=[UIAlertController alertControllerWithTitle:@"提示" message:s preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];
    if(p.section==1){[self editRule:p.row];return;}
    if(p.section==2){[t reloadData];return;}
    if(p.row!=2)return;
    NSDictionary *c=config();UIAlertController *a=[UIAlertController alertControllerWithTitle:@"在线时间段（期间不回复）" message:@"输入08:00-23:00；区间包含开始、不包含结束。支持跨午夜；相同起止不暂停。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=[NSString stringWithFormat:@"%@-%@",RKWTime([c[@"start"] integerValue]),RKWTime([c[@"end"] integerValue])];}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *w=a;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSInteger start,end;if(!RKWParseTime(w.textFields.firstObject.text,&start,&end)){dispatch_async(dispatch_get_main_queue(),^{[self notice:@"格式错误，未保存。请填写HH:mm-HH:mm。"];} );return;}NSMutableDictionary *c=[config() mutableCopy];c[@"start"]=@(start);c[@"end"]=@(end);save(c);[self.tableView reloadData];}]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)addRule {[self editRule:NSNotFound];}
- (void)editRule:(NSInteger)index {
    NSArray *rules=config()[@"rules"];NSDictionary *r=index==NSNotFound?@{}:rules[index];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"关键词规则" message:@"区分大小写；按照列表顺序选择首条匹配。" preferredStyle:UIAlertControllerStyleAlert];
    for(NSString *k in @[@"keyword",@"reply"]) [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=[k isEqual:@"keyword"]?@"关键词（1-512字）":@"回复文本（1-2048字）";f.text=r[k];}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];__weak UIAlertController *w=a;
    for(NSString *mode in @[@"exact",@"contains"]) [a addAction:[UIAlertAction actionWithTitle:[mode isEqual:@"exact"]?@"保存为精确匹配":@"保存为包含匹配" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *k=w.textFields[0].text,*reply=w.textFields[1].text;
        if(!k.length || k.length>512 || !reply.length || reply.length>2048){dispatch_async(dispatch_get_main_queue(),^{[self notice:@"关键词或回复为空、或长度超出限制，未保存。"];} );return;}
        NSMutableDictionary *c=[config() mutableCopy];NSMutableArray *list=[c[@"rules"] mutableCopy];NSDictionary *item=@{@"keyword":k,@"reply":reply,@"mode":mode,@"enabled":@YES};
        if(index==NSNotFound){if(list.count>=100){dispatch_async(dispatch_get_main_queue(),^{[self notice:@"最多100条规则。"];} );return;}[list addObject:item];}else if(index<list.count)list[index]=item;
        c[@"rules"]=list;save(c);[self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)p {return p.section==1;}
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)s forRowAtIndexPath:(NSIndexPath *)p {if(s!=UITableViewCellEditingStyleDelete)return;NSMutableDictionary *c=[config() mutableCopy];NSMutableArray *r=[c[@"rules"] mutableCopy];[r removeObjectAtIndex:p.row];c[@"rules"]=r;save(c);[t reloadData];}
@end
@interface RKWEntry : NSObject
+ (instancetype)shared;
- (void)open:(id)sender;
@end
@implementation RKWEntry
+ (instancetype)shared {static RKWEntry *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
- (void)open:(UIBarButtonItem *)sender {
    UIViewController *vc=objc_getAssociatedObject(sender,@selector(open:));
    if(vc && !vc.presentedViewController){UINavigationController *nav=[[UINavigationController alloc]initWithRootViewController:[[RKWSettings alloc]initWithStyle:UITableViewStyleInsetGrouped]];[vc presentViewController:nav animated:YES completion:nil];}
}
@end
static void (*originalAppear)(id,SEL,BOOL);
static char entryKey;
static void appeared(id self,SEL cmd,BOOL animated) {
    originalAppear(self,cmd,animated);
    NSString *name=NSStringFromClass([self class]);
    // Candidate WeChat settings class names, not verified against a supplied WeChat executable.
    if(![@[@"NewSettingViewController",@"MMNewSettingViewController"] containsObject:name])return;
    UIViewController *vc=self;
    if(objc_getAssociatedObject(vc,&entryKey))return;
    UIBarButtonItem *b=[[UIBarButtonItem alloc]initWithTitle:@"关键词回复" style:UIBarButtonItemStylePlain target:[RKWEntry shared] action:@selector(open:)];
    objc_setAssociatedObject(b,@selector(open:),vc,OBJC_ASSOCIATION_ASSIGN);
    NSMutableArray *items=[vc.navigationItem.rightBarButtonItems mutableCopy]?:[NSMutableArray array];[items addObject:b];vc.navigationItem.rightBarButtonItems=items;
    objc_setAssociatedObject(vc,&entryKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
__attribute__((constructor)) static void start(void) {
    @autoreleasepool {
        loadedAt=NSDate.date.timeIntervalSince1970;
        dispatch_async(dispatch_get_main_queue(),^{
            seen=[NSMutableSet set];seenOrder=[NSMutableArray array];lastReply=[NSMutableDictionary dictionary];
            // One UIKit hook for a visible settings navigation button; no gesture or MiYou UI dependency.
            Method m=class_getInstanceMethod(UIViewController.class,@selector(viewDidAppear:));
            originalAppear=(void *)method_getImplementation(m);method_setImplementation(m,(IMP)appeared);
            __block NSUInteger attempts=0;
            dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
            dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);
            dispatch_source_set_event_handler(timer,^{
                if(conflict()){statusText=@"检测到原插件，请移除原库与旧补丁";dispatch_source_cancel(timer);}
                else if(installReceive() || ++attempts>=120){if(!receiveReady)statusText=@"接收接口不匹配：未启用自动回复";dispatch_source_cancel(timer);}
            });dispatch_source_set_cancel_handler(timer,^{dispatch_source_set_event_handler(timer,nil);});dispatch_resume(timer);
        });
    }
}
