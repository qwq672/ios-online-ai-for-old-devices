//
//  NetworkService.m
//  iOS6AIChat
//
//  SSE streaming over NSURLConnection.
//
//  Endpoint construction:
//     useTransit=YES : endpoint = {transitURL}/v1/chat/completions
//     useTransit=NO  : endpoint = {baseURL}/v1/chat/completions
//
//  Headers (transit mode):
//     Authorization: Bearer {apiKey}
//     X-Provider:    {provider}      (e.g. "zhipu", "openai", "ollama")
//     X-Model:       {model}          (informational; also in body)
//  Headers (direct mode):
//     Authorization: Bearer {apiKey}
//
//  v261018 tool_calls support:
//    When `enableWebSearchTools:YES`, the request body includes a `tools`
//    array defining a `tavily_search` function. The AI can choose to
//    call it (or not), possibly multiple times. When the AI emits
//    `tool_calls`, this class:
//      1) Suspends the current connection.
//      2) Calls Tavily with the AI's specified args (sync, on bg queue).
//      3) Appends the tool result as a `tool` role message.
//      4) Re-triggers the stream with the augmented messages.
//    Multi-turn is supported: the AI can call the tool again in the
//    next turn. The loop ends when the AI emits no more tool_calls.
//

#import "NetworkService.h"
#import "SettingsViewController.h"
#import "NSDataBase64.h"
#import "Logger.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>

// v261025-12: SyncHTTPDelegate — async NSURLConnection transport wrapped
// with a semaphore so callers keep synchronous semantics while the TLS
// handshake + delegate callbacks run on the MAIN runloop (the SAME
// transport the streaming chat path uses, proven to work where
// +sendSynchronousRequest: fails with -1012 on iOS 6 from GCD threads).
@interface SyncHTTPDelegate : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, retain) NSMutableData *data;
@property (nonatomic, retain) NSURLResponse *response;
@property (nonatomic, retain) NSError *error;
@property (nonatomic, assign) BOOL done;
@property (nonatomic, assign) dispatch_semaphore_t sem;
- (id)initWithSemaphore:(dispatch_semaphore_t)sem;
@end

@implementation SyncHTTPDelegate
@synthesize data=_data, response=_response, error=_error, done=_done, sem=_sem;
- (id)initWithSemaphore:(dispatch_semaphore_t)sem {
    if (self = [super init]) {
        self.sem = sem;
        _data = [[NSMutableData alloc] init];
    }
    return self;
}
- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)r {
    self.response = r;
    [_data setData:nil];
}
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)d {
    if (d) [_data appendData:d];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)c {
    self.done = YES;
    if (self.sem) dispatch_semaphore_signal(self.sem);
}
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)e {
    self.error = e;
    self.done = YES;
    if (self.sem) dispatch_semaphore_signal(self.sem);
}
- (void)dealloc {
    self.data = nil; self.response = nil; self.error = nil;
    [super dealloc];
}
@end

@interface NetworkService ()
@property (nonatomic, retain) NSURLConnection *connection;
// v261103-19: NSURLSession (iOS 7+) 用于突破 NSURLConnection 的 ~130KB body 限制。
// SDK 7.1 有定义，deployment target 6.0 — 编译 OK，运行时用 NSClassFromString 检测。
@property (nonatomic, retain) NSURLSession *urlSession;
@property (nonatomic, retain) NSURLSessionDataTask *dataTask;
@property (nonatomic, retain) NSMutableData   *rawBuffer;
@property (nonatomic, retain) NSMutableString *accumulated;
@property (nonatomic, retain) NSMutableString *thinkingAccumulated;
@property (nonatomic, copy)   NSString         *conversationID;
@property (nonatomic, retain) NSError          *lastError;

// HTTP status of the streaming response (0 = unknown / non-HTTP).
// Previously non-200 replies (transit 404/502, upstream auth errors) were
// silently swallowed: no SSE "data:" lines parse → empty accumulated →
// the user saw an EMPTY reply instead of the actual error. Capturing the
// status lets us surface the real cause.
@property (nonatomic, assign) NSInteger httpStatus;

// Tool-call state (for multi-turn web search).
@property (nonatomic, retain) NSMutableArray *toolCallAccumulators;  // array of NSMutableDictionary
@property (nonatomic, retain) NSMutableArray *pendingToolMessages;  // array of NSDictionary (tool role)
@property (nonatomic, assign) BOOL toolCallPending;  // YES = we need to run a tool call

// Request context (saved so we can re-trigger stream for multi-turn).
@property (nonatomic, assign) BOOL useTransit;
@property (nonatomic, copy)   NSString *transitURL;
@property (nonatomic, copy)   NSString *baseURL;
@property (nonatomic, copy)   NSString *provider;
@property (nonatomic, copy)   NSString *apiKey;
@property (nonatomic, copy)   NSString *model;
@property (nonatomic, assign) CGFloat temperature;
@property (nonatomic, retain) NSMutableArray *baseMessages;  // immutable base (system + user + assistant)
@property (nonatomic, assign) BOOL enableWebSearchTools;
@property (nonatomic, copy)   NSString *tavilyKey;
@property (nonatomic, assign) NSInteger tavilyMaxResults;
@property (nonatomic, assign) NSInteger toolCallTurn;  // counts how many tool turns we've done
@property (nonatomic, assign) NSInteger maxToolTurns;  // hard cap (avoid infinite loops)
// v261025-1: stream launch timestamp — for duration logging at finish.
@property (nonatomic, assign) NSTimeInterval streamStartTs;
// v261025-3: set once the current stream already attempted the https→http
// transit fallback (guards against a fallback relaunch loop).
@property (nonatomic, assign) BOOL httpFallbackTried;
// v261025-13: segmented thinking — when YES, _launchStreamWithMessages
// preserves _accumulated (pre-tool-call text + markers) instead of
// clearing it. Set by _runPendingToolCalls before the re-launch.
@property (nonatomic, assign) BOOL toolCallRelaunch;
// v261102-1: per-provider autonomous capability switches are declared in
// the public header (NetworkService.h). Do NOT redeclare them in this
// class extension — clang rejects redeclaration when the primary property
// is already readwrite (only readonly → readwrite promotion is allowed).
// The @synthesize lines below pull in the ivars directly.
// v261025-3: https→http URL rewrite for the iOS 6 TLS transit fallback
// (see the implementation comment for the full rationale).
+ (NSString *)_httpFallbackForURLString:(NSString *)s;
// v261025-3: map provider → real upstream base URL for image generation
// (the image-gen entry point doesn't receive baseURL, so we map provider
// to a known base URL — used only to construct X-Target-URL).
+ (NSString *)_imageAPIBaseURLForProvider:(NSString *)provider;
@end

@implementation NetworkService

@synthesize connection=_connection, rawBuffer=_rawBuffer,
            accumulated=_accumulated, conversationID=_conversationID,
            lastError=_lastError, delegate=_delegate,
            thinkingAccumulated=_thinkingAccumulated,
            httpStatus=_httpStatus,
            toolCallAccumulators=_toolCallAccumulators,
            pendingToolMessages=_pendingToolMessages,
            toolCallPending=_toolCallPending,
            useTransit=_useTransit, transitURL=_transitURL,
            baseURL=_baseURL, provider=_provider, apiKey=_apiKey,
            model=_model, temperature=_temperature,
            baseMessages=_baseMessages, enableWebSearchTools=_enableWebSearchTools,
            tavilyKey=_tavilyKey, tavilyMaxResults=_tavilyMaxResults,
            toolCallTurn=_toolCallTurn, maxToolTurns=_maxToolTurns,
            streamStartTs=_streamStartTs, httpFallbackTried=_httpFallbackTried,
            toolCallRelaunch=_toolCallRelaunch,
            autonomousWebSearch=_autonomousWebSearch,
            autonomousURLRead=_autonomousURLRead,
            autonomousSearchURL=_autonomousSearchURL,
            autonomousSearchKey=_autonomousSearchKey,
            autonomousFetchURL=_autonomousFetchURL,
            autonomousFetchKey=_autonomousFetchKey;
@dynamic accumulatedThinking;

- (id)init
{
    if (self = [super init]) {
        _rawBuffer   = [[NSMutableData alloc] init];
        _accumulated = [[NSMutableString alloc] init];
        _thinkingAccumulated = [[NSMutableString alloc] init];
        _toolCallAccumulators = [[NSMutableArray alloc] init];
        _pendingToolMessages = [[NSMutableArray alloc] init];
        _maxToolTurns = 5;  // hard cap — don't let AI loop forever
    }
    return self;
}

- (BOOL)streamChatWithUseTransit:(BOOL)useTransit
                       transitURL:(NSString *)transitURL
                         baseURL:(NSString *)baseURL
                         provider:(NSString *)provider
                          apiKey:(NSString *)apiKey
                           model:(NSString *)model
                     temperature:(CGFloat)temperature
                        messages:(NSArray *)messages
                  conversationID:(NSString *)conversationID
{
    // Backwards-compatible entry point. Web-search tools disabled
    // (legacy callers don't expect tool_calls).
    return [self streamChatWithUseTransit:useTransit
                               transitURL:transitURL
                                 baseURL:baseURL
                                 provider:provider
                                  apiKey:apiKey
                                   model:model
                             temperature:temperature
                                messages:messages
                          conversationID:conversationID
                            enableWebSearchTools:NO
                                  tavilyKey:@""
                            tavilyMaxResults:0];
}

// New entry point — when enableWebSearchTools=YES, the request body
// includes the `tools` array and tool_choice="auto". AI can decide
// to call tavily_search any number of times.
- (BOOL)streamChatWithUseTransit:(BOOL)useTransit
                       transitURL:(NSString *)transitURL
                         baseURL:(NSString *)baseURL
                         provider:(NSString *)provider
                          apiKey:(NSString *)apiKey
                           model:(NSString *)model
                     temperature:(CGFloat)temperature
                        messages:(NSArray *)messages
                  conversationID:(NSString *)conversationID
            enableWebSearchTools:(BOOL)enableTools
                      tavilyKey:(NSString *)tavilyKey
                tavilyMaxResults:(NSInteger)tavilyMaxResults
{
    // Save context for multi-turn tool use.
    self.useTransit = useTransit;
    self.transitURL = transitURL;
    // v261025-3: normalize — an empty transit URL means the default relay;
    // materialize it so the TLS fallback in didFailWithError: can reason
    // about the scheme (and flip it to http when iOS 6 can't handshake).
    if (!self.transitURL || self.transitURL.length == 0) {
        self.transitURL = @"https://ai-transit.awa.lat";
    }
    self.baseURL = baseURL;
    self.provider = provider;
    self.apiKey = apiKey;
    self.model = model;
    self.temperature = temperature;
    self.enableWebSearchTools = enableTools;
    self.tavilyKey = tavilyKey;
    self.tavilyMaxResults = tavilyMaxResults;
    // baseMessages is the immutable starting point — we'll append tool
    // role messages as we go.
    self.baseMessages = [NSMutableArray arrayWithArray:messages];

    // Reset per-stream state.
    self.conversationID = conversationID;
    // v261025-3: each NEW user message gets a fresh TLS-fallback attempt
    // (the flag only guards against a loop WITHIN one stream).
    self.httpFallbackTried = NO;
    // v261025-13 bugfix: toolCallRelaunch must also be reset here —
    // if a previous tool-call relaunch failed early (e.g. invalid URL
    // returned NO before reaching the reset at line 386), the flag
    // would stay YES and the next user message would skip the
    // _accumulated clear → stale text from previous turn carried over.
    self.toolCallRelaunch = NO;
    // v261102-1: the autonomous flags + URLs are set externally by
    // ChatViewController right before calling streamChat... — DO NOT
    // reset them here (would clobber the per-provider config the caller
    // just installed). They survive across the multi-turn tool-call loop
    // within one user message, which is what we want.
    [_accumulated setString:@""];
    [_thinkingAccumulated setString:@""];
    [_toolCallAccumulators removeAllObjects];
    [_pendingToolMessages removeAllObjects];
    self.toolCallPending = NO;
    self.toolCallTurn = 0;

    return [self _launchStreamWithMessages:self.baseMessages];
}

