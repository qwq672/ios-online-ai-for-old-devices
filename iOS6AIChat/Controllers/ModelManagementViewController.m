//
//  ModelManagementViewController.m
//  iOS6AIChat
//
//  v261024-15: independent model management page.
//    Sections:
//      0) 当前默认模型 + 搜索 /v1/models 按钮
//      1) 已保存模型列表 (tap = 设为默认, swipe = 删除)
//      2) 添加新模型 (alert 输入)
//      3) 能力开关 (支持图片识别 / 支持思考)
//

#import "ModelManagementViewController.h"
#import "iOS6Theme.h"
#import "SettingsViewController.h"
#import "NetworkService.h"
#import "ModelAddViewController.h"
#import "Logger.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kCellReuseID = @"ModelMgmtCell";

enum {
    kMMSectionCurrent = 0,   // 当前默认 (resolved active entry) + 测试/搜索
    // v261025-7: provider group sections live between Current and Add.
    // Their count is dynamic (_providerGroups.count).
    kMMSectionAdd = 100,    // 添加 (+ 添加模型 → ModelAddViewController)
    kMMSectionCaps,          // 能力开关 (图片识别 / 思考)
    kMMSectionCount
};

// v261025-7: provider display order for the group sections.
static NSArray *kProviderOrder = nil;

@interface ModelManagementViewController () {
    NSMutableArray *_availableModels;   // for /v1/models search action sheet
    NSString *_pendingAddModel;          // for tag-300 alert (LEGACY — add now goes through ModelAddVC; kept harmless)
    NSString *_pendingDeleteModel;       // for tag-700 alert (confirm delete)
    // v261025-3: transit bundled-model search state.
    BOOL _transitSearchInProgress;       // YES while a search is in-flight
    BOOL _transitSearchCancelled;        // YES if user tapped 取消 on the loading alert
    // v261025-7: provider → entries groups for the two-tier list.
    NSMutableArray *_providerGroups;     // array of {provider, entries(NSArray)}
}
@end

@implementation ModelManagementViewController

@synthesize tableView=_tableView, availableModels=_availableModels;

+ (NSArray *)_providerOrder
{
    if (!kProviderOrder) {
        kProviderOrder = [[NSArray arrayWithObjects:
                           ProviderIDZhipu, ProviderIDOpenAI, ProviderIDOllama, @"custom", nil] retain];
    }
    return kProviderOrder;
}

#pragma mark - Model list persistence (class helpers)

// v261025-3 storage format: JSON array of dicts:
//   [{"id":"gpt-4o","source":"user"}, {"id":"glm-4-flash","source":"transit"}]
// source values: "user" (manually added) | "transit" (auto-added from the
// transit server's bundled list — bulk-removed when the user toggles
// "transit default model" OFF in Settings).
//
// Old format (pre-v261025-3) was a flat JSON array of strings — we
// auto-migrate it to the dict format on first read, marking each
// migrated entry as source="user" (since the user manually added them
// or they were provider-seed defaults).

+ (NSArray *)savedModelEntries
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *json = [d stringForKey:SettingsKeyModelList];
    if (!json || json.length == 0) {
        // First launch: seed provider defaults as source="user".
        NSString *provider = [d stringForKey:SettingsKeyProvider] ?: ProviderIDOpenAI;
        NSArray *seedIDs = [SettingsViewController _defaultModelListForProvider:provider];
        NSMutableArray *seed = [NSMutableArray arrayWithCapacity:[seedIDs count]];
        for (NSString *mid in seedIDs) {
            [seed addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                             mid, @"id",
                             @"user", @"source", nil]];
        }
        [self saveModelEntries:seed];
        return seed;
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![parsed isKindOfClass:[NSArray class]]) {
        // Corrupt → re-seed.
        NSString *provider = [d stringForKey:SettingsKeyProvider] ?: ProviderIDOpenAI;
        NSArray *seedIDs = [SettingsViewController _defaultModelListForProvider:provider];
        NSMutableArray *seed = [NSMutableArray arrayWithCapacity:[seedIDs count]];
        for (NSString *mid in seedIDs) {
            [seed addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                             mid, @"id",
                             @"user", @"source", nil]];
        }
        [self saveModelEntries:seed];
        return seed;
    }
    // Migrate: if parsed contains bare NSStrings (old format) or dicts
    // missing source, convert to canonical {id, source} form.
    // v261025-7: dicts that ALREADY have valid id+source (and possibly the
    // new provider/baseURL/apiKey/displayName keys) pass through UNTOUCHED
    // — the old code rebuilt them as bare {id, source}, which would strip
    // the provider-management data on first read.
    BOOL migrated = NO;
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[parsed count]];
    for (id e in parsed) {
        if ([e isKindOfClass:[NSString class]] && [(NSString *)e length] > 0) {
            [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                e, @"id",
                                @"user", @"source", nil]];
            migrated = YES;
        } else if ([e isKindOfClass:[NSDictionary class]]) {
            NSString *mid = [e objectForKey:@"id"];
            NSString *src = [e objectForKey:@"source"];
            if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
            if (![src isKindOfClass:[NSString class]] || src.length == 0) {
                // Missing source → mutate a copy with source=user, keep the
                // other keys (provider/baseURL/apiKey/displayName) intact.
                NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)e];
                [m setObject:@"user" forKey:@"source"];
                [entries addObject:m];
                migrated = YES;
            } else {
                [entries addObject:e];
            }
        }
    }
    if (migrated) [self saveModelEntries:entries];
    return entries;
}

// Back-compat shim: return only the IDs (NSStrings) — old callers
// (e.g. SettingsVC fallback logic) expect a flat array of model-id
// strings. New callers should use savedModelEntries directly.
+ (NSArray *)savedModelList
{
    NSArray *entries = [self savedModelEntries];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[entries count]];
    for (NSDictionary *e in entries) {
        NSString *mid = [e objectForKey:@"id"];
        if ([mid isKindOfClass:[NSString class]] && mid.length > 0) {
            [out addObject:mid];
        }
    }
    return out;
}

