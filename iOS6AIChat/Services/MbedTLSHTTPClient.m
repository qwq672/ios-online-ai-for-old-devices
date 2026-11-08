//
//  MbedTLSHTTPClient.m
//  iOS6AIChat
//
//  v261103-25: mbedTLS HTTP 客户端实现
//  自带 TLS 1.2 栈，绕过 iOS 6 SecureTransport 的所有 bug
//  支持 SSE 流式响应 + 后台线程 TLS 握手
//

#import "MbedTLSHTTPClient.h"
#include <mbedtls/ssl.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>
#include <sys/socket.h>   // v261103-26: shutdown() for cancel

// iOS 系统证书（用于验证服务器证书）
#include <Security/Security.h>

@interface MbedTLSHTTPClient ()
@property (nonatomic, retain) NSThread *networkThread;
@property (nonatomic, assign) volatile BOOL cancelled;
@property (nonatomic, assign) volatile int socketFd;  // v261103-26: cancel 时 shutdown
@property (nonatomic, retain) NSURL *requestURL;
@property (nonatomic, copy) NSString *requestMethod;
@property (nonatomic, retain) NSDictionary *requestHeaders;
@property (nonatomic, retain) NSData *requestBody;
@property (nonatomic, assign) BOOL statusCodeSent;
@end

@implementation MbedTLSHTTPClient

- (void)startRequest:(NSURL *)url method:(NSString *)method headers:(NSDictionary *)headers body:(NSData *)body
{
    self.requestURL = [url retain];
    self.requestMethod = [method copy];
    self.requestHeaders = [headers retain];
    self.requestBody = [body retain];
    self.cancelled = NO;
    self.statusCodeSent = NO;

    // 在后台线程跑 TLS（阻塞操作）
    self.networkThread = [[[NSThread alloc] initWithTarget:self
                                                  selector:@selector(_runRequest)
                                                    object:nil] autorelease];
    [self.networkThread start];
}

- (void)cancel
{
    self.cancelled = YES;
    // v261103-26: shutdown socket 让 mbedtls_ssl_read 立即返回
    // 否则 mbedtls_ssl_read 会阻塞等待数据，用户点停止后不立即生效
    int fd = self.socketFd;
    if (fd > 0) {
        shutdown(fd, SHUT_RDWR);
    }
}

- (void)_runRequest
{
    @autoreleasepool {
        [self _doTLSRequest];
    }
}

// 从 iOS 系统钥匙串导出根证书（给 mbedTLS 验证服务器证书用）
- (NSData *)_systemRootCertificates
{
    // iOS 系统根证书在 /System/Library/Library/Keychains/SystemRootCertificates.keychain
    // 用 SecCertificateCopyData 提取所有根证书的 DER 数据，拼成 PEM
    CFArrayRef certs = NULL;
    NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
        (__bridge id)kCFBooleanTrue, (__bridge id)kSecReturnData,
        (__bridge id)kCFBooleanTrue, (__bridge id)kSecMatchLimit,
        kSecClassCertificate, (__bridge id)kSecClass,
        nil];
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&certs);
    if (status != errSecSuccess || !certs) {
        return nil;
    }

    NSMutableData *allCerts = [NSMutableData data];
    CFIndex count = CFArrayGetCount(certs);
    for (CFIndex i = 0; i < count; i++) {
        CFDataRef certData = (CFDataRef)CFArrayGetValueAtIndex(certs, i);
        if (certData) {
            [allCerts appendData:(__bridge NSData *)certData];
        }
    }
    CFRelease(certs);
    return allCerts;
}

