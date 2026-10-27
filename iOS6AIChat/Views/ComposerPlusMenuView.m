//
//  ComposerPlusMenuView.m
//  iOS6AIChat
//
//  See the .h for the layout & delegate protocol.
//

#import "ComposerPlusMenuView.h"
#import "iOS6Theme.h"
#import "ModelManagementViewController.h"
#import "CharacterManagementViewController.h"
#import "ComposerView.h"   // for toggle class accessors
#import "Logger.h"
#import <QuartzCore/QuartzCore.h>

enum {
    kPMSectionToggles = 0,
    kPMSectionActions,
    kPMSectionModels,   // inline starred-models list (may be empty)
    kPMSectionCharacters,
    kPMSectionCount
};

enum {
    kPMActionImageUpload = 0,
    // v261025-11 精简 (user feedback #6): dropped kPMActionClearConversation
    // (low-frequency + destructive — history long-press delete covers it)
    // and kPMActionMoreModels / kPMActionMoreCharacters (exact duplicates
    // of the trailing "更多…" row already present in the 切换模型 /
    // 切换角色 sections). The action section now holds image upload only.
    kPMActionCount
};

@interface ComposerPlusMenuView () {
    UIView *_dimLayer;       // semi-transparent black overlay covering the chat
    UITableView *_table;
    // Inline submenu state — re-fetched on every show/refresh.
    NSArray *_starredChatModels;     // array of dicts (see ModelMgmt +starredChatModels)
    NSArray *_starredImageModels;
    NSArray *_allCharacters;         // array of {name, prompt} dicts
    NSString *_activeChatModelID;
    NSString *_activeImageModelID;
    NSString *_activeCharacterName;
}
@end

@implementation ComposerPlusMenuView

@synthesize delegate=_delegate;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        // The view itself is the rounded white panel. (The dim layer is
        // a sibling overlay attached when showInView: is called.)
        self.layer.cornerRadius = 10.0f;
        self.layer.masksToBounds = YES;

        _table = [[UITableView alloc] initWithFrame:self.bounds style:UITableViewStyleGrouped];
        _table.dataSource = self;
        _table.delegate = self;
        _table.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight);
        _table.backgroundColor = [UIColor clearColor];
        _table.backgroundView = nil;
        _table.opaque = NO;
        [self addSubview:_table];

        // Swipe-up gesture to dismiss.
        UISwipeGestureRecognizer *up = [[[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(dismissAnimated)] autorelease];
        up.direction = UISwipeGestureRecognizerDirectionUp;
        [_table addGestureRecognizer:up];

        // Theme change observer so colors update live.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_themeChanged)
                                                     name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_dimLayer release];
    [_table release];
    [_starredChatModels release];
    [_starredImageModels release];
    [_allCharacters release];
    [_activeChatModelID release];
    [_activeImageModelID release];
    [_activeCharacterName release];
    [super dealloc];
}

- (void)_themeChanged
{
    _table.backgroundColor = [UIColor clearColor];
    _table.backgroundView = nil;
    [_table reloadData];
}

#pragma mark - Show / dismiss

