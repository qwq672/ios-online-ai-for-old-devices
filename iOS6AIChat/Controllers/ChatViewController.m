//
//  ChatViewController.m
//  iOS6AIChat
//
//  Primary chat screen. Owns:
//     - A UITableView listing all messages in the current Conversation
//     - A ComposerView for typing & sending
//     - A NetworkService driving the streaming chat completion
//
//  Keyboard handling:
//     - On iOS 6/7, listen to UIKeyboardWillShowNotification / WillHide
//     - Manually animate the bottom inset to keep the composer above keyboard
//     - Auto-scroll the table to the latest message
//
//  v261018 optimizations:
//     - Performance: use reloadRowsAtIndexPaths on just the streaming row
//       instead of reloadData during streaming. Throttle to 250ms.
//     - Deep thinking: capture reasoning_content via the new delegate
//       method and attach it to the assistant Message's `thinking` field.
//     - Web search: don't show search results AS the assistant message —
//       instead show a small status indicator above the input bar and
//       inject results as a system message that the AI sees (user can't).
//       This keeps the assistant placeholder clean ("…") and prevents
//       the search-results dump from being saved as the AI's answer.
//

#import "ChatViewController.h"
#import "iOS6Theme.h"
#import "IconDrawing.h"
#import "ChatMessageCell.h"
#import "ConversationStore.h"
#import "SettingsViewController.h"
#import "HistoryViewController.h"
#import "CharacterManagementViewController.h"
#import "DrawerViewController.h"
#import "Logger.h"

NSString *const ChatViewControllerDidLoadConversationNotification = @"ChatViewControllerDidLoadConversation";
NSString *const ChatViewControllerConversationIDKey               = @"conversationID";

static NSString *const kCellReuseID = @"ChatMessageCell";

@interface ChatViewController ()
@property (nonatomic, retain) ComposerView *composer;
@property (nonatomic, assign) CGFloat lastKeyboardHeight;
@property (nonatomic, retain) UIView *searchStatusView;
@property (nonatomic, retain) UILabel *searchStatusLabel;
// v261025-1: instance-level refresh throttle. It used to be a `static`
// inside the method — one variable SHARED by every ChatVC instance
// (root + pushed), so two visible chats starved each other's streaming
// refreshes.
@property (nonatomic, assign) NSTimeInterval lastRowReloadTime;
@end

@implementation ChatViewController

@synthesize tableView=_tableView, conversation=_conversation,
            networkService=_networkService, composer=_composer,
            lastKeyboardHeight=_lastKeyboardHeight,
            searchStatusView=_searchStatusView, searchStatusLabel=_searchStatusLabel,
            lastRowReloadTime=_lastRowReloadTime;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"Chat", nil);
        _networkService = [[NetworkService alloc] init];
        _networkService.delegate = self;

        // Listen for "switch conversation" events from HistoryViewController.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_onLoadConversation:)
                                                     name:ChatViewControllerDidLoadConversationNotification
                                                   object:nil];
    }
    return self;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // v261025-1: iOS 6 devices have very little RAM. Drop the render/
    // height caches (they rebuild lazily) instead of getting jetsammed.
    [ChatMessageCell flushCaches];
    [[Logger sharedLogger] warn:@"ChatVC didReceiveMemoryWarning — caches flushed"];
}

