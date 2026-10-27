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
// v261025-3: needed for [ModelManagementViewController savedModelList]
// in the send guard (model list empty check).
#import "ModelManagementViewController.h"
#import "DrawerViewController.h"
#import "Logger.h"
// v261025-8: base64 decode of the image-generation result.
#import "NSDataBase64.h"
// v261025-8: ComposerView imageGenEnabled + Message.isImageGenResult are
// used in the send path; Message.h comes via ChatMessageCell.h.

NSString *const ChatViewControllerDidLoadConversationNotification = @"ChatViewControllerDidLoadConversation";
NSString *const ChatViewControllerConversationIDKey               = @"conversationID";

static NSString *const kCellReuseID = @"ChatMessageCell";

#pragma mark - v261025-8: full-screen generated-image viewer

// Minimal tap-to-dismiss image viewer (iOS 6 compatible, MRC). Presented
// modally when the user taps a generated image bubble.
@interface GenImageViewerController : UIViewController
@property (nonatomic, retain) UIImage *image;
@end

@implementation GenImageViewerController
@synthesize image=_image;

- (void)loadView
{
    CGRect frame = [UIScreen mainScreen].applicationFrame;
    self.view = [[[UIView alloc] initWithFrame:frame] autorelease];
    self.view.backgroundColor = [UIColor blackColor];
    UIImageView *iv = [[[UIImageView alloc] initWithFrame:self.view.bounds] autorelease];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                           UIViewAutoresizingFlexibleHeight);
    iv.image = _image;
    iv.backgroundColor = [UIColor blackColor];
    [self.view addSubview:iv];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(_dismissTapped)];
    tap.numberOfTapsRequired = 1;
    [self.view addGestureRecognizer:tap];
    [tap release];
}

- (void)_dismissTapped
{
    // iOS 6-safe dismissal.
    [self dismissModalViewControllerAnimated:YES];
}

- (BOOL)wantsFullScreenLayout { return YES; }

- (void)dealloc
{
    [_image release];
    [super dealloc];
}

@end

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
// v261025-5: empty-state placeholder shown when the conversation has no
// messages (screenshot IMG_0452 showed the chat as a blank dark void
// with no clue what to do — fix is a centered hint label).
@property (nonatomic, retain) UIView *emptyPlaceholderView;
@property (nonatomic, retain) UILabel *emptyTitleLabel;
@property (nonatomic, retain) UILabel *emptyHintLabel;
// v261025-6: pending user-message-edit alert state. The alert (tag 600)
// asks the user to edit their original message; on save, the conv is
// truncated from this message onward and the (possibly edited) text is
// re-sent as a new user message + fresh AI placeholder.
@property (nonatomic, retain) NSString *pendingEditMessageID;
@property (nonatomic, retain) NSString *pendingEditOriginalText;
// v261025-8: image-generation in-flight state. The generate call is a
// synchronous NSURLConnection on a GCD background queue — unlike the chat
// stream it has no delegate, so completion is handled inside the block:
// success → write PNG to Documents/genimg + set message.generatedImagePath;
// failure → error text in the placeholder message. The assistant message
// is retained here because the user may switch conversations while the
// (up to 120s) request is running.
@property (nonatomic, assign) BOOL imageGenInProgress;
@property (nonatomic, assign) BOOL imageGenCancelled;
@property (nonatomic, retain) Message *imageGenAssistantMessage;
// v261025-10: plus-button slide-up menu (lazy-initialized on first show;
// reused thereafter).
@property (nonatomic, retain) ComposerPlusMenuView *plusMenu;
@end

@implementation ChatViewController

@synthesize tableView=_tableView, conversation=_conversation,
            networkService=_networkService, composer=_composer,
            lastKeyboardHeight=_lastKeyboardHeight,
            searchStatusView=_searchStatusView, searchStatusLabel=_searchStatusLabel,
            lastRowReloadTime=_lastRowReloadTime,
            emptyPlaceholderView=_emptyPlaceholderView,
            emptyTitleLabel=_emptyTitleLabel,
            emptyHintLabel=_emptyHintLabel,
            pendingEditMessageID=_pendingEditMessageID,
            pendingEditOriginalText=_pendingEditOriginalText,
            imageGenInProgress=_imageGenInProgress,
            imageGenCancelled=_imageGenCancelled,
            imageGenAssistantMessage=_imageGenAssistantMessage,
            plusMenu=_plusMenu;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        // v261025-5: title was hard-coded English "Chat" — screenshot
        // IMG_0457 showed the jarring mixed-language UI (English title
        // over Chinese content). Switch to the localized Chinese title
        // (matches the menu drawer title and the HistoryVC title style).
        self.title = NSLocalizedString(@"聊天", nil);
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
    // v261025-5: empty-state placeholder ivars.
    [_emptyTitleLabel release];
    [_emptyHintLabel release];
    [_emptyPlaceholderView release];
    // v261025-6: pending edit alert state.
    [_pendingEditMessageID release];
    [_pendingEditOriginalText release];
    // v261025-8: image-gen in-flight state (the block holds its own
    // retain on the message, so releasing here can't dangle it).
    [_imageGenAssistantMessage release];
    // v261025-10: plus-button slide-up menu (lazy-init, retained).
    [_plusMenu release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // v261025-4: Messages-style paper backdrop (dove-blue pinstriped
    // paper in light mode, charcoal grain in dark) — replaces the flat
    // pinstripe so the chat reads as a skeuomorphic "page".
    self.view.backgroundColor = [iOS6Theme chatBackgroundPatternColor];

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

    // v261025-5: empty-state placeholder — centered title + hint label,
    // shown when the conversation has no messages. Hidden by default;
    // _reload toggles its visibility based on _conversation.messages count.
    [self _buildEmptyPlaceholder];

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
    // v261025-10: refresh the plus-button badge + image-gen blue tint
    // (the old _refreshToggleVisuals was renamed and now also handles
    // the badge count + the input field's image-gen tint).
    if ([_composer respondsToSelector:@selector(refreshPlusButtonVisuals)]) {
        [_composer refreshPlusButtonVisuals];
    }
    [self _reload];
}