- (BOOL)_launchStreamWithMessages:(NSArray *)messages
{
    // v261025-8: provider → API format. Anthropic speaks its own
    // /v1/messages protocol (different endpoint, different auth headers,
    // different SSE event shapes); every other provider (智谱 / DeepSeek /
    // Kimi / OpenAI / Ollama / custom OpenAI-compat endpoints) uses the
    // OpenAI /v1/chat/completions format below.
    BOOL anthropic = [SettingsViewController providerUsesAnthropicFormat:self.provider];

    // v261103-2: chat ALWAYS goes direct to the provider's baseURL.
    // The transit server is no longer used for chat (user testing showed
    // iOS 6 TLS reaches providers directly, and transit caused more errors
    // than it solved). The transitURL property is kept only for image gen
    // (which may use it as an optional geo-proxy).
    NSString *base = self.baseURL;
    if (!base || base.length == 0) {
        base = anthropic ? @"https://api.anthropic.com" : @"https://api.openai.com";
    }
    NSString *endpoint = [base stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (anthropic) {
        // Anthropic Messages API: {base}/v1/messages (or {base}/messages
        // when the user's baseURL already ends with /v1).
        if ([endpoint hasSuffix:@"/v1"] || [endpoint hasSuffix:@"/v1/"]) {
            endpoint = [endpoint stringByAppendingPathComponent:@"messages"];
        } else {
            endpoint = [endpoint stringByAppendingPathComponent:@"v1/messages"];
        }
    } else {
        if ([endpoint hasSuffix:@"/v1"] || [endpoint hasSuffix:@"/v1/"]) {
            endpoint = [endpoint stringByAppendingPathComponent:@"chat/completions"];
        } else {
            endpoint = [endpoint stringByAppendingPathComponent:@"v1/chat/completions"];
        }
    }

    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
            NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                              code:400
                                          userInfo:@{NSLocalizedDescriptionKey: @"无效的 BaseURL"}];
            [_delegate networkService:self didFailForConversationID:_conversationID error:err];
        }
        return NO;
    }

    // Read the streaming preference ONCE (shared by both formats).
    BOOL doStream = YES;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"streamingOutput"]) {
        doStream = [[NSUserDefaults standardUserDefaults] boolForKey:@"streamingOutput"];
    }
    // v261025-8: stream:false would leave the OpenAI parser with nothing
    // (it only understands SSE "data:" lines) and Anthropic returns plain
    // JSON too — connectionDidFinishLoading now has a non-stream JSON
    // fallback for both shapes. Anthropic additionally REQUIRES stream:true
    // for our SSE path, but the fallback covers stream:false as well.

    NSData *bodyData = nil;
    if (anthropic) {
        bodyData = [self _buildAnthropicRequestBody:messages stream:doStream];
    } else {
        bodyData = [self _buildOpenAIRequestBody:messages stream:doStream];
    }
    if (!bodyData) {
        if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
            NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                              code:500
                                          userInfo:@{NSLocalizedDescriptionKey: @"请求体序列化失败"}];
            [_delegate networkService:self didFailForConversationID:_conversationID error:err];
        }
        return NO;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:240.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    // v261103-18: revert Connection: close. v261103-15 加的 Connection: close
    // 基于 DeepSeek "死连接" 假说，但该假说未被证实。更糟的是: iOS 6 无视
    // Connection: close (DeepSeek 自己说的)，加了可能让每次请求后关闭连接，
    // 下次请求要新建 TLS 握手。大请求新建 TLS 时更容易失败 — 这可能就是
    // 大请求失败率高的部分原因。revert 后连接复用，小请求建立的 TLS
    // 连接可能被大请求复用，绕过新建握手的失败。
    // v261103-15: timeout bumped 120s→240s. iOS 6 changed the default
    // timeout for HTTPBody-bearing requests from 240s (pre-iOS6) to 60s.
    // 120s was sometimes too short for large image uploads combined
    // with slow mobile networks; 240s restores the historical behavior
    // and gives the adaptive re-compression + retry path time to work.
    if (self.apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey]
        forHTTPHeaderField:@"Authorization"];
    }
    if (anthropic) {
        // Anthropic auth headers. x-api-key is the canonical one; the
        // Bearer Authorization above is ALSO accepted by Anthropic and is
        // the only one the current transit forwards — send both.
        // (Transit ≥ v261025-8 additionally forwards x-api-key +
        // anthropic-version; until it is redeployed, some strict
        // deployments may require the update.)
        if (self.apiKey.length > 0) {
            [req setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
        }
        [req setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    }
    // v261103-2: removed X-Target-URL header — chat no longer goes through
    // a transit proxy. The request goes directly to the provider's endpoint.
    // v261103-19: revert setHTTPBodyStream → setHTTPBody。setHTTPBodyStream
    // 在 iOS 6 上是"假流式"(先读全到内存)，没突破 130KB 限制，反而引入 -1021
    // (stream 耗尽后无法重试)。用 setHTTPBody (NSData 可重放)。
    // iOS 7+ 改用 NSURLSession (无 body 限制)，iOS 6 fallback 到这里。
    [req setHTTPBody:bodyData];

    // Reset accumulators for this turn.
    // v261025-13: segmented thinking — when re-launching after a tool
    // call (toolCallRelaunch=YES), DON'T clear _accumulated (it holds
    // the pre-tool-call text + tool markers that should stay visible).
    // Only clear tool call accumulators (new turn may emit new calls).
    if (!self.toolCallRelaunch) {
        [_accumulated setString:@""];
    }
    [_toolCallAccumulators removeAllObjects];
    self.toolCallPending = NO;
    self.toolCallRelaunch = NO;

    // Cancel any in-flight connection before starting a new one — otherwise
    // both connections will dispatch into the same accumulators / delegate,
    // corrupting state. This was audit finding #8.
    [_connection cancel];
    // v261103-19: 也取消 NSURLSession task (iOS 7+)
    if (_dataTask) { @try { [_dataTask cancel]; } @catch (id e) {} }

    self.streamStartTs = [NSDate timeIntervalSinceReferenceDate];
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"NET → POST %@ | provider=%@ model=%@ stream=%d format=%@ msgs=%lu bytes=%lu",
        url.absoluteString ?: @"?",
        self.useTransit ? (self.provider ?: @"?") : @"(direct)",
        (self.model ?: @"(server-default)"),
        (int)doStream,
        anthropic ? @"anthropic" : @"openai",
        (unsigned long)[messages count], (unsigned long)[bodyData length]]];

    // v261103-19: iOS 7+ 用 NSURLSession 突破 NSURLConnection 的 ~130KB body 限制。
    // NSURLConnection 有已知 body 大小 bug (>~130KB 时 TLS 失败 -1200)，
    // Stack Overflow 有 64KB 报告。NSURLSession 是 iOS 7 全新实现，
    // uploadTask 能处理 GB 级 body，无此限制。
    // iPhone 4S (iOS 7+) 走 NSURLSession 路径；iPhone 3GS (iOS 6) fallback。
    Class sessionClass = NSClassFromString(@"NSURLSession");
    if (sessionClass) {
        // iOS 7+ — 用 NSURLSession 突破 body 限制
        [self _launchStreamWithNSURLSession:req bodyBytes:[bodyData length]];
        return YES;
    }

    // v261103-18: iOS 6 fallback — startImmediately:NO + common modes
    // 让连接在 UI 滑动时也能继续跑 (流式渲染 ListView 刷新不打断 TLS 握手)。
    self.connection = [[[NSURLConnection alloc] initWithRequest:req delegate:self
                                             startImmediately:NO] autorelease];
    if (self.connection) {
        [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop]
                                   forMode:NSRunLoopCommonModes];
        [self.connection start];
    }
    return (self.connection != nil);
}

#pragma mark - Request body builders (v261025-8)

// OpenAI-compatible body: {model, messages, stream, temperature,
// [thinking], [tools]}. Message content uses the array form when images
// are attached (multi-modal vision).
- (NSData *)_buildOpenAIRequestBody:(NSArray *)messages stream:(BOOL)doStream
{
    // Build the messages payload in OpenAI format.
    // messages array may contain Message objects (user/system/assistant)
    // OR NSDictionary objects (raw tool_calls assistant message and
    // tool role results from multi-turn tool use). We must handle both
    // — blindly calling isUser on an NSDictionary crashes (unrecognized
    // selector). This was bug1: search crashed during "正在执行搜索".
    NSMutableArray *msgs = [NSMutableArray arrayWithCapacity:[messages count]];
    for (id obj in messages) {
        if ([obj isKindOfClass:[Message class]]) {
            Message *m = (Message *)obj;
            NSString *role = m.isUser      ? @"user" :
                             m.isAssistant ? @"assistant" :
                                             @"system";
            // Multi-modal: if message has images, send array content format.
            if (m.images && [m.images count] > 0) {
                NSMutableArray *content = [NSMutableArray array];
                if (m.content && m.content.length > 0) {
                    [content addObject:@{@"type": @"text", @"text": m.content}];
                }
                for (NSString *dataUrl in m.images) {
                    [content addObject:@{@"type": @"image_url", @"image_url": @{@"url": dataUrl}}];
                }
                [msgs addObject:@{@"role": role, @"content": content}];
            } else {
                [msgs addObject:@{@"role": role, @"content": m.content ?: @""}];
            }
        } else if ([obj isKindOfClass:[NSDictionary class]]) {
            // Raw JSON message (assistant tool_calls or tool role).
            // Pass through unchanged.
            [msgs addObject:obj];
        }
    }

    // Check model supports thinking (default ON).
    BOOL doThink = NO;
    if (self.thinkingEnabled) {
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"modelSupportsThinking"]) {
            doThink = [[NSUserDefaults standardUserDefaults] boolForKey:@"modelSupportsThinking"];
        } else {
            doThink = YES; // default ON
        }
    }

    // "Use transit server's model" feature: when ON, omit the `model`
    // field from the request body — the transit server substitutes its
    // own configured default. When OFF (default), send the user-selected
    // model field. Only meaningful when useTransit=YES.
    BOOL useServerModel = NO;
    if (self.useTransit && [[NSUserDefaults standardUserDefaults] objectForKey:@"useServerModel"]) {
        useServerModel = [[NSUserDefaults standardUserDefaults] boolForKey:@"useServerModel"];
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"messages":    msgs,
        @"stream":      @(doStream),
        @"temperature": [NSNumber numberWithFloat:(float)self.temperature]
    }];
    if (!useServerModel) {
        // Send the user-selected model.
        [body setObject:self.model ?: @"gpt-3.5-turbo" forKey:@"model"];
    }
    // useServerModel=YES → omit `model`; transit server will fill it in.
    // v261102-1: 思考挡位重写。用户报告"思考开关关闭仍被强制思考"。
    // 根因：旧逻辑只在 doThink=YES 且 provider=zhipu 时挂 thinking 参数，
    // 其他情况一律不发——但 DeepSeek-Reasoner / GPT-5 / GLM-5.x 等
    // 默认开启思考的模型，没有显式 "disabled" 时仍会输出 reasoning_content。
    // 修复：按各供应商规范显式开关思考。
    //   - zhipu / deepseek (openai-compat): 顶层 "thinking":{"type":"enabled"|"disabled"}
    //       (deepseek-flash 支持 thinking.type; deepseek-reasoner 不支持 disabled
    //        但仍接受 enabled 字段)
    //   - openai (gpt-5+ reasoning models): 顶层 "reasoning_effort":"low"|"medium"|"high"
    //       (gpt-5 系列才接受此字段; gpt-3.5/gpt-4o 会忽略，无副作用)
    //   - 其他 (kimi/ollama/custom): 不发 (无原生控制; 关闭时只能靠模型本身默认)
    // 参考:
    //   https://api-docs.deepseek.com/zh-cn/guides/thinking_mode
    //   https://docs.bigmodel.cn/cn/guide/capabilities/thinking
    //   https://platform.openai.com/docs/guides/reasoning
    if (doThink) {
        if ([self.provider isEqualToString:ProviderIDZhipu] ||
            [self.provider isEqualToString:ProviderIDDeepSeek] ||
            [self.provider isEqualToString:ProviderIDKimi]) {
            [body setObject:@{@"type": @"enabled"} forKey:@"thinking"];
        } else if ([self.provider isEqualToString:ProviderIDOpenAI]) {
            [body setObject:@"high" forKey:@"reasoning_effort"];
        }
    } else {
        if ([self.provider isEqualToString:ProviderIDZhipu] ||
            [self.provider isEqualToString:ProviderIDDeepSeek] ||
            [self.provider isEqualToString:ProviderIDKimi]) {
            [body setObject:@{@"type": @"disabled"} forKey:@"thinking"];
        } else if ([self.provider isEqualToString:ProviderIDOpenAI]) {
            [body setObject:@"minimal" forKey:@"reasoning_effort"];
        }
    }

    // Tools array. The two lightweight tools (get_current_time,
    // get_device_info) are gated by 总设置 toggles (default ON — keeps
    // the previous "always available" behavior unless user turns them
    // off explicitly). generate_image is gated by the global 生图功能
    // switch (default ON). Search/fetch routing depends on the
    // autonomous flags: when the provider has its own native search or
    // fetch URL enabled, we declare `web_search` / `fetch_url` tools
    // (provider's own API) INSTEAD OF `tavily_search` — and the AI's
    // tool-call for those routes through _runPendingToolCalls' provider
    // branch instead of the Tavily branch.
    NSMutableArray *toolsArray = [NSMutableArray array];

    // v261103-7: 分段推理 toggle. When OFF, simple chat mode — no tools.
    // When ON (default), full agent mode with multi-turn tool calls.
    BOOL segmentedReasoning = YES;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"composer.segmentedReasoning"]) {
        segmentedReasoning = [[NSUserDefaults standardUserDefaults] boolForKey:@"composer.segmentedReasoning"];
    }

    if (segmentedReasoning) {
    // v261102-1: global toggles for the two lightweight tools.
    BOOL timeToolOn = YES;  // default ON
    if ([[NSUserDefaults standardUserDefaults] objectForKey:SettingsKeyEnableTimeTool]) {
        timeToolOn = [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyEnableTimeTool];
    }
    BOOL deviceInfoToolOn = YES;  // default ON
    if ([[NSUserDefaults standardUserDefaults] objectForKey:SettingsKeyEnableDeviceInfoTool]) {
        deviceInfoToolOn = [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyEnableDeviceInfoTool];
    }
    BOOL imageGenFeatureOn = YES;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:SettingsKeyImageGenFeatureEnabled]) {
        imageGenFeatureOn = [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyImageGenFeatureEnabled];
    }

    // Tool 1: get_current_time — gated by global toggle.
    if (timeToolOn) {
        [toolsArray addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": @"get_current_time",
                @"description": @"Get the current date, time, timezone, and day of week on the user's device. Use this when the user asks about the current time, today's date, what day it is, or any time-sensitive query.",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[]
                }
            }
        }];
    }

    // Tool 2: get_device_info — gated by global toggle.
    if (deviceInfoToolOn) {
        [toolsArray addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": @"get_device_info",
                @"description": @"Get information about the user's device: hardware model identifier (e.g. iPhone4,1), iOS version, battery level, screen size, language. Use this when the user asks about their device or for debugging.",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[]
                }
            }
        }];
    }

    // Tool 3: generate_image — gated by global 生图功能 toggle.
    if (imageGenFeatureOn) {
        [toolsArray addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": @"generate_image",
                @"description": @"Generate an image based on a text description. Use this when the user asks to draw, paint, create, generate, or make an image/picture/illustration. The generated image will be displayed in the chat automatically.",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"prompt": @{
                            @"type": @"string",
                            @"description": @"The image description. Be specific and descriptive for best results. English prompts usually work better."
                        },
                        @"size": @{
                            @"type": @"string",
                            @"description": @"Image size. Options: '256x256', '512x512', '1024x1024' (default). Some providers also support '1792x1024' or '1024x1792'.",
                            @"default": @"1024x1024"
                        }
                    },
                    @"required": @[@"prompt"]
                }
            }
        }];
    }

    // Tool 4a: web_search (provider's OWN native search) — when the
    // active provider has autonomous web search enabled. This tool is
    // declared INSTEAD OF tavily_search (mutually exclusive — avoids
    // the AI choosing Tavily when the user wants the provider's native
    // search).
    if (self.autonomousWebSearch) {
        [toolsArray addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": @"web_search",
                @"description": @"Search the web for current information using the model provider's built-in web search. Use this when the user asks about recent events, current prices, latest news, or anything you don't already know. Each call returns titles, URLs, and content snippets. Cite URLs in your answer.",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"query": @{
                            @"type": @"string",
                            @"description": @"The search query (in English or Chinese as appropriate). Keep concise."
                        }
                    },
                    @"required": @[@"query"]
                }
            }
        }];
    }

    // Tool 4b: fetch_url (provider's OWN native URL reader) — when the
    // active provider has autonomous URL reading enabled.
    if (self.autonomousURLRead) {
        [toolsArray addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": @"fetch_url",
                @"description": @"Fetch the content of a web page URL and return it as text. Use this when the user shares a link or asks about a specific web page — you'll get the page's title and main content.",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"url": @{
                            @"type": @"string",
                            @"description": @"The full URL to fetch (including https://)."
                        }
                    },
                    @"required": @[@"url"]
                }
            }
        }];
    }

    // Tool 4c: tavily_search — only when webSearch is enabled AND the
    // provider does NOT have autonomous web search enabled (mutually
    // exclusive — when autonomous is ON, we declared web_search above
    // and the Tavily path is shut off).
    if (self.enableWebSearchTools && !self.autonomousWebSearch
        && self.tavilyKey.length > 0) {
        [toolsArray addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": @"tavily_search",
                @"description": @"Search the web for current information. Use this when the user asks about recent events, current prices, latest news, or anything you don't already know. Each call returns up to N results with title, URL, and a content snippet. Cite URLs in your answer.",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"query": @{
                            @"type": @"string",
                            @"description": @"The search query (in English or Chinese as appropriate)."
                        }
                    },
                    @"required": @[@"query"]
                }
            }
        }];
    }

    } // end if (segmentedReasoning)

    if ([toolsArray count] > 0) {
        [body setObject:toolsArray forKey:@"tools"];
        [body setObject:@"auto" forKey:@"tool_choice"];
    }

    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:&jsonErr];
    if (jsonErr || !bodyData) return nil;
    return bodyData;
}

