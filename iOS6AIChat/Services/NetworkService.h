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

// Kick off a streaming chat completion. Returns YES if the request was
// dispatched; the delegate will receive incremental callbacks until
// -networkServiceDidFinishStreaming: or -networkService:didFailWithError:.
//
// Parameters:
//   useTransit   — YES: hit transitURL; NO: hit baseURL
//   transitURL   — base URL of the relay server (used iff useTransit)
//   baseURL      — base URL of the OpenAI-compatible server (used iff !useTransit)
//   provider     — provider id string ("zhipu"|"openai"|"ollama"|"" )
//                  sent as X-Provider header in transit mode
//   apiKey       — Bearer token, can be nil for unauthenticated local Ollama
//   model        — model name as the backend expects
//   temperature  — 0..1
//   messages     — [Message] — order matters, sent to backend
//   conversationID — opaque id passed back in every delegate callback
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

@end


@protocol NetworkServiceDelegate <NSObject>
@optional
- (void)networkService:(NetworkService *)svc
   didReceiveChunkForConversationID:(NSString *)conversationID
                       fullText:(NSString *)fullText;        // incremental update
- (void)networkService:(NetworkService *)svc
 didFinishForConversationID:(NSString *)conversationID
                       fullText:(NSString *)fullText;
- (void)networkService:(NetworkService *)svc
     didFailForConversationID:(NSString *)conversationID
                       error:(NSError *)error;
@end

// ============================================================
// Tavily web search (sync — fires before sending to AI model)
// ============================================================
//
// POST https://api.tavily.com/search
//   { "api_key": "...", "query": "...", "max_results": 1..8 }
// Returns JSON: { results: [{ title, url, content }, ...] }
//
// If useTransit=YES, the request goes through the transit server instead:
//   POST {transitURL}/v1/tavily/search
//   Headers: X-Provider: tavily
//   Body: same as above
//
// This is a synchronous call (blocks the calling thread) — call it on
// a background queue and dispatch back to main when done.
//
// On success, returns an NSArray of NSDictionary with keys:
//   title, url, content.
// On failure, returns nil and sets *error.

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
// Returns JSON: { data: [{ id: "gpt-4o-mini" }, ...] }
// We return an NSArray of model-id NSStrings.
//
// useTransit=YES hits {transitURL}/v1/models with X-Provider set.
// On failure, returns nil.

- (NSArray *)listModelsWithUseTransit:(BOOL)useTransit
                             transitURL:(NSString *)transitURL
                              baseURL:(NSString *)baseURL
                              provider:(NSString *)provider
                               apiKey:(NSString *)apiKey
                                 error:(NSError **)error;