+ (void)saveModelEntries:(NSArray *)entries
{
    // De-duplicate by id; first occurrence wins.
    // v261025-7: ALSO preserve the new per-entry keys (provider / baseURL /
    // apiKey / displayName). The old sanitizer dropped unknown keys, which
    // would silently strip the provider-management data on every save.
    NSMutableArray *seen = [NSMutableArray array];
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:[entries count]];
    for (id e in entries) {
        NSString *mid = nil;
        NSString *src = @"user";
        NSString *provider = nil;
        NSString *baseURL = nil;
        NSString *apiKey = nil;
        NSString *displayName = nil;
        NSString *kind = nil;
        if ([e isKindOfClass:[NSDictionary class]]) {
            mid = [e objectForKey:@"id"];
            id srcObj = [e objectForKey:@"source"];
            if ([srcObj isKindOfClass:[NSString class]] && [(NSString *)srcObj length] > 0) {
                src = srcObj;
            }
            id p = [e objectForKey:@"provider"];
            if ([p isKindOfClass:[NSString class]] && [(NSString *)p length] > 0) provider = p;
            id b = [e objectForKey:@"baseURL"];
            if ([b isKindOfClass:[NSString class]] && [(NSString *)b length] > 0) baseURL = b;
            id k = [e objectForKey:@"apiKey"];
            if ([k isKindOfClass:[NSString class]] && [(NSString *)k length] > 0) apiKey = k;
            id d = [e objectForKey:@"displayName"];
            if ([d isKindOfClass:[NSString class]] && [(NSString *)d length] > 0) displayName = d;
            // v261025-8: image-generation entries (kind="image") must
            // survive the save round-trip — the composer's 生图 mode looks
            // them up via SettingsKeyImageGenModel.
            id kk = [e objectForKey:@"kind"];
            if ([kk isKindOfClass:[NSString class]] && [(NSString *)kk length] > 0) kind = kk;
        } else if ([e isKindOfClass:[NSString class]]) {
            mid = e;
        }
        if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
        if ([seen containsObject:mid]) continue;
        [seen addObject:mid];
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                          mid, @"id",
                          src, @"source", nil];
        // v261025-7: only attach the keys that are actually set — entries
        // without them resolve from global settings (backward compatible).
        if (provider)    [entry setObject:provider forKey:@"provider"];
        if (baseURL)     [entry setObject:baseURL forKey:@"baseURL"];
        if (apiKey)      [entry setObject:apiKey forKey:@"apiKey"];
        if (displayName) [entry setObject:displayName forKey:@"displayName"];
        if (kind)        [entry setObject:kind forKey:@"kind"];
        [clean addObject:entry];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:clean options:0 error:&err];
    if (err || !data) {
        // Fallback: CSV of just IDs (loses source info but preserves
        // the list across a corrupting JSON failure).
        NSString *csv = [seen componentsJoinedByString:@","];
        [[NSUserDefaults standardUserDefaults] setObject:csv
                                                  forKey:SettingsKeyModelList];
    } else {
        NSString *json = [[[NSString alloc] initWithData:data
                                                encoding:NSUTF8StringEncoding] autorelease];
        [[NSUserDefaults standardUserDefaults] setObject:json
                                                  forKey:SettingsKeyModelList];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Back-compat shim: save an array of IDs (all become source="user").
+ (void)saveModelList:(NSArray *)list
{
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[list count]];
    for (NSString *mid in list) {
        if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
        [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            mid, @"id",
                            @"user", @"source", nil]];
    }
    [self saveModelEntries:entries];
}

// v261025-7: bare-id add (legacy path — still used by the /v1/models search
// sheet when the user picks a result). Creates a minimal entry with
// source=user and NO provider overrides (resolves from global settings).
+ (void)addModel:(NSString *)model
{
    if (!model || model.length == 0) return;
    NSArray *cur = [self savedModelEntries];
    for (NSDictionary *e in cur) {
        NSString *mid = [e objectForKey:@"id"];
        if ([mid isKindOfClass:[NSString class]] && [mid isEqualToString:model]) return;
    }
    NSMutableArray *arr = [NSMutableArray arrayWithArray:cur];
    [arr addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    model, @"id",
                    @"user", @"source", nil]];
    [self saveModelEntries:arr];
}

// v261025-7: full-entry add. Merges the caller's dict with defaults; keeps
// existing entries untouched. De-duplicates by id.
+ (void)addModelEntry:(NSDictionary *)entry
{
    if (![entry isKindOfClass:[NSDictionary class]]) return;
    NSString *mid = [entry objectForKey:@"id"];
    if (![mid isKindOfClass:[NSString class]] || mid.length == 0) return;
    NSArray *cur = [self savedModelEntries];
    for (NSDictionary *e in cur) {
        NSString *eid = [e objectForKey:@"id"];
        if ([eid isKindOfClass:[NSString class]] && [eid isEqualToString:mid]) {
            // Already exists — replace it (the add page doubles as edit).
            NSMutableArray *arr = [NSMutableArray arrayWithArray:cur];
            [arr replaceObjectAtIndex:[arr indexOfObject:e] withObject:entry];
            [self saveModelEntries:arr];
            return;
        }
    }
    NSMutableArray *arr = [NSMutableArray arrayWithArray:cur];
    [arr addObject:entry];
    [self saveModelEntries:arr];
}

// v261025-7: resolve the connection the CHAT path should use. Merges the
// ACTIVE entry's overrides (provider / baseURL / apiKey) with the global
// settings defaults. Entries from pre-v261025-7 files have no overrides —
// they fall through to the global settings exactly as before.
+ (NSDictionary *)resolvedConnectionForChat
{
    NSDictionary *settings = [SettingsViewController loadSettings];
    NSString *model = [settings objectForKey:SettingsKeyModel];
    NSDictionary *entry = nil;
    if (model.length > 0) {
        for (NSDictionary *e in [self savedModelEntries]) {
            // v261025-8: NEVER resolve the chat path to an image-gen entry
            // — a kind="image" model id in SettingsKeyModel would send
            // chat-completion requests at an image API.
            if ([self entryIsImageKind:e]) continue;
            NSString *eid = [e objectForKey:@"id"];
            if ([eid isKindOfClass:[NSString class]] && [eid isEqualToString:model]) {
                entry = e;
                break;
            }
        }
    }
    NSString *provider = [entry objectForKey:@"provider"];
    if (![provider isKindOfClass:[NSString class]] || provider.length == 0) {
        provider = [settings objectForKey:SettingsKeyProvider];
    }
    NSString *baseURL = [entry objectForKey:@"baseURL"];
    if (![baseURL isKindOfClass:[NSString class]] || baseURL.length == 0) {
        baseURL = [settings objectForKey:SettingsKeyBaseURL];
    }
    NSString *apiKey = [entry objectForKey:@"apiKey"];
    if (![apiKey isKindOfClass:[NSString class]] || apiKey.length == 0) {
        apiKey = [settings objectForKey:SettingsKeyAPIKey];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
            provider ?: ProviderIDOpenAI, @"provider",
            baseURL   ?: @"https://api.openai.com", @"baseURL",
            apiKey    ?: @"", @"apiKey",
            model     ?: @"", @"model",
            nil];
}

// v261025-8: is this entry a 生图 model? (kind=="image"; absent = chat)
+ (BOOL)entryIsImageKind:(NSDictionary *)entry
{
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;
    NSString *k = [entry objectForKey:@"kind"];
    return [k isKindOfClass:[NSString class]] && [k isEqualToString:@"image"];
}