// v261025-8: Anthropic Messages API body:
//   {model, max_tokens, [temperature], stream, [system], messages:[
//      {role:"user"|"assistant", content:[{type:"text",text:…} |
//                                         {type:"image", source:{…}}]}]}
// System messages are hoisted into the top-level `system` field (the
// Anthropic protocol has no system role in the messages array). Tool
// calls are NOT sent for Anthropic in this beta (the tool-use event
// shapes differ); pre-search web results still work because they are
// injected as a system prompt, which maps cleanly onto `system`.
- (NSData *)_buildAnthropicRequestBody:(NSArray *)messages stream:(BOOL)doStream
{
    NSMutableString *systemText = [NSMutableString string];
    NSMutableArray *msgs = [NSMutableArray arrayWithCapacity:[messages count]];
    for (id obj in messages) {
        if (![obj isKindOfClass:[Message class]]) continue;   // no raw tool dicts for anthropic
        Message *m = (Message *)obj;
        if (m.role == MessageRoleSystem) {
            if (m.content.length > 0) {
                if (systemText.length > 0) [systemText appendString:@"\n\n"];
                [systemText appendString:m.content];
            }
            continue;
        }
        NSString *role = m.isUser ? @"user" : @"assistant";
        NSMutableArray *content = [NSMutableArray array];
        if (m.content && m.content.length > 0) {
            [content addObject:@{@"type": @"text", @"text": m.content}];
        }
        // Multi-modal: convert "data:image/jpeg;base64,…" data URLs into
        // Anthropic's {type:"image", source:{type:"base64",…}} blocks.
        for (NSString *dataUrl in (m.images ?: @[])) {
            if (![dataUrl isKindOfClass:[NSString class]]) continue;
            NSRange semi = [dataUrl rangeOfString:@";base64,"];
            if (semi.location == NSNotFound || ![dataUrl hasPrefix:@"data:image/"]) continue;
            NSString *mediaType = [dataUrl substringWithRange:NSMakeRange(5, semi.location - 5)];
            NSString *b64 = [dataUrl substringFromIndex:semi.location + semi.length];
            if (b64.length == 0) continue;
            [content addObject:@{
                @"type": @"image",
                @"source": @{
                    @"type": @"base64",
                    @"media_type": mediaType,
                    @"data": b64
                }
            }];
        }
        if ([content count] == 0) continue;   // nothing to send for this turn
        [msgs addObject:@{@"role": role, @"content": content}];
    }
    if ([msgs count] == 0) return nil;

    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"model":      self.model ?: @"claude-3-5-haiku-20241022",
        @"max_tokens": @4096,
        @"stream":     @(doStream),
        @"messages":   msgs
    }];
    // Anthropic recommends temperature 0..1; clamp our 0..2 range.
    CGFloat t = self.temperature;
    if (t > 1.0f) t = 1.0f;
    [body setObject:[NSNumber numberWithFloat:(float)t] forKey:@"temperature"];
    if (systemText.length > 0) {
        [body setObject:[NSString stringWithString:systemText] forKey:@"system"];
    }

    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:&jsonErr];
    if (jsonErr || !bodyData) return nil;
    return bodyData;
}

- (void)cancel
{
    // Nil-out the delegate first so any in-flight callbacks from the
    // dying connection don't dispatch into a freed VC (audit #2, #3).
    _delegate = nil;
    [_connection cancel];
}

// v261025-1: cancel the stream, keep the delegate. Also mark the service
// as not-streaming so the connection's (already-scheduled) final
// callbacks are ignored: NSURLConnection may still deliver a final
// didFail/didFinish to this runloop turn even after -cancel, and we
// don't want a cancelled stream to fire didFinish into the NEW
// conversation's UI.
- (void)cancelStream
{
    [_connection cancel];
    self.connection = nil;
    [_rawBuffer setData:nil];
    self.conversationID = nil;   // invalidates all late callbacks (ID guards)
    [_accumulated setString:@""];
    [_thinkingAccumulated setString:@""];
    [_toolCallAccumulators removeAllObjects];
    self.toolCallPending = NO;
}

// v261025-3: Stop the in-flight stream but PRESERVE the accumulated text.
// Unlike cancelStream (which is used when switching conversations and
// clears all state so the next send starts clean), stopGenerating is
// triggered by the user tapping the "Stop" button mid-stream. The text
// the AI has produced so far should be KEPT as the assistant message —
// the user explicitly asked to stop, not to discard.
//
// Implementation:
//   1. Nil the connection so no more chunks arrive.
//   2. Capture accumulated text + thinking + conversation ID into locals
//      (we're about to clear them, but we still need to deliver them).
//   3. Reset all stream state (same as cancelStream minus the conversationID).
//   4. Manually fire didFinishForConversationID with the captured text,
//      so the delegate (ChatViewController) sees the normal completion path
//      and saves the partial message to disk + clears isStreaming.
//
// NOTE: This method MUST be called on the main thread. The delegate is
// __unsafe_unretained, so we cannot dispatch_async — the delegate could
// be released before the async block runs. Synchronous delivery on the
// caller's (main) thread is the only safe path.
- (void)stopGenerating
{
    if (!_connection) {
        // Nothing in flight — no-op (defensive; UI shouldn't allow this).
        return;
    }
    NSString *capturedConvID = [_conversationID retain];
    NSString *capturedText = [_accumulated copy];
    NSString *capturedThinking = [_thinkingAccumulated copy];

    [_connection cancel];
    self.connection = nil;
    [_rawBuffer setData:nil];
    self.toolCallPending = NO;
    [_toolCallAccumulators removeAllObjects];
    // NOTE: do NOT nil out _conversationID here — we still need it for
    // the didFinish delegate callback. Clear it AFTER delivery.
    [_accumulated setString:@""];
    [_thinkingAccumulated setString:@""];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"NET ⊘ user stopped — delivering %lu chars of partial text",
        (unsigned long)(capturedText.length)]];

    // Synchronous delivery on the caller's thread. Delegate is assign,
    // so we must not defer this to a queue (the delegate could be freed
    // before the block runs — its owning VC could be torn down).
    if ([_delegate respondsToSelector:@selector(networkService:didReceiveThinkingForConversationID:thinkingText:)] &&
        capturedThinking.length > 0) {
        [_delegate networkService:self
            didReceiveThinkingForConversationID:capturedConvID
                              thinkingText:capturedThinking];
    }
    if ([_delegate respondsToSelector:@selector(networkService:didFinishForConversationID:fullText:)]) {
        [_delegate networkService:self
              didFinishForConversationID:capturedConvID
                              fullText:capturedText ?: @""];
    }
    self.conversationID = nil;
    [capturedConvID release];
    [capturedText release];
    [capturedThinking release];
}

#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    [_rawBuffer setData:nil];
    self.httpStatus = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.httpStatus = [(NSHTTPURLResponse *)response statusCode];
    }
    // v261025-1: RESPONSE log — first thing the server said.
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"NET ← HTTP %ld", (long)self.httpStatus]];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    // v261024-19: NO @try — nil-guards.
    if (!data) return;
    if (!_rawBuffer) return;
    [_rawBuffer appendData:data];
    [self _parseBufferedChunks];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSTimeInterval dur = [NSDate timeIntervalSinceReferenceDate] - self.streamStartTs;
    // Non-2xx HTTP status → surface the REAL error instead of an empty
    // reply. Extract the upstream error message from the JSON body when
    // possible so the user sees WHY (404 route, 401 key, 502 upstream…).
    if (self.httpStatus != 0 && (self.httpStatus < 200 || self.httpStatus >= 300)) {
        NSString *bodyText = [[[NSString alloc] initWithData:_rawBuffer
                                                    encoding:NSUTF8StringEncoding] autorelease];
        NSString *detail = [self _extractErrorMessageFromBody:bodyText];
        if (detail.length == 0 && bodyText.length > 0) {
            detail = ([bodyText length] > 200) ? [bodyText substringToIndex:200] : bodyText;
        }
        NSString *msg = [NSString stringWithFormat:@"HTTP %d: %@",
                         (int)self.httpStatus,
                         detail.length > 0 ? detail : @"请求失败（中转或上游返回错误）"];
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"NET ✗ HTTP %ld after %.1fs — %@", (long)self.httpStatus, dur,
            detail.length > 0 ? detail : @"(no body detail)"]];
        if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
            NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                               code:(NSInteger)self.httpStatus
                                           userInfo:@{NSLocalizedDescriptionKey: msg}];
            [_delegate networkService:self didFailForConversationID:_conversationID error:err];
        }
        return;
    }

    [self _parseBufferedChunksForce:YES];

    // v261025-8 BUG FIX: 流式输出关闭 (stream:false) 或响应被代理去掉 SSE 框架时，
    // 整个响应是一个纯 JSON body —— SSE 解析器只认 "data:" 行，什么都不 accumulate，
    // 用户就会看到 "⚠️ 服务器返回了空回复"。这里补上两种非流式 JSON 形状的解析。
    if (_accumulated.length == 0 && [_rawBuffer length] > 0 &&
        self.httpStatus >= 200 && self.httpStatus < 300) {
        [self _tryParseNonStreamJSONBody];
    }

    // Check if AI emitted tool_calls → multi-turn tool use flow.
    if ([_toolCallAccumulators count] > 0 && _toolCallTurn < _maxToolTurns) {
        _toolCallTurn++;
        [[Logger sharedLogger] info:[NSString stringWithFormat:
            @"NET ⟳ tool-call turn %ld (%lu calls) — executing",
            (long)_toolCallTurn, (unsigned long)[_toolCallAccumulators count]]];
        [self _runPendingToolCalls];
        return;
    }

    // v261025-1: FINISH log — the full anatomy of the reply. When the
    // answer is EMPTY we also dump the head of the raw response body so
    // the user can SEE whether it was an SSE stream, a JSON body, or
    // something the parser didn't understand (this is the "空回复"
    // diagnostic the user asked for).
    if (_accumulated.length == 0) {
        NSString *bodyHead = [[[NSString alloc] initWithData:_rawBuffer
                                                    encoding:NSUTF8StringEncoding] autorelease];
        if (bodyHead.length > 200) bodyHead = [bodyHead substringToIndex:200];
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"NET ✗ EMPTY reply after %.1fs — body head: %@",
            dur, bodyHead.length > 0 ? bodyHead : @"(zero bytes)"]];
    } else {
        [[Logger sharedLogger] info:[NSString stringWithFormat:
            @"NET ✓ done in %.1fs — %lu chars, %lu thinking-chars, %ld tool turns",
            dur,
            (unsigned long)_accumulated.length,
            (unsigned long)_thinkingAccumulated.length,
            (long)_toolCallTurn]];
    }

    // Normal completion.
    if ([_delegate respondsToSelector:@selector(networkService:didFinishForConversationID:fullText:)]) {
        [_delegate networkService:self
             didFinishForConversationID:_conversationID
                             fullText:_accumulated];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    // v261103-2: removed the transit TLS fallback (https → http retry).
    // Chat no longer goes through a transit proxy, so there's no transit
    // URL to downgrade. Direct connections stay https — if iOS 6 TLS
    // can't negotiate with a specific provider, the error surfaces as-is
    // and the user sees the real failure reason (not a masked retry).
    NSTimeInterval dur = [NSDate timeIntervalSinceReferenceDate] - self.streamStartTs;
    // v261025-1: FAIL log with duration + OS-level error.
    [[Logger sharedLogger] error:[NSString stringWithFormat:
        @"NET ✗ connection failed after %.1fs — code=%ld domain=%@ desc=%@",
        dur, (long)error.code, error.domain,
        error.localizedDescription ?: @"(no desc)"]];
    if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
        [_delegate networkService:self
              didFailForConversationID:_conversationID
                              error:error];
    }
}

#pragma mark - NSURLSession path (iOS 7+) — v261103-19
// NSURLSession 突破 NSURLConnection 的 ~130KB body 限制。
// iPhone 4S (iOS 7+) 走这条路。方法名跟 NSURLConnection delegate 不同，共存。
// 用 NSClassFromString + performSelector 动态调用，避免 iOS 6 运行时崩溃。

- (void)_launchStreamWithNSURLSession:(NSMutableURLRequest *)req bodyBytes:(NSUInteger)bodyBytes
{
    // 取消旧的 session/task
    if (_dataTask) { @try { [_dataTask cancel]; } @catch (id e) {} }
    if (_urlSession) { @try { [_urlSession invalidateAndCancel]; } @catch (id e) {} }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 240.0;
    config.timeoutIntervalForResource = 300.0;
    // 不让 session 在后台跑（避免 iOS 6 设备上的奇怪行为）
    config.HTTPShouldUsePipelining = YES;

    self.urlSession = [NSURLSession sessionWithConfiguration:config
                                                    delegate:self
                                               delegateQueue:nil];
    if (!self.urlSession) {
        [[Logger sharedLogger] error:@"NSURLSession 创建失败，fallback 到 NSURLConnection"];
        self.connection = [[[NSURLConnection alloc] initWithRequest:req delegate:self
                                                startImmediately:NO] autorelease];
        if (self.connection) {
            [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            [self.connection start];
        }
        return;
    }

    self.dataTask = [self.urlSession dataTaskWithRequest:req];
    if (!self.dataTask) {
        [[Logger sharedLogger] error:@"NSURLSessionDataTask 创建失败，fallback"];
        [_urlSession invalidateAndCancel];
        self.urlSession = nil;
        self.connection = [[[NSURLConnection alloc] initWithRequest:req delegate:self
                                                startImmediately:NO] autorelease];
        if (self.connection) {
            [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            [self.connection start];
        }
        return;
    }

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"NET → (NSURLSession) body=%luB", (unsigned long)bodyBytes]];

    [self.dataTask resume];
}

#pragma mark - NSURLSessionDataDelegate (iOS 7+)
// 方法名跟 NSURLConnection delegate 不同，能共存。
// iOS 6 设备走 NSURLConnection 路径，这些方法不会被调用。

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    [_rawBuffer setData:nil];
    self.httpStatus = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.httpStatus = [(NSHTTPURLResponse *)response statusCode];
    }
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"NET ← HTTP %ld (NSURLSession)", (long)self.httpStatus]];
    if (completionHandler) completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    if (!data) return;
    if (!_rawBuffer) return;
    [_rawBuffer appendData:data];
    [self _parseBufferedChunks];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error) {
        [self connection:nil didFailWithError:error];
    } else {
        [self connectionDidFinishLoading:nil];
    }
    @try { [_urlSession finishTasksAndInvalidate]; } @catch (id e) {}
    self.urlSession = nil;
    self.dataTask = nil;
}

#pragma mark - Tool call execution