- (void)dealloc
{
    // Cancel any in-flight stream + nil the NetworkService's delegate
    // before release. Otherwise the NSURLConnection inside NetworkService
    // retains NetworkService across its lifetime, and its `_delegate`
    // assign-ivar would dangle after this VC is freed — leading to
    // EXC_BAD_ACCESS when the next SSE chunk arrives. (Audit #2, #3.)
    [_networkService cancel];
    _networkService.delegate = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [_conversation release];
    [_networkService release];
    [_composer release];
    [_searchStatusView release];
    [_searchStatusLabel release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];

    CGRect tableFrame = CGRectMake(0, 0,
                                    self.view.bounds.size.width,
                                    self.view.bounds.size.height - 48);
    _tableView = [[UITableView alloc] initWithFrame:tableFrame style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight);
    _tableView.allowsSelectionDuringEditing = NO;
    // estimatedRowHeight is iOS 7+; on iOS 6 we just rely on the explicit
    // height-for-row delegate method.
    if ([_tableView respondsToSelector:@selector(setEstimatedRowHeight:)]) {
        [_tableView performSelector:@selector(setEstimatedRowHeight:) withObject:@(60)];
    }
    // Set a sensible rowHeight hint for the table — reduces the number of
    // height-for-row calls during fast scrolling.
    _tableView.rowHeight = 80;
    [self.view addSubview:_tableView];

    // Composer initial height = row1 (34) + small gap + min row2 (44) + pad (6) ≈ 86.
    CGFloat composerInitH = 48.0f;  // single-row composer
    _composer = [[ComposerView alloc] initWithFrame:CGRectMake(0,
                                                                 self.view.bounds.size.height - composerInitH,
                                                                 self.view.bounds.size.width,
                                                                 composerInitH)];
    _composer.delegate = self;
    _composer.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleTopMargin);
    [self.view addSubview:_composer];

    // Search status view — small banner above composer, hidden by default.
    CGFloat statusH = 24.0f;
    _searchStatusView = [[UIView alloc] initWithFrame:CGRectMake(0,
                                                                  self.view.bounds.size.height - composerInitH - statusH,
                                                                  self.view.bounds.size.width, statusH)];
    _searchStatusView.backgroundColor = [iOS6Theme thinkingBackgroundColor];
    _searchStatusView.hidden = YES;
    _searchStatusView.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin);
    [self.view addSubview:_searchStatusView];

    _searchStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0,
                                                                    self.view.bounds.size.width - 16, statusH)];
    _searchStatusLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
    _searchStatusLabel.textColor = [iOS6Theme secondaryTextColor];
    _searchStatusLabel.backgroundColor = [UIColor clearColor];
    _searchStatusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_searchStatusView addSubview:_searchStatusLabel];

    // New session if none set.
    if (!_conversation) {
        Conversation *c = [[ConversationStore sharedStore] createNewConversation];
        self.conversation = c;
    }
    [self _reload];

    // Tap on table view background to dismiss keyboard.
    UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(_dismissKeyboard)] autorelease];
    tap.cancelsTouchesInView = NO; // don't block cell taps
    [_tableView addGestureRecognizer:tap];

// Navigation items — hamburger (drawer) on the left, "+" new chat on the right.
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
                                                 initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                 target:self
                                                 action:@selector(startNewConversation)] autorelease];
    [self _installDrawerButton];

    // Keyboard observers.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    // Theme change observer.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self _applyTheme];
    // Refresh toggle button icons.
    if ([_composer respondsToSelector:@selector(_refreshToggleVisuals)]) {
        [_composer performSelector:@selector(_refreshToggleVisuals)];
    }
    [self _reload];
}

- (void)_applyTheme
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    // Composer draws its own metal-bar chrome in drawRect — leave its
    // backgroundColor clear or the bar gradient would be hidden.
    _composer.backgroundColor = [UIColor clearColor];
    _searchStatusView.backgroundColor = [iOS6Theme thinkingBackgroundColor];
    _searchStatusLabel.textColor = [iOS6Theme secondaryTextColor];
}

- (void)_themeChanged
{
    // Flush render caches FIRST — cached attributed strings bake in the
    // old theme's colors (user-reported: toggle dark mode → text stays
    // black because cache still returns light-theme-colored strings).
    [ChatMessageCell flushCaches];
    [self _applyTheme];
    [self _installDrawerButton];   // re-tint hamburger with new bar tint
    [_tableView reloadData];
}

#pragma mark - Drawer (hamburger) button

- (void)_installDrawerButton
{
    // iOS 6 renders bar-button images as-is (no auto tint like iOS 7+),
    // so the icon is drawn in the current bar-item tint colour and
    // re-created whenever the theme flips.
    UIImage *menuIcon = [IconDrawing imageForType:IconTypeHamburger
                                            size:CGSizeMake(22, 22)
                                           color:[iOS6Theme barItemTintColor]];
    UIBarButtonItem *menuBtn =
        [[[UIBarButtonItem alloc] initWithImage:menuIcon
                                          style:UIBarButtonItemStyleBordered
                                         target:self
                                         action:@selector(_toggleDrawer)] autorelease];
    self.navigationItem.leftBarButtonItem = menuBtn;
}

- (void)_toggleDrawer
{
    // Don't slide the drawer under an open keyboard.
    [self _dismissKeyboard];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DrawerViewControllerToggleNotification object:nil];
}

