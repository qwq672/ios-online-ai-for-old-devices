//
//  CharacterAddViewController.m
//  iOS6AIChat
//
//  v261025-7: full character-add form page.
//
//    Section 0 — 角色: 角色名 row (single-line text field).
//    Section 1 — 提示词: one tall row embedding a multi-line UITextView
//                (~200pt) with a Done toolbar to drop the keyboard.
//    Section 2 — 保存: one blue row. Validates the name, saves via
//                CharacterManagementViewController's persistence helpers,
//                pops back.
//
//  Edit mode: fields pre-filled from the character passed to
//  -initWithCharacter:; saving replaces it in place (matched by name).
//
//  Memory model: MRC. The text view is created via alloc/init, retained
//  by the ivar AND its cell's content view; released once in dealloc.
//  (See ChatMessageCell's v261025-7 writeup for why convenience-
//  constructor assignments MUST retain.)
//

#import "CharacterAddViewController.h"
#import "iOS6Theme.h"
#import "CharacterManagementViewController.h"
#import "Logger.h"
// v261025-7: needed for layer.borderColor / cornerRadius on the prompt view.
#import <QuartzCore/QuartzCore.h>

static NSString *const kCharFormCellID = @"CharAddFormCell";

static CGFloat const kCARowH = 44.0f;
static CGFloat const kCAPad  = 12.0f;
static CGFloat const kCALabelW = 70.0f;
static CGFloat const kCAPromptRowH = 200.0f;

enum {
    kCASectionName = 0,
    kCASectionPrompt,
    kCASectionSave,
    kCASectionCount
};

@interface CharacterAddViewController () {
    UITableView *_formTable;

    UITextField *_nameField;      // owned via alloc/init (released in dealloc)
    UITextView *_promptView;      // owned via alloc/init (released in dealloc)

    // v261025-7 CRITICAL: the prompt view's layer.borderColor holds a
    // CGColorRef OWNED by a UIColor. If that UIColor is autoreleased (like
    // [iOS6Theme inputFieldBorderColor] returns), the pool pop frees it and
    // the layer keeps a dangling pointer → SIGSEGV at teardown. This is the
    // SAME crash family fixed in v261025-5 for ChatMessageCell/ComposerView.
    // Retain the UIColor in an ivar; release it in dealloc AFTER the view.
    UIColor *_promptBorderUIColor;

    NSDictionary *_editingCharacter;   // nil when adding fresh
}
@end

@implementation CharacterAddViewController

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_formTable release];
    // v261025-7: release the VIEWS first (their layer teardown does the
    // CGColorRelease, bringing the CGColor RC 2→1), THEN release the
    // retained UIColor ivar (1→0). Order matters — see ChatMessageCell.
    [_nameField release];
    [_promptView release];
    [_promptBorderUIColor release];
    [_editingCharacter release];
    [super dealloc];
}

- (id)initWithCharacter:(NSDictionary *)character
{
    if (self = [super initWithNibName:nil bundle:nil]) {
        if ([character isKindOfClass:[NSDictionary class]]) {
            _editingCharacter = [character retain];
        }
        self.title = (_editingCharacter != nil)
            ? NSLocalizedString(@"编辑角色", nil)
            : NSLocalizedString(@"添加角色", nil);
    }
    return self;
}

- (id)init
{
    return [self initWithCharacter:nil];
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    return [self initWithCharacter:nil];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    CGRect frame = self.view.bounds;
    _formTable = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    _formTable.dataSource = self;
    _formTable.delegate = self;
    _formTable.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight);
    _formTable.backgroundColor = [UIColor clearColor];
    _formTable.backgroundView = nil;
    _formTable.opaque = NO;
    [self.view addSubview:_formTable];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _formTable.backgroundColor = [UIColor clearColor];
    _formTable.backgroundView = nil;
}

