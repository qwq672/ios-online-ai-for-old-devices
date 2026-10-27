//
//  CharacterAddViewController.h
//  iOS6AIChat
//
//  v261025-7: full character-add form page (replaces the old two-step
//  alert flow). A proper form with a name field AND a multi-line prompt
//  text view — writing a long system prompt into a one-line alert field
//  was miserable.
//
//  Also serves as the EDIT page when initialized with an existing
//  character dict ({name, prompt}).
//

#import <UIKit/UIKit.h>

@interface CharacterAddViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UITextViewDelegate,
                               UITextFieldDelegate>

// Init with an existing character dict ({name, prompt}) to EDIT it.
// Init plain (init) to ADD a new one.
- (id)initWithCharacter:(NSDictionary *)character;

@end
