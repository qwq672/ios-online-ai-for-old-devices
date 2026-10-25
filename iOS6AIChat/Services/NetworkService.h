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

// Cancel an in-flight stream AND detach the delegate (used when the
// owning view controller is being destroyed).
- (void)cancel;

// v261025-1: Cancel the in-flight stream but KEEP the delegate attached.
// Used when the user switches conversation mid-stream — the service is
// reused for the next send, so the delegate must survive. (The old flow
// either left the stream running with a mismatched conversationID —
// freezing the composer — or used -cancel, which permanently detached
// the delegate and made every later send silent.)
- (void)cancelStream;

// v261025-3: Stop the in-flight stream, PRESERVE accumulated text, and
// dispatch the normal didFinish delegate path. Use this when the user
// taps the "Stop" button mid-generation. The text produced so far is
// KEPT as the assistant message (unlike cancelStream which discards
// everything and is meant for switching conversations).
- (void)stopGenerating;

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

// ============================================================
// Transit server's own bundled model list (v261025-3)
// ============================================================
//
// GET {transitURL}/v1/transit/models
//   Returns: { "enabled": true/false, "models": ["glm-4-flash", ...] }
//
// The transit server can optionally bundle a list of models (controlled
// by TRANSIT_MODELS_ENABLED + TRANSIT_MODELS env vars on the server side).
// When the user opens the "transit default model" toggle in settings, this
// method is called. If enabled=true, the returned models are added to the
// app's local model management under source="transit".
//
// Returns NSDictionary with keys:
//   enabled (NSNumber bool) — whether the transit server has any bundled models
//   models  (NSArray of NSString) — model id list (empty if disabled)
// Returns nil + *error on network/HTTP/parse failure.
- (NSDictionary *)transitModelsAtTransitURL:(NSString *)transitURL
                                      error:(NSError **)error;

// ============================================================
// Image generation (sync)
// ============================================================
//
// POST {endpoint}/v1/images/generations  (forwarded by transit server)
//   Body: { "model": "dall-e-3" | "cogview-3plus" | ...,
//           "prompt": "...", "n": 1, "size": "1024x1024" }
//   Returns: { "data": [{ "url": "..." }] } or { "data": [{ "b64_json": "..." }] }
//
// If response contains a URL, this method ALSO fetches the image via
// the transit server's /v1/fetch_image?url=... endpoint (avoids iOS 6
// TLS issues with the image host).
//
// Returns an NSString of the form "data:image/png;base64,..." ready
// to be added to a Message's images array. Returns nil + *error on failure.

- (NSString *)generateImageWithPrompt:(NSString *)prompt
                                 model:(NSString *)model
                                 size:(NSString *)size
                            useTransit:(BOOL)useTransit
                            transitURL:(NSString *)transitURL
                              provider:(NSString *)provider
                               apiKey:(NSString *)apiKey
                                 error:(NSError **)error;

// Fetch an arbitrary image URL via the transit server's /v1/fetch_image
// endpoint (returns the raw image bytes as a base64 data URL string).
// Use this to download images from hosts that iOS 6's NSURLConnection
// can't negotiate TLS with.
- (NSString *)fetchImageURLViaTransit:(NSString *)imageURL
                            transitURL:(NSString *)transitURL
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
// Fired when the AI calls generate_image and the image has been generated
// + downloaded. The delegate should append this data URL to the current
// assistant message's images array so the image displays in the chat.
- (void)networkService:(NetworkService *)svc
didGenerateImageForConversationID:(NSString *)conversationID
            imageDataURL:(NSString *)imageDataURL;
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
