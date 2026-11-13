#include <assert.h>
#include "../src/TimeWindow.h"
int main(void) {
 for(int n=0;n<1440;n++) {
  assert(MYInWindow(n,480,1380)==(n>=480 && n<1380));
  assert(MYInWindow(n,1380,480)==(n>=1380 || n<480));
  assert(!MYInWindow(n,480,480));
  for(int original=0;original<2;original++) for(int enabled=0;enabled<2;enabled++) for(int ui=0;ui<2;ui++) {
   assert(MYKeywordAllowed(original,enabled,ui,n,480,1380)==(original && (ui || !enabled || !(n>=480 && n<1380))));
   assert(MYKeywordAllowed(original,enabled,ui,n,1380,480)==(original && (ui || !enabled || !(n>=1380 || n<480))));
   assert(MYKeywordAllowed(original,enabled,ui,n,480,480)==(bool)original);
  }
 }
 return 0;
}