- (void)_themeChanged
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _formTable.backgroundColor = [UIColor clearColor];
    _formTable.backgroundView = nil;
    if (_nameField) {
        _nameField.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
        _nameField.textColor = [iOS6Theme inputFieldTextColor];
    }
    if (_promptView) {
        _promptView.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
        _promptView.textColor = [iOS6Theme inputFieldTextColor];
        // v261025-7: refresh the retained border-color ivar too so the
        // layer keeps pointing at a LIVE UIColor after the theme flip.
        UIColor *newBorder = [iOS6Theme inputFieldBorderColor];
        _promptView.layer.borderColor = [newBorder CGColor];
        [_promptBorderUIColor release];
        _promptBorderUIColor = [newBorder retain];
    }
    [_formTable reloadData];
}

#pragma mark - Save

- (void)_saveTapped
{
    // Drop the keyboard so the latest text is committed.
    [_nameField resignFirstResponder];
    [_promptView resignFirstResponder];

    NSString *name = [[_nameField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    NSString *prompt = [[_promptView.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];

    if (name.length == 0) {
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"缺少角色名", nil)
                  message:NSLocalizedString(@"请填写角色名（如「翻译官」）。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        [name release];
        [prompt release];
        return;
    }

    // Save through the existing persistence (de-dupe by name — same
    // semantics as the old alert flow: same name replaces).
    NSArray *chars = [CharacterManagementViewController loadCharacters];
    NSMutableArray *updated = [NSMutableArray arrayWithArray:chars];
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < [updated count]; i++) {
        NSDictionary *d = [updated objectAtIndex:i];
        if ([[[d objectForKey:@"name"] description] isEqualToString:name]) {
            [updated replaceObjectAtIndex:i withObject:
                [NSDictionary dictionaryWithObjectsAndKeys:
                 name, @"name", prompt ?: @"", @"prompt", nil]];
            replaced = YES;
            break;
        }
    }
    if (!replaced) {
        [updated addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            name, @"name", prompt ?: @"", @"prompt", nil]];
    }
    [CharacterManagementViewController saveCharacters:updated];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"CharAdd saved '%@' (promptLen=%lu) — %@",
        name, (unsigned long)prompt.length, replaced ? @"replaced" : @"new"]];

    [name release];
    [prompt release];
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kCASectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kCASectionName)   return 1;
    if (section == kCASectionPrompt) return 1;
    if (section == kCASectionSave)   return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kCASectionName)   return NSLocalizedString(@"角色", nil);
    if (section == kCASectionPrompt) return NSLocalizedString(@"提示词 (system prompt)", nil);
    return @"";
}

