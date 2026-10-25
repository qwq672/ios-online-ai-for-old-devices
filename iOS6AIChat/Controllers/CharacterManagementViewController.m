//
//  CharacterManagementViewController.m
//  iOS6AIChat
//
//  v261024-15: per-character role management.
//    Persistence: JSON array of dicts in NSUserDefaults under
//    SettingsKeyCharacterList. Schema per item:
//        { name: string, prompt: string }
//    The currently-active character is tracked separately by ID
//    (its name) under SettingsKeyActiveCharacter ("", "" = no character).
//    On/off switch for "user identity injection" (SettingsKeyInjectUserIdentity)
//    prepends [[UIDevice currentDevice] name] to the system prompt as
//    "User identity: <device-name>" so the assistant can address the user
//    by their device name.
//

#import "CharacterManagementViewController.h"
#import "iOS6Theme.h"
#import "Logger.h"

// Settings keys (declared here, not in SettingsViewController.h to keep
// the changes localized — SettingsVC doesn't need to know about them).
NSString *const SettingsKeyCharacterList = @"characterList";
NSString *const SettingsKeyActiveCharacter = @"activeCharacter";
NSString *const SettingsKeyInjectUserIdentity = @"injectUserIdentity";

static NSString *const kCellReuseID = @"CharMgmtCell";

// Alert tags.
enum {
    kAlertAddCharacter = 301,    // Step 1: ask for name
    kAlertAddCharacterPrompt = 302,  // Step 2: ask for prompt
    kAlertEditCharacter = 303,        // Edit existing character
    kAlertConfirmDelete = 304,        // Delete confirmation
};

enum {
    kCharSectionAdd = 0,
    kCharSectionList,
    kCharSectionActive,
    kCharSectionIdentity,
    kCharSectionCount
};

@interface CharacterManagementViewController () {
    NSString *_pendingName;       // for kAlertAddCharacterPrompt and kAlertEditCharacter
    NSString *_pendingEditName;   // for kAlertConfirmDelete
    NSMutableArray *_characters;  // array of dicts
}
@end

@implementation CharacterManagementViewController

@synthesize tableView=_tableView;

#pragma mark - Persistence (class helpers)

+ (NSArray *)loadCharacters
{
    NSString *json = [[NSUserDefaults standardUserDefaults]
                       stringForKey:SettingsKeyCharacterList];
    if (!json || json.length == 0) return [NSArray array];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:&err];
    if (err || ![arr isKindOfClass:[NSArray class]]) return [NSArray array];
    // v261025-1: STRICT type filter. The old check was `objectForKey:`
    // truthiness — an NSNull (JSON null) PASSES that test, sneaks into
    // the list, and later explodes isEqualToString:/length with
    // "unrecognized selector". Now every field must be a real NSString.
    NSMutableArray *out = [NSMutableArray array];
    for (id e in arr) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        id name   = [(NSDictionary *)e objectForKey:@"name"];
        id prompt = [(NSDictionary *)e objectForKey:@"prompt"];
        if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0 &&
            [prompt isKindOfClass:[NSString class]]) {
            [out addObject:@{@"name": name, @"prompt": prompt}];
        }
    }
    return out;
}

+ (void)saveCharacters:(NSArray *)characters
{
    NSMutableArray *clean = [NSMutableArray array];
    for (NSDictionary *d in characters) {
        if ([d isKindOfClass:[NSDictionary class]]) {
            NSString *name = [d objectForKey:@"name"];
            NSString *prompt = [d objectForKey:@"prompt"];
            if ([name isKindOfClass:[NSString class]] && name.length > 0 &&
                [prompt isKindOfClass:[NSString class]]) {
                [clean addObject:@{@"name": name, @"prompt": prompt}];
            }
        }
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:clean
                                                    options:0
                                                      error:&err];
    if (data) {
        NSString *json = [[[NSString alloc] initWithData:data
                                                encoding:NSUTF8StringEncoding] autorelease];
        [[NSUserDefaults standardUserDefaults] setObject:json
                                                  forKey:SettingsKeyCharacterList];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)activeCharacterName
{
    return [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyActiveCharacter] ?: @"";
}

+ (void)setActiveCharacterName:(NSString *)name
{
    [[NSUserDefaults standardUserDefaults] setObject:(name ?: @"")
                                              forKey:SettingsKeyActiveCharacter];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)injectUserIdentity
{
    // Default ON — this matches the user-requested "用户身份注入开关".
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:SettingsKeyInjectUserIdentity];
    if (!v) return YES;
    return [v boolValue];
}

