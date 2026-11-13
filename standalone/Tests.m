#import "Engine.h"
#include <assert.h>
int main(void) {@autoreleasepool {
    NSInteger s,e;assert(RKWParseTime(@"08:00-23:00",&s,&e)&&s==480&&e==1380);
    assert(RKWParseTime(@"23：00－08：00",&s,&e)&&s==1380&&e==480);
    for(NSString *bad in @[@"24:00-08:00",@"08:60-23:00",@"8:00-23:00",@"08:00",@"aa:bb-23:00",@"08:00-23:00-01:00"])assert(!RKWParseTime(bad,&s,&e));
    for(NSNumber *a in @[@0,@480,@1380,@1439])for(NSNumber *b in @[@0,@480,@1380,@1439])for(int n=0;n<1440;n++) {
        int start=a.intValue,end=b.intValue;BOOL expected=NO;
        for(int t=start;t!=end;t=(t+1)%1440)if(t==n)expected=YES;
        assert(RKWBlocked(n,start,end)==expected);
        NSDateComponents *parts=[NSDateComponents new];parts.year=2026;parts.month=1;parts.day=15;parts.hour=n/60;parts.minute=n%60;
        NSDate *date=[NSCalendar.currentCalendar dateFromComponents:parts];
        for(NSNumber *enabled in @[@NO,@YES])for(NSNumber *schedule in @[@NO,@YES]) {
            NSDictionary *c=@{@"enabled":enabled,@"schedule":schedule,@"start":a,@"end":b};
            assert(RKWAllowed(c,date)==(enabled.boolValue && (!schedule.boolValue || !expected)));
        }
    }
    assert(RKWBlocked(0,-1,2));assert(RKWBlocked(0,1,1440));
    assert(!RKWAllowed(@{@"enabled":@YES,@"schedule":@YES},NSDate.date));
    NSDictionary *exact=@{@"enabled":@YES,@"keyword":@"你好",@"reply":@"您好",@"mode":@"exact"};
    NSDictionary *contains=@{@"enabled":@YES,@"keyword":@"你好",@"reply":@"在的",@"mode":@"contains"};
    assert([RKWMatch(@[exact,contains],@"你好") isEqual:exact]);
    assert([RKWMatch(@[exact,contains],@"你好呀") isEqual:contains]);
    assert(!RKWMatch(@[exact],@"你好呀"));assert(!RKWMatch(@[exact],@""));
    assert(!RKWMatch(@[@{@"enabled":@NO,@"keyword":@"你好",@"reply":@"禁用",@"mode":@"exact"}],@"你好"));
    assert(!RKWMatch(@[@{},@"invalid"],@"你好"));
    puts("PASS: minute-by-minute windows, switches, invalid inputs, first-match and matching modes");
}return 0;}
