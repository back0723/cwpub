#import "TDSExceptionCatcher.h"

static NSString *TDSExceptionDescription = nil;

BOOL TDSRunCatchingException(void (^block)(void)) {
    @try {
        block();
        TDSExceptionDescription = nil;
        return YES;
    } @catch (NSException *exception) {
        TDSExceptionDescription = [NSString stringWithFormat:@"%@：%@", exception.name, exception.reason ?: @"无原因"];
        return NO;
    }
}

NSString * _Nullable TDSLastExceptionDescription(void) {
    return TDSExceptionDescription;
}
