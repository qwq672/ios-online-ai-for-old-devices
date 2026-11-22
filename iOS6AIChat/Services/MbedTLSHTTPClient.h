//
//  MbedTLSHTTPClient.h
//  iOS6AIChat
//
//  v261103-25: mbedTLS HTTP 客户端 — 自带 TLS 栈，绕过 iOS 6 SecureTransport
//  用 mbedTLS 替代系统 TLS，解决 -1200 (body 限制) + -1012 (TLS 握手失败)
//  支持 SSE 流式响应（循环 mbedtls_ssl_read + delegate 回调）
//

#import <Foundation/Foundation.h>

@protocol MbedTLSHTTPDelegate;

@interface MbedTLSHTTPClient : NSObject
{
    // v261122-3: HTTP chunked 传输解码状态（后台线程使用，无锁）
    BOOL  _chunked;            // 响应是否 Transfer-Encoding: chunked
    NSInteger _chunkRemaining; // 当前 chunk 剩余字节数；-1 = 正在读 chunk size 行
    NSMutableData *_chunkBuf;  // 跨 read 调用累积的字节（chunk size 行 / 半行数据）
}

@property (nonatomic, assign) id<MbedTLSHTTPDelegate> delegate;

// 发起 HTTPS POST 请求（异步，后台线程跑 TLS）
- (void)startRequest:(NSURL *)url
              method:(NSString *)method
             headers:(NSDictionary *)headers
                body:(NSData *)body;

// 取消请求
- (void)cancel;

@end

@protocol MbedTLSHTTPDelegate <NSObject>
// 收到响应数据 chunk（SSE 流式，多次调用）
- (void)httpClient:(MbedTLSHTTPClient *)client didReceiveData:(NSData *)data;
// 收到 HTTP 状态码（第一个 chunk 之前调用）
- (void)httpClient:(MbedTLSHTTPClient *)client didReceiveStatusCode:(NSInteger)statusCode;
// 请求完成
- (void)httpClientDidFinish:(MbedTLSHTTPClient *)client;
// 请求失败
- (void)httpClient:(MbedTLSHTTPClient *)client didFailWithError:(NSError *)error;
@end
