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
@end

@implementation ChatViewController

@synthesize tableView=_tableView, conversation=_conversation,
            networkService=_networkService, composer=_composer,
            lastKeyboardHeight=_lastKeyboardHeight;

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
        // Listen for direct "send" notifications from the composer.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_onComposerSend:)
                                                     name:ComposerViewSendMessageNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [_conversation release];
    [_networkService release];
    [_composer release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];

    CGRect tableFrame = CGRectMake(0, 0,
                                    self.view.bounds.size.width,
                                    self.view.bounds.size.height - 56);
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
    [self.view addSubview:_tableView];

    _composer = [[ComposerView alloc] initWithFrame:CGRectMake(0,
                                                                 self.view.bounds.size.height - 56,
                                                                 self.view.bounds.size.width,
                                                                 56)];
    _composer.delegate = self;
    _composer.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleTopMargin);
    [self.view addSubview:_composer];

    // New session if none set.
    if (!_conversation) {
        Conversation *c = [[ConversationStore sharedStore] createNewConversation];
        self.conversation = c;
    }
    [self _reload];

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
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self _scrollToBottomAnimated:NO];
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
    [_tableView scrollToRowAtIndexPath:lastIdx
                      atScrollPosition:UITableViewScrollPositionBottom
                              animated:animated];
}

#pragma mark - Composer delegate

- (void)composer:(ComposerView *)c didSendText:(NSString *)text
        deepThinking:(BOOL)deepThinking webSearch:(BOOL)webSearch
{
    [self _sendUserMessage:text deepThinking:deepThinking webSearch:webSearch];
}

- (void)composerDidChangeHeight:(ComposerView *)composer
{
    [self _adjustForComposerHeight];
}

- (void)_onComposerSend:(NSNotification *)note
{
    NSString *text = [[note userInfo] objectForKey:ComposerViewSendMessageTextKey];
    BOOL dt = [[[note userInfo] objectForKey:ComposerViewSendMessageDeepThinkingKey] boolValue];
    BOOL ws = [[[note userInfo] objectForKey:ComposerViewSendMessageWebSearchKey] boolValue];
    if (text.length > 0) [self _sendUserMessage:text deepThinking:dt webSearch:ws];
}

- (void)_adjustForComposerHeight
{
    CGFloat composerH = _composer.frame.size.height;
    CGRect tableFrame = _tableView.frame;
    tableFrame.origin.y = 0;
    tableFrame.size.height = self.view.bounds.size.height - composerH;
    [UIView animateWithDuration:0.25 animations:^{
        _tableView.frame = tableFrame;
        _composer.frame = CGRectMake(0,
                                      self.view.bounds.size.height - composerH,
                                      self.view.bounds.size.width,
                                      composerH);
    }];
    [self _scrollToBottomAnimated:YES];
}

#pragma mark - Sending

- (void)_sendUserMessage:(NSString *)text
{
    [self _sendUserMessage:text deepThinking:[ComposerView deepThinkingEnabled]
                          webSearch:[ComposerView webSearchEnabled]];
}