- (void)_doTLSRequest
{
    NSURL *url = self.requestURL;
    if (!url) {
        [self _failWithError:@"no URL"];
        return;
    }

    // v261103-27: iOS 6 的 [url host] 可能返回 nil（已知 bug）
    // 手动从 URL 字符串解析 host/port/path
    NSString *urlStr = [url absoluteString];
    if (!urlStr || urlStr.length == 0) {
        [self _failWithError:@"no URL string"];
        return;
    }

    // v261103-27: iOS 6 的 NSURL 可能 normalize URL（https:// → https:/）
    // 不找 "://"，改找第一个 ":" 然后跳过所有 /
    NSRange colonRange = [urlStr rangeOfString:@":"];
    if (colonRange.location == NSNotFound) {
        [self _failWithError:@"no scheme: in URL"];
        return;
    }
    NSUInteger hostStart = colonRange.location + 1;
    NSUInteger urlLen = [urlStr length];
    // 跳过 ":" 后的所有 /（兼容 https:// https:/ https: 三种格式）
    while (hostStart < urlLen && [urlStr characterAtIndex:hostStart] == '/') {
        hostStart++;
    }
    if (hostStart >= urlLen) {
        [self _failWithError:@"no host after scheme"];
        return;
    }

    // host 结束于: 第一个 "/" 或 ":" (port) 或字符串末尾
    NSUInteger hostEnd = urlLen;
    for (NSUInteger i = hostStart; i < urlLen; i++) {
        unichar c = [urlStr characterAtIndex:i];
        if (c == '/' || c == ':') {
            hostEnd = i;
            break;
        }
    }
    if (hostEnd <= hostStart) {
        [self _failWithError:@"no host in URL"];
        return;
    }
    NSString *host = [urlStr substringWithRange:NSMakeRange(hostStart, hostEnd - hostStart)];

    // 解析 port（如果有）
    NSInteger port = 443;
    if (hostEnd < urlLen && [urlStr characterAtIndex:hostEnd] == ':') {
        NSUInteger portStart = hostEnd + 1;
        NSUInteger portEnd = portStart;
        for (NSUInteger i = portStart; i < urlLen; i++) {
            unichar c = [urlStr characterAtIndex:i];
            if (c == '/' || c == '?') break;
            portEnd = i + 1;
        }
        if (portEnd > portStart) {
            NSString *portStr = [urlStr substringWithRange:NSMakeRange(portStart, portEnd - portStart)];
            port = [portStr integerValue];
        }
        hostEnd = portEnd;
    }

    // path + query
    NSString *path = @"/";
    if (hostEnd < urlLen) {
        path = [urlStr substringFromIndex:hostEnd];
        if (path.length == 0) path = @"/";
    }

    // 构造 HTTP 请求
    NSMutableString *httpReq = [NSMutableString string];
    [httpReq appendFormat:@"%@ %@ HTTP/1.1\r\n", self.requestMethod ?: @"POST", path];
    // v261103-31: Host header 加 port（非标准端口时）
    if (port != 443) {
        [httpReq appendFormat:@"Host: %@:%ld\r\n", host, (long)port];
    } else {
        [httpReq appendFormat:@"Host: %@\r\n", host];
    }
    // 添加 headers
    for (NSString *key in self.requestHeaders) {
        NSString *val = [self.requestHeaders objectForKey:key];
        if ([key isKindOfClass:[NSString class]] && [val isKindOfClass:[NSString class]]) {
            [httpReq appendFormat:@"%@: %@\r\n", key, val];
        }
    }
    // Content-Length
    if (self.requestBody) {
        [httpReq appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[self.requestBody length]];
    }
    [httpReq appendString:@"Connection: close\r\n\r\n"];

    // 拼接 body
    NSMutableData *fullRequest = [NSMutableData data];
    [fullRequest appendData:[httpReq dataUsingEncoding:NSUTF8StringEncoding]];
    if (self.requestBody) {
        [fullRequest appendData:self.requestBody];
    }

    // mbedTLS 初始化
    mbedtls_net_context server_fd;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_x509_crt cacert;

    mbedtls_net_init(&server_fd);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);
    mbedtls_x509_crt_init(&cacert);

    int ret;

    // 1. 随机数种子
    const char *pers = "iOS6AIChat";
    ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                                 (const unsigned char *)pers, strlen(pers));
    if (ret != 0) {
        [self _failWithError:[NSString stringWithFormat:@"ctr_drbg_seed failed: %d", ret]];
        goto cleanup;
    }

    // 2. 加载系统根证书
    NSData *rootCerts = [self _systemRootCertificates];
    if (rootCerts && [rootCerts length] > 0) {
        ret = mbedtls_x509_crt_parse_der(&cacert, (const unsigned char *)[rootCerts bytes],
                                           [rootCerts length]);
        // 忽略错误——即使证书加载失败，也继续（跳过验证）
    }

    // 3. SSL 配置
    ret = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT,
                                       MBEDTLS_SSL_TRANSPORT_STREAM,
                                       MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        [self _failWithError:[NSString stringWithFormat:@"ssl_config_defaults failed: %d", ret]];
        goto cleanup;
    }

    // v261103-25: 跳过证书验证（iOS 6 老设备兼容）
    // 跟 SSL Kill Switch 类似——接受所有证书
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctr_drbg);
    // v261103-29: 缩短 timeout 到 10s — 更频繁检查 cancelled，"停不了"概率大幅降低
    // 30s 太长（thinking 模型思考时用户等 30s 才能停）
    // 10s 内 timeout 后检查 cancelled，如果用户已点停止就退出
    mbedtls_ssl_conf_read_timeout(&conf, 10000);
    // 设置 ca cert（即使 VERIFY_NONE 也设上）
    mbedtls_ssl_conf_ca_chain(&conf, &cacert, NULL);

    ret = mbedtls_ssl_setup(&ssl, &conf);
    if (ret != 0) {
        [self _failWithError:[NSString stringWithFormat:@"ssl_setup failed: %d", ret]];
        goto cleanup;
    }

    // 设置 hostname（SNI）
    mbedtls_ssl_set_hostname(&ssl, [host UTF8String]);

    // 4. TCP 连接
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%ld", (long)port);
    ret = mbedtls_net_connect(&server_fd, [host UTF8String], portStr, MBEDTLS_NET_PROTO_TCP);
    if (ret != 0) {
        [self _failWithError:[NSString stringWithFormat:@"net_connect failed: %d (host=%@ port=%ld)", ret, host, (long)port]];
        goto cleanup;
    }
    // v261103-26: 保存 socket fd 用于 cancel 时 shutdown
    self.socketFd = server_fd.fd;

    // 5. 设置 bio
    mbedtls_ssl_set_bio(&ssl, &server_fd, mbedtls_net_send, mbedtls_net_recv, mbedtls_net_recv_timeout);

    // 6. TLS 握手
    while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            [self _failWithError:[NSString stringWithFormat:@"ssl_handshake failed: %d", ret]];
            goto cleanup;
        }
        if (self.cancelled) goto cleanup;
    }

    if (self.cancelled) goto cleanup;

    // 7. 发送 HTTP 请求
    size_t written = 0;
    while (written < [fullRequest length]) {
        if (self.cancelled) goto cleanup;  // v261103-31: cancel 检查
        ret = mbedtls_ssl_write(&ssl, (const unsigned char *)[fullRequest bytes] + written,
                                 [fullRequest length] - written);
        if (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_WANT_READ) {
            usleep(1000);  // v261103-31: 防忙等（跟 ssl_read 一致）
            continue;
        }
        if (ret <= 0) {
            [self _failWithError:[NSString stringWithFormat:@"ssl_write failed: %d", ret]];
            goto cleanup;
        }
        written += ret;
    }

    // 8. 循环读取响应（SSE 流式）
    unsigned char buf[8192];
    int totalRead = 0;
    BOOL headersParsed = NO;
    NSMutableData *headerBuffer = [NSMutableData data];

    while (!self.cancelled) {
        memset(buf, 0, sizeof(buf));
        ret = mbedtls_ssl_read(&ssl, buf, sizeof(buf) - 1);

        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) {
            // v261103-29: 从 10ms 减到 1ms — 提高响应速度，仍防 CPU 100%
            usleep(1000);
            continue;
        }
        if (ret == MBEDTLS_ERR_SSL_TIMEOUT) {
            // v261103-28: read timeout (30s) — thinking 模型可能长时间不输出
            // 不算错误，继续等
            continue;
        }
        if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || ret == 0) {
            // 连接关闭 — 正常结束
            break;
        }
        if (ret < 0) {
            // 读错误
            if (totalRead > 0) {
                // 已经收到一些数据，当作正常完成
                break;
            }
            [self _failWithError:[NSString stringWithFormat:@"ssl_read failed: %d", ret]];
            goto cleanup;
        }

        // 收到数据
        NSData *chunkData = [NSData dataWithBytes:buf length:ret];
        totalRead += ret;

        if (!headersParsed) {
            // v261103-30: 兼容 \r\n\r\n 和 \n\n 两种分隔符
            [headerBuffer appendData:chunkData];
            // 某些服务器/代理用 \n\n（不带 \r），只找 \r\n\r\n 会找不到
            const char *hdr = [headerBuffer bytes];
            NSUInteger hdrLen = [headerBuffer length];
            NSUInteger bodyStart = 0;
            NSUInteger sepLen = 0;  // v261103-30: 分隔符长度（4 或 2）
            for (NSUInteger i = 0; i + 1 < hdrLen; i++) {
                if (i + 3 < hdrLen && hdr[i] == '\r' && hdr[i+1] == '\n' && hdr[i+2] == '\r' && hdr[i+3] == '\n') {
                    bodyStart = i + 4;
                    sepLen = 4;
                    headersParsed = YES;
                    break;
                }
                if (hdr[i] == '\n' && hdr[i+1] == '\n') {
                    bodyStart = i + 2;
                    sepLen = 2;
                    headersParsed = YES;
                    break;
                }
            }
            if (headersParsed) {
                NSString *headerStr = [[[NSString alloc] initWithBytes:[headerBuffer bytes]
                                                                 length:bodyStart - sepLen
                                                               encoding:NSUTF8StringEncoding] autorelease];
                NSInteger statusCode = 0;
                NSScanner *scanner = [NSScanner scannerWithString:headerStr];
                [scanner scanString:@"HTTP/" intoString:nil];
                // 跳过版本号
                while (![scanner isAtEnd] && [[scanner string] characterAtIndex:[scanner scanLocation]] != ' ') {
                    [scanner setScanLocation:[scanner scanLocation] + 1];
                }
                [scanner scanString:@" " intoString:nil];
                [scanner scanInteger:&statusCode];

                // 发送状态码到主线程
                [self performSelectorOnMainThread:@selector(_deliverStatusCode:)
                                       withObject:[NSNumber numberWithInteger:statusCode]
                                    waitUntilDone:NO];

                // 发送 body 部分（headerEnd 之后的数据）
                if (bodyStart < hdrLen) {
                    NSData *bodyData = [headerBuffer subdataWithRange:NSMakeRange(bodyStart, hdrLen - bodyStart)];
                    [self performSelectorOnMainThread:@selector(_deliverData:)
                                           withObject:bodyData
                                        waitUntilDone:NO];
                }
            }
        } else {
            // 直接发送 body chunk
            [self performSelectorOnMainThread:@selector(_deliverData:)
                                   withObject:chunkData
                                waitUntilDone:NO];
        }
    }

    // 9. 完成
    if (!self.cancelled) {
        [self performSelectorOnMainThread:@selector(_deliverFinish)
                               withObject:nil
                            waitUntilDone:NO];
    }