- (void)_applyTheme
{
    // v261025-4: paper-texture chat backdrop (cached pattern tile).
    self.view.backgroundColor = [iOS6Theme chatBackgroundPatternColor];
    _tableView.backgroundColor = [UIColor clearColor];
    // Composer draws its own metal-bar chrome in drawRect — leave its
    // backgroundColor clear or the bar gradient would be hidden.
    _composer.backgroundColor = [UIColor clearColor];
    _searchStatusView.backgroundColor = [iOS6Theme thinkingBackgroundColor];
    _searchStatusLabel.textColor = [iOS6Theme secondaryTextColor];
    // v261025-5: refresh the empty-state placeholder colors so they match
    // the new theme (light/dark). Nil-guarded: _themeChanged can fire
    // before viewDidLoad on certain launch orderings, in which case
    // _emptyTitleLabel is still nil.
    if (_emptyTitleLabel) {
        _emptyTitleLabel.textColor = [iOS6Theme secondaryTextColor];
        _emptyTitleLabel.shadowColor = [iOS6Theme isDarkMode]
            ? [UIColor colorWithWhite:0.0f alpha:0.4f]
            : [UIColor colorWithWhite:1.0f alpha:0.7f];
    }
    if (_emptyHintLabel) {
        _emptyHintLabel.textColor = [iOS6Theme secondaryTextColor];
    }
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
    // v261025-8: also cancel a pending image generation — its completion
    // block checks the flag and discards the result.
    if (_imageGenInProgress) {
        _imageGenCancelled = YES;
        _imageGenInProgress = NO;
        self.imageGenAssistantMessage = nil;
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
    [self _updateEmptyPlaceholder];
}

// v261025-5: empty-state placeholder. The chat view used to show a blank
// dark void when there were no messages (screenshot IMG_0452). Now it
// shows a centered title + hint label so the user knows what to do.
- (void)_buildEmptyPlaceholder
{
    if (_emptyPlaceholderView) return;   // already built
    CGRect frame = self.view.bounds;
    _emptyPlaceholderView = [[UIView alloc] initWithFrame:frame];
    _emptyPlaceholderView.backgroundColor = [UIColor clearColor];
    _emptyPlaceholderView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                              UIViewAutoresizingFlexibleHeight);
    _emptyPlaceholderView.hidden = YES;
    [self.view addSubview:_emptyPlaceholderView];

    // Big muted title centered in the upper third.
    CGFloat titleW = frame.size.width - 32;
    _emptyTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, frame.size.height * 0.30, titleW, 36)];
    _emptyTitleLabel.text = NSLocalizedString(@"开始新对话", nil);
    _emptyTitleLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:22]];
    _emptyTitleLabel.textColor = [iOS6Theme secondaryTextColor];
    _emptyTitleLabel.textAlignment = NSTextAlignmentCenter;
    _emptyTitleLabel.backgroundColor = [UIColor clearColor];
    _emptyTitleLabel.shadowColor = [iOS6Theme isDarkMode]
        ? [UIColor colorWithWhite:0.0f alpha:0.4f]
        : [UIColor colorWithWhite:1.0f alpha:0.7f];
    _emptyTitleLabel.shadowOffset = CGSizeMake(0, 1);
    _emptyTitleLabel.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                         UIViewAutoresizingFlexibleTopMargin |
                                         UIViewAutoresizingFlexibleBottomMargin);
    [_emptyPlaceholderView addSubview:_emptyTitleLabel];

    // Hint line right below the title.
    _emptyHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, frame.size.height * 0.30 + 38, titleW, 22)];
    _emptyHintLabel.text = NSLocalizedString(@"在下方输入框输入消息，或点击右上角 + 新建会话", nil);
    _emptyHintLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
    _emptyHintLabel.textColor = [iOS6Theme secondaryTextColor];
    _emptyHintLabel.alpha = 0.85f;
    _emptyHintLabel.textAlignment = NSTextAlignmentCenter;
    _emptyHintLabel.backgroundColor = [UIColor clearColor];
    _emptyHintLabel.numberOfLines = 0;
    _emptyHintLabel.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                        UIViewAutoresizingFlexibleTopMargin |
                                        UIViewAutoresizingFlexibleBottomMargin);
    [_emptyPlaceholderView addSubview:_emptyHintLabel];
}