// v261025-8: resolve the connection the IMAGE-GEN path should use.
// Looks up the ACTIVE image model (SettingsKeyImageGenModel — set by
// ModelAddViewController on save, or by tapping an image entry here).
// model is @"" when no image model is configured — ChatViewController
// prompts the user to add one in that case.
+ (NSDictionary *)resolvedConnectionForImageGen
{
    NSDictionary *settings = [SettingsViewController loadSettings];
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyImageGenModel];
    NSDictionary *entry = nil;
    if ([model isKindOfClass:[NSString class]] && model.length > 0) {
        for (NSDictionary *e in [self savedModelEntries]) {
            if (![self entryIsImageKind:e]) continue;   // image entries only
            NSString *eid = [e objectForKey:@"id"];
            if ([eid isKindOfClass:[NSString class]] && [eid isEqualToString:model]) {
                entry = e;
                break;
            }
        }
    }
    // Fallback: no stored key / stale id — use the FIRST image entry.
    if (!entry) {
        for (NSDictionary *e in [self savedModelEntries]) {
            if ([self entryIsImageKind:e]) {
                entry = e;
                NSString *eid = [e objectForKey:@"id"];
                if ([eid isKindOfClass:[NSString class]] && eid.length > 0) {
                    model = eid;
                    // Self-heal: persist so the composer + the section-0
                    // row stay in sync.
                    [[NSUserDefaults standardUserDefaults] setObject:eid
                                                              forKey:SettingsKeyImageGenModel];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
                break;
            }
        }
    }
    NSString *provider = [entry objectForKey:@"provider"];
    if (![provider isKindOfClass:[NSString class]] || provider.length == 0) {
        provider = [settings objectForKey:SettingsKeyProvider];
    }
    NSString *baseURL = [entry objectForKey:@"baseURL"];
    if (![baseURL isKindOfClass:[NSString class]] || baseURL.length == 0) {
        baseURL = [settings objectForKey:SettingsKeyBaseURL];
    }
    NSString *apiKey = [entry objectForKey:@"apiKey"];
    if (![apiKey isKindOfClass:[NSString class]] || apiKey.length == 0) {
        apiKey = [settings objectForKey:SettingsKeyAPIKey];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
            provider ?: ProviderIDZhipu, @"provider",
            baseURL   ?: @"", @"baseURL",
            apiKey    ?: @"", @"apiKey",
            model     ?: @"", @"model",
            nil];
}

// v261025-7: which provider bucket does an entry belong to?
+ (NSString *)_providerBucketForEntry:(NSDictionary *)entry
{
    NSString *p = [entry objectForKey:@"provider"];
    if ([p isKindOfClass:[NSString class]] && p.length > 0) {
        return p;
    }
    // No explicit provider → global settings provider at the time of read.
    NSString *globalProvider = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyProvider];
    return globalProvider.length > 0 ? globalProvider : ProviderIDOpenAI;
}

+ (void)removeModel:(NSString *)model
{
    if (!model || model.length == 0) return;
    NSArray *cur = [self savedModelEntries];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *e in cur) {
        NSString *mid = [e objectForKey:@"id"];
        if (![mid isEqualToString:model]) [arr addObject:e];
    }
    [self saveModelEntries:arr];
}

// v261025-3: bulk-add transit-server bundled models.
// - Skips models that already exist (by id, regardless of source).
// - Each new model is added with source="transit".
+ (void)addTransitModels:(NSArray *)modelIDs
{
    if (!modelIDs || [modelIDs count] == 0) return;
    NSArray *cur = [self savedModelEntries];
    NSMutableArray *arr = [NSMutableArray arrayWithArray:cur];
    for (NSString *mid in modelIDs) {
        if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
        BOOL exists = NO;
        for (NSDictionary *e in arr) {
            NSString *eID = [e objectForKey:@"id"];
            if ([eID isKindOfClass:[NSString class]] && [eID isEqualToString:mid]) {
                exists = YES;
                break;
            }
        }
        if (exists) continue;
        [arr addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        mid, @"id",
                        @"transit", @"source", nil]];
    }
    [self saveModelEntries:arr];
}

// v261025-3: bulk-remove all source="transit" models.
// Called when the user toggles "transit default model" OFF in Settings.
+ (void)removeAllTransitModels
{
    NSArray *cur = [self savedModelEntries];
    NSMutableArray *arr = [NSMutableArray array];
    NSInteger removedCount = 0;
    for (NSDictionary *e in cur) {
        NSString *src = [e objectForKey:@"source"];
        if ([src isKindOfClass:[NSString class]] && [src isEqualToString:@"transit"]) {
            removedCount++;
            continue;
        }
        [arr addObject:e];
    }
    [self saveModelEntries:arr];
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelMgmt removeAllTransitModels — %d removed", (int)removedCount]];
}

// v261025-3: get the source ("user" | "transit") for a given model id.
// Used by ModelMgmt cell UI to show the "中转" 角标.
+ (NSString *)sourceForModel:(NSString *)model
{
    if (!model || model.length == 0) return @"user";
    NSArray *cur = [self savedModelEntries];
    for (NSDictionary *e in cur) {
        NSString *mid = [e objectForKey:@"id"];
        if ([mid isKindOfClass:[NSString class]] && [mid isEqualToString:model]) {
            NSString *src = [e objectForKey:@"source"];
            return [src isKindOfClass:[NSString class]] ? src : @"user";
        }
    }
    return @"user";
}

#pragma mark - Lifecycle

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"模型管理", nil);
        _availableModels = [[NSMutableArray array] retain];
        _providerGroups = [[NSMutableArray array] retain];
    }
    return self;
}

- (void)dealloc
{
    // v261025-1 CRITICAL: this dealloc was MISSING removeObserver — the
    // theme-change observer registered in viewDidLoad stayed in the
    // notification center as a ZOMBIE after the page was popped. The
    // next iOS6ThemeDidChangeNotification (dark mode / font size / the
    // image-support toggle on THIS VERY PAGE posts it!) messaged freed
    // memory → SIGSEGV with NOTHING in the log.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // v261025-1: also drop any deferred sheet presentation still pending.
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_tableView release];
    [_availableModels release];
    [_pendingAddModel release];
    [_pendingDeleteModel release];
    // v261025-7: provider group cache.
    [_providerGroups release];
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
    [self _rebuildGroups];
    [_tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    // v261025-7: rebuild groups every appear — the ModelAddViewController
    // may have added/edited entries while we were covered.
    [self _rebuildGroups];
    [_tableView reloadData];
}

// v261025-8: any image-gen entry saved at all? (Section-0 footer hint.)
- (BOOL)_hasAnyImageEntry
{
    for (NSDictionary *e in [ModelManagementViewController savedModelEntries]) {
        if ([ModelManagementViewController entryIsImageKind:e]) return YES;
    }
    return NO;
}

#pragma mark - v261025-7 Provider groups (two-tier structure)