#pragma mark - Conversation management

- (void)loadConversation:(Conversation *)conversation
{
    // v261025-1: switching conversations must tear down any in-flight
    // stream FIRST. The old code left the stream running with the OLD
    // conversationID; its didFinish was then filtered out by the ID
    // guard in the delegate callbacks — so `_composer.isStreaming = NO`
    // never ran and the send button stayed disabled FOREVER (the
    // "composer dead after browsing history" bug).
    if (_conversation != conversation) {
        [self _teardownActiveStream];
    }
    self.conversation = conversation;
    [self _reload];
    [self _scrollToBottomAnimated:NO];
}

// Cancel the in-flight stream (if any) and put the composer back into
// the interactive state. Safe to call any time.
- (void)_teardownActiveStream
{
    if (_networkService) {
        [_networkService cancelStream];
    }
    _composer.isStreaming = NO;
    [self _hideSearchStatus];
}

- (void)startNewConversation
{
    // Plan 1 (v261024-18): ChatVC IS the nav root — a "new chat" simply
    // swaps the conversation in place.
    // v261025-1: also tear down any active stream — otherwise the old
    // stream's didFinish gets filtered by the conversationID guard and
    // the composer stays stuck in the disabled/streaming state.
    [[Logger sharedLogger] info:@"ChatVC startNewConversation (in-place)"];
    [self _teardownActiveStream];
    if ([_conversation.messages count] > 0) {
        self.conversation = [[ConversationStore sharedStore] createNewConversation];
        [self _reload];
    }
}

- (void)_onLoadConversation:(NSNotification *)note
{
    NSString *cid = [[note userInfo] objectForKey:ChatViewControllerConversationIDKey];
    if (!cid) return;
    Conversation *c = [[ConversationStore sharedStore] conversationWithID:cid];
    if (c) [self loadConversation:c];
}

- (void)_reload
{
    [_tableView reloadData];
    [self _scrollToBottomAnimated:NO];
}

- (void)_scrollToBottomAnimated:(BOOL)animated
{
    if ([_conversation.messages count] == 0) return;
    NSIndexPath *lastIdx = [NSIndexPath indexPathForRow:[_conversation.messages count] - 1
                                              inSection:0];
    // v261024-19: NO @try — bounds-check before scrolling instead.
    if (!lastIdx) return;
    NSInteger totalRows = (NSInteger)[_tableView numberOfRowsInSection:0];
    if (lastIdx.row >= totalRows) {
        // Row count is stale — full reload instead.
        [_tableView reloadData];
        return;
    }
    [_tableView scrollToRowAtIndexPath:lastIdx
                      atScrollPosition:UITableViewScrollPositionBottom
                              animated:animated];
}

- (void)_dismissKeyboard
{
    [_composer.textView resignFirstResponder];
}

#pragma mark - Composer delegate

- (void)composer:(ComposerView *)c didSendText:(NSString *)text
              images:(NSArray *)images
        deepThinking:(BOOL)deepThinking webSearch:(BOOL)webSearch
{
    [self _sendUserMessage:text images:images deepThinking:deepThinking webSearch:webSearch];
}

- (void)composerDidChangeHeight:(ComposerView *)composer
{
    [self _adjustForComposerHeight];
}

- (void)_adjustForComposerHeight
{
    CGFloat composerH = _composer.frame.size.height;
    CGFloat statusH = _searchStatusView.hidden ? 0 : _searchStatusView.frame.size.height;
    CGRect tableFrame = _tableView.frame;
    tableFrame.origin.y = 0;
    tableFrame.size.height = self.view.bounds.size.height - composerH - statusH;
    [UIView animateWithDuration:0.2 animations:^{
        _tableView.frame = tableFrame;
        _composer.frame = CGRectMake(0,
                                      self.view.bounds.size.height - composerH,
                                      self.view.bounds.size.width,
                                      composerH);
        _searchStatusView.frame = CGRectMake(0,
                                             self.view.bounds.size.height - composerH - statusH,
                                             self.view.bounds.size.width, statusH);
    }];
    [self _scrollToBottomAnimated:YES];
}

#pragma mark - Sending

- (void)_sendUserMessage:(NSString *)text
{
    [self _sendUserMessage:text images:nil deepThinking:[ComposerView deepThinkingEnabled] webSearch:[ComposerView webSearchEnabled]];
}

