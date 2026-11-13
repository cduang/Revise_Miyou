#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>
#import "TimeWindow.h"
static NSString *const Enabled = @"ReviseMiyou.KeywordSchedule.Enabled";
static NSString *const Start = @"ReviseMiyou.KeywordSchedule.Start";
static NSString *const End = @"ReviseMiyou.KeywordSchedule.End";
static BOOL (*originalGetter)(id, SEL);
static void (*originalAppear)(id, SEL, BOOL);
static BOOL filteredGetter(id self, SEL cmd) {
    BOOL original = originalGetter(self, cmd);
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!original || ![d boolForKey:Enabled]) return original;
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
@interface RMYSettings : NSObject
+ (void)show:(UILongPressGestureRecognizer *)gesture;
@end
@implementation RMYSettings
+ (void)show:(UILongPressGestureRecognizer *)gesture {
    if(gesture.state != UIGestureRecognizerStateBegan) return;
    UIResponder *r=gesture.view; while(r && ![r isKindOfClass:UIViewController.class]) r=r.nextResponder;
    UIViewController *vc=(UIViewController *)r;
    if(!vc) { UIWindow *w=gesture.view.window; vc=w.rootViewController; while(vc.presentedViewController) vc=vc.presentedViewController; if([vc isKindOfClass:UINavigationController.class]) vc=((UINavigationController *)vc).topViewController; }
    if(!vc || vc.presentedViewController || ![vc isKindOfClass:NSClassFromString(@"MiYouSettingViewController")]) return;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"关键词在线时间" message:@"区间内暂停关键词回复，区间外仍按原规则回复。使用手机本地时间；相同起止表示不暂停。实验版：尚未覆盖延迟发送。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"开始 HH:mm";t.text=formatTime([d integerForKey:Start]);}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"结束 HH:mm";t.text=formatTime([d integerForKey:End]);}];
    [a addAction:[UIAlertAction actionWithTitle:@"保存并启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        int s,e; if(!parseTime(a.textFields[0].text,&s)||!parseTime(a.textFields[1].text,&e)) {
            UIAlertController *error=[UIAlertController alertControllerWithTitle:@"时间格式错误" message:@"请输入 00:00 至 23:59，例如 08:00。未保存。" preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [vc presentViewController:error animated:YES completion:nil]; return;
        }
        [d setInteger:s forKey:Start];[d setInteger:e forKey:End];[d setBool:YES forKey:Enabled];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭时间限制" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[d setBool:NO forKey:Enabled];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
@end
static void settingsAppear(id self, SEL cmd, BOOL animated) {
    originalAppear(self,cmd,animated);
    UINavigationBar *bar=((UIViewController *)self).navigationController.navigationBar;
    for(UIGestureRecognizer *g in bar.gestureRecognizers) if([g.name isEqualToString:@"ReviseMiyou.Schedule"]) return;
    UILongPressGestureRecognizer *g=[[UILongPressGestureRecognizer alloc] initWithTarget:RMYSettings.class action:@selector(show:)];
    g.name=@"ReviseMiyou.Schedule";g.minimumPressDuration=2;[bar addGestureRecognizer:g];
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
static BOOL installUI(void) {
    Class cls=NSClassFromString(@"MiYouSettingViewController"); SEL sel=@selector(viewDidAppear:);Method m=class_getInstanceMethod(cls,sel);
    if(!m) return NO;
    originalAppear=(void *)method_getImplementation(m);
    if(!class_addMethod(cls,sel,(IMP)settingsAppear,method_getTypeEncoding(m))) method_setImplementation(m,(IMP)settingsAppear);
    return YES;
}
__attribute__((constructor)) static void initSchedule(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{Enabled:@NO,Start:@480,End:@1380}];
        __block BOOL getter=NO,ui=NO; __block int attempts=0;
        dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
        dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);
        dispatch_source_set_event_handler(timer,^{
            if(!getter) getter=installGetter(); if(!ui) ui=installUI();
            if((getter&&ui)||++attempts>=120) {NSLog(@"[ReviseMiyou] getter=%d UI=%d",getter,ui);dispatch_source_cancel(timer);}
        });dispatch_resume(timer);
    });
}