- (void)_updateEmptyPlaceholder
{
    BOOL hasMessages = (_conversation && [_conversation.messages count] > 0);
    if (_emptyPlaceholderView) {
        _emptyPlaceholderView.hidden = hasMessages;
    }
    // Bring the placeholder ABOVE the table view when shown (so it's
    // tappable for the hint area), but BELOW the composer + status bar.
    if (!hasMessages && _emptyPlaceholderView) {
        [self.view bringSubviewToFront:_emptyPlaceholderView];
        // Composer needs to stay above so the user can still type.
        if (_composer) [self.view bringSubviewToFront:_composer];
        if (_searchStatusView) [self.view bringSubviewToFront:_searchStatusView];
    }
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
            imageGen:(BOOL)imageGen
{
    [self _sendUserMessage:text images:images deepThinking:deepThinking webSearch:webSearch imageGen:imageGen];
}

// v261025-3: send button morphed into stop button while streaming.
// Hand off to NetworkService.stopGenerating — it cancels the in-flight
// connection but PRESERVES the accumulated text, then fires the normal
// didFinish delegate path. The composer's isStreaming flag will be
// cleared when didFinish/didFail is dispatched.
- (void)composerDidTapStop:(ComposerView *)composer
{
    [[Logger sharedLogger] info:@"CHAT ⊘ user tapped stop — calling stopGenerating"];
    // v261025-8: image-gen stop — flag the cancel; the completion block
    // discards the result and resets the composer.
    if (_imageGenInProgress) {
        [[Logger sharedLogger] info:@"CHAT ⊘ image-gen cancelled by user"];
        _imageGenCancelled = YES;
        return;
    }
    if (!_networkService) {
        // Defensive: no service to stop. Make sure the composer is
        // visually reset (a desync would otherwise leave it stuck).
        _composer.isStreaming = NO;
        return;
    }
    // NetworkService.stopGenerating is synchronous (it does NOT
    // dispatch_async) — it will fire didFinish on this same (main)
    // thread before returning. That guarantees _composer.isStreaming
    // is cleared by the time this method returns.
    [_networkService stopGenerating];
}

- (void)composerDidChangeHeight:(ComposerView *)composer
{
    [self _adjustForComposerHeight];
}

#pragma mark - v261025-10 ComposerPlusMenuDelegate

// The plus button on the composer was tapped — lazily create the menu
// and show it as an overlay over the chat root view.
- (void)composerDidTapPlusButton:(ComposerView *)composer
{
    if (!_plusMenu) {
        _plusMenu = [[ComposerPlusMenuView alloc] initWithFrame:CGRectZero];
        _plusMenu.delegate = self;
    }
    // Refresh inline data + show.
    [_plusMenu refresh];
    [_plusMenu showInView:self.view];
}

// Toggle state changed from inside the menu — refresh the composer's
// plus-button badge + image-gen blue tint.
- (void)plusMenu:(ComposerPlusMenuView *)menu
  deepThinkingEnabledChanged:(BOOL)enabled
{
    (void)enabled;
    [_composer refreshPlusButtonVisuals];
}
- (void)plusMenu:(ComposerPlusMenuView *)menu
  webSearchEnabledChanged:(BOOL)enabled
{
    (void)enabled;
    [_composer refreshPlusButtonVisuals];
}
- (void)plusMenu:(ComposerPlusMenuView *)menu
  imageGenEnabledChanged:(BOOL)enabled
{
    (void)enabled;
    // Refresh the composer (badge count + input field blue tint).
    [_composer refreshPlusButtonVisuals];
    // Reload the toggles section of the menu itself so DT/Web grey out
    // when image-gen turns ON (and un-grey when it turns OFF).
    [menu refresh];
}

// Action callbacks — wire to existing ChatVC flows.
- (void)plusMenuDidTapImageUpload:(ComposerPlusMenuView *)menu
{
    // ComposerView owns the UIImagePickerController delegate + the
    // _pendingImages array; just hand the picker presentation over.
    [_composer presentImagePickerFromViewController:self];
}

- (void)plusMenuDidTapClearConversation:(ComposerPlusMenuView *)menu
{
    // Confirm before clearing the active conversation.
    if (!_conversation || _conversation.messages.count == 0) {
        // Nothing to clear — just dismiss (already auto-dismissed by menu,
        // but show a hint alert for UX).
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"当前对话为空", nil)
                  message:nil
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        return;
    }
    UIAlertView *av = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"清空当前对话?", nil)
              message:NSLocalizedString(@"所有消息将删除且不可撤销。", nil)
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
    otherButtonTitles:NSLocalizedString(@"清空", nil), nil] autorelease];
    [av setTag:750];
    [av show];
}

- (void)plusMenuDidTapMoreModels:(ComposerPlusMenuView *)menu
{
    // Push the model management VC.
    ModelManagementViewController *vc = [[[ModelManagementViewController alloc] init] autorelease];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)plusMenuDidTapMoreCharacters:(ComposerPlusMenuView *)menu
{
    // Push the character management VC.
    CharacterManagementViewController *vc = [[[CharacterManagementViewController alloc] init] autorelease];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)plusMenu:(ComposerPlusMenuView *)menu
  didSelectChatModelID:(NSString *)modelID
{
    // Active model was already persisted by the menu; just log + refresh
    // the composer's empty placeholder (which may show the model name).
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"CHAT ⊕ switched chat model → %@", modelID]];
    [self _updateEmptyPlaceholder];
}