- (void)_sendUserMessage:(NSString *)text images:(NSArray *)images deepThinking:(BOOL)deepThinking webSearch:(BOOL)webSearch
{
    if (!_conversation) {
        Conversation *c = [[ConversationStore sharedStore] createNewConversation];
        self.conversation = c;
    }

    Message *userMsg = [Message messageWithRole:MessageRoleUser content:text];
    if (images && [images count] > 0) {
        userMsg.images = images;
    }
    [_conversation appendMessage:userMsg];

    // Append an empty assistant placeholder — this cell will visibly
    // grow as chunks arrive.
    Message *assistantMsg = [Message messageWithRole:MessageRoleAssistant
                                              content:@"…"];
    [_conversation appendMessage:assistantMsg];
    [[ConversationStore sharedStore] saveConversation:_conversation];

    [_tableView reloadData];
    [self _scrollToBottomAnimated:YES];

    // Disable composer while streaming.
    _composer.isStreaming = YES;

    // Read settings.
    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit       = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL  = [settings objectForKey:SettingsKeyTransitURL];
    NSString *baseURL     = [settings objectForKey:SettingsKeyBaseURL];
    NSString *provider    = [settings objectForKey:SettingsKeyProvider];
    NSString *apiKey      = [settings objectForKey:SettingsKeyAPIKey];
    NSString *model        = [settings objectForKey:SettingsKeyModel];
    CGFloat temperature    = [[settings objectForKey:SettingsKeyTemperature] floatValue];

    // v261024-15: log the outgoing request for crash/error diagnosis.
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"send textLen=%lu imgs=%lu think=%d search=%d transit=%d provider=%@ model=%@",
        (unsigned long)text.length,
        images ? (unsigned long)[images count] : 0,
        (int)deepThinking, (int)webSearch,
        (int)useTransit, provider, model ?: @"(unset)"]];

    // v261024-15: compose effective system prompt (active character +
    // user identity + base prompt). If no character is active and
    // injectUserIdentity is off, this just returns `base` unchanged.
    NSString *basePrompt = [settings objectForKey:SettingsKeySystemPrompt]
                            ?: @"You are a helpful assistant.";
    NSString *systemPrompt = [CharacterManagementViewController effectiveSystemPromptWithBase:basePrompt];

    // If deep thinking is on, augment the system prompt with a chain-of-
    // thought instruction. The model's native reasoning_content field is
    // where thinking should go (we parse that separately).
    if (deepThinking) {
        systemPrompt = [NSString stringWithFormat:
            @"%@ Think step by step before answering. Reasoning goes in reasoning_content, not in the answer.",
            systemPrompt];
    }

    // If web search is on, ALWAYS pre-search the user's last message and
    // inject results as a system message. This is reliable — even if the
    // AI model doesn't support tool_calls, it still sees the search results.
    // tool_calls is ALSO enabled so the AI can search more if it wants.
    // This is a fallback after the pure-tool_calls approach proved
    // unreliable across different models.
    NSString *tavilyKey = webSearch ? ([settings objectForKey:SettingsKeyTavilyAPIKey] ?: @"") : @"";
    NSInteger maxResults = 0;
    if (webSearch) {
        maxResults = [[settings objectForKey:SettingsKeyTavilyMaxResults] integerValue];
        if (maxResults < 1) maxResults = 1;
        if (maxResults > 8) maxResults = 8;
    }

    if (webSearch && tavilyKey.length == 0) {
        // No Tavily key — show warning in status, proceed without search.
        [self _showSearchStatus:@"⚠️ 未配置 Tavily API Key，搜索不可用"];
        [self _launchAIStreamWithMessages:nil
                              systemPrompt:systemPrompt
                                useTransit:useTransit
                                transitURL:transitURL
                                  baseURL:baseURL
                                  provider:provider
                                   apiKey:apiKey
                                    model:model
                              temperature:temperature
                          conversationID:_conversation.conversationID
                            assistantMsg:assistantMsg
                              webSearch:NO
                              tavilyKey:@""
                          tavilyMaxResults:0
                        deepThinking:deepThinking
                       preSearchResults:nil];
        return;
    }

    if (webSearch && tavilyKey.length > 0) {
        // Pre-search the user's last message.
        [self _showSearchStatus:[NSString stringWithFormat:@"🔍 搜索: \"%@\"…", text]];
        NSString *capturedText = [text copy];
        NSString *capturedTavilyKey = [tavilyKey copy];
        NSInteger capturedMaxResults = maxResults;
        BOOL capturedUseTransit = useTransit;
        NSString *capturedTransitURL = [transitURL copy];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // v261025-1: @autoreleasepool — GCD worker threads have NO pool;
            // the autoreleased NetworkService + result objects leaked per search.
            @autoreleasepool {
            NetworkService *svc = [[[NetworkService alloc] init] autorelease];
            NSError *err = nil;
            NSArray *results = [svc tavilySearchWithQuery:capturedText
                                                     apiKey:capturedTavilyKey
                                                maxResults:capturedMaxResults
                                                useTransit:capturedUseTransit
                                                 transitURL:capturedTransitURL
                                                     error:&err];
            NSArray *resultsCopy = [results retain];
            NSError *errCopy = [err retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _hideSearchStatus];
                if (resultsCopy && [resultsCopy count] > 0) {
                    // Build a system message with the search results.
                    NSMutableString *ctx = [NSMutableString string];
                    [ctx appendString:@"Web search results (use as authoritative context, cite URLs):\n\n"];
                    NSInteger i = 1;
                    for (NSDictionary *r in resultsCopy) {
                        [ctx appendFormat:@"%d. %@\n   URL: %@\n   %@\n\n",
                            (int)i++,
                            [r objectForKey:@"title"],
                            [r objectForKey:@"url"],
                            [r objectForKey:@"content"]];
                    }
                    [self _launchAIStreamWithMessages:nil
                                          systemPrompt:systemPrompt
                                            useTransit:capturedUseTransit
                                            transitURL:capturedTransitURL
                                              baseURL:baseURL
                                              provider:provider
                                               apiKey:apiKey
                                                model:model
                                          temperature:temperature
                                      conversationID:_conversation.conversationID
                                        assistantMsg:assistantMsg
                                          webSearch:YES
                                          tavilyKey:capturedTavilyKey
                                      tavilyMaxResults:capturedMaxResults
                                        deepThinking:deepThinking
                                       preSearchResults:ctx];
                } else {
                    // Pre-search failed — proceed without search context.
                    [self _showSearchStatus:[NSString stringWithFormat:@"⚠️ 搜索失败: %@", [errCopy localizedDescription] ?: @"无结果"]];
                    // Hide the warning after 2 seconds.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self _hideSearchStatus];
                    });
                    [self _launchAIStreamWithMessages:nil
                                          systemPrompt:systemPrompt
                                            useTransit:capturedUseTransit
                                            transitURL:capturedTransitURL
                                              baseURL:baseURL
                                              provider:provider
                                               apiKey:apiKey
                                                model:model
                                          temperature:temperature
                                      conversationID:_conversation.conversationID
                                        assistantMsg:assistantMsg
                                          webSearch:YES
                                          tavilyKey:capturedTavilyKey
                                      tavilyMaxResults:capturedMaxResults
                                        deepThinking:deepThinking
                                       preSearchResults:nil];
                }
                [resultsCopy release];
                [errCopy release];
            });
            } // @autoreleasepool
        });
        [capturedText release];
        return;
    }

    // No web search — proceed directly.
    [self _launchAIStreamWithMessages:nil
                          systemPrompt:systemPrompt
                            useTransit:useTransit
                            transitURL:transitURL
                              baseURL:baseURL
                              provider:provider
                               apiKey:apiKey
                                model:model
                          temperature:temperature
                      conversationID:_conversation.conversationID
                        assistantMsg:assistantMsg
                          webSearch:webSearch
                          tavilyKey:tavilyKey
                          tavilyMaxResults:maxResults
                        deepThinking:deepThinking
                       preSearchResults:nil];
}