// Group saved entries by provider bucket into _providerGroups:
//   [{ provider: "zhipu",   entries: [...] },
//    { provider: "openai",  entries: [...] }, ...]
// Providers appear in kProviderOrder order; the "custom" bucket collects
// anything not matching a known provider id. Groups with zero entries are
// omitted entirely.
- (void)_rebuildGroups
{
    NSArray *all = [ModelManagementViewController savedModelEntries];
    NSArray *order = [ModelManagementViewController _providerOrder];
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *prov in order) {
        NSMutableArray *bucket = [NSMutableArray array];
        for (NSDictionary *e in all) {
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            NSString *bucketProv = [ModelManagementViewController _providerBucketForEntry:e];
            BOOL isKnown = [bucketProv isEqualToString:prov];
            // "custom" bucket swallows every non-zhipu/openai/ollama provider.
            if ([prov isEqualToString:@"custom"]) {
                isKnown = ([bucketProv isEqualToString:ProviderIDZhipu] ||
                           [bucketProv isEqualToString:ProviderIDOpenAI] ||
                           [bucketProv isEqualToString:ProviderIDOllama]) ? NO : YES;
            }
            if (isKnown) [bucket addObject:e];
        }
        if ([bucket count] > 0) {
            [groups addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                               prov, @"provider",
                               [NSArray arrayWithArray:bucket], @"entries",
                               nil]];
        }
    }
    [_providerGroups release];
    _providerGroups = [groups retain];
}

// Map a displayed section index → group index (or NSNotFound).
- (NSInteger)_groupIndexForSection:(NSInteger)section
{
    if (section < 1 || section > (NSInteger)[_providerGroups count]) return NSNotFound;
    return section - 1;
}

- (NSInteger)_sectionForAdd      { return 1 + (NSInteger)[_providerGroups count]; }
- (NSInteger)_sectionForCaps     { return 2 + (NSInteger)[_providerGroups count]; }

- (NSString *)_displayNameForProvider:(NSString *)provider
{
    NSString *n = [SettingsViewController displayNameForProvider:provider];
    if ([provider isEqualToString:@"custom"]) return NSLocalizedString(@"自定义", nil);
    return n;
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // v261025-7: 1 (current) + N (provider groups) + 1 (add) + 1 (caps).
    [self _rebuildGroupsIfNeeded];
    return 1 + (NSInteger)[_providerGroups count] + 2;
}