// v261025-7: custom TRANSPARENT header/footer views (dark-mode white-bar fix).
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return [iOS6Theme groupedSectionHeaderViewWithTitle:title
                                                  width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return (title.length > 0) ? 26.0f : 8.0f;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kCASectionPrompt) {
        return NSLocalizedString(@"激活的角色会以 system prompt 形式注入每次对话。", nil);
    }
    return @"";
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForFooterInSection:section];
    return [iOS6Theme groupedSectionFooterViewWithTitle:title
                                                  width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForFooterInSection:section];
    return [iOS6Theme groupedSectionFooterHeightForTitle:title
                                                   width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kCASectionPrompt) return kCAPromptRowH;
    return kCARowH;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCharFormCellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                   reuseIdentifier:kCharFormCellID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSArray *oldSubviews = [cell.contentView.subviews copy];
    for (UIView *v in oldSubviews) [v removeFromSuperview];
    [oldSubviews release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
    cell.textLabel.text = @"";
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == kCASectionName) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(kCAPad, 0, kCALabelW, kCARowH)];
        l.text = NSLocalizedString(@"角色名", nil);
        l.backgroundColor = [UIColor clearColor];
        l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        l.textColor = [iOS6Theme textColor];
        l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:l];
        [l release];

        if (!_nameField) {
            CGFloat w = cell.contentView.bounds.size.width;
            _nameField = [[UITextField alloc]
                initWithFrame:CGRectMake(kCAPad + kCALabelW + 4, 7,
                                         w - kCAPad - kCALabelW - 8, kCARowH - 14)];
            _nameField.borderStyle = UITextBorderStyleRoundedRect;
            _nameField.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
            _nameField.placeholder = NSLocalizedString(@"如「翻译官」", nil);
            _nameField.autocorrectionType = UITextAutocorrectionTypeNo;
            _nameField.returnKeyType = UIReturnKeyNext;
            _nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
            _nameField.delegate = self;
            _nameField.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
            _nameField.textColor = [iOS6Theme inputFieldTextColor];
            _nameField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            if ([iOS6Theme isDarkMode] &&
                [_nameField respondsToSelector:@selector(setKeyboardAppearance:)]) {
                [_nameField setKeyboardAppearance:UIKeyboardAppearanceAlert];
            }
            // Edit-mode pre-fill.
            if (_editingCharacter) {
                _nameField.text = [_editingCharacter objectForKey:@"name"] ?: @"";
            }
        }
        [cell.contentView addSubview:_nameField];
        return cell;
    }

    if (indexPath.section == kCASectionPrompt) {
        if (!_promptView) {
            _promptView = [[UITextView alloc] initWithFrame:CGRectZero];
            _promptView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
            _promptView.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
            _promptView.textColor = [iOS6Theme inputFieldTextColor];
            _promptView.delegate = self;
            _promptView.layer.cornerRadius = 8.0f;
            _promptView.layer.borderWidth = 1.0f;
            // v261025-7: retain-then-assign — NEVER feed an autoreleased
            // UIColor's CGColor straight into a layer (dangling after pool
            // pop; the v261025-5 crash family).
            _promptBorderUIColor = [[iOS6Theme inputFieldBorderColor] retain];
            _promptView.layer.borderColor = [_promptBorderUIColor CGColor];
            if ([_promptView respondsToSelector:@selector(setTextContainerInset:)]) {
                [_promptView performSelector:@selector(setTextContainerInset:)
                                   withObject:[NSValue valueWithUIEdgeInsets:
                                               UIEdgeInsetsMake(8, 8, 8, 8)]];
            }
            if ([iOS6Theme isDarkMode] &&
                [_promptView respondsToSelector:@selector(setKeyboardAppearance:)]) {
                [_promptView setKeyboardAppearance:UIKeyboardAppearanceAlert];
            }
            // Done toolbar above the keyboard.
            UIToolbar *kbdToolbar = [[[UIToolbar alloc]
                initWithFrame:CGRectMake(0, 0, 320, 44)] autorelease];
            kbdToolbar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
            UIBarButtonItem *flex = [[[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                    target:nil action:nil] autorelease];
            UIBarButtonItem *done = [[[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                    target:self action:@selector(_promptDone)] autorelease];
            kbdToolbar.items = [NSArray arrayWithObjects:flex, done, nil];
            _promptView.inputAccessoryView = kbdToolbar;
            // Edit-mode pre-fill.
            if (_editingCharacter) {
                _promptView.text = [_editingCharacter objectForKey:@"prompt"] ?: @"";
            }
        }
        CGRect cf = cell.contentView.bounds;
        _promptView.frame = CGRectMake(kCAPad, 6, cf.size.width - kCAPad * 2, kCAPromptRowH - 12);
        _promptView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:_promptView];
        return cell;
    }

    // Save row.
    cell.textLabel.text = NSLocalizedString(@"保存", nil);
    cell.textLabel.textColor = [iOS6Theme tintColor];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:17]];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kCASectionSave) {
        [self _saveTapped];
    }
}

- (void)_promptDone
{
    [_promptView resignFirstResponder];
}

#pragma mark - UITextFieldDelegate / UITextViewDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    // Name field → jump into the prompt view.
    if (textField == _nameField) {
        [_promptView becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

@end
