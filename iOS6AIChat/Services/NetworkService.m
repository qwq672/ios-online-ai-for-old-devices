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

@interface NetworkService ()
@property (nonatomic, retain) NSURLConnection *connection;
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
            streamStartTs=_streamStartTs;
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
    NSString *base = self.useTransit ? self.transitURL : self.baseURL;
    if (!base || base.length == 0) {
        base = self.useTransit ? @"https://ai-transit.awa.lat" : @"https://api.openai.com";
    }
    NSString *endpoint = [base stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if ([endpoint hasSuffix:@"/v1"] || [endpoint hasSuffix:@"/v1/"]) {
        endpoint = [endpoint stringByAppendingPathComponent:@"chat/completions"];
    } else {
        endpoint = [endpoint stringByAppendingPathComponent:@"v1/chat/completions"];
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

    // Check streaming output setting (default YES).
    BOOL doStream = YES;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"streamingOutput"]) {
        doStream = [[NSUserDefaults standardUserDefaults] boolForKey:@"streamingOutput"];
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
    if (doThink) {
        [body setObject:@{@"type": @"enabled"} forKey:@"thinking"];
    }
    // Tools array. The two lightweight tools (get_current_time,
    // get_device_info) are ALWAYS available — they don't need any user
    // config and are useful for time/device queries. tavily_search is
    // only added when web search is enabled.
    NSMutableArray *toolsArray = [NSMutableArray array];

    // Tool 1: get_current_time — always available.
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

    // Tool 2: get_device_info — always available.
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

    // Tool 3: generate_image — always available.
    // The AI can decide to call this when the user asks to draw/paint/create
    // an image. Returns the generated image displayed in the chat.
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

    // Tool 3: tavily_search — only when web search is enabled.
    if (self.enableWebSearchTools && self.tavilyKey.length > 0) {
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

    if ([toolsArray count] > 0) {
        [body setObject:toolsArray forKey:@"tools"];
        [body setObject:@"auto" forKey:@"tool_choice"];
    }

    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:&jsonErr];
    if (jsonErr || !bodyData) {
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
                                                      timeoutInterval:120.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    if (self.apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey]
        forHTTPHeaderField:@"Authorization"];
    }
    if (self.useTransit && self.provider.length > 0) {
        [req setValue:self.provider forHTTPHeaderField:@"X-Provider"];
    }
    if (self.useTransit && self.model.length > 0) {
        [req setValue:self.model forHTTPHeaderField:@"X-Model"];
    }
    [req setHTTPBody:bodyData];

    // Reset accumulators for this turn.
    [_accumulated setString:@""];
    [_toolCallAccumulators removeAllObjects];
    self.toolCallPending = NO;

    // Cancel any in-flight connection before starting a new one — otherwise
    // both connections will dispatch into the same accumulators / delegate,
    // corrupting state. This was audit finding #8.
    [_connection cancel];

    // v261025-1: REQUEST log — the user needs to see exactly what was sent
    // to diagnose transit issues (endpoint / provider / model / stream /
    // body size / message count).
    self.streamStartTs = [NSDate timeIntervalSinceReferenceDate];
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"NET → POST %@ | provider=%@ model=%@ stream=%d think=%d tools=%d msgs=%lu bytes=%lu",
        url.absoluteString ?: @"?",
        self.useTransit ? (self.provider ?: @"?") : @"(direct)",
        (self.model ?: @"(server-default)"),
        (int)doStream, (int)doThink, (int)[toolsArray count],
        (unsigned long)[msgs count], (unsigned long)[bodyData length]]];

    self.connection = [[[NSURLConnection alloc] initWithRequest:req delegate:self
                                             startImmediately:YES] autorelease];
    return (self.connection != nil);
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

    // Notify delegate that we're executing the tool call.
    if ([_delegate respondsToSelector:@selector(networkService:didReceiveToolCallStartedForConversationID:)]) {
        [_delegate networkService:self
     didReceiveToolCallStartedForConversationID:_conversationID];
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
            // Returns: {iso8601, timezone, day_of_week}
            // No parameters needed.
            if ([fnName isEqualToString:@"get_current_time"]) {
                NSDate *now = [NSDate date];
                NSDateFormatter *isoFmt = [[[NSDateFormatter alloc] init] autorelease];
                [isoFmt setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZ"];
                NSString *iso = [isoFmt stringFromDate:now];
                NSDateFormatter *dowFmt = [[[NSDateFormatter alloc] init] autorelease];
                [dowFmt setDateFormat:@"EEEE"];
                NSString *dow = [dowFmt stringFromDate:now];
                NSTimeZone *tz = [NSTimeZone systemTimeZone];
                NSString *contentStr = [NSString stringWithFormat:
                    @"{\n  \"iso8601\": \"%@\",\n  \"timezone\": \"%@\",\n  \"timezone_abbreviation\": \"%@\",\n  \"day_of_week\": \"%@\",\n  \"unix_timestamp\": %.0f\n}",
                    iso,
                    [tz name],
                    [tz abbreviation],
                    dow,
                    [now timeIntervalSince1970]];
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
            // Returns: {model, hardware_identifier, system_version, battery,
            //           screen_width, screen_height, language, locale}
            // No parameters needed.
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
                // v261024-19: NO @try — sysctl returns 0 size on failure;
                // fall-through to "unknown" is the same effect.
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
                    @"{\n  \"model\": \"%@\",\n  \"hardware_identifier\": \"%@\",\n  \"system_version\": \"%@\",\n  \"system_name\": \"%@\",\n  \"battery_level\": \"%@\",\n  \"battery_state\": \"%@\",\n  \"screen_width\": %.0f,\n  \"screen_height\": %.0f,\n  \"screen_scale\": %.1f,\n  \"language\": \"%@\",\n  \"locale\": \"%@\"\n}",
                    [device model] ?: @"unknown",
                    hwMachine,
                    [device systemVersion] ?: @"unknown",
                    [device systemName] ?: @"unknown",
                    batteryStr,
                    batteryStateStr,
                    screen.size.width,
                    screen.size.height,
                    [[UIScreen mainScreen] scale],
                    lang,
                    localeId];
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
                NSString *imgModel = [[NSUserDefaults standardUserDefaults] stringForKey:@"imageGenModel"];
                if (!imgModel || imgModel.length == 0) {
                    if ([providerName isEqualToString:@"zhipu"]) {
                        imgModel = @"cogview-3plus";
                    } else {
                        imgModel = @"dall-e-3";
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
        for (NSDictionary *tr in toolResults) {
            [newMessages addObject:tr];
        }
        self.baseMessages = newMessages;

        // Reset accumulators and re-launch stream on main.
        // v261024-19: NO @try — defensive nil-guards (the only ops that
        // could fail are setObject:forKey: on nil-key, but _accumulated
        // and _toolCallAccumulators are non-nil by init).
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_accumulated) [self->_accumulated setString:@""];
            if (self->_toolCallAccumulators) [self->_toolCallAccumulators removeAllObjects];
            self.toolCallPending = NO;
            [self _launchStreamWithMessages:self.baseMessages];
        });
        } // @autoreleasepool
    });
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
    [super dealloc];
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

