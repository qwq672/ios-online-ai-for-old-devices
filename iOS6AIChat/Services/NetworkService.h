//
//  NetworkService.h
//  iOS6AIChat
//
//  Talks to an OpenAI-compatible /v1/chat/completions endpoint with
//  streaming ("stream": true) enabled. iOS 6 has no NSURLSession, so
//  we drive NSURLConnection manually and parse the SSE byte stream
//  as chunks arrive.
//
//  Two modes:
//   1) Transit mode (recommended for iOS 6):
//      - Endpoint = {transitURL}/v1/chat/completions
//      - Sends X-Provider: zhipu | openai | ollama  header so the
//        transit server routes to the right backend.
//      - Authorization: Bearer {apiKey}  still sent (provider key).
//   2) Direct mode:
//      - Endpoint = {baseURL}/v1/chat/completions
//      - Authorization: Bearer {apiKey}
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Conversation.h"

@protocol NetworkServiceDelegate;

@interface NetworkService : NSObject <NSURLConnectionDelegate>

@property (nonatomic, assign) id<NetworkServiceDelegate> delegate;
@property (nonatomic, assign) BOOL thinkingEnabled;

// Kick off a streaming chat completion.
- (BOOL)streamChatWithUseTransit:(BOOL)useTransit
                       transitURL:(NSString *)transitURL
                         baseURL:(NSString *)baseURL
                         provider:(NSString *)provider
                          apiKey:(NSString *)apiKey
                           model:(NSString *)model
                     temperature:(CGFloat)temperature
                        messages:(NSArray *)messages
                  conversationID:(NSString *)conversationID;

// v261018: streaming chat with web-search tools enabled.
// When enableWebSearchTools=YES, the request body includes a `tools`
// array defining a `tavily_search` function. The AI can autonomously
// decide whether to call it (and may call it multiple times). When the
// AI emits tool_calls, this service suspends the stream, runs the
// Tavily search, appends the result as a `tool` role message, and
// re-launches the stream with the augmented message history.
//
// `tavilyKey` and `tavilyMaxResults` are required when enableTools=YES.
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
                tavilyMaxResults:(NSInteger)tavilyMaxResults;

// Cancel an in-flight stream.
- (void)cancel;

// Read the accumulated reasoning/thinking text after the stream finishes
// (or any time during the stream). The delegate can call this to attach
// thinking to a Message object.
@property (nonatomic, readonly) NSString *accumulatedThinking;

// ============================================================
// Tavily web search (sync — fires before sending to AI model)
// ============================================================
//
// POST https://api.tavily.com/search  (or {transitURL}/v1/tavily/search
//   with X-Provider: tavily header if useTransit=YES)
//   Body: { "api_key": "...", "query": "...", "max_results": 1..8 }
//   Returns: { results: [{ title, url, content }, ...] }
//
// Synchronous — call from a background queue. Returns NSArray of
// NSDictionary with title / url / content keys; nil + *error on failure.

- (NSArray *)tavilySearchWithQuery:(NSString *)query
                            apiKey:(NSString *)apiKey
                       maxResults:(NSInteger)maxResults
                       useTransit:(BOOL)useTransit
                        transitURL:(NSString *)transitURL
                            error:(NSError **)error;

// ============================================================
// Model list fetch (sync)
// ============================================================
//
// GET {endpoint}/v1/models  (with Authorization: Bearer {apiKey})
//   Returns: { data: [{ id: "gpt-4o-mini" }, ...] }
//
// useTransit=YES → endpoint = transitURL/v1/models with X-Provider set.
// Returns NSArray of model-id NSStrings; nil on failure.

- (NSArray *)listModelsWithUseTransit:(BOOL)useTransit
                             transitURL:(NSString *)transitURL
                              baseURL:(NSString *)baseURL
                              provider:(NSString *)provider
                               apiKey:(NSString *)apiKey
                                 error:(NSError **)error;

@end


@protocol NetworkServiceDelegate <NSObject>
@optional
- (void)networkService:(NetworkService *)svc
   didReceiveChunkForConversationID:(NSString *)conversationID
                       fullText:(NSString *)fullText;
- (void)networkService:(NetworkService *)svc
didReceiveThinkingForConversationID:(NSString *)conversationID
                          thinkingText:(NSString *)thinkingText;
// Fired when the AI emits a tool_call (function call). The delegate can
// update the UI to show "AI is calling tavily_search...".
- (void)networkService:(NetworkService *)svc
didReceiveToolCallForConversationID:(NSString *)conversationID
                          toolName:(NSString *)toolName;
// Fired when the service has finished collecting tool_calls and is
// about to execute them and re-launch the stream. Useful for showing
// "Running tool..." status.
- (void)networkService:(NetworkService *)svc
didReceiveToolCallStartedForConversationID:(NSString *)conversationID;
- (void)networkService:(NetworkService *)svc
 didFinishForConversationID:(NSString *)conversationID
                       fullText:(NSString *)fullText;
- (void)networkService:(NetworkService *)svc
     didFailForConversationID:(NSString *)conversationID
                       error:(NSError *)error;
@end