- (void)_showSearchStatus:(NSString *)msg
{
    _searchStatusLabel.text = msg;
    _searchStatusView.hidden = NO;
    [self _adjustForComposerHeight];
}

- (void)_hideSearchStatus
{
    _searchStatusView.hidden = YES;
    [self _adjustForComposerHeight];
}

// Refactored helper — kicks off the streaming API call.
// When `webSearch=YES`, the service attaches the `tools` array to the
// request body so the AI can autonomously call tavily_search any number
// of times. The service handles multi-turn internally — this method
// is called once per user message.
- (void)_launchAIStreamWithMessages:(NSArray *)msgsForAPI
                        systemPrompt:(NSString *)systemPrompt
                          useTransit:(BOOL)useTransit
                          transitURL:(NSString *)transitURL
                            baseURL:(NSString *)baseURL
                            provider:(NSString *)provider
                             apiKey:(NSString *)apiKey
                              model:(NSString *)model
                        temperature:(CGFloat)temperature
                      conversationID:(NSString *)conversationID
                        assistantMsg:(Message *)assistantMsg
                            webSearch:(BOOL)webSearch
                            tavilyKey:(NSString *)tavilyKey
                        tavilyMaxResults:(NSInteger)tavilyMaxResults
                          deepThinking:(BOOL)deepThinking
                         preSearchResults:(NSString *)preSearchResults
{
    // Build the messages array.
    NSMutableArray *messages = [NSMutableArray array];
    if (systemPrompt.length > 0) {
        [messages addObject:[Message messageWithRole:MessageRoleSystem content:systemPrompt]];
    }
    // Inject pre-search results as a separate system message (BEFORE the
    // user messages, so the AI sees search context first).
    if (preSearchResults.length > 0) {
        [messages addObject:[Message messageWithRole:MessageRoleSystem content:preSearchResults]];
    }
    for (Message *m in _conversation.messages) {
        if (m == assistantMsg) continue;
        [messages addObject:m];
    }
    // Tie the `thinking` parameter to BOTH:
    // 1. Deep thinking button ON (user wants reasoning)
    // 2. AND modelSupportsThinking ON (model supports it)
    // Either OFF → don't send `thinking` parameter.
    _networkService.thinkingEnabled = deepThinking;
    if (webSearch) {
        [self _showSearchStatus:@"🔍 AI 可调用搜索工具"];
        // New tool_calls entry point.
        [_networkService streamChatWithUseTransit:useTransit
                                        transitURL:transitURL
                                          baseURL:baseURL
                                          provider:provider
                                           apiKey:apiKey
                                            model:model
                                      temperature:temperature
                                         messages:messages
                                   conversationID:conversationID
                             enableWebSearchTools:YES
                                       tavilyKey:tavilyKey
                                 tavilyMaxResults:tavilyMaxResults];
    } else {
        [_networkService streamChatWithUseTransit:useTransit
                                        transitURL:transitURL
                                          baseURL:baseURL
                                          provider:provider
                                           apiKey:apiKey
                                            model:model
                                      temperature:temperature
                                         messages:messages
                                   conversationID:conversationID];
    }
}