#pragma mark - Tavily web search (sync)

- (NSArray *)tavilySearchWithQuery:(NSString *)query
                            apiKey:(NSString *)apiKey
                       maxResults:(NSInteger)maxResults
                       useTransit:(BOOL)useTransit
                        transitURL:(NSString *)transitURL
                            error:(NSError **)error
{
    if (!query || query.length == 0) return nil;
    NSString *endpoint;
    // Independent control: Tavily routing is determined SOLELY by the
    // 'transitWebSearch' toggle, NOT by 'useTransit'.
    // This matches the user's spec:
    //   - useTransit=NO, transitWebSearch=YES → only Tavily goes through transit
    //   - useTransit=YES, transitWebSearch=YES → both AI + Tavily go through transit
    //   - useTransit=YES, transitWebSearch=NO → only AI goes through transit
    //   - useTransit=NO, transitWebSearch=NO → both direct
    BOOL transitWebSearch = YES;  // default ON
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"transitWebSearch"]) {
        transitWebSearch = [[NSUserDefaults standardUserDefaults] boolForKey:@"transitWebSearch"];
    }
    if (transitWebSearch) {
        NSString *base = transitURL;
        if (!base || base.length == 0) {
            base = @"https://ai-transit.awa.lat";
        }
        base = [base stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        endpoint = [base stringByAppendingPathComponent:@"v1/tavily/search"];
    } else {
        endpoint = @"https://api.tavily.com/search";
    }

    if (maxResults < 1) maxResults = 1;
    if (maxResults > 8) maxResults = 8;

    NSDictionary *body = @{
        @"api_key":     apiKey ?: @"",
        @"query":       query,
        @"max_results": @(maxResults)
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!bodyData) return nil;

    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:30.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (transitWebSearch) [req setValue:@"tavily" forHTTPHeaderField:@"X-Provider"];
    [req setHTTPBody:bodyData];

    // v261025-1: search request log (the user asked for deep search-
    // failure diagnosis — is it network or app logic? This line shows
    // exactly which endpoint was tried.)
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"SEARCH → POST %@ | q=%@… max=%ld", endpoint,
        ([query length] > 40 ? [NSString stringWithFormat:@"%@…", [query substringToIndex:40]] : query),
        (long)maxResults]];

    NSDate *t0 = [NSDate date];
    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                          returningResponse:&resp
                                                      error:&netErr];
    NSTimeInterval dur = [NSDate timeIntervalSinceDate:t0];
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
    NSString *base = useTransit ? transitURL : baseURL;
    if (!base || base.length == 0) {
        base = useTransit ? @"https://ai-transit.awa.lat" : @"https://api.openai.com";
    }
    NSString *endpoint = [base stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    endpoint = [endpoint stringByAppendingPathComponent:@"v1/models"];

    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:15.0];
    [req setHTTPMethod:@"GET"];
    if (apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
        forHTTPHeaderField:@"Authorization"];
    }
    if (useTransit && provider.length > 0) {
        [req setValue:provider forHTTPHeaderField:@"X-Provider"];
    }

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"MODELS → GET %@", endpoint]];
    NSDate *t0 = [NSDate date];

    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                          returningResponse:&resp
                                                      error:&netErr];
    NSTimeInterval dur = [NSDate timeIntervalSinceDate:t0];
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