- (void)plusMenu:(ComposerPlusMenuView *)menu
  didSelectImageModelID:(NSString *)modelID
{
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"CHAT ⊕ switched image model → %@", modelID]];
}

- (void)plusMenu:(ComposerPlusMenuView *)menu
  didSelectCharacterName:(NSString *)name
{
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"CHAT ⊕ switched character → %@", name]];
    // Update the empty placeholder's subtitle to reflect the new character.
    [self _updateEmptyPlaceholder];
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

// v261025-8: image-generation send path. Mirrors _sendUserMessage: the
// prompt becomes the user message, an assistant placeholder shows
// "正在生成图片…", then a GCD block runs the synchronous generate call.
// Success → PNG written to Documents/genimg/<uuid>.png and the message's
// generatedImagePath is set (the cell then renders the image). Failure →
// the error text lands in the placeholder so the user sees why.
- (void)_generateImageWithPrompt:(NSString *)prompt
{
    if (!prompt || prompt.length == 0) return;

    if (!_conversation) {
        Conversation *c = [[ConversationStore sharedStore] createNewConversation];
        self.conversation = c;
    }

    Message *userMsg = [Message messageWithRole:MessageRoleUser content:prompt];
    [_conversation appendMessage:userMsg];
    Message *assistantMsg = [Message messageWithRole:MessageRoleAssistant
                                              content:NSLocalizedString(@"🎨 正在生成图片…", nil)];
    [_conversation appendMessage:assistantMsg];
    [[ConversationStore sharedStore] saveConversation:_conversation];
    [_tableView reloadData];
    [self _scrollToBottomAnimated:YES];
    [self _updateEmptyPlaceholder];

    _composer.isStreaming = YES;
    _imageGenInProgress = YES;
    _imageGenCancelled = NO;
    self.imageGenAssistantMessage = assistantMsg;

    NSDictionary *iconn = [ModelManagementViewController resolvedConnectionForImageGen];
    NSDictionary *settings = [SettingsViewController loadSettings];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *imgModel = [iconn objectForKey:@"model"];
    NSString *provider = [iconn objectForKey:@"template"];
    NSString *baseURL  = [iconn objectForKey:@"baseURL"];
    NSString *apiKey   = [iconn objectForKey:@"apiKey"];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"imggen promptLen=%lu provider=%@ model=%@ transit=%d",
        (unsigned long)prompt.length, provider ?: @"?",
        imgModel ?: @"(unset)", (int)useTransit]];

    // v261025-2 lesson: capture everything the block needs as values —
    // never read self->_conversation at execution time.
    NSString *capturedPrompt = [prompt copy];
    NSString *capturedModel = [imgModel copy];
    NSString *capturedProvider = [provider copy];
    NSString *capturedBaseURL = [baseURL copy];
    NSString *capturedAPIKey = [apiKey copy];
    NSString *capturedTransitURL = [transitURL copy];
    BOOL capturedUseTransit = useTransit;
    // assistantMsg is owned by _conversation.messages; retain so a
    // conversation switch mid-request can't free it under the block.
    Message *capturedMsg = [assistantMsg retain];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // The synchronous generate call (120s timeout inside) — safe on a
        // background queue. NOTE: reading self->_networkService captures
        // self (retained by the block under MRC) — ChatVC is the nav root
        // and outlives the queue, same pattern as the Tavily pre-search.
        NSError *err = nil;
        NSString *dataURL = [self->_networkService
            generateImageWithPrompt:capturedPrompt
                              model:capturedModel
                               size:@"1024x1024"
                          useTransit:capturedUseTransit
                          transitURL:capturedTransitURL
                            baseURL:capturedBaseURL
                           provider:capturedProvider
                             apiKey:capturedAPIKey
                               error:&err];

        // Decode "data:image/png;base64,...." → NSData.
        NSData *pngData = nil;
        if ([dataURL isKindOfClass:[NSString class]] && dataURL.length > 0) {
            NSRange comma = [dataURL rangeOfString:@","];
            if (comma.location != NSNotFound && comma.location + 1 < dataURL.length) {
                NSString *b64 = [dataURL substringFromIndex:comma.location + 1];
                pngData = [NSData dataFromBase64String:b64];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // USER-CANCELLED (stop button) → discard the result entirely.
            // SUPERSEDED (user switched conversations / new chat while the
            // request was in flight) → still WRITE the result into the
            // message + save its owning conversation, just don't touch the
            // active UI. The user finds the image when they switch back
            // (the "正在生成图片…" placeholder becomes the image on reload)
            // instead of a forever-loading bubble.
            if (self->_imageGenCancelled) {
                [capturedPrompt release];
                [capturedModel release];
                [capturedProvider release];
                [capturedBaseURL release];
                [capturedAPIKey release];
                [capturedTransitURL release];
                [capturedMsg release];
                self->_imageGenInProgress = NO;
                self->_composer.isStreaming = NO;
                self->_imageGenCancelled = NO;
                return;
            }
            BOOL superseded = (self->_imageGenAssistantMessage != capturedMsg);

            if (pngData && pngData.length > 0) {
                // Write the PNG under Documents/genimg/<uuid>.png.
                NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                    NSUserDomainMask, YES);
                if ([dirs count] > 0) {
                    NSString *genDir = [[dirs objectAtIndex:0]
                        stringByAppendingPathComponent:@"genimg"];
                    // iOS 5+ API — 3GS on iOS 6 has it.
                    [[NSFileManager defaultManager]
                        createDirectoryAtPath:genDir
                        withIntermediateDirectories:YES
                         attributes:nil
                              error:NULL];
                    NSString *fileName = [NSString stringWithFormat:@"gen-%@.png",
                                           [[NSUUID UUID] UUIDString]];
                    NSString *path = [genDir stringByAppendingPathComponent:fileName];
                    if ([pngData writeToFile:path atomically:YES]) {
                        capturedMsg.generatedImagePath = fileName;
                        // Keep the prompt as the bubble's caption.
                        capturedMsg.content = capturedPrompt;
                        [[Logger sharedLogger] info:[NSString stringWithFormat:
                            @"imggen ✓ wrote %@ (%lu bytes)",
                            fileName, (unsigned long)pngData.length]];
                    } else {
                        capturedMsg.content = NSLocalizedString(@"图片保存失败（磁盘写入错误）", nil);
                        [[Logger sharedLogger] warn:@"imggen ✗ writeToFile failed"];
                    }
                } else {
                    capturedMsg.content = NSLocalizedString(@"图片保存失败（无法定位 Documents）", nil);
                }
            } else {
                NSString *reason = [err localizedDescription];
                capturedMsg.content = [NSString stringWithFormat:@"%@%@",
                    NSLocalizedString(@"生图失败", nil),
                    ([reason isKindOfClass:[NSString class]] && reason.length > 0)
                        ? [NSString stringWithFormat:@": %@", reason] : @"（未知错误）"];
                [[Logger sharedLogger] warn:[NSString stringWithFormat:
                    @"imggen ✗ %@", reason ?: @"(no error)"]];
            }

            // Persist + refresh. capturedMsg may no longer be in the ACTIVE
            // conversation (user switched) — find its owner and save that.
            ConversationStore *store = [ConversationStore sharedStore];
            Conversation *owner = nil;
            for (Conversation *c in [store conversations]) {
                if ([c.messages containsObject:capturedMsg]) { owner = c; break; }
            }
            if (owner) [store saveConversation:owner];

            if (!superseded) {
                // Still the active conversation → refresh the UI in place.
                [ChatMessageCell invalidateHeightCache];
                [self->_tableView reloadData];
                [self _scrollToBottomAnimated:YES];
                self->_imageGenInProgress = NO;
                self->_composer.isStreaming = NO;
                self.imageGenAssistantMessage = nil;
            } else {
                // The _teardownActiveStream already reset the composer when
                // the conversation switched; only reset the progress flag.
                self->_imageGenInProgress = NO;
                [[Logger sharedLogger] info:@"imggen ✓ result saved to background conversation (superseded)"];
            }

            [capturedPrompt release];
            [capturedModel release];
            [capturedProvider release];
            [capturedBaseURL release];
            [capturedAPIKey release];
            [capturedTransitURL release];
            [capturedMsg release];
        });
    });
}