#pragma mark - NetworkServiceDelegate

- (void)networkService:(NetworkService *)svc
didReceiveChunkForConversationID:(NSString *)conversationID
                   fullText:(NSString *)fullText
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    [_conversation updateLastAssistantMessageContent:fullText];
    // Don't save to disk on every chunk — only on finish/thinking-change.
    // The throttle on _refreshLastRow already limits UI updates to 250ms,
    // but writing the whole conversation to disk every 250ms during a
    // long answer is a major perf killer (NSKeyedArchiver serializes
    // the entire message array each call).
    [self _refreshLastRow];
}

- (void)networkService:(NetworkService *)svc
didReceiveThinkingForConversationID:(NSString *)conversationID
                  thinkingText:(NSString *)thinkingText
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    if ([_conversation.messages count] == 0) return;
    Message *lastMsg = [_conversation.messages objectAtIndex:[_conversation.messages count] - 1];
    if ([lastMsg isAssistant]) {
        lastMsg.thinking = thinkingText;
        // Don't save to disk on every chunk — only on finish.
        [self _refreshLastRow];
    }
}

- (void)networkService:(NetworkService *)svc
didReceiveToolCallForConversationID:(NSString *)conversationID
                          toolName:(NSString *)toolName
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    // Show status banner indicating the AI is calling a search tool.
    NSString *status = [NSString stringWithFormat:@"🔧 AI 调用工具: %@", toolName ?: @"unknown"];
    [self _showSearchStatus:status];
}

- (void)networkService:(NetworkService *)svc
didReceiveToolCallStartedForConversationID:(NSString *)conversationID
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    [self _showSearchStatus:@"🔧 正在执行搜索…"];
}