- (void)_sendUserMessage:(NSString *)text
            deepThinking:(BOOL)deepThinking
                webSearch:(BOOL)webSearch
{
    if (!_conversation) {
        Conversation *c = [[ConversationStore sharedStore] createNewConversation];
        self.conversation = c;
    }

    Message *userMsg = [Message messageWithRole:MessageRoleUser content:text];
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
    // thought instruction.
    if (deepThinking) {
        systemPrompt = [NSString stringWithFormat:
            @"%@ Think step by step before answering. Show your reasoning process prefixed with \"Reasoning:\" and then give the final answer prefixed with \"Answer:\".",
            systemPrompt];
    }

    // If web search is on, do a Tavily /search first (sync, on background
    // queue) and inject the results as an additional system message.
    __block NSArray *searchResults = nil;
    if (webSearch) {
        NSString *tavilyKey = [settings objectForKey:SettingsKeyTavilyAPIKey];
        NSInteger maxResults = [[settings objectForKey:SettingsKeyTavilyMaxResults] integerValue];
        if (maxResults < 1) maxResults = 1;
        if (maxResults > 8) maxResults = 8;
        if (tavilyKey.length > 0) {
            // Show a transient "正在联网搜索…" placeholder by replacing the
            // assistant placeholder content.
            assistantMsg.content = NSLocalizedString(@"🔍 正在联网搜索…", nil);
            [self _refreshLastRow];

            // Synchronous Tavily call on background queue, then continue.
            // NOTE: we use dispatch_sync here so the AI request waits for
            // results. Caller is the main thread, so this would deadlock —
            // dispatch_async instead and call _launchAPIStream from inside.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NetworkService *svc = [[[NetworkService alloc] init] autorelease];
                NSError *err = nil;
                NSArray *results = [svc tavilySearchWithQuery:text
                                                         apiKey:tavilyKey
                                                    maxResults:maxResults
                                                    useTransit:useTransit
                                                     transitURL:transitURL
                                                         error:&err];
                searchResults = [results retain];
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Re-enable "…" placeholder while AI streams.
                    assistantMsg.content = @"…";
                    [self _refreshLastRow];

                    // Inject search results into the conversation as a system
                    // message just before the AI call. We do NOT persist
                    // this synthesized system message — it's only for the
                    // API request.
                    NSMutableArray *msgsForAPI = [NSMutableArray array];
                    if (systemPrompt.length > 0) {
                        [msgsForAPI addObject:[Message messageWithRole:MessageRoleSystem
                                                                content:systemPrompt]];
                    }
                    if (searchResults && [searchResults count] > 0) {
                        NSMutableString *ctx = [NSMutableString string];
                        [ctx appendString:@"Web search results for: "];
                        [ctx appendString:text];
                        [ctx appendString:@"\n\n"];
                        NSInteger i = 1;
                        for (NSDictionary *r in searchResults) {
                            [ctx appendFormat:@"%d. %@\n   URL: %@\n   %@\n\n",
                                (int)i++,
                                [r objectForKey:@"title"],
                                [r objectForKey:@"url"],
                                [r objectForKey:@"content"]];
                        }
                        [ctx appendString:@"Use these results as context when answering the user's question."];
                        [msgsForAPI addObject:[Message messageWithRole:MessageRoleSystem content:ctx]];
                    }
                    // Now add the actual conversation messages, EXCLUDING the placeholder.
                    for (Message *m in _conversation.messages) {
                        if (m == assistantMsg) continue;
                        [msgsForAPI addObject:m];
                    }
                    [self _launchAPIStreamWithMessages:msgsForAPI
                                              useTransit:useTransit
                                              transitURL:transitURL
                                                baseURL:baseURL
                                                provider:provider
                                                 apiKey:apiKey
                                                  model:model
                                            temperature:temperature
                                          conversationID:_conversation.conversationID
                                       assistantMsg:assistantMsg];
                    [searchResults release];
                });
            });
            return; // Wait for the async call to complete.
        }
    }

    // No web search — proceed directly.
    NSMutableArray *msgsForAPI = [NSMutableArray array];
    if (systemPrompt.length > 0) {
        [msgsForAPI addObject:[Message messageWithRole:MessageRoleSystem content:systemPrompt]];
    }
    for (Message *m in _conversation.messages) {
        if (m == assistantMsg) continue;
        [msgsForAPI addObject:m];
    }
    [self _launchAPIStreamWithMessages:msgsForAPI
                              useTransit:useTransit
                              transitURL:transitURL
                                baseURL:baseURL
                                provider:provider
                                 apiKey:apiKey
                                  model:model
                            temperature:temperature
                          conversationID:_conversation.conversationID
                            assistantMsg:assistantMsg];
}

// Refactored helper — kicks off the streaming API call.
- (void)_launchAPIStreamWithMessages:(NSArray *)msgsForAPI
                          useTransit:(BOOL)useTransit
                          transitURL:(NSString *)transitURL
                            baseURL:(NSString *)baseURL
                            provider:(NSString *)provider
                             apiKey:(NSString *)apiKey
                              model:(NSString *)model
                        temperature:(CGFloat)temperature
                      conversationID:(NSString *)conversationID
                        assistantMsg:(Message *)assistantMsg
{
    [_networkService streamChatWithUseTransit:useTransit
                                    transitURL:transitURL
                                      baseURL:baseURL
                                      provider:provider
                                       apiKey:apiKey
                                        model:model
                                  temperature:temperature
                                     messages:msgsForAPI
                               conversationID:conversationID];
}

#pragma mark - NetworkServiceDelegate

- (void)networkService:(NetworkService *)svc
didReceiveChunkForConversationID:(NSString *)conversationID
                   fullText:(NSString *)fullText
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    [_conversation updateLastAssistantMessageContent:fullText];
    [[ConversationStore sharedStore] saveConversation:_conversation];
    [self _refreshLastRow];
}

- (void)networkService:(NetworkService *)svc
didFinishForConversationID:(NSString *)conversationID
                fullText:(NSString *)fullText
{
    if (![conversationID isEqualToString:_conversation.conversationID]) return;
    [_conversation updateLastAssistantMessageContent:fullText ?: @""];
    [[ConversationStore sharedStore] saveConversation:_conversation];
    [self _refreshLastRow];
    _composer.isStreaming = NO;
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
    [self _refreshLastRow];
    _composer.isStreaming = NO;
}

- (void)_refreshLastRow
{
    if ([_conversation.messages count] == 0) return;
    NSIndexPath *lastIdx = [NSIndexPath indexPathForRow:[_conversation.messages count] - 1
                                              inSection:0];
    // Reload the last row only — minimises visual churn.
    if ([_tableView indexPathForSelectedRow] || [_tableView numberOfSections] > 0) {
        [_tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:lastIdx]
                          withRowAnimation:UITableViewRowAnimationNone];
    } else {
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