- (void)_runPendingToolCalls
{
    // v261024-19: NO @try — defensive nil-guards instead.
    NSMutableArray *newMessages = [NSMutableArray arrayWithArray:self.baseMessages];

    // Append the assistant message that contains the tool_calls.
    // This is required so the API knows the assistant already emitted these calls.
    NSMutableArray *toolCallsArray = [NSMutableArray array];
    for (NSMutableDictionary *tc in _toolCallAccumulators) {
        NSString *callId = [tc objectForKey:@"id"] ?: @"";
        NSString *fnName = [tc objectForKey:@"name"] ?: @"tavily_search";
        NSString *args   = [tc objectForKey:@"arguments"] ?: @"{}";
        [toolCallsArray addObject:@{
            @"id": callId,
            @"type": @"function",
            @"function": @{
                @"name": fnName,
                @"arguments": args
            }
        }];
    }
    // Bug fix: COPY _accumulated into the dict. The original code put
    // a reference to the NSMutableString directly into the dict — later,
    // when we do `[_accumulated setString:@""]` in the bg-queue's main
    // dispatch (before re-launching the stream), the dict's content would
    // silently become empty. This caused the assistant's pre-tool-call
    // text to be lost AND could lead to confusing state when the API
    // received an assistant message with empty content but tool_calls.
    NSString *contentForDict = [_accumulated copy];
    NSDictionary *assistantToolMsg = @{
        @"role": @"assistant",
        @"content": contentForDict.length > 0 ? contentForDict : [NSNull null],
        @"tool_calls": toolCallsArray
    };
    [contentForDict release];
    [newMessages addObject:assistantToolMsg];

    // Save context for the bg-queue closure.
    NSMutableArray *toolCallAcc = [NSMutableArray arrayWithArray:_toolCallAccumulators];
    NSString *tavilyKey = [_tavilyKey copy];
    NSInteger tavilyMax = _tavilyMaxResults;
    BOOL useTransit = _useTransit;
    NSString *transitURL = [_transitURL copy];
    // v261024-16 fix: generate_image needs the AI PROVIDER key, not the
    // Tavily key. The old code passed `tavilyKey` (comment said "reuse
    // API key" but grabbed the wrong variable) → image generation always
    // got 401 from the upstream.
    NSString *providerKey = [self.apiKey copy];
    // Also copy provider — accessing self.provider inside the bg block
    // would return an autorelease object with no autorelease pool on the
    // GCD worker thread.
    NSString *providerName = [self.provider copy];
    // v261025-8: the chat's own baseURL — needed by the image-gen tool
    // call so the image API target matches the active entry's endpoint
    // (per-entry baseURL now drives everything).
    NSString *providerBaseURL = [self.baseURL copy];

    // Notify delegate that we're executing the tool call.
    if ([_delegate respondsToSelector:@selector(networkService:didReceiveToolCallStartedForConversationID:)]) {
        [_delegate networkService:self
     didReceiveToolCallStartedForConversationID:_conversationID];
    }

    // v261025-13: agent-style segmented thinking — insert tool call
    // markers into _accumulated so the user sees what's happening inline.
    // This runs on the MAIN thread (we're in connectionDidFinishLoading).
    BOOL showToolCalls = YES;  // default ON
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"showToolCalls"]) {
        showToolCalls = [[NSUserDefaults standardUserDefaults] boolForKey:@"showToolCalls"];
    }
    // v261103-8: 分段推理 UI — before showing tool markers, insert the
    // accumulated thinking as an inline :::thinking block so the user
    // sees the reasoning flow: think → tool call → think → answer.
    // This is what "分段推理" means visually — each segment is a
    // distinct block, not crammed together.
    if (showToolCalls && _thinkingAccumulated.length > 0) {
        NSString *thinkSnippet = _thinkingAccumulated.length > 200 ?
            [_thinkingAccumulated substringToIndex:200] : [NSString stringWithString:_thinkingAccumulated];
        NSString *thinkMarker = [NSString stringWithFormat:
            @"\n:::thinking\n💭 %@…\n:::\n", thinkSnippet];
        [_accumulated appendString:thinkMarker];
        // Clear thinking accumulator — the next turn's thinking will be
        // a separate :::thinking block (visually segmented from this one).
        [_thinkingAccumulated setString:@""];
    }
    if (showToolCalls) {
        for (NSDictionary *tc in toolCallAcc) {
            NSString *fnName = [tc objectForKey:@"name"] ?: @"";
            NSString *args = [tc objectForKey:@"arguments"] ?: @"{}";
            NSData *argsData = [args dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *argsDict = [NSJSONSerialization JSONObjectWithData:argsData options:0 error:NULL] ?: @{};
            // v261102-1: NEW marker syntax — wrapped in :::tool fences so
            // MarkdownParser renders them as a gray box. Per-tool status
            // text follows the user's spec:
            //   search    → 正在搜索"xxx"
            //   fetch_url → 正在读取 https://xxx.com/xx...
            //   get_current_time → 获取时间中...
            //   get_device_info   → 获取设备简单信息中...
            //   generate_image    → 正在生成图片...
            //   (other)           → 正在调用工具 fnName...
            // The matching "done" marker is appended after the tool
            // finishes (in the bg-queue closure's main-thread dispatch).
            NSString *marker = nil;
            if ([fnName isEqualToString:@"tavily_search"] ||
                [fnName isEqualToString:@"web_search"]) {
                id q = [argsDict objectForKey:@"query"];
                NSString *qs = [q isKindOfClass:[NSString class]] ? q : @"?";
                marker = [NSString stringWithFormat:@"\n\n:::tool\n正在搜索“%@”…\n:::\n\n", qs];
            } else if ([fnName isEqualToString:@"fetch_url"]) {
                id u = [argsDict objectForKey:@"url"];
                NSString *us = [u isKindOfClass:[NSString class]] ? u : @"?";
                // Truncate long URLs in the marker (full URL still goes
                // to the API). 60 chars + ellipsis matches the spec
                // "正在读取 https://xxx.com/xx...".
                NSString *displayURL = us.length > 60
                    ? [NSString stringWithFormat:@"%@…", [us substringToIndex:60]]
                    : us;
                marker = [NSString stringWithFormat:@"\n\n:::tool\n正在读取 %@…\n:::\n\n", displayURL];
            } else if ([fnName isEqualToString:@"get_current_time"]) {
                marker = @"\n\n:::tool\n获取时间中…\n:::\n\n";
            } else if ([fnName isEqualToString:@"get_device_info"]) {
                marker = @"\n\n:::tool\n获取设备简单信息中…\n:::\n\n";
            } else if ([fnName isEqualToString:@"generate_image"]) {
                id p = [argsDict objectForKey:@"prompt"];
                NSString *ps = [p isKindOfClass:[NSString class]] ? p : @"?";
                marker = [NSString stringWithFormat:@"\n\n:::tool\n正在生成图片“%@”…\n:::\n\n", ps];
            } else {
                marker = [NSString stringWithFormat:@"\n\n:::tool\n正在调用工具 %@…\n:::\n\n", fnName];
            }
            if (marker) [_accumulated appendString:marker];
        }
        if ([_delegate respondsToSelector:@selector(networkService:didReceiveChunkForConversationID:fullText:)]) {
            [_delegate networkService:self
                didReceiveChunkForConversationID:_conversationID fullText:_accumulated];
        }
    }

    // Run Tavily searches on a background queue (avoid blocking main).
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // GCD worker threads have NO autorelease pool — wrap everything
        // so the `autorelease`d NetworkService/NSDateFormatter objects
        // below don't leak per tool-call round.
        @autoreleasepool {
        // v261024-19: NO @try — per-step nil-guards. If anything goes
        // wrong mid-loop we still re-launch with whatever tool results
        // we have so the chat doesn't get stuck.
        NSMutableArray *toolResults = [NSMutableArray array];
        for (NSDictionary *tc in toolCallAcc) {
            NSString *callId = [tc objectForKey:@"id"];
            NSString *args   = [tc objectForKey:@"arguments"];
            NSString *fnName = [tc objectForKey:@"name"];
            // Defensive: JSON null becomes NSNull singleton, which doesn't
            // respond to NSString methods. Coerce NSNull → nil/empty so
            // isEqualToString: doesn't crash. (User-reported crash:
            // -[NSNull isEqualToString:]: unrecognized selector)
            if (![callId isKindOfClass:[NSString class]]) callId = nil;
            if (![args isKindOfClass:[NSString class]])   args = @"{}";
            if (![fnName isKindOfClass:[NSString class]]) fnName = @"";

            // === get_current_time =========================================
            // v261103-1: 返回 PLAIN TEXT (不是 JSON) 给模型。原版返回 JSON,
            // 模型容易在回复里原样 echo, 用户看到一堆 JSON 混在对话里很乱。
            // 现在用自然语言格式, 模型 echo 也只是一句可读的话。
            if ([fnName isEqualToString:@"get_current_time"]) {
                NSDate *now = [NSDate date];
                NSDateFormatter *isoFmt = [[[NSDateFormatter alloc] init] autorelease];
                [isoFmt setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
                NSString *iso = [isoFmt stringFromDate:now];
                NSDateFormatter *dowFmt = [[[NSDateFormatter alloc] init] autorelease];
                [dowFmt setDateFormat:@"EEEE"];
                NSString *dow = [dowFmt stringFromDate:now];
                NSTimeZone *tz = [NSTimeZone systemTimeZone];
                NSString *contentStr = [NSString stringWithFormat:
                    @"Current time: %@ (%@, UTC%@). Timezone: %@.",
                    iso, dow, [tz abbreviation] ?: @"?",
                    [tz name]];
                @synchronized(toolResults) {
                    [toolResults addObject:@{
                        @"role": @"tool",
                        @"tool_call_id": callId ?: @"",
                        @"content": contentStr
                    }];
                }
                continue;
            }

            // === get_device_info ==========================================
            // v261103-1: 同样改 PLAIN TEXT。
            if ([fnName isEqualToString:@"get_device_info"]) {
                UIDevice *device = [UIDevice currentDevice];
                [device setBatteryMonitoringEnabled:YES];
                float batteryLevel = [device batteryLevel];
                NSString *batteryStr;
                if (batteryLevel < 0) {
                    batteryStr = @"unknown";
                } else {
                    batteryStr = [NSString stringWithFormat:@"%.0f%%", batteryLevel * 100.0f];
                }
                UIDeviceBatteryState batteryState = [device batteryState];
                NSString *batteryStateStr;
                switch (batteryState) {
                    case UIDeviceBatteryStateUnplugged: batteryStateStr = @"unplugged"; break;
                    case UIDeviceBatteryStateCharging:  batteryStateStr = @"charging"; break;
                    case UIDeviceBatteryStateFull:      batteryStateStr = @"full"; break;
                    default:                             batteryStateStr = @"unknown"; break;
                }
                // Get hardware identifier (e.g. "iPhone4,1") via sysctl.
                NSString *hwMachine = @"unknown";
                size_t size = 0;
                sysctlbyname("hw.machine", NULL, &size, NULL, 0);
                if (size > 0) {
                    char *machine = (char *)malloc(size);
                    if (machine) {
                        sysctlbyname("hw.machine", machine, &size, NULL, 0);
                        NSString *s = [NSString stringWithCString:machine
                                                          encoding:NSUTF8StringEncoding];
                        if (s) hwMachine = s;
                        free(machine);
                    }
                }
                CGRect screen = [[UIScreen mainScreen] bounds];
                NSString *lang = [[NSLocale preferredLanguages] objectAtIndex:0] ?: @"unknown";
                NSLocale *locale = [NSLocale currentLocale];
                NSString *localeId = [locale localeIdentifier] ?: @"unknown";
                NSString *contentStr = [NSString stringWithFormat:
                    @"Device: %@ (hardware %@). System: %@ %@. Battery: %@ (%@). Screen: %.0fx%.0f @%.1fx. Language: %@. Locale: %@.",
                    [device model] ?: @"unknown",
                    hwMachine,
                    [device systemName] ?: @"iOS",
                    [device systemVersion] ?: @"unknown",
                    batteryStr, batteryStateStr,
                    screen.size.width, screen.size.height,
                    [[UIScreen mainScreen] scale],
                    lang, localeId];
                @synchronized(toolResults) {
                    [toolResults addObject:@{
                        @"role": @"tool",
                        @"tool_call_id": callId ?: @"",
                        @"content": contentStr
                    }];
                }
                continue;
            }

            // === generate_image ===========================================
            // AI asks to generate an image. iOS calls the image gen API via
            // transit, gets back a base64 data URL, fires didGenerateImage
            // delegate so ChatViewController appends it to the assistant
            // message's images array (image displays in the chat).
            if ([fnName isEqualToString:@"generate_image"]) {
                NSData *argsData = [args dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *argsDict = [NSJSONSerialization JSONObjectWithData:argsData
                                                                          options:0
                                                                            error:NULL];
                // Defensive: prompt/size might be NSNull.
                id promptRaw = [argsDict objectForKey:@"prompt"];
                NSString *prompt = [promptRaw isKindOfClass:[NSString class]] ? promptRaw : nil;
                id sizeRaw = [argsDict objectForKey:@"size"];
                NSString *size = [sizeRaw isKindOfClass:[NSString class]] ? sizeRaw : nil;
                if (!prompt || prompt.length == 0) {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": @"Error: missing 'prompt' argument"
                        }];
                    }
                    continue;
                }
                // Default image gen model per provider.
                // v261025-8: prefer the user's configured 生图模型
                // (SettingsKeyImageGenModel — set by tapping a kind="image"
                // entry in ModelManagement); fall back to a provider default
                // (cogview for zhipu, gpt-image-1 for openai).
                NSString *imgModel = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyImageGenModel];
                if (!imgModel || imgModel.length == 0) {
                    if ([providerName isEqualToString:ProviderIDZhipu]) {
                        imgModel = @"cogview-3plus";
                    } else {
                        imgModel = @"gpt-image-1";
                    }
                }
                // v261024-19: NO @try — nil-check on dataURL instead.
                NetworkService *svc = [[[NetworkService alloc] init] autorelease];
                NSError *err = nil;
                NSString *dataURL = [svc generateImageWithPrompt:prompt
                                                            model:imgModel
                                                            size:size
                                                       useTransit:useTransit
                                                       transitURL:transitURL
                                                         baseURL:providerBaseURL
                                                         provider:providerName
                                                          apiKey:providerKey
                                                            error:&err];
                if (dataURL.length > 0) {
                    // Fire delegate to append image to assistant message.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([self->_delegate respondsToSelector:@selector(networkService:didGenerateImageForConversationID:imageDataURL:)]) {
                            [self->_delegate networkService:self
                      didGenerateImageForConversationID:self->_conversationID
                                          imageDataURL:dataURL];
                        }
                    });
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": @"Image generated successfully and displayed in the chat above."
                        }];
                    }
                } else {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": [NSString stringWithFormat:@"Image generation failed: %@", err.localizedDescription ?: @"unknown error"]
                        }];
                    }
                }
                continue;
            }

            // === web_search (provider's OWN native search API) ===========
            // v261102-1: when the active provider has autonomousWebSearch
            // enabled, the AI calls `web_search` instead of `tavily_search`.
            // We POST to the provider's autonomousSearchURL (or a URL
            // derived from the chat base URL when none is configured),
            // using autonomousSearchKey or the chat's own apiKey.
            if ([fnName isEqualToString:@"web_search"]) {
                NSData *argsData = [args dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *argsDict = [NSJSONSerialization JSONObjectWithData:argsData
                                                                          options:0
                                                                            error:NULL];
                id queryRaw = [argsDict objectForKey:@"query"];
                NSString *query = [queryRaw isKindOfClass:[NSString class]] ? queryRaw : nil;
                // Some models may emit "search_query" (Zhipu schema).
                if (!query) {
                    id q2 = [argsDict objectForKey:@"search_query"];
                    query = [q2 isKindOfClass:[NSString class]] ? q2 : nil;
                }
                if (!query || query.length == 0) {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": @"Error: missing 'query' argument"
                        }];
                    }
                    continue;
                }
                NSError *err = nil;
                NSString *resultText = [self _autonomousWebSearchWithQuery:query
                                                                       error:&err];
                if (err || resultText.length == 0) {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": [NSString stringWithFormat:@"Web search failed: %@", err.localizedDescription ?: @"empty"]
                        }];
                    }
                } else {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": resultText
                        }];
                    }
                }
                continue;
            }

            // === fetch_url (provider's OWN native URL reader API) ========
            // v261102-1: autonomousURLRead → AI calls `fetch_url` to read
            // a web page. POST to autonomousFetchURL (or derived from chat
            // base URL) with {"url": "..."} body.
            if ([fnName isEqualToString:@"fetch_url"]) {
                NSData *argsData = [args dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *argsDict = [NSJSONSerialization JSONObjectWithData:argsData
                                                                          options:0
                                                                            error:NULL];
                id urlRaw = [argsDict objectForKey:@"url"];
                NSString *urlStr = [urlRaw isKindOfClass:[NSString class]] ? urlRaw : nil;
                if (!urlStr || urlStr.length == 0) {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": @"Error: missing 'url' argument"
                        }];
                    }
                    continue;
                }
                NSError *err = nil;
                NSString *resultText = [self _autonomousFetchURLWithURL:urlStr
                                                                    error:&err];
                if (err || resultText.length == 0) {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": [NSString stringWithFormat:@"URL fetch failed: %@", err.localizedDescription ?: @"empty"]
                        }];
                    }
                } else {
                    @synchronized(toolResults) {
                        [toolResults addObject:@{
                            @"role": @"tool",
                            @"tool_call_id": callId ?: @"",
                            @"content": resultText
                        }];
                    }
                }
                continue;
            }

            // === tavily_search ============================================
            // Existing handler — search the web via Tavily.
            if (![fnName isEqualToString:@"tavily_search"]) {
                @synchronized(toolResults) {
                    [toolResults addObject:@{
                        @"role": @"tool",
                        @"tool_call_id": callId ?: @"",
                        @"content": [NSString stringWithFormat:@"Error: unknown tool %@", fnName]
                    }];
                }
                continue;
            }
            NSData *argsData = [args dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *argsDict = [NSJSONSerialization JSONObjectWithData:argsData
                                                                      options:0
                                                                        error:NULL];
            // Defensive: query might be NSNull if AI emits "query": null.
            id queryRaw = [argsDict objectForKey:@"query"];
            NSString *query = [queryRaw isKindOfClass:[NSString class]] ? queryRaw : nil;
            if (!query || query.length == 0) {
                @synchronized(toolResults) {
                    [toolResults addObject:@{
                        @"role": @"tool",
                        @"tool_call_id": callId ?: @"",
                        @"content": @"Error: missing 'query' argument"
                    }];
                }
                continue;
            }
            // v261024-19: NO @try — nil-check on searchResults instead.
            NetworkService *svc = [[[NetworkService alloc] init] autorelease];
            NSError *err = nil;
            NSArray *searchResults = [svc tavilySearchWithQuery:query
                                                          apiKey:tavilyKey
                                                     maxResults:tavilyMax
                                                     useTransit:useTransit
                                                      transitURL:transitURL
                                                          error:&err];
            if (err || !searchResults || [searchResults count] == 0) {
                @synchronized(toolResults) {
                    [toolResults addObject:@{
                        @"role": @"tool",
                        @"tool_call_id": callId ?: @"",
                        @"content": [NSString stringWithFormat:@"Search returned no results: %@", err.localizedDescription ?: @"empty"]
                    }];
                }
            } else {
                NSMutableString *contentStr = [NSMutableString string];
                [contentStr appendFormat:@"Search results for \"%@\" (%d):\n", query, (int)[searchResults count]];
                NSInteger i = 1;
                for (NSDictionary *r in searchResults) {
                    [contentStr appendFormat:@"%d. %@\n   URL: %@\n   %@\n\n",
                        (int)i++,
                        [r objectForKey:@"title"],
                        [r objectForKey:@"url"],
                        [r objectForKey:@"content"]];
                }
                @synchronized(toolResults) {
                    [toolResults addObject:@{
                        @"role": @"tool",
                        @"tool_call_id": callId ?: @"",
                        @"content": contentStr
                    }];
                }
            }
        }
        // Append tool results to messages.
        // v261103-5: FIX "tool call stops answering" bug — append a nudge
        // to the LAST tool result's content (not as a separate user msg,
        // which some models interpret as a new question). The nudge tells
        // the AI to produce a final answer. Without this, DeepSeek and
        // some other models see the tool results and generate EMPTY content
        // (they "think" but don't answer), triggering the "空回复" error.
        NSInteger trCount = [toolResults count];
        for (NSInteger ti = 0; ti < trCount; ti++) {
            NSMutableDictionary *tr = [NSMutableDictionary dictionaryWithDictionary:[toolResults objectAtIndex:ti]];
            if (ti == trCount - 1) {
                // Last tool result — append the nudge to its content.
                NSString *origContent = [tr objectForKey:@"content"] ?: @"";
                NSString *nudged = [NSString stringWithFormat:
                    @"%@\n\n---\nPlease now provide your final answer to the user based on the above tool results.",
                    origContent];
                [tr setObject:nudged forKey:@"content"];
            }
            [newMessages addObject:tr];
        }
        self.baseMessages = newMessages;

        // v261103-1: REMOVED inline result summary ("[结果] %@\n\n").
        // 原逻辑: 当 showSearchResults toggle ON 时, 把 tool result content
        // 截 300 字内联输出到 _accumulated — 用户看到 JSON / 搜索结果摘要
        // 直接混在对话里。即使 toggle OFF, 模型仍可能 echo 工具返回的 JSON
        // 内容到自己的回复里。彻底解决:
        //   1. get_current_time / get_device_info 已改返回 PLAIN TEXT
        //   2. web_search / fetch_url 的 result 只发给模型, 不再内联到 chat
        //   3. 用户看到的只有 :::tool 灰框 (已搜索 / 已读取 / 已获取时间)
        // 旧的 showSearchResults toggle 不再读取 (用户即使打开也不显示),
        // 设置页那个 toggle 行后续可以移除。

        // v261102-1: per-tool "done" markers — always show (gated by
        // showToolCalls, same as the pre-call markers). Per spec:
        //   search    → 已搜索"xxx"
        //   fetch_url → 已读取 https://xxx.com/xxx...
        //   get_current_time → 已获取时间
        //   get_device_info   → 已获取设备简单信息
        //   generate_image    → 已生成图片
        //   (other)           → 已完成工具调用 fnName
        // We use the callId → toolCallAcc mapping (preserved above as
        // toolCallAcc) to find each tool's name + args, then emit the
        // matching done marker in a :::tool gray box.
        NSMutableArray *doneMarkers = [NSMutableArray array];
        BOOL showToolCallsDone = YES;
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"showToolCalls"]) {
            showToolCallsDone = [[NSUserDefaults standardUserDefaults] boolForKey:@"showToolCalls"];
        }
        if (showToolCallsDone) {
            for (NSDictionary *tc in toolCallAcc) {
                NSString *fnName = [tc objectForKey:@"name"] ?: @"";
                NSString *args = [tc objectForKey:@"arguments"] ?: @"{}";
                NSData *argsData = [args dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *argsDict = [NSJSONSerialization JSONObjectWithData:argsData options:0 error:NULL] ?: @{};
                NSString *m = nil;
                if ([fnName isEqualToString:@"tavily_search"] ||
                    [fnName isEqualToString:@"web_search"]) {
                    id q = [argsDict objectForKey:@"query"];
                    if (!q) q = [argsDict objectForKey:@"search_query"];
                    NSString *qs = [q isKindOfClass:[NSString class]] ? q : @"?";
                    m = [NSString stringWithFormat:@"\n:::tool\n已搜索“%@”\n:::\n", qs];
                } else if ([fnName isEqualToString:@"fetch_url"]) {
                    id u = [argsDict objectForKey:@"url"];
                    NSString *us = [u isKindOfClass:[NSString class]] ? u : @"?";
                    NSString *displayURL = us.length > 60
                        ? [NSString stringWithFormat:@"%@…", [us substringToIndex:60]]
                        : us;
                    m = [NSString stringWithFormat:@"\n:::tool\n已读取 %@\n:::\n", displayURL];
                } else if ([fnName isEqualToString:@"get_current_time"]) {
                    m = @"\n:::tool\n已获取时间\n:::\n";
                } else if ([fnName isEqualToString:@"get_device_info"]) {
                    m = @"\n:::tool\n已获取设备简单信息\n:::\n";
                } else if ([fnName isEqualToString:@"generate_image"]) {
                    m = @"\n:::tool\n已生成图片\n:::\n";
                } else {
                    m = [NSString stringWithFormat:@"\n:::tool\n已完成工具调用 %@\n:::\n", fnName];
                }
                if (m) [doneMarkers addObject:m];
            }
        }
        // Re-launch stream on main — segmented thinking: preserve
        // _accumulated so pre-tool-call text + markers stay visible.
        dispatch_async(dispatch_get_main_queue(), ^{
            // v261103-1: append per-tool "done" markers (gray :::tool box)
            // — the ONLY visible artifact of the tool call. Tool result
            // content (JSON or text) is fed back to the model in the
            // messages array but NEVER shown in the chat bubble.
            if ([doneMarkers count] > 0) {
                for (NSString *m in doneMarkers) {
                    [self->_accumulated appendString:m];
                }
                if ([self->_delegate respondsToSelector:@selector(networkService:didReceiveChunkForConversationID:fullText:)]) {
                    [self->_delegate networkService:self
                        didReceiveChunkForConversationID:self->_conversationID
                                             fullText:self->_accumulated];
                }
            }
            // v261025-13: DON'T clear _accumulated — toolCallRelaunch flag
            // tells _launchStreamWithMessages to preserve it.
            if (self->_toolCallAccumulators) [self->_toolCallAccumulators removeAllObjects];
            self.toolCallPending = NO;
            self.toolCallRelaunch = YES;
            [self _launchStreamWithMessages:self.baseMessages];
        });
        } // @autoreleasepool
    });
    // v261025-8: balance the [x copy] captures above — the block retains
    // them for the duration of the GCD work; these releases drop the
    // caller-side +1 (they previously leaked per tool-call round).
    [tavilyKey release];
    [transitURL release];
    [providerKey release];
    [providerName release];
    [providerBaseURL release];
}

