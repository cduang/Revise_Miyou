#import "Engine.h"
BOOL RKWBlocked(NSInteger minute, NSInteger start, NSInteger end) {
    if (minute<0 || minute>=1440 || start<0 || start>=1440 || end<0 || end>=1440) return YES;
    if (start==end) return NO;
    return start<end ? minute>=start && minute<end : minute>=start || minute<end;
}
BOOL RKWAllowed(NSDictionary *c, NSDate *date) {
    if (![c[@"enabled"] boolValue]) return NO;
    if (![c[@"schedule"] boolValue]) return YES;
    if (![c[@"start"] isKindOfClass:NSNumber.class] || ![c[@"end"] isKindOfClass:NSNumber.class]) return NO;
    NSDateComponents *t=[NSCalendar.currentCalendar components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:date];
    return !RKWBlocked(t.hour*60+t.minute,[c[@"start"] integerValue],[c[@"end"] integerValue]);
}
NSDictionary *RKWMatch(NSArray *rules, NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length || text.length>4096 || ![rules isKindOfClass:NSArray.class]) return nil;
    for (id item in rules) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *r=item;
        NSString *k=r[@"keyword"], *reply=r[@"reply"], *mode=r[@"mode"];
        if (![r[@"enabled"] boolValue] || ![k isKindOfClass:NSString.class] || !k.length || k.length>512 || ![reply isKindOfClass:NSString.class] || !reply.length || reply.length>2048) continue;
        if (([mode isEqual:@"exact"] && [text isEqualToString:k]) || ([mode isEqual:@"contains"] && [text rangeOfString:k].location!=NSNotFound)) return r;
    }
    return nil;
}
static BOOL parse(NSString *s, NSInteger *out) {
    if (s.length!=5 || [s characterAtIndex:2]!=':') return NO;
    for (NSUInteger i=0;i<5;i++) if(i!=2 && ([s characterAtIndex:i]<'0'||[s characterAtIndex:i]>'9')) return NO;
    NSInteger h=[[s substringToIndex:2] integerValue],m=[[s substringFromIndex:3] integerValue];
    if(h>23||m>59)return NO;*out=h*60+m;return YES;
}
BOOL RKWParseTime(NSString *text, NSInteger *start, NSInteger *end) {
    text=[[text stringByReplacingOccurrencesOfString:@"：" withString:@":"] stringByReplacingOccurrencesOfString:@"－" withString:@"-"];
    text=[text stringByReplacingOccurrencesOfString:@"–" withString:@"-"];
    NSArray *parts=[text componentsSeparatedByString:@"-"];
    NSInteger s,e;
    if(parts.count!=2 || !parse(parts[0],&s) || !parse(parts[1],&e))return NO;
    *start=s;*end=e;return YES;
}
NSString *RKWTime(NSInteger t) {return [NSString stringWithFormat:@"%02ld:%02ld",(long)(t/60),(long)(t%60)];}