- (void)networkService:(NetworkService *)svc
didGenerateImageForConversationID:(NSString *)conversationID
            imageDataURL:(NSString *)imageDataURL
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    if (!imageDataURL || imageDataURL.length == 0) return;
    if ([_conversation.messages count] == 0) return;
    // Append the generated image to the last assistant message so it
    // displays in the chat bubble.
    Message *lastMsg = [_conversation.messages objectAtIndex:[_conversation.messages count] - 1];
    if ([lastMsg isAssistant]) {
        NSMutableArray *images = [NSMutableArray arrayWithArray:lastMsg.images ?: @[]];
        [images addObject:imageDataURL];
        lastMsg.images = images;
        [[ConversationStore sharedStore] saveConversation:_conversation];
        [self _refreshLastRowForce:YES];
    }
}

- (void)networkService:(NetworkService *)svc
didFinishForConversationID:(NSString *)conversationID
                fullText:(NSString *)fullText
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    // v261025-1: EMPTY-REPLY guard — a 200 OK with zero content chars is
    // NOT a usable answer. Surface it clearly in the bubble (NetworkService
    // already logged the raw body head for diagnosis) instead of silently
    // showing a blank/“…” bubble.
    if (fullText.length == 0) {
        fullText = NSLocalizedString(@"⚠️ 服务器返回了空回复（详见日志——可能为中转/上游异常）", nil);
    }
    [_conversation updateLastAssistantMessageContent:fullText ?: @""];
    // Attach accumulated thinking text to the message — preserves it
    // across launches / conversation switches.
    if ([_conversation.messages count] > 0) {
        Message *last = [_conversation.messages objectAtIndex:[_conversation.messages count] - 1];
        if ([last isAssistant]) {
            last.thinking = [svc accumulatedThinking];
        }
    }
    [[ConversationStore sharedStore] saveConversation:_conversation];
    [self _refreshLastRowForce:YES];
    _composer.isStreaming = NO;
    [self _hideSearchStatus];
}

- (void)networkService:(NetworkService *)svc
didFailForConversationID:(NSString *)conversationID
                error:(NSError *)error
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    NSString *errText = [NSString stringWithFormat:@"⚠️ %@",
                         error.localizedDescription ?: @"网络错误"];
    [[Logger sharedLogger] error:[NSString stringWithFormat:
        @"networkService didFail conv=%@ code=%ld desc=%@",
        conversationID, (long)error.code,
        error.localizedDescription ?: @"(no desc)"]];
    [_conversation updateLastAssistantMessageContent:errText];
    [[ConversationStore sharedStore] saveConversation:_conversation];
    [self _refreshLastRowForce:YES];
    _composer.isStreaming = NO;
    [self _hideSearchStatus];
}

- (void)_refreshLastRow
{
    [self _refreshLastRowForce:NO];
}

- (void)_refreshLastRowForce:(BOOL)force
{
    if ([_conversation.messages count] == 0) return;
    // Throttle: only reload every 0.4s to reduce CPU usage during streaming.
    // v261025-1: was a `static` (one variable shared across ALL ChatVC
    // instances — the root chat AND any pushed history chat starved each
    // other's refreshes); now per-instance.
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - self.lastRowReloadTime < 0.4) return;
    self.lastRowReloadTime = now;

    NSIndexPath *lastIdx = [NSIndexPath indexPathForRow:[_conversation.messages count] - 1
                                              inSection:0];
    if (!lastIdx || lastIdx.row < 0 ||
        lastIdx.row >= (NSInteger)[_tableView numberOfRowsInSection:0]) {
        [_tableView reloadData];
    } else {
        [_tableView beginUpdates];
        [_tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:lastIdx]
                        withRowAnimation:UITableViewRowAnimationNone];
        [_tableView endUpdates];
    }
    [self _scrollToBottomAnimated:YES];
}

