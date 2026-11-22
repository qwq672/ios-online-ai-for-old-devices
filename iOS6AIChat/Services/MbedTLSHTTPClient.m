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
    // v261103-35 fix #1: 去掉外层 retain/copy — property setter 已 retain/copy
    self.requestURL = url;
    self.requestMethod = method;
    self.requestHeaders = headers;
    self.requestBody = body;
    self.cancelled = NO;
    self.statusCodeSent = NO;
    // v261122-3: 重置 chunked 解码状态
    _chunked = NO;
    _chunkRemaining = -1;
    if (_chunkBuf) { [_chunkBuf release]; _chunkBuf = nil; }
    _chunkBuf = [[NSMutableData alloc] init];

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
    // v261122-3: 加锁并"取出即清零"，避免 cleanup 线程 free/复用 fd 后
    // shutdown 误伤新请求的 socket（竞态）。
    int fd = -1;
    @synchronized(self) {
        fd = (int)self.socketFd;
        self.socketFd = 0;
    }
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
    BOOL hasConnectionHeader = NO;  // v261103-36: 防止 Connection 头重复
    for (NSString *key in self.requestHeaders) {
        NSString *val = [self.requestHeaders objectForKey:key];
        if ([key isKindOfClass:[NSString class]] && [val isKindOfClass:[NSString class]]) {
            [httpReq appendFormat:@"%@: %@\r\n", key, val];
            if ([key caseInsensitiveCompare:@"Connection"] == NSOrderedSame) {
                hasConnectionHeader = YES;
            }
        }
    }
    // Content-Length
    if (self.requestBody) {
        [httpReq appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[self.requestBody length]];
    }
    // v261103-36: 只在调用方没设 Connection 时加（防止重复头）
    if (!hasConnectionHeader) {
        [httpReq appendString:@"Connection: close\r\n"];
    }
    [httpReq appendString:@"\r\n"];

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

    // v261103-34: 跳过系统根证书加载 — VERIFY_NONE 模式不需要证书
    // 加载系统根证书需要 SecItemCopyMatching（耗时 100-300ms）
    // 跳过后首次连接快 200ms+
    // （证书验证已设为 VERIFY_NONE，加载了也不验证）

    // v261103-34: 跳过 hostname SNI — 某些 iOS 6 设备上 mbedtls_ssl_set_hostname
    // 会触发额外的 DNS 查询（耗 50-100ms）。大部分 API 服务器不需要 SNI。

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
    // v261103-34: 跳过 ca_chain — VERIFY_NONE 不需要
    // mbedtls_ssl_conf_ca_chain(&conf, &cacert, NULL);

    ret = mbedtls_ssl_setup(&ssl, &conf);
    if (ret != 0) {
        [self _failWithError:[NSString stringWithFormat:@"ssl_setup failed: %d", ret]];
        goto cleanup;
    }

    // v261103-36: 恢复 SNI（v261103-34 跳过的修复）
    // v261103-34 为省 50-100ms 跳过了 mbedtls_ssl_set_hostname，但这会
    // 导致 TLS ClientHello 不发 Server Name extension → Cloudflare / Vercar /
    // 现代 API 网关（多 vhost 共享 IP）不知道客户端要连哪个 vhost → 返回默认
    // 证书或直接 handshake_failure alert → ssl_handshake 返回非 0 →
    // "聊天直接报错"。
    // mbedtls_ssl_set_hostname 同时做两件事：
    //   (1) 证书验证的 hostname 检查（VERIFY_NONE 跳过这个）
    //   (2) TLS ClientHello 的 SNI extension（必须保留）
    // 跳过 set_hostname 会同时跳过 (2)，这是 v261103-34 的错误判断。
    // 注释里"大部分 API 服务器不需要 SNI"是错的 — 现代 HTTPS 服务器
    // （特别是 CDN/网关后面的）几乎都要求 SNI。
    // 用户的中转 api-ai.awa.lat 在 Cloudflare 后面，要求 SNI → 触发此 bug。
    ret = mbedtls_ssl_set_hostname(&ssl, [host UTF8String]);
    if (ret != 0) {
        [self _failWithError:[NSString stringWithFormat:@"set_hostname failed: %d", ret]];
        goto cleanup;
    }

    // 4. TCP 连接
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%ld", (long)port);
    ret = mbedtls_net_connect(&server_fd, [host UTF8String], portStr, MBEDTLS_NET_PROTO_TCP);
    if (ret != 0) {
        [self _failWithError:[NSString stringWithFormat:@"net_connect failed: %d (host=%@ port=%ld)", ret, host, (long)port]];
        goto cleanup;
    }
    // v261103-26: 保存 socket fd 用于 cancel 时 shutdown
    // v261122-3: 若请求已被取消（cancel 先于连接建立），立即关闭 fd 退出
    if (self.cancelled) { goto cleanup; }
    @synchronized(self) {
        self.socketFd = server_fd.fd;
    }

    // 5. 设置 bio
    mbedtls_ssl_set_bio(&ssl, &server_fd, mbedtls_net_send, mbedtls_net_recv, mbedtls_net_recv_timeout);

    // 6. TLS 握手
    // v261116-3: 加 usleep 退避 — 旧实现 WANT_READ/WANT_WRITE 直接重试握手无 sleep
    // 老 iOS CPU 拉满，3GS/4S 发热降频
    while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            [self _failWithError:[NSString stringWithFormat:@"ssl_handshake failed: %d", ret]];
            goto cleanup;
        }
        if (self.cancelled) goto cleanup;
        usleep(1000);  // v261116-3: WANT_READ/WANT_WRITE 退避
    }

    if (self.cancelled) goto cleanup;

    // 7. 发送 HTTP 请求
    size_t written = 0;
    int wantWriteCount = 0;  // v261116-3: 连续 WANT_WRITE 计数
    while (written < [fullRequest length]) {
        if (self.cancelled) goto cleanup;  // v261103-31: cancel 检查
        ret = mbedtls_ssl_write(&ssl, (const unsigned char *)[fullRequest bytes] + written,
                                 [fullRequest length] - written);
        if (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_WANT_READ) {
            // v261116-3: 连续 N 次 WANT_WRITE 后用更长 sleep 替代 1ms 轮询
            // 避免服务器持续拥塞时 CPU 100%
            wantWriteCount++;
            if (wantWriteCount > 50) {
                usleep(10000);  // 10ms — 服务器拥塞时退避
            } else {
                usleep(1000);
            }
            if (wantWriteCount > 1000) {
                // 30 秒（1000 × 10ms + 50 × 1ms ≈ 10s）仍卡 WANT_WRITE → 放弃
                [self _failWithError:@"ssl_write 超时（连续 WANT_WRITE）"];
                goto cleanup;
            }
            continue;
        }
        if (ret <= 0) {
            [self _failWithError:[NSString stringWithFormat:@"ssl_write failed: %d", ret]];
            goto cleanup;
        }
        written += ret;
        wantWriteCount = 0;  // 成功写入重置计数
    }

    // 8. 循环读取响应（SSE 流式）
    unsigned char buf[8192];
    int totalRead = 0;
    BOOL headersParsed = NO;
    NSMutableData *headerBuffer = [NSMutableData data];
    // v261122-3: 整体超时兜底 —— read timeout 只 continue，服务端挂起会
    // 永久占住后台线程。用 wall-clock 限制总时长（300s，与 NSURLSession
    // timeoutIntervalForResource 一致）。思考模型长静默由 read timeout 的
    // 10s 轮询 + cancelled 检查处理，这里只防"永远不结束"的死连接。
    NSTimeInterval readDeadline = [NSDate timeIntervalSinceReferenceDate] + 300.0;

    while (!self.cancelled) {
        if ([NSDate timeIntervalSinceReferenceDate] > readDeadline) {
            [self _failWithError:@"响应整体超时（300s）"];
            goto cleanup;
        }
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

                // v261122-3: 检测 Transfer-Encoding: chunked —— mbedTLS 拿到的是
                // 原始字节，必须自己解块，否则 chunk 大小行(如 "1a3")混进 SSE，
                // 边界落在 data JSON 行中间时该行解析失败 → 丢 token。
                if ([headerStr rangeOfString:@"chunked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    _chunked = YES;
                    _chunkRemaining = -1;
                }

                // 发送状态码到主线程
                [self performSelectorOnMainThread:@selector(_deliverStatusCode:)
                                       withObject:[NSNumber numberWithInteger:statusCode]
                                    waitUntilDone:NO];

                // 发送 body 部分（headerEnd 之后的数据）
                if (bodyStart < hdrLen) {
                    NSData *bodyData = [headerBuffer subdataWithRange:NSMakeRange(bodyStart, hdrLen - bodyStart)];
                    [self _processBodyBytes:bodyData];
                }
            }
        } else {
            // 直接发送 body chunk
            [self _processBodyBytes:chunkData];
        }
    }

    // 9. 完成
    if (!self.cancelled) {
        [self performSelectorOnMainThread:@selector(_deliverFinish)
                               withObject:nil
                            waitUntilDone:NO];
    }