+ (void)setInjectUserIdentity:(BOOL)on
{
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:SettingsKeyInjectUserIdentity];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)activeCharacterPrompt
{
    // Resolve the active character's prompt (or "" if none / not found).
    NSString *activeName = [self activeCharacterName];
    if (activeName.length == 0) return @"";
    for (NSDictionary *d in [self loadCharacters]) {
        NSString *n = [d objectForKey:@"name"];
        if ([n isKindOfClass:[NSString class]] && [n isEqualToString:activeName]) {
            return [d objectForKey:@"prompt"];
        }
    }
    return @"";
}

+ (NSString *)effectiveSystemPromptWithBase:(NSString *)base
{
    // Compose the final system prompt:
    //   1) If active character exists, prepend its prompt.
    //   2) If injectUserIdentity is ON, prepend "User identity: <device-name>"
    //      as the very first line.
    //   3) Append the user's base system prompt.
    NSMutableString *out = [NSMutableString string];
    if ([self injectUserIdentity]) {
        NSString *devName = [[UIDevice currentDevice] name] ?: @"(unknown device)";
        [out appendFormat:@"User identity: %@\n", devName];
    }
    NSString *charPrompt = [self activeCharacterPrompt];
    if (charPrompt.length > 0) {
        [out appendFormat:@"%@\n", charPrompt];
    }
    if (base.length > 0) {
        [out appendString:base];
    }
    return out;
}

#pragma mark - Lifecycle

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"角色管理", nil);
        _characters = [[NSMutableArray arrayWithArray:
                        [CharacterManagementViewController loadCharacters]] retain];
    }
    return self;
}

- (void)dealloc
{
    // v261025-1 CRITICAL: this dealloc was MISSING removeObserver — the
    // theme-change observer registered in viewDidLoad stayed in the
    // notification center as a ZOMBIE after the page was popped. The
    // next iOS6ThemeDidChangeNotification (dark mode / font size / the
    // image-support toggle all post it) messaged freed memory → SIGSEGV
    // with NOTHING in the log. This was one of the random post-visit
    // crashes.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [_characters release];
    [_pendingName release];
    [_pendingEditName release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    CGRect frame = self.view.bounds;
    _tableView = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight);
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.opaque = NO;
    [self.view addSubview:_tableView];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
}

