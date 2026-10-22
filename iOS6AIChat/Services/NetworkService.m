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

@interface NetworkService ()
@property (nonatomic, retain) NSURLConnection *connection;
@property (nonatomic, retain) NSMutableData   *rawBuffer;
@property (nonatomic, retain) NSMutableString *accumulated;
@property (nonatomic, retain) NSMutableString *thinkingAccumulated;
@property (nonatomic, copy)   NSString         *conversationID;
@property (nonatomic, retain) NSError          *lastError;

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
@end

@implementation NetworkService

@synthesize connection=_connection, rawBuffer=_rawBuffer,
            accumulated=_accumulated, conversationID=_conversationID,
            lastError=_lastError, delegate=_delegate,
            thinkingAccumulated=_thinkingAccumulated,
            toolCallAccumulators=_toolCallAccumulators,
            pendingToolMessages=_pendingToolMessages,
            toolCallPending=_toolCallPending,
            useTransit=_useTransit, transitURL=_transitURL,
            baseURL=_baseURL, provider=_provider, apiKey=_apiKey,
            model=_model, temperature=_temperature,
            baseMessages=_baseMessages, enableWebSearchTools=_enableWebSearchTools,
            tavilyKey=_tavilyKey, tavilyMaxResults=_tavilyMaxResults,
            toolCallTurn=_toolCallTurn, maxToolTurns=_maxToolTurns;
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
    // If web search tools enabled, add tools + tool_choice.
    if (self.enableWebSearchTools && self.tavilyKey.length > 0) {
        NSDictionary *tavilyTool = @{
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
        };
        [body setObject:[NSArray arrayWithObject:tavilyTool] forKey:@"tools"];
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

#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    [_rawBuffer setData:nil];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (!data) return;
    @try {
        [_rawBuffer appendData:data];
        [self _parseBufferedChunks];
    } @catch (NSException *e) {
        NSLog(@"[NetworkService] didReceiveData parse crashed: %@", e);
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    @try {
        [self _parseBufferedChunksForce:YES];
    } @catch (NSException *e) {
        NSLog(@"[NetworkService] didFinish parse crashed: %@", e);
    }

    // Check if AI emitted tool_calls → multi-turn tool use flow.
    if ([_toolCallAccumulators count] > 0 && _toolCallTurn < _maxToolTurns) {
        _toolCallTurn++;
        [self _runPendingToolCalls];
        return;
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
    if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
        [_delegate networkService:self
              didFailForConversationID:_conversationID
                              error:error];
    }
}

#pragma mark - Tool call execution

- (void)_runPendingToolCalls
{
    // Wrap the whole pre-bg part in @try — if any of the dict construction
    // or array access crashes, fire didFail on main instead of crashing.
    @try {
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

    // Notify delegate that we're executing the tool call.
    if ([_delegate respondsToSelector:@selector(networkService:didReceiveToolCallStartedForConversationID:)]) {
        [_delegate networkService:self
     didReceiveToolCallStartedForConversationID:_conversationID];
    }

    // Run Tavily searches on a background queue (avoid blocking main).
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Wrap the whole bg flow in @try — a crash anywhere here would
        // leave the chat stuck (status banner shown, composer disabled).
        // The user reported crashes during "中转搜索". This catch-all
        // ensures we always fire didFinish/didFail to release the UI.
        @try {
        NSMutableArray *toolResults = [NSMutableArray array];
        for (NSDictionary *tc in toolCallAcc) {
            NSString *callId = [tc objectForKey:@"id"];
            NSString *args   = [tc objectForKey:@"arguments"];
            NSString *fnName = [tc objectForKey:@"name"];
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
            NSString *query = [argsDict objectForKey:@"query"];
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
            @try {
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
            } @catch (NSException *e) {
                @synchronized(toolResults) {
                    [toolResults addObject:@{
                        @"role": @"tool",
                        @"tool_call_id": callId ?: @"",
                        @"content": [NSString stringWithFormat:@"Exception: %@", e.reason]
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
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                [self->_accumulated setString:@""];
                [self->_toolCallAccumulators removeAllObjects];
                self.toolCallPending = NO;
                [self _launchStreamWithMessages:self.baseMessages];
            } @catch (NSException *e) {
                // Re-launch failed — fire didFail so the UI releases.
                NSLog(@"[NetworkService] tool call re-launch failed: %@", e);
                if ([self->_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
                    NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                                       code:500
                                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"工具调用重试失败: %@", e.reason ?: @"unknown"]}];
                    [self->_delegate networkService:self
                          didFailForConversationID:self->_conversationID
                                          error:err];
                }
            }
        });
        } @catch (NSException *e) {
            // Whole bg flow crashed — fire didFail on main so UI releases.
            NSLog(@"[NetworkService] tool call bg execution crashed: %@", e);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self->_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
                    NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                                       code:500
                                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"工具调用执行崩溃: %@", e.reason ?: @"unknown"]}];
                    [self->_delegate networkService:self
                          didFailForConversationID:self->_conversationID
                                          error:err];
                }
            });
        }
    });
    } @catch (NSException *e) {
        // Pre-bg crash — fire didFail on main.
        NSLog(@"[NetworkService] _runPendingToolCalls pre-bg crashed: %@", e);
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self->_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
                NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                                   code:500
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"工具调用准备失败: %@", e.reason ?: @"unknown"]}];
                [self->_delegate networkService:self
                      didFailForConversationID:self->_conversationID
                                      error:err];
            }
        });
    }
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
        if (!force) return;
        text = @"";
    }

    NSArray *components = [text componentsSeparatedByString:@"\n\n"];
    NSUInteger count   = [components count];

    // Bug fix: when count == 1 (no complete event block yet), the
    // original `count - 2` would underflow NSUIntegerMax — crashing
    // later in the loop. Guard: skip processing entirely until we have
    // at least one complete block.
    if (count < 2 && !force) return;

    NSUInteger lastCompleteIdx = (force ? count - 1 : count - 2);

    for (NSUInteger i = 0; i <= lastCompleteIdx; i++) {
        NSString *eventBlock = [components objectAtIndex:i];
        [self _processEventBlock:eventBlock];
    }

    NSUInteger remainingStart = lastCompleteIdx + 1;
    if (remainingStart < count) {
        NSUInteger consumedBytes = 0;
        for (NSUInteger i = 0; i < remainingStart; i++) {
            consumedBytes += [[components objectAtIndex:i] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            consumedBytes += 2;
        }
        if (consumedBytes < [_rawBuffer length]) {
            NSData *leftover = [_rawBuffer subdataWithRange:NSMakeRange(consumedBytes,
                                                                         [_rawBuffer length] - consumedBytes)];
            [_rawBuffer setData:leftover];
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
                NSString *tcId = [tc objectForKey:@"id"];
                if (tcId) [acc setObject:tcId forKey:@"id"];
                NSDictionary *fn = [tc objectForKey:@"function"];
                if ([fn isKindOfClass:[NSDictionary class]]) {
                    NSString *name = [fn objectForKey:@"name"];
                    if (name) [acc setObject:name forKey:@"name"];
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

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *results = [json objectForKey:@"results"];
    if (![results isKindOfClass:[NSArray class]]) return nil;
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
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *models = [json objectForKey:@"data"];
    if (![models isKindOfClass:[NSArray class]]) return nil;
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

@end