- (void)showInView:(UIView *)parentView
{
    if (!parentView) return;
    // Refresh inline data first so the table reflects current state.
    [self refresh];
    // Place dim layer over the parent.
    if (!_dimLayer) {
        _dimLayer = [[UIView alloc] initWithFrame:parentView.bounds];
        _dimLayer.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight);
        _dimLayer.opaque = NO;
        // Tap to dismiss.
        UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(dismissAnimated)] autorelease];
        [_dimLayer addGestureRecognizer:tap];
    }
    // v261025-11 BUG FIX ("半屏菜单的遮罩没了"): the old code animated
    // _dimLayer.alpha to 1.0 INSIDE the slide-up block — but after the
    // previous dismissAnimated left it at 0.0, the beginAnimations combo
    // on a freshly re-added subview could settle at 0 on iOS 6 (and the
    // 0.4 black was nearly invisible over the dark-mode charcoal chat
    // backdrop anyway). Fix: set alpha = 1.0 OUTSIDE the animation block
    // (guaranteed visible), and use a deeper 0.55 tint in dark mode.
    _dimLayer.backgroundColor = [UIColor colorWithRed:0.0f green:0.0f blue:0.0f
                                                 alpha:([iOS6Theme isDarkMode] ? 0.55f : 0.4f)];
    _dimLayer.frame = parentView.bounds;
    _dimLayer.alpha = 1.0f;
    [parentView addSubview:_dimLayer];
    // Place the menu panel at the bottom, offscreen to start.
    CGRect pb = parentView.bounds;
    CGFloat menuH = MIN(pb.size.height * 0.6f, 380.0f);
    if (menuH < 220) menuH = 220;
    self.frame = CGRectMake(0, pb.size.height, pb.size.width, menuH);
    self.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                              UIViewAutoresizingFlexibleTopMargin |
                              UIViewAutoresizingFlexibleHeight);
    [parentView addSubview:self];
    // Animate slide-up.
    [UIView beginAnimations:@"plusMenuUp" context:nil];
    [UIView setAnimationDuration:0.28];
    [UIView setAnimationCurve:UIViewAnimationCurveEaseOut];
    CGRect f = self.frame;
    f.origin.y = pb.size.height - menuH;
    self.frame = f;
    [UIView commitAnimations];
}

- (void)dismissAnimated
{
    CGRect f = self.frame;
    CGRect parentBounds = self.superview ? self.superview.bounds : CGRectZero;
    [UIView beginAnimations:@"plusMenuDown" context:nil];
    [UIView setAnimationDuration:0.22];
    [UIView setAnimationCurve:UIViewAnimationCurveEaseIn];
    // Slide off the bottom.
    f.origin.y = parentBounds.size.height;
    self.frame = f;
    _dimLayer.alpha = 0.0f;
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(_afterDismiss)];
    [UIView commitAnimations];
}

- (void)_afterDismiss
{
    // Remove from parent after the slide-out completes.
    [_dimLayer removeFromSuperview];
    [self removeFromSuperview];
}