// v261025-7: groups can be empty before the first rebuild (e.g. the table
// asks before viewWillAppear on a fresh push).
- (void)_rebuildGroupsIfNeeded
{
    if ([_providerGroups count] == 0) {
        [self _rebuildGroups];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    [self _rebuildGroupsIfNeeded];
    if (section == 0) return 2;                      // 对话模型 + 生图模型 (v261025-8)
    NSInteger gIdx = [self _groupIndexForSection:section];
    if (gIdx != NSNotFound) {
        NSDictionary *g = [_providerGroups objectAtIndex:gIdx];
        return (NSInteger)[[g objectForKey:@"entries"] count];
    }
    if (section == [self _sectionForAdd])  return 1;  // + 添加模型
    if (section == [self _sectionForCaps]) return 2;  // 图片识别 / 思考
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    [self _rebuildGroupsIfNeeded];
    if (section == 0) return NSLocalizedString(@"当前默认模型", nil);
    NSInteger gIdx = [self _groupIndexForSection:section];
    if (gIdx != NSNotFound) {
        NSDictionary *g = [_providerGroups objectAtIndex:gIdx];
        NSString *prov = [g objectForKey:@"provider"];
        NSInteger cnt = (NSInteger)[[g objectForKey:@"entries"] count];
        return [NSString stringWithFormat:@"%@ (%d)",
                [self _displayNameForProvider:prov], (int)cnt];
    }
    if (section == [self _sectionForAdd]) return NSLocalizedString(@"添加", nil);
    if (section == [self _sectionForCaps]) return NSLocalizedString(@"能力（应用到所有模型）", nil);
    return @"";
}

// v261025-7: custom TRANSPARENT header/footer views — the iOS 6 system
// grouped header/footer draws an opaque LIGHT strip that shows up as a
// white bar behind the text in dark mode (user-reported).
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
    [self _rebuildGroupsIfNeeded];
    if (section == 0) {
        if ([self _hasAnyImageEntry]) {
            return NSLocalizedString(@"点「测试」验证连接；点「搜索」从 /v1/models 拉取可选用模型。", nil);
        }
        return NSLocalizedString(@"点「测试」验证连接；点「搜索」从 /v1/models 拉取可选用模型。生图：先在「添加」里选生图模型类型。", nil);
    }
    NSInteger gIdx = [self _groupIndexForSection:section];
    if (gIdx != NSNotFound) {
        NSDictionary *g = [_providerGroups objectAtIndex:gIdx];
        NSString *prov = [g objectForKey:@"provider"];
        // Show the group's shared endpoint hint when the entries carry one.
        NSDictionary *firstEntry = [[g objectForKey:@"entries"] count] > 0
            ? [[g objectForKey:@"entries"] objectAtIndex:0] : nil;
        NSString *b = [firstEntry objectForKey:@"baseURL"];
        if ([b isKindOfClass:[NSString class]] && b.length > 0) {
            return [NSString stringWithFormat:@"点模型设为默认；右滑删除。端点: %@", b];
        }
        return NSLocalizedString(@"点模型设为默认；右滑删除。", nil);
    }
    if (section == [self _sectionForAdd]) {
        return NSLocalizedString(@"打开完整表单：选提供商、填 BaseURL / API Key / 模型名。", nil);
    }
    if (section == [self _sectionForCaps]) {
        return NSLocalizedString(@"开关会附加到所有 AI 请求，决定是否携带图片/思考参数。", nil);
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
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellReuseID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kCellReuseID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    // v261025-2: snapshot subviews — see CharacterManagementVC for the
    // full root-cause writeup. Mutating subviews while iterating it is
    // SIGSEGV on cctools-port armv7.
    NSArray *oldSubviews = [cell.contentView.subviews copy];
    for (UIView *v in oldSubviews) [v removeFromSuperview];
    [oldSubviews release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    // v261025-7: explicit CLEAR label backgrounds (dark-mode white-plate fix).
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
    cell.textLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    [self _rebuildGroupsIfNeeded];
    NSInteger gIdx = [self _groupIndexForSection:indexPath.section];

    if (indexPath.section == 0) {
        // v261025-8: two rows — 0 = active CHAT model (+ 测试/搜索),
        // 1 = active IMAGE-GEN model. Fully self-drawn (textLabel stays
        // empty) so the two-line layout is exact on iOS 6.
        BOOL isImageRow = (indexPath.row == 1);
        NSDictionary *conn = isImageRow
            ? [ModelManagementViewController resolvedConnectionForImageGen]
            : [ModelManagementViewController resolvedConnectionForChat];
        NSString *model = [conn objectForKey:@"model"];
        NSString *prov  = [conn objectForKey:@"provider"];
        BOOL hasModel = [model isKindOfClass:[NSString class]] && model.length > 0;
        NSString *display = hasModel ? model : NSLocalizedString(@"(未添加)", nil);

        UILabel *main = [[[UILabel alloc]
            initWithFrame:CGRectMake(12, 5, cell.contentView.bounds.size.width - 170, 20)] autorelease];
        main.text = isImageRow
            ? [NSString stringWithFormat:@"生图模型 · %@",
               ([prov isKindOfClass:[NSString class]] && prov.length > 0)
                   ? [self _displayNameForProvider:prov] : @"?"]
            : [NSString stringWithFormat:@"对话模型 · %@",
               ([prov isKindOfClass:[NSString class]] && prov.length > 0)
                   ? [self _displayNameForProvider:prov] : @"?"];
        main.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        main.textColor = isImageRow ? [iOS6Theme tintColor] : [iOS6Theme textColor];
        main.backgroundColor = [UIColor clearColor];
        main.opaque = NO;
        main.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        main.tag = 9003;
        [cell.contentView addSubview:main];

        CGFloat subW = cell.contentView.bounds.size.width - (isImageRow ? 24 : 170);
        UILabel *sub = [[[UILabel alloc]
            initWithFrame:CGRectMake(12, 26, subW, 15)] autorelease];
        sub.text = isImageRow
            ? [NSString stringWithFormat:@"%@ — 输入栏开启生图后发送即生成图片", display]
            : [NSString stringWithFormat:@"%@ — 发送即对话", display];
        sub.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:11]];
        sub.textColor = [iOS6Theme secondaryTextColor];
        sub.backgroundColor = [UIColor clearColor];
        sub.opaque = NO;
        sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        sub.tag = 9002;
        [cell.contentView addSubview:sub];

        if (isImageRow) return cell;

        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            [testBtn setTitle:NSLocalizedString(@"测试", nil) forState:UIControlStateNormal];
            [testBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            testBtn.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
            testBtn.backgroundColor = [iOS6Theme secondaryTextColor];
            testBtn.layer.cornerRadius = 6.0f;
            testBtn.layer.masksToBounds = YES;
            testBtn.tag = 8888;  // for cleanup on cell reuse
            CGRect f = cell.contentView.bounds;
            testBtn.frame = CGRectMake(f.size.width - 76 - 12 - 64 - 4, (44 - 28) / 2, 60, 28);
            testBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [testBtn addTarget:self action:@selector(_testConnection)
              forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:testBtn];

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            [btn setTitle:NSLocalizedString(@"搜索", nil) forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
            btn.backgroundColor = [iOS6Theme tintColor];
            btn.layer.cornerRadius = 6.0f;
            btn.layer.masksToBounds = YES;
            btn.tag = 8889;  // for cleanup on cell reuse
            CGRect f2 = cell.contentView.bounds;
            btn.frame = CGRectMake(f2.size.width - 76 - 12, (44 - 28) / 2, 76, 28);
            btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [btn addTarget:self action:@selector(_searchAvailableModels)
              forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:btn];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else if (gIdx != NSNotFound) {
        // v261025-7: provider-group row — one saved model entry.
        NSDictionary *g = [_providerGroups objectAtIndex:gIdx];
        NSArray *entries = [g objectForKey:@"entries"];
        if (indexPath.row >= (NSInteger)[entries count]) return cell;
        NSDictionary *e = [entries objectAtIndex:indexPath.row];
        NSString *mid = [e objectForKey:@"id"];
        if (![mid isKindOfClass:[NSString class]]) return cell;
        // Display: displayName if set, else the raw model id.
        NSString *dn = [e objectForKey:@"displayName"];
        cell.textLabel.text = [dn isKindOfClass:[NSString class]] && dn.length > 0 ? dn : mid;
        // "自定义" badge when the entry carries its own endpoint/key —
        // i.e. it's a full provider profile, not a bare model name.
        BOOL hasOverrides = ([[e objectForKey:@"baseURL"] length] > 0) ||
                            ([[e objectForKey:@"apiKey"] length] > 0);
        NSString *src = [e objectForKey:@"source"];
        BOOL isTransit = [src isKindOfClass:[NSString class]] && [src isEqualToString:@"transit"];
        BOOL isImage = [ModelManagementViewController entryIsImageKind:e];
        // v261025-8: 生图 badge is laid out LEFT of the 自定义/中转 badge
        // (or in its place when there is none).
        CGFloat badgeRight = cell.contentView.bounds.size.width - 12;
        if (isImage) {
            UILabel *imgBadge = [[[UILabel alloc]
                initWithFrame:CGRectMake(badgeRight - 40, (44 - 18) / 2, 40, 18)] autorelease];
            imgBadge.text = NSLocalizedString(@"生图", nil);
            imgBadge.textColor = [UIColor whiteColor];
            imgBadge.backgroundColor = [iOS6Theme tintColor];
            imgBadge.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:10]];
            imgBadge.textAlignment = NSTextAlignmentCenter;
            imgBadge.layer.cornerRadius = 4.0f;
            imgBadge.layer.masksToBounds = YES;
            imgBadge.tag = 9001;
            imgBadge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [cell.contentView addSubview:imgBadge];
            badgeRight -= (40 + 6);
        }
        if (hasOverrides || isTransit) {
            UILabel *badge = [[[UILabel alloc]
                initWithFrame:CGRectMake(badgeRight - 50, (44 - 18) / 2, 50, 18)] autorelease];
            badge.text = isTransit ? NSLocalizedString(@"中转", nil)
                                   : NSLocalizedString(@"自定义", nil);
            badge.textColor = [UIColor whiteColor];
            badge.backgroundColor = isTransit ? [iOS6Theme tintColor]
                                              : [iOS6Theme secondaryTextColor];
            badge.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:10]];
            badge.textAlignment = NSTextAlignmentCenter;
            badge.layer.cornerRadius = 4.0f;
            badge.layer.masksToBounds = YES;
            badge.tag = 9001;  // for cleanup on cell reuse
            badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [cell.contentView addSubview:badge];
        }
        // Checkmark if this is the current default — v261025-8: image
        // entries compare against SettingsKeyImageGenModel, chat entries
        // against SettingsKeyModel.
        NSString *def = isImage
            ? [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyImageGenModel]
            : [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
        if (def && [def isEqualToString:mid]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    }
    else if (indexPath.section == [self _sectionForAdd]) {
        cell.textLabel.text = NSLocalizedString(@"+ 添加模型", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    }
    else if (indexPath.section == [self _sectionForCaps]) {
            // Build toggle cells (one per capability).
            NSString *label;
            NSString *key;
            if (indexPath.row == 0) {
                label = NSLocalizedString(@"支持图片识别", nil);
                key = SettingsKeyModelSupportsImages;
            } else {
                label = NSLocalizedString(@"支持思考", nil);
                key = SettingsKeyModelSupportsThinking;
            }
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 160, 44)];
            l.text = label;
            l.backgroundColor = [UIColor clearColor];
            l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
            l.textColor = [iOS6Theme textColor];
            l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
            [cell.contentView addSubview:l];
            [l release];

            UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
            BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
            [sw setOn:on animated:NO];
            sw.tag = indexPath.row == 0 ? 100 : 101;
            [sw addTarget:self action:@selector(_capToggleChanged:)
              forControlEvents:UIControlEventValueChanged];
            sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            CGRect f = cell.contentView.bounds;
            sw.frame = CGRectMake(f.size.width - 79 - 12, (44 - 27) / 2, 79, 27);
            [cell.contentView addSubview:sw];
    }
    return cell;
}

