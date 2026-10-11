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

// Cancel an in-flight stream.
- (void)cancel;

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
 didFinishForConversationID:(NSString *)conversationID
                       fullText:(NSString *)fullText;
- (void)networkService:(NetworkService *)svc
     didFailForConversationID:(NSString *)conversationID
                       error:(NSError *)error;
@end