// Expose the accumulated thinking text.
- (NSString *)accumulatedThinking { return [[_thinkingAccumulated copy] autorelease]; }

#pragma mark - SSE chunk parsing

- (void)_parseBufferedChunks
{
    [self _parseBufferedChunksForce:NO];
}

- (void)_parseBufferedChunksForce:(BOOL)force
{
    if ([_rawBuffer length] == 0) return;

    NSData *data = _rawBuffer;
    NSString *text = [[[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding] autorelease];
    if (!text) {
        // Incomplete multi-byte UTF-8 at a chunk boundary — wait for the
        // rest UNLESS this is the final flush.
        if (!force) return;
        text = @"";
    }

    // v261025-1 REWRITE. Two defects in the old parser:
    //
    //  1) CRLF streams never split. We split on "\n\n", but SSE servers
    //     that emit \r\n line endings separate events with "\r\n\r\n"
    //     which contains NO "\n\n" — so the whole response stayed glued
    //     into one block until the final force-parse: no live streaming
    //     AND stray \r characters polluting the JSON payloads. Now we
    //     normalize \r\n → \n (and lone \r → \n) FIRST.
    //
    //  2) The leftover buffer was recomputed with hand-rolled BYTE
    //     arithmetic (sum of component UTF-8 lengths + 2 bytes per
    //     separator). With any \r normalization or mixed content that
    //     arithmetic drifts from reality and the buffer corrupts itself.
    //     Now we keep the leftover as a plain STRING suffix and convert
    //     it back to data — no byte math at all.
    if ([text rangeOfString:@"\r"].location != NSNotFound) {
        text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
        text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    }

    NSArray *components = [text componentsSeparatedByString:@"\n\n"];
    NSUInteger count = [components count];

    // No complete event block yet — hold everything for the next chunk.
    if (count < 2 && !force) return;

    NSUInteger lastCompleteIdx = (force ? count - 1 : count - 2);

    for (NSUInteger i = 0; i <= lastCompleteIdx; i++) {
        NSString *eventBlock = [components objectAtIndex:i];
        [self _processEventBlock:eventBlock];
    }

    // Keep the trailing (incomplete) part as a string suffix.
    NSUInteger remainingStart = lastCompleteIdx + 1;
    if (remainingStart < count) {
        NSMutableString *leftover = [NSMutableString string];
        for (NSUInteger i = remainingStart; i < count; i++) {
            if (i > remainingStart) [leftover appendString:@"\n\n"];
            [leftover appendString:[components objectAtIndex:i]];
        }
        if (leftover.length > 0) {
            NSData *leftoverData = [leftover dataUsingEncoding:NSUTF8StringEncoding];
            [_rawBuffer setData:leftoverData];
        } else {
            [_rawBuffer setData:nil];
        }
    } else {
        [_rawBuffer setData:nil];
    }
}

- (void)_processEventBlock:(NSString *)eventBlock
{
    if (!eventBlock || [eventBlock length] == 0) return;
    NSArray *lines = [eventBlock componentsSeparatedByString:@"\n"];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (![line hasPrefix:@"data:"]) continue;

        NSString *payload = [line substringFromIndex:5];
        payload = [payload stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
        if ([payload isEqualToString:@"[DONE]"]) {
            return;
        }
        if (payload.length == 0) continue;

        NSData *json = [payload dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:json
                                                            options:0
                                                              error:&err];
        if (err || ![obj isKindOfClass:[NSDictionary class]]) continue;

        // v261025-8: Anthropic SSE events carry a top-level "type" field
        // and NO "choices" array — handle them before the OpenAI branch
        // (they'd otherwise fall through untouched).
        NSString *evtType = [obj objectForKey:@"type"];
        if ([evtType isKindOfClass:[NSString class]] && evtType.length > 0) {
            [self _processAnthropicEventObject:obj];
            continue;
        }

        NSArray *choices = [obj objectForKey:@"choices"];
        if (![choices isKindOfClass:[NSArray class]] || [choices count] == 0) continue;
        NSDictionary *choice0 = [choices objectAtIndex:0];
        NSDictionary *delta    = [choice0 objectForKey:@"delta"];
        if (![delta isKindOfClass:[NSDictionary class]]) continue;

        // === Content (the actual answer) ===
        NSString *content = [delta objectForKey:@"content"];
        if ([content isKindOfClass:[NSString class]] && content.length > 0) {
            [_accumulated appendString:content];
        }

        // === Reasoning / thinking ===
        NSString *reasoning = [delta objectForKey:@"reasoning_content"];
        if (![reasoning isKindOfClass:[NSString class]] || reasoning.length == 0) {
            reasoning = [delta objectForKey:@"reasoning"];
        }
        if (![reasoning isKindOfClass:[NSString class]] || reasoning.length == 0) {
            reasoning = [delta objectForKey:@"thinking"];
        }
        if (![reasoning isKindOfClass:[NSString class]] || reasoning.length == 0) {
            reasoning = [delta objectForKey:@"thinking_content"];
        }
        if ([reasoning isKindOfClass:[NSString class]] && reasoning.length > 0) {
            [_thinkingAccumulated appendString:reasoning];
            if ([_delegate respondsToSelector:@selector(networkService:didReceiveThinkingForConversationID:thinkingText:)]) {
                NSString *thinkCopy = [NSString stringWithString:_thinkingAccumulated];
                [_delegate networkService:self
     didReceiveThinkingForConversationID:_conversationID
                               thinkingText:thinkCopy];
            }
        }

        // === Tool calls (function calls emitted by AI) ===
        NSArray *deltaToolCalls = [delta objectForKey:@"tool_calls"];
        if ([deltaToolCalls isKindOfClass:[NSArray class]]) {
            for (NSUInteger i = 0; i < [deltaToolCalls count]; i++) {
                NSDictionary *tc = [deltaToolCalls objectAtIndex:i];
                if (![tc isKindOfClass:[NSDictionary class]]) continue;
                NSNumber *idxNum = [tc objectForKey:@"index"];
                NSInteger idx = idxNum ? [idxNum integerValue] : (NSInteger)i;
                // Get or create accumulator for this index.
                NSMutableDictionary *acc = nil;
                for (NSMutableDictionary *d in _toolCallAccumulators) {
                    if ([[d objectForKey:@"__index"] integerValue] == idx) {
                        acc = d;
                        break;
                    }
                }
                if (!acc) {
                    acc = [NSMutableDictionary dictionary];
                    [acc setObject:[NSNumber numberWithInteger:idx] forKey:@"__index"];
                    [acc setObject:[NSMutableString string] forKey:@"arguments"];
                    [_toolCallAccumulators addObject:acc];
                }
                // Update id / function name (only present on first chunk for the call).
                // Defensive: JSON null becomes NSNull singleton — guard
                // against storing NSNull (which would later crash
                // isEqualToString: in the tool dispatch).
                NSString *tcId = [tc objectForKey:@"id"];
                if ([tcId isKindOfClass:[NSString class]]) {
                    [acc setObject:tcId forKey:@"id"];
                }
                NSDictionary *fn = [tc objectForKey:@"function"];
                if ([fn isKindOfClass:[NSDictionary class]]) {
                    NSString *name = [fn objectForKey:@"name"];
                    if ([name isKindOfClass:[NSString class]]) {
                        [acc setObject:name forKey:@"name"];
                    }
                    NSString *argsDelta = [fn objectForKey:@"arguments"];
                    if ([argsDelta isKindOfClass:[NSString class]]) {
                        [[acc objectForKey:@"arguments"] appendString:argsDelta];
                    }
                }
            }
            // Notify the delegate that a tool call has been received.
            if ([_delegate respondsToSelector:@selector(networkService:didReceiveToolCallForConversationID:toolName:)]) {
                NSString *toolName = nil;
                if ([_toolCallAccumulators count] > 0) {
                    toolName = [[_toolCallAccumulators lastObject] objectForKey:@"name"];
                }
                [_delegate networkService:self
       didReceiveToolCallForConversationID:_conversationID
                                toolName:toolName ?: @"tavily_search"];
            }
        }

        // Push incremental content update to delegate.
        if ([_delegate respondsToSelector:@selector(networkService:didReceiveChunkForConversationID:fullText:)]) {
            NSString *copy = [NSString stringWithString:_accumulated];
            [_delegate networkService:self
   didReceiveChunkForConversationID:_conversationID
                            fullText:copy];
        }
    }
}

- (void)dealloc
{
    // v261103-19: 清理 NSURLSession (iOS 7+)
    if (_urlSession) { @try { [_urlSession invalidateAndCancel]; } @catch (id e) {} [_urlSession release]; }
    if (_dataTask) { [_dataTask release]; }
    [_connection release];
    [_rawBuffer release];
    [_accumulated release];
    [_thinkingAccumulated release];
    [_conversationID release];
    [_lastError release];
    [_toolCallAccumulators release];
    [_pendingToolMessages release];
    [_transitURL release];
    [_baseURL release];
    [_provider release];
    [_apiKey release];
    [_model release];
    [_baseMessages release];
    [_tavilyKey release];
    // v261102-1: autonomous-URL copy properties.
    [_autonomousSearchURL release];
    [_autonomousSearchKey release];
    [_autonomousFetchURL release];
    [_autonomousFetchKey release];
    [super dealloc];
}

#pragma mark - Anthropic SSE events (v261025-8)

// Anthropic streams typed events:
//   data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}
//   data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"…"}}
//   data: {"type":"message_stop"}
//   data: {"type":"error","error":{"message":"…"}}
// (content_block_start / message_start / ping are informational — skipped.)
// Tool-use blocks (input_json_delta) are unsupported in this beta.
- (void)_processAnthropicEventObject:(NSDictionary *)obj
{
    NSString *evtType = [obj objectForKey:@"type"];
    if (![evtType isKindOfClass:[NSString class]]) return;

    if ([evtType isEqualToString:@"content_block_delta"]) {
        NSDictionary *delta = [obj objectForKey:@"delta"];
        if (![delta isKindOfClass:[NSDictionary class]]) return;
        NSString *deltaType = [delta objectForKey:@"type"];
        if ([deltaType isEqualToString:@"text_delta"]) {
            NSString *text = [delta objectForKey:@"text"];
            if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                [_accumulated appendString:text];
                if ([_delegate respondsToSelector:@selector(networkService:didReceiveChunkForConversationID:fullText:)]) {
                    NSString *copy = [NSString stringWithString:_accumulated];
                    [_delegate networkService:self
       didReceiveChunkForConversationID:_conversationID
                                 fullText:copy];
                }
            }
        } else if ([deltaType isEqualToString:@"thinking_delta"]) {
            NSString *think = [delta objectForKey:@"thinking"];
            if ([think isKindOfClass:[NSString class]] && think.length > 0) {
                [_thinkingAccumulated appendString:think];
                if ([_delegate respondsToSelector:@selector(networkService:didReceiveThinkingForConversationID:thinkingText:)]) {
                    NSString *thinkCopy = [NSString stringWithString:_thinkingAccumulated];
                    [_delegate networkService:self
        didReceiveThinkingForConversationID:_conversationID
                                 thinkingText:thinkCopy];
                }
            }
        }
        return;
    }

    if ([evtType isEqualToString:@"message_stop"]) {
        // Like [DONE] — connectionDidFinishLoading fires the normal
        // completion path right after the stream ends.
        return;
    }

    if ([evtType isEqualToString:@"error"]) {
        NSDictionary *errObj = [obj objectForKey:@"error"];
        NSString *msg = nil;
        if ([errObj isKindOfClass:[NSDictionary class]]) {
            msg = [errObj objectForKey:@"message"];
        }
        if (![msg isKindOfClass:[NSString class]] || msg.length == 0) {
            msg = @"Anthropic 流式错误";
        }
        [[Logger sharedLogger] error:[NSString stringWithFormat:@"NET ✗ anthropic stream error — %@", msg]];
        if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
            NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                              code:500
                                          userInfo:@{NSLocalizedDescriptionKey: msg}];
            [_delegate networkService:self didFailForConversationID:_conversationID error:err];
        }
        return;
    }
}

