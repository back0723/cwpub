#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 运行一段可能抛 Objective-C 异常（而不只是 Swift 错误）的代码并捕获它。
/// 用途：AVAudioEngine 在「通话中 CarAudio 路由没有输入口」时访问 inputNode 会抛
/// `required condition is false: inputNode != nullptr || outputNode != nullptr`，
/// Swift 无法 catch，整个进程随之被杀（真机崩溃信号 6）。用它把这段操作变成可控失败。
/// 返回 NO 表示捕获到异常，原因可用 TDSLastExceptionDescription() 取。
BOOL TDSRunCatchingException(void (^block)(void));

/// 最近一次被捕获的异常描述（主线程使用）。
NSString * _Nullable TDSLastExceptionDescription(void);

NS_ASSUME_NONNULL_END