- (void)_themeChanged
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    [_tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Refresh local cache from disk in case Settings/reset changed it.
    [_characters release];
    _characters = [[NSMutableArray arrayWithArray:
                    [CharacterManagementViewController loadCharacters]] retain];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    [_tableView reloadData];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kCharSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kCharSectionAdd:     return 1;
        case kCharSectionList:    return (NSInteger)[_characters count];
        case kCharSectionActive:  return 1;
        case kCharSectionIdentity: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kCharSectionAdd:      return NSLocalizedString(@"添加", nil);
        case kCharSectionList:     return NSLocalizedString(@"已保存角色", nil);
        case kCharSectionActive:   return NSLocalizedString(@"当前激活", nil);
        case kCharSectionIdentity: return NSLocalizedString(@"用户身份", nil);
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section) {
        case kCharSectionAdd:
            return NSLocalizedString(@"弹出输入框依次输入角色名 + 提示词。", nil);
        case kCharSectionList:
            return NSLocalizedString(@"点角色 = 设为激活（注入到 system prompt）；右滑可删除。", nil);
        case kCharSectionActive:
            return NSLocalizedString(@"激活的角色会以 system prompt 形式注入每次对话。空字符串 = 不注入任何角色。", nil);
        case kCharSectionIdentity:
            return NSLocalizedString(@"把设备名作为「User identity: <name>」注入到 system prompt 第一行。", nil);
        default: return @"";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellReuseID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:kCellReuseID] autorelease];
    }
    // v261025-2: CRITICAL — iOS 6's -[UIView subviews] may return a
    // direct reference to the internal subview array (NOT a copy on
    // every device/orientation). Mutating it via -removeFromSuperview
    // while iterating triggers "Collection was mutated while being
    // enumerated" — on cctools-port armv7 with no @catch this becomes a
    // hard SIGSEGV. This is the root cause of "tap any component on the
    // Character Management page → crash" — every cellForRowAtIndexPath
    // call hit this line. Fix: snapshot the array first.
    NSArray *oldSubviews = [cell.contentView.subviews copy];
    for (UIView *v in oldSubviews) [v removeFromSuperview];
    [oldSubviews release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    cell.detailTextLabel.textColor = [iOS6Theme secondaryTextColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = @"";

    switch (indexPath.section) {
        case kCharSectionAdd:
            cell.textLabel.text = NSLocalizedString(@"+ 添加角色", nil);
            cell.textLabel.textColor = [iOS6Theme tintColor];
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            break;
        case kCharSectionList: {
            if (indexPath.row >= (NSInteger)[_characters count]) return cell;
            NSDictionary *c = [_characters objectAtIndex:indexPath.row];
            NSString *name = [c objectForKey:@"name"];
            NSString *prompt = [c objectForKey:@"prompt"];
            cell.textLabel.text = name;
            // Truncate prompt to 60 chars for the detail label.
            // (Note: `shortPrompt` is used because `short` is a C reserved
            //  keyword — `short int` is a type.)
            NSString *shortPrompt = prompt;
            if (shortPrompt.length > 60) {
                shortPrompt = [NSString stringWithFormat:@"%@…", [shortPrompt substringToIndex:59]];
            }
            cell.detailTextLabel.text = shortPrompt;
            cell.detailTextLabel.numberOfLines = 1;
            // Checkmark if active.
            NSString *active = [CharacterManagementViewController activeCharacterName];
            if (active && [active isEqualToString:name]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            break;
        }
        case kCharSectionActive: {
            NSString *active = [CharacterManagementViewController activeCharacterName];
            cell.textLabel.text = active.length > 0 ? active : NSLocalizedString(@"（无激活角色）", nil);
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case kCharSectionIdentity: {
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 200, 44)];
            l.text = NSLocalizedString(@"注入用户身份", nil);
            l.backgroundColor = [UIColor clearColor];
            l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
            l.textColor = [iOS6Theme textColor];
            l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
            [cell.contentView addSubview:l];
            [l release];

            UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
            [sw setOn:[CharacterManagementViewController injectUserIdentity] animated:NO];
            [sw addTarget:self action:@selector(_identityToggle:)
              forControlEvents:UIControlEventValueChanged];
            sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            CGRect f = cell.contentView.bounds;
            sw.frame = CGRectMake(f.size.width - 79 - 12, (44 - 27) / 2, 79, 27);
            [cell.contentView addSubview:sw];
            break;
        }
    }
    return cell;
}

#pragma mark - Table delegate

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == kCharSectionList;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete &&
        indexPath.section == kCharSectionList &&
        indexPath.row < (NSInteger)[_characters count]) {
        NSDictionary *c = [_characters objectAtIndex:indexPath.row];
        NSString *name = [c objectForKey:@"name"];
        // Confirm delete.
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"删除角色?", nil)
                  message:[NSString stringWithFormat:@"%@ \"%@\"", NSLocalizedString(@"确定删除", nil), name]
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"删除", nil), nil] autorelease];
        [av setTag:kAlertConfirmDelete];
        self.pendingEditName = name;
        [av show];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    // v261025-1: lean logging — 2 lines bracketing the toggle (the v19
    // per-step firehose drowned the log; Logger is crash-safe now).
    if (indexPath.section == kCharSectionAdd) {
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"角色名", nil)
                  message:NSLocalizedString(@"输入角色名（如 \"翻译官\"）", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"下一步", nil), nil] autorelease];
        if ([av respondsToSelector:@selector(setAlertViewStyle:)]) {
            [av setAlertViewStyle:UIAlertViewStylePlainTextInput];
        }
        [av setTag:kAlertAddCharacter];
        [av show];
    } else if (indexPath.section == kCharSectionList) {
        if (indexPath.row >= (NSInteger)[_characters count]) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
        NSDictionary *c = [_characters objectAtIndex:indexPath.row];
        if (![c isKindOfClass:[NSDictionary class]]) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
        NSString *name = [c objectForKey:@"name"];
        if (![name isKindOfClass:[NSString class]] || name.length == 0) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
        // Toggle: tapping the active character = deactivate.
        NSString *cur = [CharacterManagementViewController activeCharacterName];
        if (cur && [cur isKindOfClass:[NSString class]] && [cur isEqualToString:name]) {
            [[Logger sharedLogger] info:[NSString stringWithFormat:@"CharMgmt deactivate '%@'", name]];
            [CharacterManagementViewController setActiveCharacterName:@""];
        } else {
            [[Logger sharedLogger] info:[NSString stringWithFormat:@"CharMgmt activate '%@'", name]];
            [CharacterManagementViewController setActiveCharacterName:name];
        }
        [_tableView reloadData];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (IBAction)_identityToggle:(UISwitch *)sw
{
    [CharacterManagementViewController setInjectUserIdentity:sw.on];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"Inject user identity = %@", sw.on ? @"ON" : @"OFF"]];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == 0) {
        // Cancel — clear pending state.
        self.pendingName = nil;
        self.pendingEditName = nil;
        return;
    }
    if (alertView.tag == kAlertAddCharacter) {
        // Step 1: user entered name → ask for prompt.
        UITextField *tf = nil;
        if ([alertView respondsToSelector:@selector(textFieldAtIndex:)]) {
            tf = [alertView textFieldAtIndex:0];
        }
        NSString *name = [tf.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name || name.length == 0) {
            self.pendingName = nil;
            return;
        }
        self.pendingName = name;
        UIAlertView *av2 = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"提示词", nil)
                  message:[NSString stringWithFormat:@"%@ %@", name, NSLocalizedString(@"的 system prompt", nil)]
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"保存", nil), nil] autorelease];
        if ([av2 respondsToSelector:@selector(setAlertViewStyle:)]) {
            [av2 setAlertViewStyle:UIAlertViewStylePlainTextInput];
        }
        [av2 setTag:kAlertAddCharacterPrompt];
        [av2 show];
    } else if (alertView.tag == kAlertAddCharacterPrompt) {
        // Step 2: user entered prompt → save the character.
        NSString *name = _pendingName;
        if (!name || name.length == 0) return;
        UITextField *tf = nil;
        if ([alertView respondsToSelector:@selector(textFieldAtIndex:)]) {
            tf = [alertView textFieldAtIndex:0];
        }
        NSString *prompt = tf.text ?: @"";
        // Add to the in-memory list and persist.
        NSDictionary *newChar = @{@"name": name, @"prompt": prompt};
        NSMutableArray *updated = [NSMutableArray arrayWithArray:_characters];
        // De-dupe by name (replace if exists).
        BOOL replaced = NO;
        for (NSUInteger i = 0; i < [updated count]; i++) {
            NSDictionary *d = [updated objectAtIndex:i];
            if ([[d objectForKey:@"name"] isEqualToString:name]) {
                [updated replaceObjectAtIndex:i withObject:newChar];
                replaced = YES;
                break;
            }
        }
        if (!replaced) [updated addObject:newChar];
        [_characters release];
        _characters = [[NSMutableArray arrayWithArray:updated] retain];
        [CharacterManagementViewController saveCharacters:_characters];
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"Saved character %@ (prompt len=%lu)", name, (unsigned long)prompt.length]];
        self.pendingName = nil;
        [_tableView reloadData];
    } else if (alertView.tag == kAlertConfirmDelete) {
        NSString *name = _pendingEditName;
        if (!name || name.length == 0) return;
        NSMutableArray *updated = [NSMutableArray array];
        for (NSDictionary *d in _characters) {
            if (![[d objectForKey:@"name"] isEqualToString:name]) {
                [updated addObject:d];
            }
        }
        [_characters release];
        _characters = [[NSMutableArray arrayWithArray:updated] retain];
        [CharacterManagementViewController saveCharacters:_characters];
        // If we just deleted the active character, deactivate.
        if ([[CharacterManagementViewController activeCharacterName] isEqualToString:name]) {
            [CharacterManagementViewController setActiveCharacterName:@""];
        }
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"Deleted character %@", name]];
        self.pendingEditName = nil;
        [_tableView reloadData];
    }
}

#pragma mark - Pending property setters (manual retain/release)

- (void)setPendingName:(NSString *)s
{
    if (_pendingName != s) {
        [_pendingName release];
        _pendingName = [s retain];
    }
}

- (void)setPendingEditName:(NSString *)s
{
    if (_pendingEditName != s) {
        [_pendingEditName release];
        _pendingEditName = [s retain];
    }
}

@end
