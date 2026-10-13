//
//  ChatViewController.h
//  iOS6AIChat
//

#import <UIKit/UIKit.h>
#import "Conversation.h"
#import "NetworkService.h"
#import "ComposerView.h"

extern NSString *const ChatViewControllerDidLoadConversationNotification;
extern NSString *const ChatViewControllerConversationIDKey;

@interface ChatViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               NetworkServiceDelegate,
                               ComposerViewDelegate>

@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic, retain) Conversation *conversation;
@property (nonatomic, retain) NetworkService *networkService;

- (void)loadConversation:(Conversation *)conversation;
- (void)startNewConversation;

@end
