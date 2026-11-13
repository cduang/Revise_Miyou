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
    if (settingsDepth || !original || ![d boolForKey:Enabled]) return original;
    NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:NSDate.date];
    return !MYInWindow((int)(c.hour*60+c.minute), (int)[d integerForKey:Start], (int)[d integerForKey:End]);
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
// Capture the exact class instantiated while the ORIGINAL time editor executes.
static Class observedAlertClass;
static unsigned originalEditorDepth;
static void (*originalTimeEditor)(id, SEL);
static char initHookKey;
static id captureAlertInit(id self, SEL cmd, id title, id message) {
    Class cls=object_getClass(self);
    NSValue *stored=nil;
    for(Class c=cls;c && !stored;c=class_getSuperclass(c)) stored=objc_getAssociatedObject(c,&initHookKey);
    id (*imp)(id,SEL,id,id)=(void *)stored.pointerValue;
    if(!imp) return nil;
    id result=imp(self,cmd,title,message);
    if(originalEditorDepth && result) {
        observedAlertClass=object_getClass(result);
        NSLog(@"[ReviseMiyou] confirmed original time alert class: %@",NSStringFromClass(observedAlertClass));
    }
    return result;
}
static void observeTimeEditor(id self, SEL cmd) {
    originalEditorDepth++;
    @try { originalTimeEditor(self,cmd); }
    @finally { originalEditorDepth--; }
}
static BOOL alertAPI(Class cls) {
    NSArray *names=@[@"initWithTitle:message:",@"showTextFieldWithMaxLen:",@"setTextFieldDefaultText:",@"getTextFieldText",@"addBtnTitle:handler:",@"addCancelBtnTitle:target:sel:",@"show"];
    unsigned counts[]={4,3,3,2,4,5,2};
    for(unsigned j=0;j<names.count;j++) {
        Method m=class_getInstanceMethod(cls,NSSelectorFromString(names[j]));
        if(!m || method_getNumberOfArguments(m)!=counts[j]) return NO;
    }
    return YES;
}
static void installAlertObservation(void) {
    unsigned count=0; Class *classes=objc_copyClassList(&count);
    SEL sel=NSSelectorFromString(@"initWithTitle:message:");
    // Only hook implementations owned by the class, avoiding inherited IMP recursion.
    for(unsigned i=0;i<count;i++) {
        Class cls=classes[i]; if(!alertAPI(cls)) continue;
        unsigned n=0;Method *methods=class_copyMethodList(cls,&n);
        for(unsigned j=0;j<n;j++) if(method_getName(methods[j])==sel) {
            Method m=methods[j];
            objc_setAssociatedObject(cls,&initHookKey,[NSValue valueWithPointer:method_getImplementation(m)],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            method_setImplementation(m,(IMP)captureAlertInit);
            break;
        }
        free(methods);
    }
    free(classes);
}
static Class nativeAlertClass(void) { return observedAlertClass; }
static BOOL showNativeSchedule(id owner) {
    Class cls=nativeAlertClass(); if(!cls) return NO;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    id a=((id(*)(id,SEL))objc_msgSend)((id)cls,@selector(alloc));
    a=((id(*)(id,SEL,id,id))objc_msgSend)(a,NSSelectorFromString(@"initWithTitle:message:"),@"关键词在线时间段",@"请输入 HH:mm-HH:mm，例如 08:00-23:00。该时段不回复，范围外按原规则回复；支持跨午夜。相同起止表示不暂停。");
    if(!a) return NO;
    ((void(*)(id,SEL,NSUInteger))objc_msgSend)(a,NSSelectorFromString(@"showTextFieldWithMaxLen:"),100);
    NSString *text=[NSString stringWithFormat:@"%@-%@",formatTime([d integerForKey:Start]),formatTime([d integerForKey:End])];
    ((void(*)(id,SEL,id))objc_msgSend)(a,NSSelectorFromString(@"setTextFieldDefaultText:"),text);
    // Weak reference avoids a retained alert -> callback -> alert cycle.
    __weak id weakAlert=a;
    void (^save)(void)=^{
        id alert=weakAlert; if(!alert) return;
        id value=((id(*)(id,SEL))objc_msgSend)(alert,NSSelectorFromString(@"getTextFieldText"));
        if(![value isKindOfClass:NSString.class]) return;
        NSArray *parts=[value componentsSeparatedByString:@"-"]; int start,end;
        if(parts.count!=2 || !parseTime(parts[0],&start) || !parseTime(parts[1],&end)) {
            UIAlertController *error=[UIAlertController alertControllerWithTitle:@"时间格式错误" message:@"未保存，请输入 HH:mm-HH:mm，例如 08:00-23:00。" preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [(UIViewController *)owner presentViewController:error animated:YES completion:nil]; return;
        }
        [d setInteger:start forKey:Start];[d setInteger:end forKey:End];reloadSettings(owner);
    };
    ((void(*)(id,SEL,id,id,SEL))objc_msgSend)(a,NSSelectorFromString(@"addCancelBtnTitle:target:sel:"),@"取消",nil,NULL);
    ((void(*)(id,SEL,id,id))objc_msgSend)(a,NSSelectorFromString(@"addBtnTitle:handler:"),@"保存",save);
    ((void(*)(id,SEL))objc_msgSend)(a,NSSelectorFromString(@"show")); return YES;
}
static void editSchedule(id self, SEL cmd) {
    UIViewController *vc=(UIViewController *)self;
    if(vc.presentedViewController) return;
    if(showNativeSchedule(self)) return;
    UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"需要确认原版输入控件" message:@"请先打开一次普通自动回复的在线时间弹窗，点击取消，再返回设置关键词时间。补丁将复用这次实际使用的控件类，不再显示不同样式的回退输入框。" preferredStyle:UIAlertControllerStyleAlert];
    [notice addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:notice animated:YES completion:nil];
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
    SEL editor=NSSelectorFromString(@"ReplyOnlineTime");
    if(hasSignature(cls,editor,2,"v")) {
        installAlertObservation();
        originalTimeEditor=(void *)method_getImplementation(class_getInstanceMethod(cls,editor));
        replaceMethod(cls,editor,(IMP)observeTimeEditor);
    }
    SEL layout=@selector(viewDidLayoutSubviews);
    if(hasSignature(cls,layout,2,"v")) {
        originalLayout=(void *)method_getImplementation(class_getInstanceMethod(cls,layout));
        replaceMethod(cls,layout,(IMP)settingsLayout);
    }
    NSLog(@"[ReviseMiyou] inline keyword schedule and build footer installed (v4)");
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