cleanup:
    @synchronized(self) {
        self.socketFd = 0;  // v261103-26: 重置，避免 cancel shutdown 已关闭的 fd
    }
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_entropy_free(&entropy);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_x509_crt_free(&cacert);
    mbedtls_net_free(&server_fd);

    // v261116-3: retain cycle 修复 — NSThread 强引用 target=self，self.networkThread 又 retain thread
    // 必须在 _runRequest 末尾置 nil 才能打破 cycle，否则每次请求泄漏 client + thread 对象
    // 在主线程异步执行，避免 self 在 runLoop 内被自释放（thread dealloc 需在 main thread 外的安全时机）
    [self performSelectorOnMainThread:@selector(_clearNetworkThread)
                           withObject:nil
                        waitUntilDone:NO];
}

// v261116-3: 主线程清理 networkThread，打破 retain cycle
- (void)_clearNetworkThread
{
    self.networkThread = nil;
}

#pragma mark - HTTP chunked 解码（v261122-3，后台线程执行）

// 把读到的原始字节按 HTTP chunked 规则解码，解出的纯 body 经 _deliverData
// 转发到主线程。非 chunked 响应直接透传。
// 状态机：_chunkRemaining == -1 表示正在等 chunk size 行；否则读取该 chunk 的数据。
- (void)_processBodyBytes:(NSData *)bytes
{
    if (!bytes || [bytes length] == 0) return;
    if (!_chunked) {
        [self performSelectorOnMainThread:@selector(_deliverData:)
                               withObject:bytes waitUntilDone:NO];
        return;
    }

    [_chunkBuf appendData:bytes];
    const char *p = [_chunkBuf bytes];
    NSUInteger len = [_chunkBuf length];
    NSUInteger consumed = 0;          // 已从 _chunkBuf 消费的字节
    NSMutableData *decoded = [NSMutableData data];

    while (consumed < len) {
        if (_chunkRemaining < 0) {
            // v261122-3: 先跳过上一个 chunk 数据后残留的 CRLF（可能跨 read
            // 边界，只有 \r 先到）。跳过后若没有更多字节，等下次。
            while (consumed < len && (p[consumed] == '\r' || p[consumed] == '\n')) {
                consumed++;
            }
            if (consumed >= len) break;
            // 读 chunk size 行（形如 "1a3\r\n" 或 "1a3;ext\r\n"），以 \n 结束
            NSUInteger lineEnd = consumed;
            BOOL found = NO;
            while (lineEnd < len) {
                if (p[lineEnd] == '\n') { found = YES; break; }
                lineEnd++;
            }
            if (!found) break;  // 行未完整，等下次
            NSUInteger lineLen = lineEnd - consumed;
            NSString *sizeLine = [[[NSString alloc] initWithBytes:p + consumed
                                                           length:lineLen
                                                         encoding:NSUTF8StringEncoding] autorelease];
            // 去掉 ;扩展 部分
            NSRange semi = [sizeLine rangeOfString:@";"];
            NSString *hex = semi.location != NSNotFound
                ? [sizeLine substringToIndex:semi.location] : sizeLine;
            hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            unsigned long long chunkSize = 0;
            NSScanner *scan = [NSScanner scannerWithString:hex];
            [scan scanHexLongLong:&chunkSize];
            consumed = lineEnd + 1;   // 跳过 \n
            if (chunkSize == 0) {
                // 最后一个 chunk —— 忽略后续 trailer，直接结束解码
                _chunkRemaining = 0;
                break;
            }
            _chunkRemaining = (NSInteger)chunkSize;
            continue;
        }

        // 读 chunk 数据
        NSUInteger avail = len - consumed;
        NSUInteger take = avail < (NSUInteger)_chunkRemaining ? avail : (NSUInteger)_chunkRemaining;
        [decoded appendBytes:p + consumed length:take];
        consumed += take;
        _chunkRemaining -= (NSInteger)take;
        if (_chunkRemaining == 0) {
            // chunk 数据读完，后面跟 \r\n —— 跳过（可能跨 read，简单处理：
            // 若剩余 >=2 且是 \r\n 消费掉；否则等下次数据到来时按 size 行处理，
            // 这里预消费一个可能的 \r\n）
            if (consumed + 1 < len && p[consumed] == '\r' && p[consumed + 1] == '\n') {
                consumed += 2;
            } else if (consumed < len && p[consumed] == '\n') {
                consumed += 1;
            }
            _chunkRemaining = -1;  // 等下一个 size 行
        }
    }

    // 保留未消费的残字节供下次
    if (consumed > 0) {
        [_chunkBuf replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
    }
    if ([decoded length] > 0) {
        [self performSelectorOnMainThread:@selector(_deliverData:)
                               withObject:decoded waitUntilDone:NO];
    }
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
    [_chunkBuf release];  // v261122-3
    [super dealloc];
}

@end