- (IBAction)_capToggleChanged:(UISwitch *)sw
{
    NSString *key = sw.tag == 100 ? SettingsKeyModelSupportsImages : SettingsKeyModelSupportsThinking;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"capability %@ = %@", key, sw.on ? @"ON" : @"OFF"]];
    if (sw.tag == 100) {
        // Image support affects ComposerView — broadcast theme change.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"iOS6ThemeDidChangeNotification" object:nil];
    }
}

#pragma mark - Table delegate

// v261025-7: group rows are editable (swipe-to-delete); everything else isn't.
- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self _groupIndexForSection:indexPath.section] != NSNotFound;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSInteger gIdx = [self _groupIndexForSection:indexPath.section];
    if (gIdx == NSNotFound) return;
    NSDictionary *g = [_providerGroups objectAtIndex:gIdx];
    NSArray *entries = [g objectForKey:@"entries"];
    if (indexPath.row >= (NSInteger)[entries count]) return;
    NSDictionary *e = [entries objectAtIndex:indexPath.row];
    NSString *toDel = [e objectForKey:@"id"];
    if (![toDel isKindOfClass:[NSString class]] || toDel.length == 0) return;
    // Confirm before deletion (tag 700 alert).
    UIAlertView *av = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"删除模型?", nil)
              message:[NSString stringWithFormat:@"%@ \"%@\"", NSLocalizedString(@"确定从列表删除", nil), toDel]
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
    otherButtonTitles:NSLocalizedString(@"删除", nil), nil] autorelease];
    [av setTag:700];
    self.pendingDeleteModel = toDel;
    [av show];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger gIdx = [self _groupIndexForSection:indexPath.section];
    if (gIdx != NSNotFound) {
        // v261025-7: tap a group row → make it the ACTIVE entry. The chat
        // path resolves provider/baseURL/apiKey from it via
        // +resolvedConnectionForChat.
        // v261025-8: image entries activate the IMAGE-GEN path instead
        // (SettingsKeyImageGenModel) — the chat default is untouched.
        NSDictionary *g = [_providerGroups objectAtIndex:gIdx];
        NSArray *entries = [g objectForKey:@"entries"];
        if (indexPath.row >= (NSInteger)[entries count]) return;
        NSDictionary *e = [entries objectAtIndex:indexPath.row];
        NSString *m = [e objectForKey:@"id"];
        if (![m isKindOfClass:[NSString class]] || m.length == 0) return;
        BOOL isImage = [ModelManagementViewController entryIsImageKind:e];
        NSString *key = isImage ? SettingsKeyImageGenModel : SettingsKeyModel;
        [[NSUserDefaults standardUserDefaults] setObject:m forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"Default %@ model set to %@ (provider %@)",
                                      isImage ? @"IMAGE" : @"chat", m,
                                      [e objectForKey:@"provider"] ?: @"(global)"]];
        [_tableView reloadData];
        return;
    }
    if (indexPath.section == [self _sectionForAdd]) {
        // v261025-7: full form page instead of the old single-field alert.
        ModelAddViewController *add = [[[ModelAddViewController alloc] init] autorelease];
        [self.navigationController pushViewController:add animated:YES];
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    // v261025-3: tag 500 = transit bundled-model search loading alert.
    // The alert has only a 取消 button (buttonIndex 0). Tapping it sets
    // the cancel flag — the in-flight HTTP request can't be aborted, but
    // its result will be discarded when the dispatch_async returns.
    if (alertView.tag == 500) {
        _transitSearchCancelled = YES;
        return;
    }
    // v261025-7: tag 300 (legacy bare-model add alert) is retired — adding
    // now goes through ModelAddViewController. The branch is removed.
    if (alertView.tag == 700 && buttonIndex == 1) {
        // v261025-1: lean logging — entry + outcome only (v19's 10-line
        // firehose drowned the log; the Logger is crash-safe now).
        NSString *m = _pendingDeleteModel;
        if (!m || ![m isKindOfClass:[NSString class]] || m.length == 0) {
            self.pendingDeleteModel = nil;
            return;
        }
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"ModelMgmt delete '%@' — start", m]];
        [ModelManagementViewController removeModel:m];
        // v261025-8: if the deleted entry was the active IMAGE model,
        // clear (or re-resolve) the image-gen pointer.
        NSString *curImg = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyImageGenModel];
        if (curImg && [curImg isEqualToString:m]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:SettingsKeyImageGenModel];
            [[NSUserDefaults standardUserDefaults] synchronize];
            // resolvedConnectionForImageGen self-heals to the first
            // remaining image entry (if any) on next read.
        }
        // If deleted was the current default, fall back to first item.
        NSString *cur = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
        if (cur && [cur isEqualToString:m]) {
            NSArray *list = [ModelManagementViewController savedModelList];
            NSString *fallback = nil;
            if ([list count] > 0 && [(id)[list objectAtIndex:0] isKindOfClass:[NSString class]]) {
                fallback = [list objectAtIndex:0];
            } else {
                NSString *prov = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyProvider];
                if (!prov) prov = ProviderIDOpenAI;
                fallback = [SettingsViewController defaultModelForProvider:prov];
            }
            if ([fallback isKindOfClass:[NSString class]] && fallback.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:fallback
                                                          forKey:SettingsKeyModel];
                [[Logger sharedLogger] info:[NSString stringWithFormat:@"ModelMgmt default fell back to '%@'", fallback]];
            } else {
                // List now empty and no provider default — clear the key so
                // we never point at a deleted model.
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:SettingsKeyModel];
                [[Logger sharedLogger] warn:@"ModelMgmt default cleared — model list empty"];
            }
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"ModelMgmt delete '%@' — done", m]];
        [self _rebuildGroups];
        if (_tableView) [_tableView reloadData];
        self.pendingDeleteModel = nil;
    }
}

#pragma mark - Pending property setters (manual retain/release)

