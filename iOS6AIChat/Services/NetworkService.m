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

#import "NetworkService.h"

@interface NetworkService ()
@property (nonatomic, retain) NSURLConnection *connection;
@property (nonatomic, retain) NSMutableData   *rawBuffer;
@property (nonatomic, retain) NSMutableString *accumulated;
@property (nonatomic, copy)   NSString         *conversationID;
@property (nonatomic, retain) NSError          *lastError;
@end

@implementation NetworkService

@synthesize connection=_connection, rawBuffer=_rawBuffer,
            accumulated=_accumulated, conversationID=_conversationID,
            lastError=_lastError, delegate=_delegate;

- (id)init
{
    if (self = [super init]) {
        _rawBuffer   = [[NSMutableData alloc] init];
        _accumulated = [[NSMutableString alloc] init];
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
    NSString *base = useTransit ? transitURL : baseURL;
    if (!base || base.length == 0) {
        base = useTransit ? @"https://api-ai.awa.lat" : @"https://api.openai.com";
    }
    NSString *endpoint = [base stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    endpoint = [endpoint stringByAppendingPathComponent:@"v1/chat/completions"];

    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
            NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                              code:400
                                          userInfo:@{NSLocalizedDescriptionKey: @"无效的 BaseURL"}];
            [_delegate networkService:self didFailForConversationID:conversationID error:err];
        }
        return NO;
    }

    self.conversationID = conversationID;
    [_accumulated setString:@""];

    // Build the messages payload in OpenAI format.
    NSMutableArray *msgs = [NSMutableArray arrayWithCapacity:[messages count]];
    for (Message *m in messages) {
        NSString *role = m.isUser      ? @"user" :
                         m.isAssistant ? @"assistant" :
                                         @"system";
        [msgs addObject:@{ @"role": role, @"content": m.content ?: @"" }];
    }

    NSDictionary *body = @{
        @"model":       model ?: @"gpt-3.5-turbo",
        @"messages":    msgs,
        @"stream":      @YES,
        @"temperature": [NSNumber numberWithFloat:(float)temperature]
    };
    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:&jsonErr];
    if (jsonErr || !bodyData) {
        if ([_delegate respondsToSelector:@selector(networkService:didFailForConversationID:error:)]) {
            NSError *err = [NSError errorWithDomain:@"iOS6AIChat"
                                              code:500
                                          userInfo:@{NSLocalizedDescriptionKey: @"请求体序列化失败"}];
            [_delegate networkService:self didFailForConversationID:conversationID error:err];
        }
        return NO;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:120.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    if (apiKey.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
        forHTTPHeaderField:@"Authorization"];
    }
    if (useTransit && provider.length > 0) {
        // X-Provider header — the transit server uses this to pick the backend.
        [req setValue:provider forHTTPHeaderField:@"X-Provider"];
    }
    if (useTransit && model.length > 0) {
        // Informational — let the transit server log/model-select.
        [req setValue:model forHTTPHeaderField:@"X-Model"];
    }
    [req setHTTPBody:bodyData];

    self.connection = [[[NSURLConnection alloc] initWithRequest:req delegate:self
                                             startImmediately:YES] autorelease];
    return (self.connection != nil);
}

- (void)cancel
{
    [_connection cancel];
}

#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    // Reset buffers; we will accumulate SSE chunks.
    [_rawBuffer setData:nil];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (!data) return;
    [_rawBuffer appendData:data];
    [self _parseBufferedChunks];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    // Flush any remaining partial event.
    [self _parseBufferedChunksForce:YES];

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

#pragma mark - SSE chunk parsing

- (void)_parseBufferedChunks
{
    [self _parseBufferedChunksForce:NO];
}

- (void)_parseBufferedChunksForce:(BOOL)force
{
    // SSE framing: an event block ends with a blank line (\n\n or \r\n\r\n).
    // Within the block, lines starting with "data:" carry JSON payloads.
    // The literal "data: [DONE]" marker terminates the stream.
    if ([_rawBuffer length] == 0) return;

    NSData *data = _rawBuffer;
    NSString *text = [[[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding] autorelease];
    if (!text) {
        // Maybe non-UTF8 chunk; ignore until we have a full frame.
        if (!force) return;
        text = @"";
    }

    NSArray *components = [text componentsSeparatedByString:@"\n\n"];
    NSUInteger count   = [components count];

    // If we don't have a trailing \n\n, the last chunk is partial — keep it.
    NSUInteger lastCompleteIdx = (force ? count - 1 : count - 2);

    for (NSUInteger i = 0; i <= lastCompleteIdx; i++) {
        NSString *eventBlock = [components objectAtIndex:i];
        [self _processEventBlock:eventBlock];
    }

    // Re-retain the remaining partial chunk (if any).
    NSUInteger remainingStart = lastCompleteIdx + 1;
    if (remainingStart < count) {
        // Find byte offset of the remaining chunk to slice the buffer properly.
        NSUInteger consumedBytes = 0;
        for (NSUInteger i = 0; i < remainingStart; i++) {
            consumedBytes += [[components objectAtIndex:i] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            consumedBytes += 2; // the "\n\n" separator
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
            // Stream end. We'll just stop appending; the finish callback
            // is fired from connectionDidFinishLoading:.
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

        NSString *content = [delta objectForKey:@"content"];
        if (![content isKindOfClass:[NSString class]] || content.length == 0) continue;

        [_accumulated appendString:content];

        // Push incremental update to delegate.
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
    [_conversationID release];
    [_lastError release];
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
    if (useTransit) {
        NSString *base = transitURL ?: @"https://api-ai.awa.lat";
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
    if (useTransit) [req setValue:@"tavily" forHTTPHeaderField:@"X-Provider"];
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
        base = useTransit ? @"https://api-ai.awa.lat" : @"https://api.openai.com";
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