#pragma mark - Non-stream JSON body fallback (v261025-8)

// 🔴 BUG FIX — "流式输出"关闭后回复全变空。The SSE parser only understands
// "data:" lines; a plain-JSON response body (stream:false from OpenAI-
// compatible servers, or Anthropic non-stream) accumulated NOTHING and the
// user saw "⚠️ 服务器返回了空回复". Parse the two plain-JSON shapes here:
//   OpenAI:    {choices:[{message:{content, reasoning_content}}]}
//   Anthropic: {content:[{type:"text"|"thinking", text|thinking}]}
- (void)_tryParseNonStreamJSONBody
{
    if ([_rawBuffer length] == 0) return;
    NSString *bodyText = [[[NSString alloc] initWithData:_rawBuffer
                                                encoding:NSUTF8StringEncoding] autorelease];
    if (bodyText.length == 0) return;
    NSUInteger brace = [bodyText rangeOfString:@"{"].location;
    if (brace == NSNotFound || brace >= bodyText.length) return;
    if (brace > 0) bodyText = [bodyText substringFromIndex:brace];
    NSData *jd = [bodyText dataUsingEncoding:NSUTF8StringEncoding];
    if (!jd) return;
    id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return;

    // OpenAI non-stream shape.
    NSArray *choices = [obj objectForKey:@"choices"];
    if ([choices isKindOfClass:[NSArray class]] && [choices count] > 0) {
        NSDictionary *c0 = [choices objectAtIndex:0];
        if ([c0 isKindOfClass:[NSDictionary class]]) {
            NSDictionary *message = [c0 objectForKey:@"message"];
            if ([message isKindOfClass:[NSDictionary class]]) {
                NSString *content = [message objectForKey:@"content"];
                if ([content isKindOfClass:[NSString class]] && content.length > 0) {
                    [_accumulated appendString:content];
                }
                NSString *reasoning = [message objectForKey:@"reasoning_content"];
                if (![reasoning isKindOfClass:[NSString class]]) {
                    reasoning = [message objectForKey:@"reasoning"];
                }
                if ([reasoning isKindOfClass:[NSString class]] && reasoning.length > 0) {
                    [_thinkingAccumulated appendString:reasoning];
                }
                [[Logger sharedLogger] info:@"NET ✓ non-stream JSON parsed (openai shape)"];
            }
        }
        return;
    }

    // Anthropic non-stream shape.
    NSArray *contentArr = [obj objectForKey:@"content"];
    if ([contentArr isKindOfClass:[NSArray class]] && [contentArr count] > 0) {
        for (NSDictionary *block in contentArr) {
            if (![block isKindOfClass:[NSDictionary class]]) continue;
            NSString *type = [block objectForKey:@"type"];
            if ([type isEqualToString:@"text"]) {
                NSString *t = [block objectForKey:@"text"];
                if ([t isKindOfClass:[NSString class]]) [_accumulated appendString:t];
            } else if ([type isEqualToString:@"thinking"]) {
                NSString *t = [block objectForKey:@"thinking"];
                if ([t isKindOfClass:[NSString class]]) [_thinkingAccumulated appendString:t];
            }
        }
        [[Logger sharedLogger] info:@"NET ✓ non-stream JSON parsed (anthropic shape)"];
    }
}


#pragma mark - Error helpers

// Pull a human-readable message out of a JSON error body. Handles the
// common upstream shapes: {"error": "msg"}, {"error": {"message": "msg"}},
// {"message": "msg"}, {"detail": "msg"}.
- (NSString *)_extractErrorMessageFromBody:(NSString *)bodyText
{
    // v261024-19: NO @try — every access is isKindOfClass-guarded.
    if (bodyText.length == 0) return nil;
    NSData *jd = [bodyText dataUsingEncoding:NSUTF8StringEncoding];
    if (!jd) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id errObj = [obj objectForKey:@"error"];
    if ([errObj isKindOfClass:[NSString class]]) return errObj;
    if ([errObj isKindOfClass:[NSDictionary class]]) {
        id msg = [errObj objectForKey:@"message"];
        if ([msg isKindOfClass:[NSString class]]) return msg;
    }
    for (NSString *key in @[@"message", @"detail"]) {
        id v = [obj objectForKey:key];
        if ([v isKindOfClass:[NSString class]]) return v;
    }
    return nil;
}

// Shared status-code guard for the synchronous (non-streaming) calls:
// returns YES when the response is an HTTP error. When it is, *error is
// filled with the status + extracted upstream detail.
- (BOOL)_checkHTTPError:(NSURLResponse *)resp data:(NSData *)data error:(NSError **)error
{
    if (![resp isKindOfClass:[NSHTTPURLResponse class]]) return NO;
    NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
    if (code >= 200 && code < 300) return NO;
    NSString *bodyText = data ? [[[NSString alloc] initWithData:data
                                                       encoding:NSUTF8StringEncoding] autorelease] : nil;
    NSString *detail = [self _extractErrorMessageFromBody:bodyText];
    if (detail.length == 0 && bodyText.length > 0) {
        detail = ([bodyText length] > 160) ? [bodyText substringToIndex:160] : bodyText;
    }
    NSString *msg = [NSString stringWithFormat:@"HTTP %d: %@",
                     (int)code,
                     detail.length > 0 ? detail : @"请求失败"];
    if (error) {
        *error = [NSError errorWithDomain:@"iOS6AIChat"
                                      code:code
                                  userInfo:@{NSLocalizedDescriptionKey: msg}];
    }
    return YES;
}

#pragma mark - Provider → image API base URL (v261025-8)

// The image generation entry point resolves its upstream base: the
// caller's per-entry baseURL wins; this map is the fallback for callers
// that only know the provider. Providers WITHOUT a hosted image API
// (DeepSeek / Kimi / Anthropic / Ollama) return nil — the caller surfaces
// a clear error instead of a cryptic upstream 404.
+ (NSString *)_imageAPIBaseURLForProvider:(NSString *)provider
{
    if ([provider isEqualToString:ProviderIDZhipu]) {
        return @"https://open.bigmodel.cn/api/paas/v4";
    }
    if ([provider isEqualToString:ProviderIDOpenAI]) {
        return @"https://api.openai.com/v1";
    }
    // deepseek / kimi / anthropic / ollama / unknown → no image API.
    return nil;
}