- (void)_sendUserMessage:(NSString *)text
{
    [self _sendUserMessage:text images:nil deepThinking:[ComposerView deepThinkingEnabled] webSearch:[ComposerView webSearchEnabled] imageGen:[ComposerView imageGenEnabled]];
}

- (void)_sendUserMessage:(NSString *)text images:(NSArray *)images deepThinking:(BOOL)deepThinking webSearch:(BOOL)webSearch imageGen:(BOOL)imageGen
{
    // ---- v261025-8: image-generation path ----
    // The 生图 toggle routes the text to the image API via the ACTIVE
    // kind="image" model entry. Vision attachments / deep thinking / web
    // search don't apply (the composer already disables their buttons).
    if (imageGen) {
        if (images && [images count] > 0) {
            UIAlertView *av = [[[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"生图模式不支持附带图片", nil)
                      message:NSLocalizedString(@"请先删除附图，或关闭生图开关。", nil)
                     delegate:nil
                cancelButtonTitle:NSLocalizedString(@"好", nil)
                otherButtonTitles:nil] autorelease];
            [av show];
            _composer.isStreaming = NO;
            return;
        }
        NSDictionary *iconn = [ModelManagementViewController resolvedConnectionForImageGen];
        NSString *imgModel = [iconn objectForKey:@"model"];
        if (![imgModel isKindOfClass:[NSString class]] || imgModel.length == 0) {
            UIAlertView *av = [[[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"未添加生图模型", nil)
                      message:NSLocalizedString(@"请到 模型管理 → 添加模型，把模型类型选为「生图模型」（如智谱 cogview-3plus）。", nil)
                     delegate:nil
                cancelButtonTitle:NSLocalizedString(@"好", nil)
                otherButtonTitles:nil] autorelease];
            [av show];
            _composer.isStreaming = NO;
            return;
        }
        [self _generateImageWithPrompt:text];
        return;
    }

    // v261025-3: send guard. If transit is ON but useServerModel is OFF
    // (i.e. user supplies their own model in the body), and the local
    // saved model list is empty AND SettingsKeyModel is unset, the
    // outgoing request would have no model field. Block this earlier
    // with a clear prompt instead of letting the upstream return 400.
    {
        NSDictionary *settings = [SettingsViewController loadSettings];
        BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
        BOOL useServerModel = [[NSUserDefaults standardUserDefaults] boolForKey:@"useServerModel"];
        if (useTransit && !useServerModel) {
            NSArray *saved = [ModelManagementViewController savedModelList];
            NSString *cur = [settings objectForKey:SettingsKeyModel];
            BOOL hasModel = (cur && cur.length > 0) || [saved count] > 0;
            if (!hasModel) {
                UIAlertView *av = [[[UIAlertView alloc]
                    initWithTitle:NSLocalizedString(@"请先添加模型", nil)
                          message:NSLocalizedString(@"模型列表为空。请到 模型管理 添加至少一个模型，或开启\"中转自带模型\"开关。", nil)
                         delegate:nil
                cancelButtonTitle:NSLocalizedString(@"好", nil)
                otherButtonTitles:nil] autorelease];
                [av show];
                // Defensive: clear isStreaming — the send button should
                // not visually stay in the "stop" state when we never
                // actually started streaming.
                _composer.isStreaming = NO;
                return;
            }
        }
    }

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
    // v261025-8 (bug #8 fix): hide the "开始新对话" placeholder NOW — the
    // user's first message + AI placeholder are already in the array, but
    // _updateEmptyPlaceholder was only called from _reload, so the big
    // title + hint label kept floating over the streaming reply.
    [self _updateEmptyPlaceholder];

    // Disable composer while streaming.
    _composer.isStreaming = YES;

    // Read settings.
    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit       = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL  = [settings objectForKey:SettingsKeyTransitURL];
    // v261025-7: provider / baseURL / apiKey / model now come from the
    // ACTIVE model entry (merged with global settings defaults) via
    // +resolvedConnectionForChat — this is what makes per-entry provider
    // profiles (the two-tier ModelManagement) actually drive the chat.
    NSDictionary *conn   = [ModelManagementViewController resolvedConnectionForChat];
    NSString *baseURL    = [conn objectForKey:@"baseURL"];
    NSString *provider   = [conn objectForKey:@"template"];
    NSString *apiKey     = [conn objectForKey:@"apiKey"];
    NSString *model      = [conn objectForKey:@"model"];
    CGFloat temperature  = [[settings objectForKey:SettingsKeyTemperature] floatValue];

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
        // v261025-2: capture EVERYTHING the GCD block needs as plain
        // values. The old code captured `systemPrompt` / `provider` /
        // `baseURL` / `apiKey` / `model` / `temperature` / `assistantMsg`
        // by reference (block retain is fine) but ALSO captured
        // `_conversation.conversationID` BY IVAR READ — i.e. the block
        // re-read self->_conversation at execution time. If the user
        // switched conversations during the (up-to-seconds) Tavily
        // search, the AI stream was launched against the NEW
        // conversation's messages (which didn't contain the userMsg /
        // assistantMsg we just appended to the OLD one) — producing
        // corrupted / overwritten replies. Capture the ID now, then
        // pass it down explicitly and also use it as a guard.
        NSString *capturedText = [text copy];
        NSString *capturedTavilyKey = [tavilyKey copy];
        NSInteger capturedMaxResults = maxResults;
        BOOL capturedUseTransit = useTransit;
        NSString *capturedTransitURL = [transitURL copy];
        NSString *capturedConversationID = [_conversation.conversationID copy];
        Conversation *capturedConversation = [_conversation retain];
        NSString *capturedSystemPrompt = [systemPrompt copy];
        NSString *capturedProvider = [provider copy];
        NSString *capturedBaseURL = [baseURL copy];
        NSString *capturedApiKey = [apiKey copy];
        NSString *capturedModel = [model copy];
        CGFloat capturedTemperature = temperature;
        BOOL capturedDeepThinking = deepThinking;
        // assistantMsg is owned by _conversation.messages; retaining it
        // here keeps it alive even if the user deletes the conversation
        // mid-search.
        Message *capturedAssistantMsg = [assistantMsg retain];
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
                // v261025-2: if the user switched conversations during the
                // search, abort — the assistantMsg / userMsg we appended
                // belong to a different conversation now and re-launching
                // the stream would corrupt the new conversation.
                if (![capturedConversationID isEqualToString:_conversation.conversationID]) {
                    [[Logger sharedLogger] warn:@"ChatVC search completed after conversation switch — discarding results"];
                    [resultsCopy release];
                    [errCopy release];
                    [self _hideSearchStatus];
                    return;
                }
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
                                          systemPrompt:capturedSystemPrompt
                                            useTransit:capturedUseTransit
                                            transitURL:capturedTransitURL
                                              baseURL:capturedBaseURL
                                              provider:capturedProvider
                                               apiKey:capturedApiKey
                                                model:capturedModel
                                          temperature:capturedTemperature
                                      conversationID:capturedConversationID
                                        assistantMsg:capturedAssistantMsg
                                          webSearch:YES
                                          tavilyKey:capturedTavilyKey
                                      tavilyMaxResults:capturedMaxResults
                                        deepThinking:capturedDeepThinking
                                       preSearchResults:ctx];
                } else {
                    // Pre-search failed — proceed without search context.
                    [self _showSearchStatus:[NSString stringWithFormat:@"⚠️ 搜索失败: %@", [errCopy localizedDescription] ?: @"无结果"]];
                    // Hide the warning after 2 seconds.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self _hideSearchStatus];
                    });
                    [self _launchAIStreamWithMessages:nil
                                          systemPrompt:capturedSystemPrompt
                                            useTransit:capturedUseTransit
                                            transitURL:capturedTransitURL
                                              baseURL:capturedBaseURL
                                              provider:capturedProvider
                                               apiKey:capturedApiKey
                                                model:capturedModel
                                          temperature:capturedTemperature
                                      conversationID:capturedConversationID
                                        assistantMsg:capturedAssistantMsg
                                          webSearch:YES
                                          tavilyKey:capturedTavilyKey
                                      tavilyMaxResults:capturedMaxResults
                                        deepThinking:capturedDeepThinking
                                       preSearchResults:nil];
                }
                [resultsCopy release];
                [errCopy release];
            });
            } // @autoreleasepool
        });
        // v261025-2: balance all the per-search retains here so the
        // cleanup lives next to the capture site. The block retains
        // these for the duration of the GCD work; this outer release
        // balances the +1 from [x copy] / [x retain] above.
        [capturedText release];
        [capturedTavilyKey release];
        [capturedTransitURL release];
        [capturedConversationID release];
        [capturedConversation release];
        [capturedSystemPrompt release];
        [capturedProvider release];
        [capturedBaseURL release];
        [capturedApiKey release];
        [capturedModel release];
        [capturedAssistantMsg release];
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
    // v261025-6: before truncating the message, snapshot the current AI
    // response (content + thinking) into the message's variants array. This
    // lets the user navigate back to this response via the ‹ 1/N › pager
    // after the new response streams in.
    // Only snapshot if there's actual content (skip the "..." placeholder
    // case where the user is regenerating an empty/failed response).
    NSString *currentContent = message.content;
    if (currentContent.length > 0 && ![currentContent isEqualToString:@"…"]) {
        NSArray *newVariants = [Message pushCurrentLiveSnapshotIntoVariants:message.variants
                                                                      content:currentContent
                                                                     thinking:message.thinking];
        message.variants = newVariants;
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
                webSearch:[ComposerView webSearchEnabled]
                  imageGen:[ComposerView imageGenEnabled]];
}