- (void)setPendingAddModel:(NSString *)m
{
    if (_pendingAddModel != m) {
        [_pendingAddModel release];
        _pendingAddModel = [m retain];
    }
}

- (void)setPendingDeleteModel:(NSString *)m
{
    if (_pendingDeleteModel != m) {
        [_pendingDeleteModel release];
        _pendingDeleteModel = [m retain];
    }
}

#pragma mark - /v1/models search

- (void)_searchAvailableModels
{
    // v261025-7: use the ACTIVE entry's resolved connection (provider /
    // baseURL / apiKey) instead of the raw global settings — so the
    // search hits whatever provider profile the user has selected.
    NSDictionary *conn = [ModelManagementViewController resolvedConnectionForChat];
    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];
    NSString *baseURL = [conn objectForKey:@"baseURL"];
    NSString *provider = [conn objectForKey:@"provider"];
    NSString *apiKey = [conn objectForKey:@"apiKey"];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelMgmt search models — transit=%d provider=%@", (int)useTransit, provider ?: @"?"]];

    UIAlertView *loading = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"搜索中…", nil)
              message:NSLocalizedString(@"正在从 /v1/models 拉取", nil)
             delegate:nil
    cancelButtonTitle:nil
    otherButtonTitles:nil] autorelease];
    [loading show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // v261025-1: @autoreleasepool — GCD worker threads have NO pool;
        // the autoreleased NetworkService below leaked per search.
        @autoreleasepool {
            NetworkService *svc = [[[NetworkService alloc] init] autorelease];
            NSError *err = nil;
            NSArray *models = [svc listModelsWithUseTransit:useTransit
                                                  transitURL:transitURL
                                                    baseURL:baseURL
                                                    provider:provider
                                                     apiKey:apiKey
                                                       error:&err];
            NSArray *resultsCopy = [models retain];
            NSError *errCopy = [err retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                // v261025-2: BUG FIX — the previous code did
                //   [resultsCopy release];
                // as the FIRST line of this block, then proceeded to
                // read `resultsCopy` (count check, objectAtIndex:) below.
                // Under MRC the block retains resultsCopy (+1) so the
                // release left it at +1 from the original [models retain]
                // — i.e. one dangling +1 that survived only by accident
                // of block-retain ordering. Move the release to the END
                // of the success path (and the existing early-return
                // releases) to match SettingsVC's correct pattern.
                [loading dismissWithClickedButtonIndex:-1 animated:NO];
                if (errCopy || !resultsCopy || [resultsCopy count] == 0) {
                    // Capture the description BEFORE releasing errCopy.
                    NSString *errDesc = [errCopy localizedDescription];
                    [[Logger sharedLogger] error:[NSString stringWithFormat:
                        @"ModelMgmt search failed — %@",
                        errDesc ?: @"no models / empty response"]];
                    UIAlertView *fail = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"未拉到模型", nil)
                              message:errDesc ?: NSLocalizedString(@"服务器无返回,请检查 BaseURL / API Key", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [errCopy release];
                    [resultsCopy release];
                    [fail show];
                    return;
                }
                [errCopy release];
                // v261025-1: NEVER show a new alert/sheet in the same tick
                // that a previous one is dismissing — on iOS 6 the
                // dismiss-then-show-same-tick pattern corrupts the alert
                ///sheet window stack (the "tap cancel → crash" report).
                // Dismiss above is animated:NO and the sheet is deferred
                // to the next runloop turn.
                NSInteger limit = MIN([resultsCopy count], (NSUInteger)8);
                NSMutableArray *picked = [NSMutableArray array];
                for (NSInteger i = 0; i < limit; i++) {
                    NSString *mid = [resultsCopy objectAtIndex:i];
                    if ([mid isKindOfClass:[NSString class]]) [picked addObject:mid];
                }
                self.availableModels = [NSMutableArray arrayWithArray:picked];
                [[Logger sharedLogger] info:[NSString stringWithFormat:
                    @"ModelMgmt search OK — %lu models", (unsigned long)[picked count]]];
                [resultsCopy release];
                [self performSelector:@selector(_presentModelSheet)
                           withObject:nil
                           afterDelay:0.1];
            });
        }
    });
}

- (void)_presentModelSheet
{
    // Runs on main, one runloop turn AFTER the loading alert was dismissed.
    if ([_availableModels count] == 0) return;
    UIActionSheet *sheet = [[[UIActionSheet alloc]
        initWithTitle:NSLocalizedString(@"选模型 → 加入列表", nil)
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
destructiveButtonTitle:nil
        otherButtonTitles:nil] autorelease];
    if ([iOS6Theme isDarkMode]) {
        sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
    } else {
        sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
    }
    NSInteger limit = MIN([_availableModels count], (NSUInteger)8);
    for (NSInteger i = 0; i < limit; i++) {
        [sheet addButtonWithTitle:[_availableModels objectAtIndex:i]];
    }
    [sheet setTag:400];
    [sheet showInView:self.view];
}

#pragma mark - v261025-6 Test connection

// Same /v1/models call as _searchAvailableModels, but the result is shown
// as an alert (not a model-picker sheet). Useful when the user just wants
// to verify their BaseURL / API Key / Transit URL / provider config
// without committing to adding a model.
- (void)_testConnection
{
    // v261025-7: use the ACTIVE entry's resolved connection — testing what
    // the chat will actually use.
    NSDictionary *conn = [ModelManagementViewController resolvedConnectionForChat];
    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];
    NSString *baseURL = [conn objectForKey:@"baseURL"];
    NSString *provider = [conn objectForKey:@"provider"];
    NSString *apiKey = [conn objectForKey:@"apiKey"];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelMgmt test connection — transit=%d provider=%@", (int)useTransit, provider ?: @"?"]];

    UIAlertView *loading = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"测试中…", nil)
              message:NSLocalizedString(@"正在发起 GET /v1/models", nil)
             delegate:nil
    cancelButtonTitle:nil
    otherButtonTitles:nil] autorelease];
    [loading show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NetworkService *svc = [[[NetworkService alloc] init] autorelease];
            NSError *err = nil;
            NSArray *models = [svc listModelsWithUseTransit:useTransit
                                                  transitURL:transitURL
                                                    baseURL:baseURL
                                                    provider:provider
                                                     apiKey:apiKey
                                                       error:&err];
            NSArray *resultsCopy = [models retain];
            NSError *errCopy = [err retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                [loading dismissWithClickedButtonIndex:-1 animated:NO];
                if (errCopy || !resultsCopy || [resultsCopy count] == 0) {
                    NSString *errDesc = [errCopy localizedDescription];
                    [[Logger sharedLogger] error:[NSString stringWithFormat:
                        @"ModelMgmt test connection FAIL — %@", errDesc ?: @"(no response)"]];
                    UIAlertView *fail = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"连接失败", nil)
                              message:errDesc ?: NSLocalizedString(@"无返回,请检查 BaseURL / API Key / 中转 URL", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [fail show];
                } else {
                    [[Logger sharedLogger] info:[NSString stringWithFormat:
                        @"ModelMgmt test connection OK — %lu models", (unsigned long)[resultsCopy count]]];
                    UIAlertView *ok = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"连接成功", nil)
                              message:[NSString stringWithFormat:
                                  NSLocalizedString(@"服务器返回 %d 个可用模型。", nil),
                                  (int)[resultsCopy count]]
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [ok show];
                }
                [errCopy release];
                [resultsCopy release];
            });
        }
    });
}