// v261025-8: append the images/generations path to an image-API base.
// Bases that already end with a version segment (/v1, /v3, /v4) take the
// path directly; bare hosts get /v1/ inserted (OpenAI-style).
+ (NSString *)_imageGenTargetForBase:(NSString *)base
{
    if (![base isKindOfClass:[NSString class]] || base.length == 0) return nil;
    NSString *trimmed = [base stringByTrimmingCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (trimmed.length == 0) return nil;
    if ([trimmed hasSuffix:@"/v1"] || [trimmed hasSuffix:@"/v3"] ||
        [trimmed hasSuffix:@"/v4"] || [trimmed hasSuffix:@"/v1/"] ||
        [trimmed hasSuffix:@"/v3/"] || [trimmed hasSuffix:@"/v4/"]) {
        return [trimmed stringByAppendingPathComponent:@"images/generations"];
    }
    return [trimmed stringByAppendingPathComponent:@"v1/images/generations"];
}

#pragma mark - iOS 6 TLS transit fallback (v261025-3)

// iOS 6 SecureTransport cannot complete TLS against Cloudflare's modern
// edge (min TLS 1.2 + modern cipher list / ECDSA-first certificates):
// the handshake dies during certificate negotiation and NSURLConnection
// reports -1012 (NSURLErrorUserCancelledAuthentication). The transit
// worker ALSO serves plain HTTP, which works end-to-end (verified in the
// field: an http transit request reached the worker and came back with
// the upstream's response body). Since the transit is the user's OWN
// relay carrying the user's OWN key, retrying over HTTP on a -1012 is an
// acceptable trade. This ONLY ever applies to TRANSIT URLs — never to
// direct third-party endpoints (their keys must stay on TLS).
+ (NSString *)_httpFallbackForURLString:(NSString *)s
{
    // v261025-12: fix off-by-one. Original used substringFromIndex:5
    // which kept the ':' (index 5 of "https:" IS the colon), producing
    // "http:://host" (malformed, double colon) → NSURL parsed an empty
    // host → -1004. The http fallback NEVER worked until now.
    if ([s isKindOfClass:[NSString class]] && [s hasPrefix:@"https://"]) {
        return [s stringByReplacingOccurrencesOfString:@"https://"
                                             withString:@"http://"];
    }
    return nil;
}

#pragma mark - Tavily web search (sync)

- (NSArray *)tavilySearchWithQuery:(NSString *)query
                            apiKey:(NSString *)apiKey
                       maxResults:(NSInteger)maxResults
                       useTransit:(BOOL)useTransit
                        transitURL:(NSString *)transitURL
                            error:(NSError **)error
{
    if (!query || query.length == 0) return nil;
    // v261103-2: Tavily search ALWAYS goes direct to api.tavily.com.
    // The transitWebSearch toggle has been removed — user testing showed
    // api.tavily.com is directly reachable from iOS 6 (no Cloudflare).
    NSString *endpoint = @"https://api.tavily.com/search";

    if (maxResults < 1) maxResults = 1;
    if (maxResults > 8) maxResults = 8;

    NSDictionary *body = @{
        @"api_key":     apiKey ?: @"",
        @"query":       query,
        @"max_results": @(maxResults)
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!bodyData) return nil;

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"SEARCH → POST %@ | q=%@… max=%ld", endpoint,
        ([query length] > 40 ? [NSString stringWithFormat:@"%@…", [query substringToIndex:40]] : query),
        (long)maxResults]];

    NSDate *t0 = [NSDate date];
    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = nil;
    // v261103-2: direct connection to api.tavily.com — no retry loop,
    // no http fallback. The old transit-based retry was removed along
    // with the transitWebSearch toggle.
    NSURL *url = [NSURL URLWithString:endpoint];
    if (url) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                              cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                          timeoutInterval:30.0];
        [req setHTTPMethod:@"POST"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setHTTPBody:bodyData];
        data = [NetworkService _syncSendRequest:req response:&resp error:&netErr];
    }
    NSTimeInterval dur = -[t0 timeIntervalSinceNow];
    if (netErr) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"SEARCH ✗ %.1fs net code=%ld — %@", dur, (long)netErr.code,
            netErr.localizedDescription ?: @"(no desc)"]];
        if (error) *error = netErr;
        return nil;
    }
    // Surface HTTP errors (404 wrong transit route, 401 bad key, 5xx…).
    if ([self _checkHTTPError:resp data:data error:error]) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"SEARCH ✗ %.1fs HTTP error — see bubble for detail", dur]];
        return nil;
    }
    if (!data || data.length == 0) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"SEARCH ✗ %.1fs — zero-byte response", dur]];
        return nil;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *results = [json objectForKey:@"results"];
    if (![results isKindOfClass:[NSArray class]]) {
        NSString *bodyHead = [[[NSString alloc] initWithData:data
                                                    encoding:NSUTF8StringEncoding] autorelease];
        if (bodyHead.length > 160) bodyHead = [bodyHead substringToIndex:160];
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"SEARCH ✗ %.1fs — 200 OK but no 'results' array (body head: %@)",
            dur, bodyHead.length > 0 ? bodyHead : @"(empty)"]];
        return nil;
    }
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"SEARCH ✓ %.1fs — %lu results, %lu bytes", dur,
        (unsigned long)[results count], (unsigned long)[data length]]];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[results count]];
    for (NSDictionary *r in results) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *clean = @{
            @"title":   [r objectForKey:@"title"] ?: @"",
            @"url":     [r objectForKey:@"url"] ?: @"",
            @"content": [r objectForKey:@"content"] ?: @""
        };
        [out addObject:clean];
    }
    return out;
}

#pragma mark - Model list fetch (sync)

- (NSArray *)listModelsWithUseTransit:(BOOL)useTransit
                             transitURL:(NSString *)transitURL
                              baseURL:(NSString *)baseURL
                              provider:(NSString *)provider
                               apiKey:(NSString *)apiKey
                                 error:(NSError **)error
{
    // v261103-2: always go direct to the provider's baseURL. The useTransit
    // parameter is kept for signature compat but ignored.
    NSString *base = baseURL;
    if (!base || base.length == 0) {
        base = @"https://api.openai.com";
    }
    NSString *endpoint = [base stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    endpoint = [endpoint stringByAppendingPathComponent:@"v1/models"];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"MODELS → GET %@", endpoint]];
    NSDate *t0 = [NSDate date];

    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = nil;
    // v261103-2: single direct request — no retry loop.
    NSURL *url = [NSURL URLWithString:endpoint];
    if (url) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                              cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                          timeoutInterval:15.0];
        [req setHTTPMethod:@"GET"];
        if (apiKey.length > 0) {
            [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
            forHTTPHeaderField:@"Authorization"];
        }
        data = [NetworkService _syncSendRequest:req response:&resp error:&netErr];
    }
    NSTimeInterval dur = -[t0 timeIntervalSinceNow];
    if (netErr) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"MODELS ✗ %.1fs net code=%ld — %@", dur, (long)netErr.code,
            netErr.localizedDescription ?: @"(no desc)"]];
        if (error) *error = netErr;
        return nil;
    }
    // Surface HTTP errors for /v1/models too.
    if ([self _checkHTTPError:resp data:data error:error]) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"MODELS ✗ %.1fs HTTP error", dur]];
        return nil;
    }
    if (!data || data.length == 0) {
        [[Logger sharedLogger] error:@"MODELS ✗ zero-byte response"];
        return nil;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *models = [json objectForKey:@"data"];
    if (![models isKindOfClass:[NSArray class]]) {
        [[Logger sharedLogger] error:@"MODELS ✗ 200 OK but no 'data' array"];
        return nil;
    }
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"MODELS ✓ %.1fs — %lu models", dur, (unsigned long)[models count]]];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[models count]];
    for (NSDictionary *m in models) {
        if (![m isKindOfClass:[NSDictionary class]]) continue;
        NSString *mid = [m objectForKey:@"id"];
        if ([mid isKindOfClass:[NSString class]] && mid.length > 0) {
            [out addObject:mid];
        }
    }
    return out;
}

#pragma mark - Transit server's own model list (sync, v261025-3)

// GET {transitURL}/v1/transit/models
//   Returns: {"enabled": true/false, "models": ["glm-4-flash", ...]}
//
// The transit server exposes its OWN model list (configured via
// TRANSIT_MODELS_ENABLED + TRANSIT_MODELS env vars on the server side).
// This is independent from the upstream's /v1/models — the user opens
// "transit default model" in settings, this method is called to fetch
// the server-bundled models, which then get added to the app's local
// Model management under source="transit".
//
// Returns NSDictionary with keys:
//   enabled (NSNumber bool) — whether the transit server has any bundled models
//   models  (NSArray of NSString) — the model id list (empty if disabled)
// Returns nil + *error on network/HTTP/parse failure.
- (NSDictionary *)transitModelsAtTransitURL:(NSString *)transitURL
                                      error:(NSError **)error
{
    NSString *base = transitURL;
    if (!base || base.length == 0) {
        base = @"https://ai-transit.awa.lat";
    }
    NSString *endpoint = [base stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    endpoint = [endpoint stringByAppendingPathComponent:@"v1/transit/models"];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"TRANSIT-MODELS → GET %@", endpoint]];
    NSDate *t0 = [NSDate date];

    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = nil;
    NSString *attemptEndpoint = endpoint;
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        NSURL *url = [NSURL URLWithString:attemptEndpoint];
        if (!url) { resp = nil; netErr = nil; data = nil; break; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                              cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                          timeoutInterval:15.0];
        [req setHTTPMethod:@"GET"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        resp = nil;
        netErr = nil;
        data = [NetworkService _syncSendRequest:req response:&resp error:&netErr];
        if (!netErr) break;
        if (attempt == 0 &&
            (netErr.code == -1012 || netErr.code == -1200)) {
            NSString *httpEndpoint = [NetworkService _httpFallbackForURLString:attemptEndpoint];
            if (httpEndpoint) {
                [[Logger sharedLogger] warn:[NSString stringWithFormat:
                    @"TRANSIT-MODELS ⚠ https 中转 TLS -1012 — 自动改用 http 重试: %@", httpEndpoint]];
                attemptEndpoint = httpEndpoint;
                continue;
            }
        }
        break;
    }
    NSTimeInterval dur = -[t0 timeIntervalSinceNow];
    if (netErr) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"TRANSIT-MODELS ✗ %.1fs net code=%ld — %@", dur, (long)netErr.code,
            netErr.localizedDescription ?: @"(no desc)"]];
        if (error) *error = netErr;
        return nil;
    }
    if ([self _checkHTTPError:resp data:data error:error]) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:
            @"TRANSIT-MODELS ✗ %.1fs HTTP error", dur]];
        return nil;
    }
    if (!data || data.length == 0) {
        [[Logger sharedLogger] error:@"TRANSIT-MODELS ✗ zero-byte response"];
        return nil;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        [[Logger sharedLogger] error:@"TRANSIT-MODELS ✗ 200 OK but not a JSON object"];
        return nil;
    }
    BOOL enabled = [[json objectForKey:@"enabled"] boolValue];
    NSArray *rawModels = [json objectForKey:@"models"];
    if (![rawModels isKindOfClass:[NSArray class]]) rawModels = @[];
    NSMutableArray *models = [NSMutableArray arrayWithCapacity:[rawModels count]];
    for (id m in rawModels) {
        if ([m isKindOfClass:[NSString class]] && [(NSString *)m length] > 0) {
            [models addObject:m];
        }
    }
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"TRANSIT-MODELS ✓ %.1fs — enabled=%d count=%lu",
        dur, (int)enabled, (unsigned long)[models count]]];
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:enabled], @"enabled",
            models, @"models",
            nil];
}

#pragma mark - Image generation (sync)

// Legacy entry point — delegates to the full-control variant without a
// per-entry baseURL (falls back to the provider map).
- (NSString *)generateImageWithPrompt:(NSString *)prompt
                                 model:(NSString *)model
                                 size:(NSString *)size
                            useTransit:(BOOL)useTransit
                            transitURL:(NSString *)transitURL
                              provider:(NSString *)provider
                               apiKey:(NSString *)apiKey
                                 error:(NSError **)error
{
    return [self generateImageWithPrompt:prompt
                                   model:model
                                   size:size
                              useTransit:useTransit
                              transitURL:transitURL
                                baseURL:nil
                              provider:provider
                               apiKey:apiKey
                                 error:error];
}

// v261025-8: full-control variant. `baseURL` is the image model entry's own
// endpoint (from ModelManagement); nil/empty falls back to the provider
// map. Image gen ALWAYS routes through the transit — iOS 6 TLS can't
// reach api.openai.com / open.bigmodel.cn directly.
- (NSString *)generateImageWithPrompt:(NSString *)prompt
                                 model:(NSString *)model
                                 size:(NSString *)size
                            useTransit:(BOOL)useTransit
                            transitURL:(NSString *)transitURL
                              baseURL:(NSString *)baseURL
                              provider:(NSString *)provider
                               apiKey:(NSString *)apiKey
                                 error:(NSError **)error
{
    if (!prompt || prompt.length == 0) return nil;
    if (!size || size.length == 0) size = @"1024x1024";
    if (!model || model.length == 0) {
        // Default per provider.
        if ([provider isEqualToString:ProviderIDZhipu]) {
            model = @"cogview-3plus";
        } else {
            model = @"gpt-image-1";
        }
    }

    // Resolve the upstream image API base: explicit per-entry baseURL
    // wins; otherwise the provider map. Providers without an image API
    // fail fast with a clear message.
    NSString *imageBase = nil;
    if ([baseURL isKindOfClass:[NSString class]] && baseURL.length > 0) {
        imageBase = baseURL;
    } else {
        imageBase = [NetworkService _imageAPIBaseURLForProvider:provider];
    }
    if (!imageBase) {
        if (error) {
            *error = [NSError errorWithDomain:@"iOS6AIChat"
                                          code:400
                                      userInfo:@{NSLocalizedDescriptionKey:
                  @"该提供商没有生图 API（建议用智谱 CogView 或 OpenAI）"}];
        }
        return nil;
    }
    NSString *imageTarget = [NetworkService _imageGenTargetForBase:imageBase];
    if (!imageTarget) {
        if (error) {
            *error = [NSError errorWithDomain:@"iOS6AIChat"
                                          code:400
                                      userInfo:@{NSLocalizedDescriptionKey: @"无效的生图 BaseURL"}];
        }
        return nil;
    }

    // v261103-3: image gen ALWAYS goes direct to the provider's image API.
    // The proxy URL option was removed from settings — user testing showed
    // transit/proxy doesn't help (OpenAI geo-blocks regardless of proxy
    // location, and the default transit server was in a blocked region).
    // Direct connection lets providers like Zhipu (cogview) work fine;
    // OpenAI image gen may fail with geo-block, which is a provider-side
    // issue the user solves by choosing a non-blocking provider.
    NSString *endpoint = imageTarget;

    // Build body — per model family:
    //   dall-e-*:  {model, prompt, n, size, response_format=b64_json}
    //   gpt-image-*: {model, prompt, n, size}  (b64 by default; rejects
    //               response_format)
    //   cogview-*: {model, prompt}             (zhipu accepts only these;
    //               size unsupported on cogview-3plus)
    BOOL isDallE = [model hasPrefix:@"dall-e"];
    BOOL isGptImage = [model hasPrefix:@"gpt-image"];
    BOOL isOpenAIModel = isDallE || isGptImage;
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"model":    model,
        @"prompt":   prompt
    }];
    if (isOpenAIModel) {
        [body setObject:@(1) forKey:@"n"];
        [body setObject:size forKey:@"size"];
        if (isDallE) {
            [body setObject:@"b64_json" forKey:@"response_format"];
        }
    }

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!bodyData) return nil;

    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = nil;
    // v261103-2: single direct request — no retry loop, no http fallback.
    // The old transit TLS retry was removed along with the transit server.
    NSURL *url = [NSURL URLWithString:endpoint];
    if (url) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                              cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                          timeoutInterval:120.0];  // image gen can be slow
        [req setHTTPMethod:@"POST"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        // v261103-3: no X-Target-URL — direct connection, no proxy.
        if (apiKey.length > 0) {
            [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
            forHTTPHeaderField:@"Authorization"];
        }
        [req setHTTPBody:bodyData];
        data = [NetworkService _syncSendRequest:req response:&resp error:&netErr];
    }
    if (netErr) {
        if (error) *error = netErr;
        return nil;
    }
    // Surface HTTP errors from image generation.
    if ([self _checkHTTPError:resp data:data error:error]) {
        return nil;
    }
    if (!data || data.length == 0) return nil;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *dataArr = [json objectForKey:@"data"];
    if (![dataArr isKindOfClass:[NSArray class]] || [dataArr count] == 0) {
        // Check for error response.
        NSDictionary *errDict = [json objectForKey:@"error"];
        if ([errDict isKindOfClass:[NSDictionary class]]) {
            NSString *errMsg = [errDict objectForKey:@"message"] ?: @"unknown";
            if (error) {
                *error = [NSError errorWithDomain:@"iOS6AIChat"
                                              code:500
                                          userInfo:@{NSLocalizedDescriptionKey: errMsg}];
            }
        }
        return nil;
    }
    NSDictionary *firstResult = [dataArr objectAtIndex:0];
    NSString *b64 = [firstResult objectForKey:@"b64_json"];
    if ([b64 isKindOfClass:[NSString class]] && b64.length > 0) {
        // Got base64 directly.
        return [NSString stringWithFormat:@"data:image/png;base64,%@", b64];
    }
    // Otherwise, fetch the URL via transit.
    NSString *imgURL = [firstResult objectForKey:@"url"];
    if (![imgURL isKindOfClass:[NSString class]] || imgURL.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"iOS6AIChat"
                                          code:500
                                      userInfo:@{NSLocalizedDescriptionKey: @"Image gen response missing both b64_json and url"}];
        }
        return nil;
    }
    return [self fetchImageURLViaTransit:imgURL transitURL:transitURL error:error];
}