// v261025-8: tap a generated image → full-screen viewer.
- (void)chatCellDidTapGeneratedImage:(ChatMessageCell *)cell message:(Message *)message
{
    if (!message || ![message isImageGenResult]) return;
    NSString *path = [Message absolutePathForGeneratedImage:message.generatedImagePath];
    if (!path) return;
    // Prefer the shared decoded cache (gImageCache) — same key the cell
    // used — so the modal opens instantly; fall back to the file.
    // (NO @try — ObjC exceptions are disabled on cctools-port armv7;
    // imageWithContentsOfFile: never throws, it just returns nil.)
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) {
        [[Logger sharedLogger] warn:@"ChatVC gen-image viewer — image file missing"];
        return;
    }
    GenImageViewerController *viewer = [[[GenImageViewerController alloc] init] autorelease];
    viewer.image = img;
    [self presentModalViewController:viewer animated:YES];
}

// v261025-6: user-message edit — pops an alert pre-filled with the user's
// text. On save, truncates the conversation from this message onward and
// re-sends (possibly edited) text. The conversation's messages array gets
// shortened, and a fresh AI placeholder is appended as part of _sendUserMessage.
- (void)chatCell:(ChatMessageCell *)cell didTapEditUserMessage:(Message *)message
{
    if (!message || !message.isUser) return;
    if (_composer.isStreaming) {
        [[Logger sharedLogger] warn:@"ChatVC edit-user ignored — still streaming"];
        return;
    }
    // Stash the message being edited + the conversation so the alert handler
    // can find them. We use a tag to distinguish edit alerts from others.
    UIAlertView *av = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"编辑消息", nil)
              message:NSLocalizedString(@"修改后将以新消息发送（旧消息会被覆盖）。", nil)
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
    otherButtonTitles:NSLocalizedString(@"发送", nil), nil] autorelease];
    if ([av respondsToSelector:@selector(setAlertViewStyle:)]) {
        [av setAlertViewStyle:UIAlertViewStylePlainTextInput];
    }
    // Pre-fill the text field with the user's original text.
    if ([av respondsToSelector:@selector(textFieldAtIndex:)]) {
        // Note: textFieldAtIndex: is only valid AFTER the alert view has
        // been added to a window (i.e. after -show). Setting .text here is
        // a no-op; we use the delegate method didPresentAlertView: below
        // to pre-fill once the text field is actually available.
    }
    [av setTag:600];
    // Stash the message ID + original text via the synthesized setters
    // (which release the previous values). The alert handler resolves the
    // message by ID from the conversation's messages array.
    self.pendingEditMessageID = message.messageID;
    self.pendingEditOriginalText = message.content;
    [av show];
}