- (void)refresh
{
    [_starredChatModels release];
    _starredChatModels = [[ModelManagementViewController starredChatModels] retain];
    [_starredImageModels release];
    _starredImageModels = [[ModelManagementViewController starredImageModels] retain];
    [_allCharacters release];
    _allCharacters = [[CharacterManagementViewController loadCharacters] retain];
    [_activeChatModelID release];
    _activeChatModelID = [[[NSUserDefaults standardUserDefaults]
        stringForKey:SettingsKeyModel] retain];
    [_activeImageModelID release];
    _activeImageModelID = [[[NSUserDefaults standardUserDefaults]
        stringForKey:SettingsKeyImageGenModel] retain];
    [_activeCharacterName release];
    _activeCharacterName = [[CharacterManagementViewController activeCharacterName] retain];
    if (_table) [_table reloadData];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // Always show toggles + actions + models + characters (4 sections), even
    // if the starred-models list is empty — that case renders a single
    // "更多..." row.
    return kPMSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // v261025-11: image-gen toggle row only shows when the global
    // image-gen FEATURE switch is ON (Settings #7). Default ON.
    BOOL igFeature = [[NSUserDefaults standardUserDefaults]
        objectForKey:SettingsKeyImageGenFeatureEnabled]
        ? [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyImageGenFeatureEnabled]
        : YES;
    if (section == kPMSectionToggles) return igFeature ? 3 : 2;
    if (section == kPMSectionActions) return kPMActionCount;
    if (section == kPMSectionModels) {
        // starredChatModels + starredImageModels + 1 row for "更多...".
        return (NSInteger)[_starredChatModels count] +
               (NSInteger)[_starredImageModels count] + 1;
    }
    if (section == kPMSectionCharacters) {
        // All characters + 1 row for "更多...".
        return (NSInteger)[_allCharacters count] + 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kPMSectionToggles)    return NSLocalizedString(@"模式", nil);
    if (section == kPMSectionActions)    return NSLocalizedString(@"动作", nil);
    if (section == kPMSectionModels)     return NSLocalizedString(@"切换模型", nil);
    if (section == kPMSectionCharacters) return NSLocalizedString(@"切换角色", nil);
    return @"";
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return [iOS6Theme groupedSectionHeaderViewWithTitle:title
                                                  width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return 26.0f;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kPMSectionToggles) {
        return NSLocalizedString(@"生图开启时输入框变蓝；深度思考/联网搜索在生图模式下不可用。", nil);
    }
    if (section == kPMSectionModels) {
        if ([_starredChatModels count] + [_starredImageModels count] == 0) {
            return NSLocalizedString(@"无星标模型。在模型管理里点 ★ 添加到快捷列表。", nil);
        }
        return NSLocalizedString(@"点模型名快速切换。点「更多」打开完整列表。", nil);
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

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellID = @"PMCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:cellID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    }
    NSArray *old = [cell.contentView.subviews copy];
    for (UIView *v in old) [v removeFromSuperview];
    [old release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    if (indexPath.section == kPMSectionToggles) {
        NSString *label = nil;
        BOOL on = NO;
        NSInteger tag = 0;
        if (indexPath.row == 0) {
            label = NSLocalizedString(@"深度思考", nil);
            on = [ComposerView deepThinkingEnabled];
            tag = 200;
        } else if (indexPath.row == 1) {
            label = NSLocalizedString(@"联网搜索", nil);
            on = [ComposerView webSearchEnabled];
            tag = 201;
        } else {
            // v261025-11: only reachable when the image-gen feature
            // switch is ON (numberOfRows hides the row otherwise).
            label = NSLocalizedString(@"生图模式", nil);
            on = [ComposerView imageGenEnabled];
            tag = 202;
        }
        // When 生图 is ON, disable DT + Web toggles.
        BOOL ig = [ComposerView imageGenEnabled];
        if (indexPath.row < 2 && ig) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.textColor = [iOS6Theme secondaryTextColor];
            cell.textLabel.alpha = 0.55f;
        }
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 160, 44)];
        l.text = label;
        l.backgroundColor = [UIColor clearColor];
        l.opaque = NO;
        l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
        l.textColor = cell.textLabel.textColor;
        l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:l];
        [l release];
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
        [sw setOn:on animated:NO];
        sw.tag = tag;
        sw.enabled = !(indexPath.row < 2 && ig);
        [sw addTarget:self action:@selector(_toggleChanged:)
          forControlEvents:UIControlEventValueChanged];
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 79 - 12, (44 - 27) / 2, 79, 27);
        [cell.contentView addSubview:sw];
        return cell;
    }

    if (indexPath.section == kPMSectionActions) {
        if (indexPath.row == kPMActionImageUpload) {
            cell.textLabel.text = NSLocalizedString(@"📷 上传/识别图片", nil);
        }
        return cell;
    }

    if (indexPath.section == kPMSectionModels) {
        NSInteger chatCount = (NSInteger)[_starredChatModels count];
        if (indexPath.row < chatCount) {
            NSDictionary *m = [_starredChatModels objectAtIndex:indexPath.row];
            NSString *dn = [m objectForKey:@"displayName"];
            NSString *prov = [m objectForKey:@"providerDisplayName"];
            cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", dn, prov];
            if ([[m objectForKey:@"active"] boolValue]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        NSInteger imgIdx = indexPath.row - chatCount;
        if (imgIdx < (NSInteger)[_starredImageModels count]) {
            NSDictionary *m = [_starredImageModels objectAtIndex:imgIdx];
            NSString *dn = [m objectForKey:@"displayName"];
            NSString *prov = [m objectForKey:@"providerDisplayName"];
            cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@ (生图)", dn, prov];
            if ([[m objectForKey:@"active"] boolValue]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        // Last row: "更多..."
        cell.textLabel.text = NSLocalizedString(@"更多模型…", nil);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = [iOS6Theme tintColor];
        return cell;
    }

    if (indexPath.section == kPMSectionCharacters) {
        if (indexPath.row < (NSInteger)[_allCharacters count]) {
            NSDictionary *c = [_allCharacters objectAtIndex:indexPath.row];
            NSString *name = [c objectForKey:@"name"];
            cell.textLabel.text = name ?: @"?";
            if ([name isEqualToString:_activeCharacterName]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        cell.textLabel.text = NSLocalizedString(@"更多角色…", nil);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = [iOS6Theme tintColor];
        return cell;
    }
    return cell;
}

#pragma mark - Table delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kPMSectionToggles) return;  // toggle via UISwitch
    if (indexPath.section == kPMSectionActions) {
        if (indexPath.row == kPMActionImageUpload) {
            if ([_delegate respondsToSelector:@selector(plusMenuDidTapImageUpload:)]) {
                [_delegate plusMenuDidTapImageUpload:self];
            }
            [self dismissAnimated];
        }
        return;
    }
    if (indexPath.section == kPMSectionModels) {
        NSInteger chatCount = (NSInteger)[_starredChatModels count];
        if (indexPath.row < chatCount) {
            NSDictionary *m = [_starredChatModels objectAtIndex:indexPath.row];
            NSString *mid = [m objectForKey:@"id"];
            if ([_delegate respondsToSelector:@selector(plusMenu:didSelectChatModelID:)]) {
                [_delegate plusMenu:self didSelectChatModelID:mid];
            }
            // Persist active model + refresh visuals.
            [[NSUserDefaults standardUserDefaults] setObject:mid forKey:SettingsKeyModel];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self refresh];
            [self dismissAnimated];
            return;
        }
        NSInteger imgIdx = indexPath.row - chatCount;
        if (imgIdx < (NSInteger)[_starredImageModels count]) {
            NSDictionary *m = [_starredImageModels objectAtIndex:imgIdx];
            NSString *mid = [m objectForKey:@"id"];
            if ([_delegate respondsToSelector:@selector(plusMenu:didSelectImageModelID:)]) {
                [_delegate plusMenu:self didSelectImageModelID:mid];
            }
            [[NSUserDefaults standardUserDefaults] setObject:mid forKey:SettingsKeyImageGenModel];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self refresh];
            [self dismissAnimated];
            return;
        }
        // "更多..." row
        if ([_delegate respondsToSelector:@selector(plusMenuDidTapMoreModels:)]) {
            [_delegate plusMenuDidTapMoreModels:self];
        }
        [self dismissAnimated];
        return;
    }
    if (indexPath.section == kPMSectionCharacters) {
        if (indexPath.row < (NSInteger)[_allCharacters count]) {
            NSDictionary *c = [_allCharacters objectAtIndex:indexPath.row];
            NSString *name = [c objectForKey:@"name"];
            if ([_delegate respondsToSelector:@selector(plusMenu:didSelectCharacterName:)]) {
                [_delegate plusMenu:self didSelectCharacterName:name];
            }
            [CharacterManagementViewController setActiveCharacterName:name];
            [self refresh];
            [self dismissAnimated];
            return;
        }
        if ([_delegate respondsToSelector:@selector(plusMenuDidTapMoreCharacters:)]) {
            [_delegate plusMenuDidTapMoreCharacters:self];
        }
        [self dismissAnimated];
        return;
    }
}

#pragma mark - Toggle switch handler

- (void)_toggleChanged:(UISwitch *)sw
{
    switch (sw.tag) {
        case 200:
            [ComposerView setDeepThinkingEnabled:sw.on];
            if ([_delegate respondsToSelector:@selector(plusMenu:deepThinkingEnabledChanged:)]) {
                [_delegate plusMenu:self deepThinkingEnabledChanged:sw.on];
            }
            break;
        case 201:
            [ComposerView setWebSearchEnabled:sw.on];
            if ([_delegate respondsToSelector:@selector(plusMenu:webSearchEnabledChanged:)]) {
                [_delegate plusMenu:self webSearchEnabledChanged:sw.on];
            }
            break;
        case 202: {
            [ComposerView setImageGenEnabled:sw.on];
            // When 生图 turns ON, the DT + Web toggles become irrelevant —
            // reload the toggles section so they grey out + the disabled
            // state shows. When it turns OFF, the disabled state clears.
            NSIndexSet *idx = [NSIndexSet indexSetWithIndex:kPMSectionToggles];
            [_table reloadSections:idx withRowAnimation:UITableViewRowAnimationAutomatic];
            if ([_delegate respondsToSelector:@selector(plusMenu:imageGenEnabledChanged:)]) {
                [_delegate plusMenu:self imageGenEnabledChanged:sw.on];
            }
            break;
        }
    }
}

@end