- (void)actionSheet:(UIActionSheet *)actionSheet
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    // v261025-2: iOS 6 UIActionSheet cancelButton occupies buttonIndex 0
    // (or actionSheet.cancelButtonIndex). The previous code only checked
    // `buttonIndex >= 0 && buttonIndex < count`, which let cancel (0) flow
    // into the "add model" branch — every "取消" tap silently added the
    // FIRST search result to the saved list and re-set the default model.
    // Not a direct crash, but it corrupts user data and matches the
    // "搜索模型后弹出列表点击取消按钮闪退" report when the resulting
    // addModel + saveModelList path raced with the next reload. Real
    // model buttons live at buttonIndex == 1..N (cancel occupies 0).
    if (actionSheet.tag != 400) return;
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (buttonIndex < 1) return;
    NSInteger modelIndex = buttonIndex - 1;
    if (modelIndex >= (NSInteger)[_availableModels count]) return;
    NSString *m = [_availableModels objectAtIndex:modelIndex];
    if (![m isKindOfClass:[NSString class]] || m.length == 0) return;
    [ModelManagementViewController addModel:m];
    // Also set as default (user picked it explicitly).
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:SettingsKeyModel];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"Search added+default %@", m]];
    if (_tableView) [_tableView reloadData];
}

#pragma mark - Transit bundled model search (v261025-3)

// Search the transit server's own bundled model list via
// GET {transitURL}/v1/transit/models. If the server's
// TRANSIT_MODELS_ENABLED env var is 1, the returned models are
// bulk-added to local storage with source="transit". If disabled,
// prompt the user with "此中转服务器不含自带模型".
//
// Mid-search the user can tap 取消 on the loading alert. The underlying
// sendSynchronousRequest can't be aborted, so the result is simply
// discarded when the dispatch_async returns.
//
// NOTE: This method is called from TWO entry points:
//   - SettingsViewController when the user toggles "transit default
//     model" ON (we instantiate a fresh ModelMgmt VC, call this method,
//     then release).
//   - ModelMgmt's own "重新搜索" button row (under kMMSectionCurrent).
- (void)searchTransitBundledModels
{
    if (_transitSearchInProgress) {
        // Already searching — no-op (defensive; UI shouldn't allow this).
        return;
    }
    NSDictionary *settings = [SettingsViewController loadSettings];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];
    if (!transitURL || transitURL.length == 0) {
        transitURL = @"https://ai-transit.awa.lat";
    }
    _transitSearchInProgress = YES;
    _transitSearchCancelled = NO;

    UIAlertView *loading = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"搜索中转自带模型…", nil)
              message:NSLocalizedString(@"正在连接中转服务器", nil)
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
    otherButtonTitles:nil] autorelease];
    [loading setTag:500];
    [loading show];

    NSString *transitURLCopy = [transitURL copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // v261025-1: @autoreleasepool — GCD worker threads have NO pool;
        // the autoreleased NetworkService below leaked per search.
        @autoreleasepool {
            NetworkService *svc = [[[NetworkService alloc] init] autorelease];
            NSError *err = nil;
            NSDictionary *result = [svc transitModelsAtTransitURL:transitURLCopy
                                                             error:&err];
            NSDictionary *resultCopy = [result retain];
            NSError *errCopy = [err retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                _transitSearchInProgress = NO;
                [loading dismissWithClickedButtonIndex:-1 animated:NO];
                // If user cancelled, ignore the result entirely.
                if (_transitSearchCancelled) {
                    _transitSearchCancelled = NO;
                    [errCopy release];
                    [resultCopy release];
                    [transitURLCopy release];
                    return;
                }
                if (errCopy || !resultCopy) {
                    NSString *errDesc = [errCopy localizedDescription];
                    [[Logger sharedLogger] error:[NSString stringWithFormat:
                        @"Transit bundled model search failed — %@",
                        errDesc ?: @"no response"]];
                    UIAlertView *fail = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"搜索失败", nil)
                              message:errDesc ?: NSLocalizedString(@"无法连接中转服务器", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [fail setTag:501];
                    [fail show];
                    [errCopy release];
                    [resultCopy release];
                    [transitURLCopy release];
                    return;
                }
                BOOL enabled = [[resultCopy objectForKey:@"enabled"] boolValue];
                NSArray *models = [resultCopy objectForKey:@"models"];
                if (!enabled) {
                    // Server-side toggle is OFF.
                    UIAlertView *disabled = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"此中转服务器不含自带模型", nil)
                              message:NSLocalizedString(@"请在中转服务器配置 TRANSIT_MODELS_ENABLED=1 后重试", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [disabled setTag:501];
                    [disabled show];
                    [errCopy release];
                    [resultCopy release];
                    [transitURLCopy release];
                    return;
                }
                if (![models isKindOfClass:[NSArray class]] || [models count] == 0) {
                    UIAlertView *empty = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"中转服务器未配置任何模型", nil)
                              message:NSLocalizedString(@"服务端 TRANSIT_MODELS 为空，请联系运维", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [empty setTag:501];
                    [empty show];
                    [errCopy release];
                    [resultCopy release];
                    [transitURLCopy release];
                    return;
                }
                // Success — bulk-add to local storage with source="transit".
                [ModelManagementViewController addTransitModels:models];
                // Record last-search timestamp (used by Settings page footer).
                [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                                          forKey:SettingsKeyTransitModelsLastSearch];
                [[NSUserDefaults standardUserDefaults] synchronize];
                if (_tableView) [_tableView reloadData];
                [[Logger sharedLogger] info:[NSString stringWithFormat:
                    @"Transit bundled models added — %lu", (unsigned long)[models count]]];
                UIAlertView *ok = [[[UIAlertView alloc]
                    initWithTitle:NSLocalizedString(@"搜索到的模型已存储至模型管理", nil)
                          message:[NSString stringWithFormat:
                              NSLocalizedString(@"已添加 %lu 个模型", nil),
                              (unsigned long)[models count]]
                         delegate:nil
                cancelButtonTitle:NSLocalizedString(@"好", nil)
                otherButtonTitles:nil] autorelease];
                [ok setTag:501];
                [ok show];
                [errCopy release];
                [resultCopy release];
                [transitURLCopy release];
            });
        }
    });
}

@end
