#include <assert.h>
#include "../src/TimeWindow.h"
int main(void) {
 for(int n=0;n<1440;n++) {
  assert(MYInWindow(n,480,1380)==(n>=480 && n<1380));
  assert(MYInWindow(n,1380,480)==(n>=1380 || n<480));
  assert(!MYInWindow(n,480,480));
 }
 return 0;
}
