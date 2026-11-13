#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#import "TimeWindow.h"
#import "BuildInfo.h"
static NSString *const Enabled = @"ReviseMiyou.KeywordSchedule.Enabled";
static NSString *const Start = @"ReviseMiyou.KeywordSchedule.Start";
static NSString *const End = @"ReviseMiyou.KeywordSchedule.End";
static BOOL (*originalGetter)(id, SEL);
static void (*originalSection)(id, SEL);
static void (*originalAddSection)(id, SEL, id);
static __thread void *buildingController;
static __thread unsigned settingsDepth;
static BOOL filteredGetter(id self, SEL cmd) {
    BOOL original = originalGetter(self, cmd);
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:NSDate.date];
    return MYKeywordAllowed(original, [d boolForKey:Enabled], settingsDepth != 0, (int)(c.hour*60+c.minute), (int)[d integerForKey:Start], (int)[d integerForKey:End]);
}
static BOOL parseTime(NSString *s, int *out) {
    if(s.length != 5 || [s characterAtIndex:2] != ':') return NO;
    for(NSUInteger i=0;i<5;i++) if(i!=2 && ([s characterAtIndex:i]<'0'||[s characterAtIndex:i]>'9')) return NO;
    int h=[[s substringToIndex:2] intValue], m=[[s substringFromIndex:3] intValue];
    if(h>23||m>59) return NO; *out=h*60+m; return YES;
}
static NSString *formatTime(NSInteger t) { return [NSString stringWithFormat:@"%02ld:%02ld",(long)(t/60),(long)(t%60)]; }
// Use the original plugin's cell factories; no gestures or overlay controls.
static void reloadSettings(id self) {
    SEL sel=NSSelectorFromString(@"reloadTableViewData");
    if ([self respondsToSelector:sel]) {
        settingsDepth++;
        @try { ((void(*)(id,SEL))objc_msgSend)(self,sel); }
        @finally { settingsDepth--; }
    }
}
static void scheduleChanged(id self, SEL cmd, id sender) {
    if (![sender respondsToSelector:@selector(isOn)]) return;
    BOOL enabled=((BOOL(*)(id,SEL))objc_msgSend)(sender,@selector(isOn));
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:Enabled];
    reloadSettings(self);
}
// Independent editor: available immediately, without touching the original editor.
static void editSchedule(id self, SEL cmd) {
    UIViewController *vc=(UIViewController *)self;
    if(vc.presentedViewController) return;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"关键词在线时间段" message:@"在线时段内暂停关键词回复，范围外按原规则回复。支持跨午夜；相同起止不暂停。保存不会改变开关状态。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder=@"08:00-23:00";
        field.text=[NSString stringWithFormat:@"%@-%@",formatTime([d integerForKey:Start]),formatTime([d integerForKey:End])];
        field.autocorrectionType=UITextAutocorrectionTypeNo;
        field.autocapitalizationType=UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *value=[weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        value=[value stringByReplacingOccurrencesOfString:@"：" withString:@":"];
        value=[value stringByReplacingOccurrencesOfString:@"–" withString:@"-"];
        value=[value stringByReplacingOccurrencesOfString:@"－" withString:@"-"];
        NSArray *parts=[value componentsSeparatedByString:@"-"]; int start,end;
        if(parts.count!=2 || !parseTime(parts[0],&start) || !parseTime(parts[1],&end)) {
            dispatch_async(dispatch_get_main_queue(),^{
                UIAlertController *error=[UIAlertController alertControllerWithTitle:@"未保存：时间格式错误" message:@"请输入 HH:mm-HH:mm，例如 08:00-23:00。原时间和开关保持不变。" preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
                [vc presentViewController:error animated:YES completion:nil];
            });
            return;
        }
        [d setInteger:start forKey:Start]; [d setInteger:end forKey:End];
        reloadSettings(self);
    }]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void addSection(id self, SEL cmd, id section) {
    id owner=(__bridge id)buildingController;
    if(owner && [section respondsToSelector:NSSelectorFromString(@"addCell:")]) {
        NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
        id toggle=((id(*)(id,SEL,SEL,id,BOOL))objc_msgSend)(owner,NSSelectorFromString(@"addSwitchCellForSel:title:on:"),NSSelectorFromString(@"rmy_scheduleChanged:"),@"启用在线时间限制",[d boolForKey:Enabled]);
        NSString *value=[NSString stringWithFormat:@"%@–%@",formatTime([d integerForKey:Start]),formatTime([d integerForKey:End])];
        id time=((id(*)(id,SEL,SEL,id,id))objc_msgSend)(owner,NSSelectorFromString(@"addNormalCellForSel:title:rightValue:"),NSSelectorFromString(@"rmy_editSchedule"),@"在线时间段（期间不回复）",value);
        SEL add=NSSelectorFromString(@"addCell:");
        if(toggle) ((void(*)(id,SEL,id))objc_msgSend)(section,add,toggle);
        if(time) ((void(*)(id,SEL,id))objc_msgSend)(section,add,time);
    }
    originalAddSection(self,cmd,section);
}
static void keywordSection(id self, SEL cmd) {
    void *previous=buildingController;
    buildingController=(__bridge void *)self; settingsDepth++;
    @try { originalSection(self,cmd); }
    @finally { settingsDepth--; buildingController=previous; }
}
static void replaceMethod(Class cls, SEL sel, IMP replacement) {
    Method m=class_getInstanceMethod(cls,sel);
    if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(m))) method_setImplementation(m,replacement);
}
static BOOL installGetter(void) {
    Class cls=NSClassFromString(@"MYReplyConfig"); SEL sel=NSSelectorFromString(@"mIsKeywordReplyMessage"); Method m=class_getInstanceMethod(cls,sel);
    if(!m || method_getNumberOfArguments(m)!=2) return NO;
    char ret[16]={0};method_getReturnType(m,ret,sizeof(ret));
    if(strcmp(ret,"B")!=0) {NSLog(@"[ReviseMiyou] incompatible getter signature");return NO;}
    originalGetter=(void *)method_getImplementation(m);
    if(!class_addMethod(cls,sel,(IMP)filteredGetter,method_getTypeEncoding(m))) method_setImplementation(m,(IMP)filteredGetter);
    NSLog(@"[ReviseMiyou] experimental keyword schedule installed"); return YES;
}
static BOOL hasSignature(Class cls, SEL sel, unsigned count, const char *ret) {
    Method m=class_getInstanceMethod(cls,sel);
    if(!m || method_getNumberOfArguments(m)!=count) return NO;
    char type[32]={0};method_getReturnType(m,type,sizeof(type));
    return strcmp(type,ret)==0;
}
static void (*originalLayout)(id,SEL);
static char footerKey;
static UITableView *findTable(UIView *view) {
    if([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for(UIView *child in view.subviews) {UITableView *t=findTable(child);if(t)return t;}
    return nil;
}
static void settingsLayout(id self, SEL cmd) {
    originalLayout(self,cmd);
    UITableView *table=findTable(((UIViewController *)self).view);if(!table)return;
    UIView *container=objc_getAssociatedObject(table,&footerKey);
    if(container && table.tableFooterView==container)return;
    UIView *old=table.tableFooterView;
    CGFloat width=table.bounds.size.width;if(width<=0)return;
    NSString *text=[NSString stringWithFormat:@"Revise_Miyou %@ · 独立修改补丁\n编译时间：%@\n提交：%@ · Actions #%@\n作用于 MiYou：关键词在线时间限制、设置弹窗适配、本地关注检查兼容\n原 MiYou.dylib 未改写；非原作者发布；不代表已完成安全审计。",@RMY_VERSION,@RMY_BUILD_TIME,@RMY_COMMIT,@RMY_RUN];
    UILabel *label=[[UILabel alloc]init];label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;
    label.font=[UIFont systemFontOfSize:11];label.textColor=UIColor.secondaryLabelColor;label.text=text;
    CGFloat oldHeight=old?old.frame.size.height:0;
    CGFloat height=ceil([label sizeThatFits:CGSizeMake(MAX(1,width-32),CGFLOAT_MAX)].height)+24;
    container=[[UIView alloc]initWithFrame:CGRectMake(0,0,width,oldHeight+height)];
    if(old){[old removeFromSuperview];old.frame=CGRectMake(0,0,width,oldHeight);[container addSubview:old];}
    label.frame=CGRectMake(16,oldHeight+12,width-32,height-24);label.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [container addSubview:label];objc_setAssociatedObject(table,&footerKey,container,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    table.tableFooterView=container;
}
static BOOL installUI(void) {
    Class cls=NSClassFromString(@"MiYouSettingViewController");
    Class manager=NSClassFromString(@"WCTableViewManager");
    SEL section=NSSelectorFromString(@"addKeywordMessageSection"),add=NSSelectorFromString(@"addSection:");
    if(!hasSignature(cls,section,2,"v") || !hasSignature(manager,add,3,"v") ||
       !hasSignature(cls,NSSelectorFromString(@"addSwitchCellForSel:title:on:"),5,"@") ||
       !hasSignature(cls,NSSelectorFromString(@"addNormalCellForSel:title:rightValue:"),5,"@")) return NO;
    if(class_getInstanceMethod(cls,NSSelectorFromString(@"rmy_scheduleChanged:")) || class_getInstanceMethod(cls,NSSelectorFromString(@"rmy_editSchedule"))) return NO;
    class_addMethod(cls,NSSelectorFromString(@"rmy_scheduleChanged:"),(IMP)scheduleChanged,"v@:@");
    class_addMethod(cls,NSSelectorFromString(@"rmy_editSchedule"),(IMP)editSchedule,"v@:");
    originalSection=(void *)method_getImplementation(class_getInstanceMethod(cls,section));
    originalAddSection=(void *)method_getImplementation(class_getInstanceMethod(manager,add));
    replaceMethod(manager,add,(IMP)addSection);
    replaceMethod(cls,section,(IMP)keywordSection);
    SEL layout=@selector(viewDidLayoutSubviews);
    if(hasSignature(cls,layout,2,"v")) {
        originalLayout=(void *)method_getImplementation(class_getInstanceMethod(cls,layout));
        replaceMethod(cls,layout,(IMP)settingsLayout);
    }
    NSLog(@"[ReviseMiyou] inline keyword schedule and build footer installed (v5)");
    return YES;
}
// This only bypasses the local follow prerequisite. It is not a security fix.
static BOOL followSatisfied(id self, SEL cmd) { return YES; }
static BOOL installFollowCompatibility(void) {
    Class cls=NSClassFromString(@"MiYouConfig"); SEL sel=NSSelectorFromString(@"isFollowAuthor");
    if(!hasSignature(cls,sel,2,"B")) return NO;
    replaceMethod(cls,sel,(IMP)followSatisfied);
    NSLog(@"[ReviseMiyou] local follow prerequisite bypass installed"); return YES;
}
__attribute__((constructor)) static void initSchedule(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{Enabled:@NO,Start:@480,End:@1380}];
        __block BOOL getter=NO,ui=NO,follow=NO; __block int attempts=0;
        dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
        dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);
        dispatch_source_set_event_handler(timer,^{
            if(!getter) getter=installGetter(); if(!ui) ui=installUI();
            if(!follow) follow=installFollowCompatibility();
            if((getter&&ui&&follow)||++attempts>=120) {NSLog(@"[ReviseMiyou] getter=%d UI=%d",getter,ui);dispatch_source_cancel(timer);}
        });dispatch_resume(timer);
    });
}
