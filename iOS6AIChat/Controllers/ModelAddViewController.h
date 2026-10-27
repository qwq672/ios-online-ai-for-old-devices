//
//  ModelAddViewController.h
//  iOS6AIChat
//
//  v261025-9: full two-tier provider-entry form page (rewritten from the
//  v261025-8 single-model form). The user picks a format + template,
//  fills in the endpoint/key, adds multiple models (search + manual),
//  and saves a complete provider entry that the chat path resolves via
//  +[ModelManagementViewController resolvedConnectionForChat].
//

#import <UIKit/UIKit.h>

@interface ModelAddViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UITextFieldDelegate>

@end