#pragma mark - Image generation (sync)

- (NSString *)generateImageWithPrompt:(NSString *)prompt
                                 model:(NSString *)model
                                 size:(NSString *)size
                            useTransit:(BOOL)useTransit
                            transitURL:(NSString *)transitURL
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
            model = @"dall-e-3";
        }
    }

    // Always use transit for image gen — direct API calls would hit iOS 6
    // TLS issues with both api.openai.com and open.bigmodel.cn.
    NSString *base = transitURL;
    if (!base || base.length == 0) {
        base = @"https://ai-transit.awa.lat";
    }
    base = [base stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *endpoint = [base stringByAppendingPathComponent:@"v1/images/generations"];

    // Build body. OpenAI supports response_format=b64_json (returns base64
    // directly, no need to fetch URL). Zhipu CogView doesn't support
    // response_format — always returns URL.
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"model":    model,
        @"prompt":    prompt,
        @"n":        @(1),
        @"size":      size
    }];
    // Use b64_json for OpenAI to avoid fetching URL (iOS 6 TLS issues).
    if ([provider isEqualToString:ProviderIDOpenAI]) {
        [body setObject:@"b64_json" forKey:@"response_format"];
    }

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!bodyData) return nil;

    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:120.0];  // image gen can be slow
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:provider ?: @"openai" forHTTPHeaderField:@"X-Provider"];
    if (apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
        forHTTPHeaderField:@"Authorization"];
    }
    [req setHTTPBody:bodyData];

    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                          returningResponse:&resp
                                                      error:&netErr];
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

    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:60.0];
    [req setHTTPMethod:@"GET"];

    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req
                                          returningResponse:&resp
                                                      error:&netErr];
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

@end
