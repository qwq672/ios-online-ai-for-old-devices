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
#import "ChatMessageCell.h"
#import "ConversationStore.h"
#import "SettingsViewController.h"
#import "HistoryViewController.h"

NSString *const ChatViewControllerDidLoadConversationNotification = @"ChatViewControllerDidLoadConversation";
NSString *const ChatViewControllerConversationIDKey               = @"conversationID";

static NSString *const kCellReuseID = @"ChatMessageCell";

@interface ChatViewController ()
@property (nonatomic, retain) ComposerView *composer;
@property (nonatomic, assign) CGFloat lastKeyboardHeight;
@property (nonatomic, retain) UIView *searchStatusView;
@property (nonatomic, retain) UILabel *searchStatusLabel;
@end

@implementation ChatViewController

@synthesize tableView=_tableView, conversation=_conversation,
            networkService=_networkService, composer=_composer,
            lastKeyboardHeight=_lastKeyboardHeight,
            searchStatusView=_searchStatusView, searchStatusLabel=_searchStatusLabel;

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

// Navigation items — a "new chat" button.
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
                                                 initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                 target:self
                                                 action:@selector(startNewConversation)] autorelease];

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
    _composer.backgroundColor = [iOS6Theme pinstripeBackground];
    _searchStatusView.backgroundColor = [iOS6Theme thinkingBackgroundColor];
    _searchStatusLabel.textColor = [iOS6Theme secondaryTextColor];
}

- (void)_themeChanged
{
    [self _applyTheme];
    // Clear the height cache so cells recompute with new font size.
    [_tableView reloadData];
}

#pragma mark - Conversation management

- (void)loadConversation:(Conversation *)conversation
{
    self.conversation = conversation;
    [self _reload];
    [self _scrollToBottomAnimated:NO];
}

- (void)startNewConversation
{
    if ([_conversation.messages count] > 0) {
        Conversation *c = [[ConversationStore sharedStore] createNewConversation];
        self.conversation = c;
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
    @try {
        [_tableView scrollToRowAtIndexPath:lastIdx
                          atScrollPosition:UITableViewScrollPositionBottom
                                  animated:animated];
    } @catch (NSException *e) {
        // Sometimes the row count is stale — silently ignore.
    }
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
    NSString *systemPrompt = [settings objectForKey:SettingsKeySystemPrompt]
                              ?: @"You are a helpful assistant.";

    // If deep thinking is on, augment the system prompt with a chain-of-
    // thought instruction. The model's native reasoning_content field is
    // where thinking should go (we parse that separately).
    if (deepThinking) {
        systemPrompt = [NSString stringWithFormat:
            @"%@ Think step by step before answering. Reasoning goes in reasoning_content, not in the answer.",
            systemPrompt];
    }

    // If web search is on, enable tool_calls mode — the AI decides
    // whether to call tavily_search and may call it multiple times.
    // We no longer pre-search; instead the service attaches the tools
    // array to the request and runs any tool_calls the AI emits.
    NSString *tavilyKey = webSearch ? ([settings objectForKey:SettingsKeyTavilyAPIKey] ?: @"") : @"";
    NSInteger maxResults = 0;
    if (webSearch) {
        maxResults = [[settings objectForKey:SettingsKeyTavilyMaxResults] integerValue];
        if (maxResults < 1) maxResults = 1;
        if (maxResults > 8) maxResults = 8;
    }

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
                        deepThinking:deepThinking];
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
{
    // Build the messages array.
    NSMutableArray *messages = [NSMutableArray array];
    if (systemPrompt.length > 0) {
        [messages addObject:[Message messageWithRole:MessageRoleSystem content:systemPrompt]];
    }
    for (Message *m in _conversation.messages) {
        if (m == assistantMsg) continue;
        [messages addObject:m];
    }
    // Tie the `thinking` parameter to BOTH:
    // 1. Deep thinking button ON (user wants reasoning)
    // 2. AND modelSupportsThinking ON (model supports it)
    // Either OFF → don't send `thinking` parameter.
    // This was bug: deep thinking button had no effect because
    // thinkingEnabled was always YES — models that support thinking
    // couldn't be turned off.
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
didFinishForConversationID:(NSString *)conversationID
                fullText:(NSString *)fullText
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
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
    // Was 0.25s but for long AI responses the Markdown re-render +
    // boundingRect was still too slow on iOS 6 hardware. 0.4s gives the
    // CPU more headroom while keeping the streaming feel responsive.
    static NSTimeInterval lastReload = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - lastReload < 0.4) return; // skip if less than 400ms
    lastReload = now;

    NSIndexPath *lastIdx = [NSIndexPath indexPathForRow:[_conversation.messages count] - 1
                                              inSection:0];
    // Use reloadRowsAtIndexPaths instead of reloadData — much cheaper.
    @try {
        [_tableView beginUpdates];
        [_tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:lastIdx]
                        withRowAnimation:UITableViewRowAnimationNone];
        [_tableView endUpdates];
    } @catch (NSException *e) {
        // Fall back to full reload if batch update fails.
        [_tableView reloadData];
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
    Message *m = [_conversation.messages objectAtIndex:indexPath.row];
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
    Message *m = [_conversation.messages objectAtIndex:indexPath.row];
    [cell applyMessage:m];
    return cell;
}

#pragma mark - Keyboard

- (void)_keyboardWillShow:(NSNotification *)note
{
    NSValue *frameVal = [[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey];
    CGRect kbRect = [frameVal CGRectValue];
    kbRect = [self.view convertRect:kbRect fromView:nil];
    CGFloat kbH = kbRect.size.height;
    self.lastKeyboardHeight = kbH;

    [UIView animateWithDuration:0.25 animations:^{
        _composer.frame = CGRectMake(0,
                                     self.view.bounds.size.height - kbH - _composer.bounds.size.height,
                                     self.view.bounds.size.width,
                                     _composer.bounds.size.height);
        CGRect f = _tableView.frame;
        f.size.height = self.view.bounds.size.height - kbH - _composer.bounds.size.height;
        _tableView.frame = f;
    }];
    [self _scrollToBottomAnimated:YES];
}

- (void)_keyboardWillHide:(NSNotification *)note
{
    [UIView animateWithDuration:0.25 animations:^{
        _composer.frame = CGRectMake(0,
                                     self.view.bounds.size.height - _composer.bounds.size.height,
                                     self.view.bounds.size.width,
                                     _composer.bounds.size.height);
        CGRect f = _tableView.frame;
        f.size.height = self.view.bounds.size.height - _composer.bounds.size.height;
        _tableView.frame = f;
    }];
}

@end