cleanup:
    self.socketFd = 0;  // v261103-26: 重置，避免 cancel shutdown 已关闭的 fd
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_entropy_free(&entropy);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_x509_crt_free(&cacert);
    mbedtls_net_free(&server_fd);
}

#pragma mark - 主线程回调

- (void)_deliverStatusCode:(NSNumber *)statusCode
{
    if (self.cancelled) return;
    if ([self.delegate respondsToSelector:@selector(httpClient:didReceiveStatusCode:)]) {
        [self.delegate httpClient:self didReceiveStatusCode:[statusCode integerValue]];
    }
}

- (void)_deliverData:(NSData *)data
{
    if (self.cancelled) return;
    if ([self.delegate respondsToSelector:@selector(httpClient:didReceiveData:)]) {
        [self.delegate httpClient:self didReceiveData:data];
    }
}

- (void)_deliverFinish
{
    if (self.cancelled) return;
    if ([self.delegate respondsToSelector:@selector(httpClientDidFinish:)]) {
        [self.delegate httpClientDidFinish:self];
    }
}

- (void)_failWithError:(NSString *)desc
{
    if (self.cancelled) return;
    NSError *error = [NSError errorWithDomain:@"MbedTLSHTTP"
                                          code:-1
                                      userInfo:@{NSLocalizedDescriptionKey: desc}];
    [self performSelectorOnMainThread:@selector(_deliverError:)
                           withObject:error
                        waitUntilDone:NO];
}

- (void)_deliverError:(NSError *)error
{
    if (self.cancelled) return;
    if ([self.delegate respondsToSelector:@selector(httpClient:didFailWithError:)]) {
        [self.delegate httpClient:self didFailWithError:error];
    }
}

- (void)dealloc
{
    self.cancelled = YES;
    [_requestURL release];
    [_requestMethod release];
    [_requestHeaders release];
    [_requestBody release];
    [_networkThread release];
    [super dealloc];
}

@end