// v261025-6: variant pager — navigate to prev/next variant. The delegate
// (ChatViewController) updates the message's currentVariantIndex and tells
// the table to reload the affected row.
- (void)chatCell:(ChatMessageCell *)cell
   didTapVariantArrow:(Message *)message
              direction:(NSInteger)direction
{
    if (!message || !message.isAssistant) return;
    if (![message.variants isKindOfClass:[NSArray class]] ||
        [message.variants count] == 0) {
        return;
    }
    // total = variants.count + 1 (the +1 is the LIVE/current).
    // index: -1 = LIVE (the rightmost); 0..N-1 = saved variants.
    NSInteger total = (NSInteger)[message.variants count] + 1;
    // Current displayed position (0-based from left, LIVE = total-1).
    NSInteger currentPos = (message.currentVariantIndex < 0)
                            ? (total - 1)
                            : message.currentVariantIndex;
    NSInteger newPos = currentPos + direction;
    if (newPos < 0) newPos = 0;       // clamp at first variant
    if (newPos >= total) newPos = total - 1;  // clamp at last (live)
    // Convert back to currentVariantIndex: -1 = LIVE, else newPos.
    message.currentVariantIndex = (newPos == total - 1) ? -1 : newPos;
    // Invalidate the height cache for this message so the row re-sizes
    // (different variant might have different content length).
    [ChatMessageCell flushCaches];
    // Reload the affected row.
    NSInteger rowIdx = (NSInteger)[_conversation.messages indexOfObject:message];
    if (rowIdx != NSNotFound && rowIdx < (NSInteger)[_tableView numberOfRowsInSection:0]) {
        [_tableView beginUpdates];
        [_tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:
                                            [NSIndexPath indexPathForRow:rowIdx inSection:0]]
                        withRowAnimation:UITableViewRowAnimationNone];
        [_tableView endUpdates];
    }
    // Save the variant-index change to disk so it persists.
    [[ConversationStore sharedStore] saveConversation:_conversation];
}

