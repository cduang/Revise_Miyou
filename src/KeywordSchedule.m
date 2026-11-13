#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#import "TimeWindow.h"
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
// Reuse the host alert by its API, not an obfuscated or version-specific class name.
static Class nativeAlertClass(void) {
    unsigned count=0; Class *classes=objc_copyClassList(&count); Class found=Nil;
    NSArray *names=@[@"initWithTitle:message:",@"showTextFieldWithMaxLen:",@"setTextFieldDefaultText:",@"getTextFieldText",@"addBtnTitle:handler:",@"show"];
    unsigned counts[]={4,3,3,2,4,2};
    for(unsigned i=0;i<count;i++) {
        BOOL ok=YES;
        for(unsigned j=0;j<names.count;j++) {
            Method m=class_getInstanceMethod(classes[i],NSSelectorFromString(names[j]));
            if(!m || method_getNumberOfArguments(m)!=counts[j]) {ok=NO;break;}
        }
        if(ok) { if(found) {found=Nil;break;} found=classes[i]; }
    }
    free(classes); return found;
}
static BOOL showNativeSchedule(id owner) {
    Class cls=nativeAlertClass(); if(!cls) return NO;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    id a=((id(*)(id,SEL))objc_msgSend)((id)cls,@selector(alloc));
    a=((id(*)(id,SEL,id,id))objc_msgSend)(a,NSSelectorFromString(@"initWithTitle:message:"),@"关键词在线时间段",@"请输入 HH:mm-HH:mm，例如 08:00-23:00。该时段不回复，范围外按原规则回复；支持跨午夜。相同起止表示不暂停。");
    if(!a) return NO;
    ((void(*)(id,SEL,NSUInteger))objc_msgSend)(a,NSSelectorFromString(@"showTextFieldWithMaxLen:"),11);
    NSString *text=[NSString stringWithFormat:@"%@-%@",formatTime([d integerForKey:Start]),formatTime([d integerForKey:End])];
    ((void(*)(id,SEL,id))objc_msgSend)(a,NSSelectorFromString(@"setTextFieldDefaultText:"),text);
    // Weak reference avoids a retained alert -> callback -> alert cycle.
    __weak id weakAlert=a;
    void (^save)(id)=^(id ignored) {
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
    ((void(*)(id,SEL,id,id))objc_msgSend)(a,NSSelectorFromString(@"addBtnTitle:handler:"),@"取消",^(id ignored){});
    ((void(*)(id,SEL,id,id))objc_msgSend)(a,NSSelectorFromString(@"addBtnTitle:handler:"),@"保存",save);
    ((void(*)(id,SEL))objc_msgSend)(a,NSSelectorFromString(@"show")); return YES;
}
static void editSchedule(id self, SEL cmd) {
    UIViewController *vc=(UIViewController *)self;
    if(vc.presentedViewController) return;
    if(showNativeSchedule(self)) return;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"关键词在线时间段" message:@"在线时间内不回复，时间段外按原关键词规则回复。支持跨午夜；相同起止表示不暂停。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"开始 HH:mm";t.text=formatTime([d integerForKey:Start]);}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"结束 HH:mm";t.text=formatTime([d integerForKey:End]);}];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        int s,e;
        if(!parseTime(a.textFields[0].text,&s)||!parseTime(a.textFields[1].text,&e)) {
            UIAlertController *error=[UIAlertController alertControllerWithTitle:@"时间格式错误" message:@"请输入 00:00 至 23:59，例如 08:00。未保存。" preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [vc presentViewController:error animated:YES completion:nil]; return;
        }
        [d setInteger:s forKey:Start]; [d setInteger:e forKey:End];
        reloadSettings(self);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
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
    NSLog(@"[ReviseMiyou] inline keyword schedule switch installed (v2)");
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