#pragma mark - Table data source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)[_conversation.messages count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // v261024-19: NO @try — bounds-check instead.
    if (indexPath.row < 0 ||
        indexPath.row >= (NSInteger)[_conversation.messages count]) {
        return 80;  // safe default
    }
    Message *m = [_conversation.messages objectAtIndex:indexPath.row];
    if (!m) return 80;
    return [ChatMessageCell heightForMessage:m width:_tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    ChatMessageCell *cell = (ChatMessageCell *)[tableView dequeueReusableCellWithIdentifier:kCellReuseID];
    if (!cell) {
        cell = [[[ChatMessageCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:kCellReuseID] autorelease];
    }
    cell.delegate = self;
    // v261024-19: NO @try — bounds-check + nil-guards.
    if (indexPath.row < 0 ||
        indexPath.row >= (NSInteger)[_conversation.messages count]) {
        cell.textLabel.text = @"⚠️ 消息索引越界";
        return cell;
    }
    Message *m = [_conversation.messages objectAtIndex:indexPath.row];
    if (!m) {
        cell.textLabel.text = @"⚠️ 消息为空";
        return cell;
    }
    [cell applyMessage:m];
    return cell;
}

#pragma mark - ChatMessageCellDelegate

- (void)chatCell:(ChatMessageCell *)cell didTapRegenerate:(Message *)message
{
    if (!message || !message.isAssistant) return;
    // v261025-1: regenerating on top of a running stream would launch a
    // second connection and mutate the message list under the first
    // stream's feet. Ignore while streaming.
    if (_composer.isStreaming) {
        [[Logger sharedLogger] warn:@"ChatVC regenerate ignored — still streaming"];
        return;
    }
    // Find the user message that preceded this AI reply.
    NSInteger idx = [_conversation.messages indexOfObject:message];
    if (idx == NSNotFound || idx == 0) return;
    Message *userMsg = [_conversation.messages objectAtIndex:idx - 1];
    if (!userMsg.isUser) return;
    // Remove the current AI reply + everything after it.
    NSMutableArray *msgs = [NSMutableArray arrayWithArray:_conversation.messages];
    [_conversation.messages removeAllObjects];
    for (NSInteger i = 0; i < idx; i++) {
        [_conversation.messages addObject:[msgs objectAtIndex:i]];
    }
    // Re-send the user message.
    [self _sendUserMessage:userMsg.content
                    images:userMsg.images
              deepThinking:[ComposerView deepThinkingEnabled]
                webSearch:[ComposerView webSearchEnabled]];
}

- (void)chatCell:(ChatMessageCell *)cell didTapCopy:(Message *)message
{
    if (!message) return;
    [[UIPasteboard generalPasteboard] setString:message.content ?: @""];
}

#pragma mark - Keyboard

- (void)_keyboardWillShow:(NSNotification *)note
{
    NSValue *frameVal = [[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey];
    CGRect kbRect = [frameVal CGRectValue];
    kbRect = [self.view convertRect:kbRect fromView:nil];
    CGFloat kbH = kbRect.size.height;
    self.lastKeyboardHeight = kbH;
    // v261025-1: account for the search-status banner — with the banner
    // visible the old math dropped it behind the keyboard.
    CGFloat statusH = _searchStatusView.hidden ? 0 : _searchStatusView.frame.size.height;

    [UIView animateWithDuration:0.25 animations:^{
        _composer.frame = CGRectMake(0,
                                     self.view.bounds.size.height - kbH - _composer.bounds.size.height,
                                     self.view.bounds.size.width,
                                     _composer.bounds.size.height);
        CGRect f = _tableView.frame;
        f.size.height = self.view.bounds.size.height - kbH - _composer.bounds.size.height - statusH;
        _tableView.frame = f;
        CGRect sf = _searchStatusView.frame;
        sf.origin.y = self.view.bounds.size.height - kbH - _composer.bounds.size.height - statusH;
        _searchStatusView.frame = sf;
    }];
    [self _scrollToBottomAnimated:YES];
}

- (void)_keyboardWillHide:(NSNotification *)note
{
    // v261025-1: keep the status banner above the composer on hide too.
    CGFloat statusH = _searchStatusView.hidden ? 0 : _searchStatusView.frame.size.height;
    [UIView animateWithDuration:0.25 animations:^{
        _composer.frame = CGRectMake(0,
                                     self.view.bounds.size.height - _composer.bounds.size.height,
                                     self.view.bounds.size.width,
                                     _composer.bounds.size.height);
        CGRect f = _tableView.frame;
        f.size.height = self.view.bounds.size.height - _composer.bounds.size.height - statusH;
        _tableView.frame = f;
        CGRect sf = _searchStatusView.frame;
        sf.origin.y = self.view.bounds.size.height - _composer.bounds.size.height - statusH;
        _searchStatusView.frame = sf;
    }];
}

@end
