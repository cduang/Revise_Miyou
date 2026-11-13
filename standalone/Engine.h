#import <Foundation/Foundation.h>
FOUNDATION_EXPORT BOOL RKWBlocked(NSInteger minute, NSInteger start, NSInteger end);
FOUNDATION_EXPORT BOOL RKWAllowed(NSDictionary *config, NSDate *date);
FOUNDATION_EXPORT NSDictionary *RKWMatch(NSArray *rules, NSString *text);
FOUNDATION_EXPORT BOOL RKWParseTime(NSString *text, NSInteger *start, NSInteger *end);
FOUNDATION_EXPORT NSString *RKWTime(NSInteger minute);