- (NSString *)fetchImageURLViaTransit:(NSString *)imageURL
                            transitURL:(NSString *)transitURL
                                error:(NSError **)error
{
    if (!imageURL || imageURL.length == 0) return nil;
    NSString *base = transitURL;
    if (!base || base.length == 0) {
        base = @"https://ai-transit.awa.lat";
    }
    base = [base stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    // URL-encode the image URL as a query param.
    NSString *encodedURL = [imageURL stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSString *endpoint = [NSString stringWithFormat:@"%@/v1/fetch_image?url=%@", base, encodedURL];

    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = nil;
    // v261025-3: single https→http retry on -1012 (always transit here).
    NSString *attemptEndpoint = endpoint;
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        NSURL *url = [NSURL URLWithString:attemptEndpoint];
        if (!url) { resp = nil; netErr = nil; data = nil; break; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                              cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                          timeoutInterval:60.0];
        [req setHTTPMethod:@"GET"];
        resp = nil;
        netErr = nil;
        data = [NetworkService _syncSendRequest:req response:&resp error:&netErr];
        if (!netErr) break;
        if (attempt == 0 &&
            (netErr.code == -1012 || netErr.code == -1200)) {
            NSString *httpEndpoint = [NetworkService _httpFallbackForURLString:attemptEndpoint];
            if (httpEndpoint) {
                [[Logger sharedLogger] warn:@"FETCH-IMG ⚠ https 中转 TLS -1012 (iOS6 握手失败) — 自动改用 http 重试"];
                attemptEndpoint = httpEndpoint;
                continue;
            }
        }
        break;
    }
    if (netErr) {
        if (error) *error = netErr;
        return nil;
    }
    if (!data || data.length == 0) return nil;
    NSString *b64 = [data base64String];
    if (!b64 || b64.length == 0) return nil;
    // Sniff content type from response if possible — default to png.
    NSString *mimeType = @"image/png";
    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
    if ([httpResp respondsToSelector:@selector(allHeaderFields)]) {
        NSDictionary *headers = [httpResp allHeaderFields];
        NSString *ct = [headers objectForKey:@"Content-Type"] ?: [headers objectForKey:@"content-type"];
        if ([ct isKindOfClass:[NSString class]] && [ct hasPrefix:@"image/"]) {
            // e.g. "image/jpeg" → use as-is, drop any ;charset suffix.
            NSRange semi = [ct rangeOfString:@";"];
            if (semi.location != NSNotFound) {
                mimeType = [ct substringToIndex:semi.location];
            } else {
                mimeType = ct;
            }
        }
    }
    return [NSString stringWithFormat:@"data:%@;base64,%@", mimeType, b64];
}

// v261025-12: Synchronous request via ASYNC transport (delegate +
// semaphore). Replaces +[NSURLConnection sendSynchronousRequest:]
// which fails with -1012 on iOS 6 from GCD background threads (TLS
// handshake / cert-chain evaluation needs a running runloop; bare GCD
// threads don't pump one, so CFNetwork cancels → -1012). This helper
// schedules the connection on the MAIN runloop (same one the streaming
// chat path uses, proven to work), then either pumps the main runloop
// (if called ON main) or blocks on a semaphore (if called from a
// background queue). Callers keep their existing synchronous call-site
// semantics. The -1012 → http fallback loop in each caller is preserved
// unchanged — only the inner transport call is replaced.
+ (NSData *)_syncSendRequest:(NSURLRequest *)req
                    response:(NSURLResponse **)outResp
                       error:(NSError **)outErr {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    SyncHTTPDelegate *del = [[SyncHTTPDelegate alloc] initWithSemaphore:sem];
    NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:req
                                                             delegate:del
                                                        startImmediately:NO];
    [conn scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [conn start];

    if ([NSThread isMainThread]) {
        // Pump the main runloop so delegate callbacks fire inline.
        // Without this the semaphore would deadlock (no one signals).
        while (!del.done) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                  beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    } else {
        // Background thread: block until the main runloop delivers the
        // callbacks and signals the semaphore. The main runloop is
        // running (app is in foreground); NSURLConnection's own
        // timeoutInterval ensures we don't hang forever.
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }

    NSData *result = [[del.data retain] autorelease];
    if (outResp) *outResp = [[del.response retain] autorelease];
    if (outErr) *outErr = del.error ? [[del.error retain] autorelease] : nil;

    [conn release];
    [del release];
    dispatch_release(sem);
    return result;
}

// v261102-1: Autonomous web search (provider's OWN native search API).
// POSTs to autonomousSearchURL when set; otherwise derives the endpoint
// from the chat's own baseURL by stripping `/chat/completions` (or
// `/v1/chat/completions`) and appending `/web_search` (智谱-style) — the
// caller can override the URL in provider-edit if their vendor uses a
// different path (e.g. DeepSeek's `/tools/search`).
// The body is a UNION of Zhipu + DeepSeek schemas so a single call works
// against either:
//   { query, search_query, search_engine:"search_std",
//     search_intent:false, count:5, need_content:true }
// Both APIs ignore unknown fields, so this is safe.
// Auth: autonomousSearchKey when set; otherwise the chat's own apiKey.
// Returns the assembled text fed back to the model as the tool result
// (titles + URLs + snippets, truncated to ~6000 chars to keep token
// cost reasonable). Returns nil + *error on failure.
- (NSString *)_autonomousWebSearchWithQuery:(NSString *)query error:(NSError **)error
{
    if (!query || query.length == 0) return nil;
    NSString *endpoint = self.autonomousSearchURL;
    if (![endpoint isKindOfClass:[NSString class]] || endpoint.length == 0) {
        // Derive from the chat baseURL + provider template:
        //   zhipu:    strip /chat/completions → append /web_search
        //   deepseek: strip /chat/completions → append /tools/search
        //   others:   strip /chat/completions → append /web_search (default OpenAI-compat)
        NSString *base = self.baseURL;
        if (![base isKindOfClass:[NSString class]] || base.length == 0) {
            if (error) *error = [NSError errorWithDomain:@"iOS6AIChat" code:400
                userInfo:@{NSLocalizedDescriptionKey: @"自主搜索未配置 URL 且无 baseURL 可推导"}];
            return nil;
        }
        NSString *trimmed = [base stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        // Strip trailing /chat/completions or /v1/chat/completions.
        if ([trimmed hasSuffix:@"/chat/completions"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - @"/chat/completions".length];
        } else if ([trimmed hasSuffix:@"/v1/chat/completions"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - @"/v1/chat/completions".length];
        }
        // Provider-specific path suffix (DeepSeek's API uses /tools/search
        // instead of /web_search; Kimi also uses /tools/search).
        // v261103-10: Kimi (api.moonshot.cn) uses /v1/tools/search and
        // /v1/tools/fetch — same pattern as DeepSeek.
        NSString *suffix = ([self.provider isEqualToString:ProviderIDDeepSeek] ||
                           [self.provider isEqualToString:ProviderIDKimi])
            ? @"tools/search"
            : @"web_search";
        endpoint = [trimmed stringByAppendingPathComponent:suffix];
    }
    NSString *apiKey = self.autonomousSearchKey;
    if (![apiKey isKindOfClass:[NSString class]] || apiKey.length == 0) {
        apiKey = self.apiKey;
    }
    // Body: union of Zhipu + DeepSeek + Kimi schemas (each API ignores
    // unknown fields).
    //   Zhipu:    { search_query, search_engine, search_intent, count, content_size }
    //   DeepSeek: { query, count, need_content }
    //   Kimi:     { text_query, limit, include_content, timeout_seconds }
    NSDictionary *body = @{
        @"query":           query,
        @"search_query":    query,
        @"text_query":      query,
        @"search_engine":   @"search_std",
        @"search_intent":   @(NO),
        @"count":           @(5),
        @"limit":           @(5),
        @"need_content":    @(YES),
        @"include_content": @(YES),
        @"timeout_seconds": @(30)
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!bodyData) return nil;
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"iOS6AIChat" code:400
            userInfo:@{NSLocalizedDescriptionKey: @"自主搜索 URL 无效"}];
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:30.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
        forHTTPHeaderField:@"Authorization"];
    }
    [req setHTTPBody:bodyData];
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"AUTO-SEARCH → POST %@ | q=%@…", endpoint,
        ([query length] > 40 ? [NSString stringWithFormat:@"%@…", [query substringToIndex:40]] : query)]];
    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = [NetworkService _syncSendRequest:req response:&resp error:&netErr];
    if (netErr) { if (error) *error = netErr; return nil; }
    if ([self _checkHTTPError:resp data:data error:error]) return nil;
    if (!data || data.length == 0) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    // Response shape varies by vendor:
    //   Zhipu:   { search_result: [{title, content, link, media, ...}] }
    //   DeepSeek:{ results: [{title, url, snippet, summary, content, ...}] }
    // Build a unified text feed for the model.
    // v261103-10: also check Kimi's response format: { search_results: [...] }
    NSArray *results = [json objectForKey:@"search_result"];
    if (![results isKindOfClass:[NSArray class]]) {
        results = [json objectForKey:@"search_results"];
    }
    if (![results isKindOfClass:[NSArray class]]) {
        results = [json objectForKey:@"results"];
    }
    if (![results isKindOfClass:[NSArray class]]) {
        // Single-object fallback: just dump the JSON.
        NSString *dump = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (dump.length > 6000) dump = [NSString stringWithFormat:@"%@…", [dump substringToIndex:6000]];
        return dump ?: @"(search returned non-standard response)";
    }
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"Search results for \"%@\" (%lu):\n", query, (unsigned long)[results count]];
    NSInteger i = 1;
    for (NSDictionary *r in results) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSString *title = [r objectForKey:@"title"] ?: @"";
        NSString *link  = [r objectForKey:@"link"] ?: @"";
        if (link.length == 0) link = [r objectForKey:@"url"] ?: @"";
        // v261103-10: Kimi uses 'snippet' for summary, 'chunks' for content
        NSString *snippet = [r objectForKey:@"snippet"] ?: @"";
        if (snippet.length == 0) snippet = [r objectForKey:@"content"] ?: @"";
        // Also check Kimi's chunks array for content fragments
        if (snippet.length == 0) {
            NSArray *chunks = [r objectForKey:@"chunks"];
            if ([chunks isKindOfClass:[NSArray class]] && [chunks count] > 0) {
                NSDictionary *firstChunk = [chunks objectAtIndex:0];
                snippet = [firstChunk objectForKey:@"text"] ?: @"";
            }
        }
        if (snippet.length > 300) snippet = [NSString stringWithFormat:@"%@…", [snippet substringToIndex:300]];
        [out appendFormat:@"%ld. %@\n   URL: %@\n   %@\n\n",
            (long)i++, title, link, snippet];
        if (i > 8) break;  // cap at 8 results
    }
    if (out.length > 6000) out = [NSMutableString stringWithFormat:@"%@…", [out substringToIndex:6000]];
    return out;
}

// v261102-1: Autonomous URL fetch (provider's OWN native URL reader API).
// POSTs to autonomousFetchURL with {"url": "..."} body. URL derivation
// when not configured: strip /chat/completions from baseURL, append
// /fetch_url. Auth: autonomousFetchKey or chat apiKey.
// Returns the page's title + content (truncated to ~8000 chars).
- (NSString *)_autonomousFetchURLWithURL:(NSString *)urlStr error:(NSError **)error
{
    if (!urlStr || urlStr.length == 0) return nil;
    NSString *endpoint = self.autonomousFetchURL;
    if (![endpoint isKindOfClass:[NSString class]] || endpoint.length == 0) {
        // Derive from baseURL + provider template:
        //   zhipu:    strip /chat/completions → append /fetch_url
        //   deepseek: strip /chat/completions → append /tools/fetch
        //   others:   strip /chat/completions → append /fetch_url (default)
        NSString *base = self.baseURL;
        if (![base isKindOfClass:[NSString class]] || base.length == 0) {
            if (error) *error = [NSError errorWithDomain:@"iOS6AIChat" code:400
                userInfo:@{NSLocalizedDescriptionKey: @"自主读取 URL 未配置且无 baseURL 可推导"}];
            return nil;
        }
        NSString *trimmed = [base stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if ([trimmed hasSuffix:@"/chat/completions"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - @"/chat/completions".length];
        } else if ([trimmed hasSuffix:@"/v1/chat/completions"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - @"/v1/chat/completions".length];
        }
        // Provider-specific path suffix (DeepSeek + Kimi use /tools/fetch).
        NSString *suffix = ([self.provider isEqualToString:ProviderIDDeepSeek] ||
                           [self.provider isEqualToString:ProviderIDKimi])
            ? @"tools/fetch"
            : @"fetch_url";
        endpoint = [trimmed stringByAppendingPathComponent:suffix];
    }
    NSString *apiKey = self.autonomousFetchKey;
    if (![apiKey isKindOfClass:[NSString class]] || apiKey.length == 0) {
        apiKey = self.apiKey;
    }
    NSDictionary *body = @{ @"url": urlStr };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!bodyData) return nil;
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"iOS6AIChat" code:400
            userInfo:@{NSLocalizedDescriptionKey: @"自主读取 URL 端点无效"}];
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:60.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
        forHTTPHeaderField:@"Authorization"];
    }
    [req setHTTPBody:bodyData];
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"AUTO-FETCH → POST %@ | url=%@…", endpoint,
        ([urlStr length] > 60 ? [NSString stringWithFormat:@"%@…", [urlStr substringToIndex:60]] : urlStr)]];
    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = [NetworkService _syncSendRequest:req response:&resp error:&netErr];
    if (netErr) { if (error) *error = netErr; return nil; }
    if ([self _checkHTTPError:resp data:data error:error]) return nil;
    if (!data || data.length == 0) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        // Some readers return raw text body — accept that too.
        NSString *raw = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (raw.length > 8000) raw = [NSString stringWithFormat:@"%@…", [raw substringToIndex:8000]];
        return raw ?: @"(fetch returned non-JSON)";
    }
    NSString *title = [json objectForKey:@"title"] ?: @"";
    NSString *content = [json objectForKey:@"content"] ?: @"";
    if (content.length == 0) content = [json objectForKey:@"markdown"] ?: @"";
    if (content.length == 0) content = [json objectForKey:@"text"] ?: @"";
    if (content.length > 8000) content = [NSString stringWithFormat:@"%@…", [content substringToIndex:8000]];
    NSMutableString *out = [NSMutableString string];
    if (title.length > 0) [out appendFormat:@"Title: %@\n\n", title];
    [out appendString:content];
    return out.length > 0 ? out : @"(empty page)";
}

@end
