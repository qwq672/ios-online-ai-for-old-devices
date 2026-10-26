//
//  ModelAddViewController.h
//  iOS6AIChat
//
//  v261025-7: full model-add form page (replaces the old single-field
//  alert). The user picks a provider, fills in the endpoint/key/model,
//  and saves a complete "provider profile" entry that the chat path
//  resolves via +[ModelManagementViewController resolvedConnectionForChat].
//
//  Also serves as the EDIT page when initialized with an existing entry.
//

#import <UIKit/UIKit.h>

@interface ModelAddViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UITextFieldDelegate>

// Init with an existing entry dict ({id, provider, baseURL, apiKey,
// displayName, ...}) to EDIT it. Init plain (init) to ADD a new one.
- (id)initWithEntry:(NSDictionary *)entry;

@end