- (void)chatCell:(ChatMessageCell *)cell didTapCopy:(Message *)message
{
    if (!message) return;
    // v261025-6: copy the DISPLAYED content (which may be a variant snapshot,
    // not the live content).
    NSString *toCopy = [Message displayedContentForMessage:message] ?: @"";
    [[UIPasteboard generalPasteboard] setString:toCopy];
}

#pragma mark - UIAlertViewDelegate (v261025-6 user-message edit)

// Pre-fill the alert's text field with the user's original message text
// once the alert has been presented (the text field is only accessible
// after -show lands the alert on screen).
- (void)didPresentAlertView:(UIAlertView *)alertView
{
    if (alertView.tag == 600 && _pendingEditOriginalText) {
        if ([alertView respondsToSelector:@selector(textFieldAtIndex:)]) {
            UITextField *tf = [alertView textFieldAtIndex:0];
            if ([tf isKindOfClass:[UITextField class]]) {
                tf.text = _pendingEditOriginalText;
            }
        }
    }
}

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    // v261025-10: tag 750 = 清空当前对话确认.
    if (alertView.tag == 750) {
        if (buttonIndex != 1) return;   // 取消
        if (_conversation) {
            [_conversation.messages removeAllObjects];
            [ConversationStore saveConversation:_conversation];
            [self _reload];
            [self _updateEmptyPlaceholder];
            [[Logger sharedLogger] info:@"CHAT ⊕ cleared current conversation"];
        }
        return;
    }
    if (alertView.tag != 600) return;
    // buttonIndex 0 = 取消, 1 = 发送.
    if (buttonIndex != 1) {
        // Cancel — clear pending state.
        self.pendingEditMessageID = nil;
        self.pendingEditOriginalText = nil;
        return;
    }
    // Send — read the text field, find the message, truncate from it, re-send.
    NSString *editedText = nil;
    if ([alertView respondsToSelector:@selector(textFieldAtIndex:)]) {
        UITextField *tf = [alertView textFieldAtIndex:0];
        if ([tf isKindOfClass:[UITextField class]]) {
            editedText = [tf.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    if (!editedText || editedText.length == 0) {
        // Empty edit — treat as cancel.
        self.pendingEditMessageID = nil;
        self.pendingEditOriginalText = nil;
        return;
    }
    // Find the message by ID.
    Message *targetMsg = nil;
    NSInteger targetIdx = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)[_conversation.messages count]; i++) {
        Message *m = [_conversation.messages objectAtIndex:i];
        if ([m isKindOfClass:[Message class]] &&
            [m.messageID isEqualToString:_pendingEditMessageID]) {
            targetMsg = m;
            targetIdx = i;
            break;
        }
    }
    if (!targetMsg || targetIdx == NSNotFound) {
        // Message no longer exists — clear state and bail.
        self.pendingEditMessageID = nil;
        self.pendingEditOriginalText = nil;
        return;
    }
    // Truncate the conversation from targetIdx onward (drop the user msg + AI
    // reply + everything after).
    NSMutableArray *kept = [NSMutableArray array];
    for (NSInteger i = 0; i < targetIdx; i++) {
        [kept addObject:[_conversation.messages objectAtIndex:i]];
    }
    // Replace the messages array.
    [_conversation.messages removeAllObjects];
    for (Message *m in kept) {
        [_conversation.messages addObject:m];
    }
    // Save the truncated state to disk so the old AI reply isn't resurrected
    // on next launch.
    [[ConversationStore sharedStore] saveConversation:_conversation];
    // Re-send the edited text as a fresh user message + AI placeholder.
    [self _sendUserMessage:editedText
                   images:targetMsg.images
             deepThinking:[ComposerView deepThinkingEnabled]
               webSearch:[ComposerView webSearchEnabled]
                 imageGen:[ComposerView imageGenEnabled]];
    // Clear pending state.
    self.pendingEditMessageID = nil;
    self.pendingEditOriginalText = nil;
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
