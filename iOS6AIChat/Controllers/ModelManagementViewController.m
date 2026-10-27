//
//  ModelManagementViewController.m
//  iOS6AIChat
//
//  v261025-9: TWO-TIER provider/model management (rewritten).
//    Section 0:   当前默认 (resolved chat model + 生图 model + 测试/搜索)
//    Sections 1..N: one section PER PROVIDER ENTRY (collapsible).
//                   Header tap = toggle collapse; row tap = set active;
//                   star button on row = toggle starred;
//                   DetailDisclosure on header = push ProviderEditViewController
//                   swipe-row = delete that model
//    Section N+1: + 添加模型供应商 (→ pushes ModelAddViewController)
//    Section N+2: 能力开关 (图片识别 / 思考)
//
//  See the .h file for the v261025-9 entry schema and migration logic.
//

#import "ModelManagementViewController.h"
#import "iOS6Theme.h"
#import "SettingsViewController.h"
#import "NetworkService.h"
#import "ModelAddViewController.h"
#import "ProviderEditViewController.h"
#import "Logger.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kCellReuseID   = @"ModelMgmtCell";
static NSString *const kHeaderReuseID = @"ModelMgmtHeader";

enum {
    kMMSectionCurrent = 0,   // 当前默认 (resolved active entry) + 测试/搜索
    // v261025-9: provider-entry group sections live between Current and Add.
    // Their count is dynamic (_providerEntries.count).
    kMMSectionAdd = 100,    // 添加 (+ 添加模型供应商 → ModelAddViewController)
    kMMSectionCaps,          // 能力开关 (图片识别 / 思考)
    kMMSectionCount
};

@interface ModelManagementViewController () {
    NSMutableArray *_availableModels;   // for /v1/models search action sheet
    NSString *_pendingDeleteModel;       // for tag-700 alert (confirm delete single model)
    NSString *_pendingDeleteProviderID;  // for tag-710 alert (confirm delete whole provider)
    BOOL _transitSearchInProgress;
    BOOL _transitSearchCancelled;
    // v261025-9: live cache of savedProviders (rebuilt on every viewWillAppear).
    NSArray *_providerEntries;
}
@end

@implementation ModelManagementViewController

@synthesize tableView=_tableView, availableModels=_availableModels;

#pragma mark - v261025-9 Two-tier provider persistence

// Generate a stable UUID string (used as provider entry id on creation).
+ (NSString *)newProviderUUID
{
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef s = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    NSString *nsStr = (NSString *)s;   // toll-free bridged
    // s is a +1 retain (CFCreate); we want an autorelease return.
    return [nsStr autorelease];
}

// v261025-10: return all starred models (across all providers) of the given
// kind, as flat dicts the composer's 加号 menu can display. kind="chat"
// picks non-image models; kind="image" picks image-gen models.
+ (NSArray *)_starredModelsOfKind:(NSString *)kind
{
    NSMutableArray *out = [NSMutableArray array];
    NSString *activeModelID = [[NSUserDefaults standardUserDefaults]
        stringForKey:[kind isEqualToString:@"image"] ? SettingsKeyImageGenModel
                                                     : SettingsKeyModel];
    for (NSDictionary *p in [self savedProviders]) {
        NSString *providerName = [p objectForKey:@"displayName"];
        if (![providerName isKindOfClass:[NSString class]] || providerName.length == 0) {
            providerName = [SettingsViewController displayNameForTemplate:
                            [p objectForKey:@"template"]];
        }
        NSArray *models = [p objectForKey:@"models"];
        if (![models isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *m in models) {
            if (![[m objectForKey:@"starred"] boolValue]) continue;
            NSString *mkind = [m objectForKey:@"kind"];
            BOOL isImage = [mkind isKindOfClass:[NSString class]] && [mkind isEqualToString:@"image"];
            if ([kind isEqualToString:@"image"]) {
                if (!isImage) continue;
            } else {
                if (isImage) continue;
            }
            NSString *mid = [m objectForKey:@"id"];
            if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
            NSString *dn = [m objectForKey:@"displayName"];
            if (![dn isKindOfClass:[NSString class]] || dn.length == 0) dn = mid;
            BOOL isActive = activeModelID && [activeModelID isEqualToString:mid];
            [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            mid, @"id",
                            dn, @"displayName",
                            providerName ?: @"?", @"providerDisplayName",
                            [NSNumber numberWithBool:isActive], @"active",
                            nil]];
        }
    }
    return out;
}

+ (NSArray *)starredChatModels  { return [self _starredModelsOfKind:@"chat"]; }
+ (NSArray *)starredImageModels { return [self _starredModelsOfKind:@"image"]; }

// Read the new two-tier structure from NSUserDefaults. Auto-migrates the
// legacy flat SettingsKeyModelList when the new key is empty.
+ (NSArray *)savedProviders
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *json = [d stringForKey:SettingsKeyProviderList];
    if (json.length == 0) {
        // Try the legacy flat list and migrate it.
        NSArray *migrated = [self _migrateLegacyFlatEntries];
        if (migrated) return migrated;
        // Nothing to migrate from either - seed an empty array.
        return [NSArray array];
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![parsed isKindOfClass:[NSArray class]]) {
        // Corrupt new key - try migrating the legacy list as a fallback.
        NSArray *migrated = [self _migrateLegacyFlatEntries];
        if (migrated) return migrated;
        return [NSArray array];
    }
    return parsed;
}

// Persist the new two-tier structure.
+ (void)saveProviders:(NSArray *)providers
{
    // De-duplicate by id (keep first occurrence); sanitize each entry.
    NSMutableArray *seen = [NSMutableArray array];
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:[providers count]];
    for (id p in providers) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        NSString *pid = [p objectForKey:@"id"];
        if (![pid isKindOfClass:[NSString class]] || pid.length == 0) {
            // Assign a fresh UUID if missing.
            pid = [self newProviderUUID];
        }
        if ([seen containsObject:pid]) continue;
        [seen addObject:pid];
        NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:p];
        [e setObject:pid forKey:@"id"];
        // Sanitize format / template / displayName / baseURL / apiKey.
        NSString *fmt = [e objectForKey:@"format"];
        if (![fmt isKindOfClass:[NSString class]] || fmt.length == 0) {
            fmt = ProviderFormatOpenAI;
        }
        [e setObject:fmt forKey:@"format"];
        NSString *tpl = [e objectForKey:@"template"];
        if (![tpl isKindOfClass:[NSString class]] || tpl.length == 0) {
            tpl = ProviderTemplateCustom;
        }
        [e setObject:tpl forKey:@"template"];
        NSString *dn = [e objectForKey:@"displayName"];
        if (![dn isKindOfClass:[NSString class]] || dn.length == 0) {
            dn = [SettingsViewController displayNameForTemplate:tpl];
        }
        [e setObject:dn forKey:@"displayName"];
        NSString *b = [e objectForKey:@"baseURL"];
        if (![b isKindOfClass:[NSString class]]) {
            [e setObject:@"" forKey:@"baseURL"];
        } else {
            [e setObject:b forKey:@"baseURL"];
        }
        NSString *k = [e objectForKey:@"apiKey"];
        if (![k isKindOfClass:[NSString class]]) {
            [e setObject:@"" forKey:@"apiKey"];
        } else {
            [e setObject:k forKey:@"apiKey"];
        }
        NSNumber *collapsed = [e objectForKey:@"collapsed"];
        if (![collapsed isKindOfClass:[NSNumber class]]) {
            [e setObject:[NSNumber numberWithBool:NO] forKey:@"collapsed"];
        }
        // Sanitize models array.
        id mObj = [e objectForKey:@"models"];
        if (![mObj isKindOfClass:[NSArray class]]) {
            [e setObject:[NSArray array] forKey:@"models"];
        } else {
            NSMutableArray *cleanModels = [NSMutableArray array];
            NSMutableArray *seenMIDs = [NSMutableArray array];
            for (id m in (NSArray *)mObj) {
                if (![m isKindOfClass:[NSDictionary class]]) continue;
                NSString *mid = [m objectForKey:@"id"];
                if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
                if ([seenMIDs containsObject:mid]) continue;
                [seenMIDs addObject:mid];
                NSMutableDictionary *mc = [NSMutableDictionary dictionaryWithDictionary:m];
                [mc setObject:mid forKey:@"id"];
                NSNumber *st = [mc objectForKey:@"starred"];
                if (![st isKindOfClass:[NSNumber class]]) {
                    [mc setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
                }
                NSString *kind = [mc objectForKey:@"kind"];
                if (![kind isKindOfClass:[NSString class]] || kind.length == 0) {
                    [mc setObject:@"chat" forKey:@"kind"];
                }
                // displayName optional - drop if not a string.
                id dnM = [mc objectForKey:@"displayName"];
                if (![dnM isKindOfClass:[NSString class]] || [(NSString *)dnM length] == 0) {
                    [mc removeObjectForKey:@"displayName"];
                }
                [cleanModels addObject:mc];
            }
            [e setObject:[NSArray arrayWithArray:cleanModels] forKey:@"models"];
        }
        [clean addObject:e];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:clean options:0 error:&err];
    if (data) {
        NSString *j = [[[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding] autorelease];
        [[NSUserDefaults standardUserDefaults] setObject:j
                                                  forKey:SettingsKeyProviderList];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

// Migrate legacy SettingsKeyModelList flat entries → new two-tier structure.
// Returns the migrated array (and persists it), or nil when there's no
// legacy list to migrate.
+ (NSArray *)_migrateLegacyFlatEntries
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *json = [d stringForKey:SettingsKeyModelList];
    if (json.length == 0) return nil;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![parsed isKindOfClass:[NSArray class]] || [parsed count] == 0) return nil;
    // Group by (provider, baseURL, apiKey).
    NSMutableArray *groups = [NSMutableArray array];
    for (id e in parsed) {
        NSString *mid = nil;
        NSString *provider = ProviderIDOpenAI;
        NSString *baseURL = @"";
        NSString *apiKey = @"";
        NSString *displayName = @"";
        NSString *kind = @"chat";
        if ([e isKindOfClass:[NSDictionary class]]) {
            mid = [e objectForKey:@"id"];
            id p = [e objectForKey:@"provider"];
            if ([p isKindOfClass:[NSString class]] && [(NSString *)p length] > 0) provider = p;
            id b = [e objectForKey:@"baseURL"];
            if ([b isKindOfClass:[NSString class]]) baseURL = b;
            id k = [e objectForKey:@"apiKey"];
            if ([k isKindOfClass:[NSString class]]) apiKey = k;
            id dn = [e objectForKey:@"displayName"];
            if ([dn isKindOfClass:[NSString class]]) displayName = dn;
            id kk = [e objectForKey:@"kind"];
            if ([kk isKindOfClass:[NSString class]] && [(NSString *)kk length] > 0) kind = kk;
        } else if ([e isKindOfClass:[NSString class]]) {
            mid = e;
        }
        if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
        // Find existing group.
        NSMutableDictionary *g = nil;
        for (NSMutableDictionary *gg in groups) {
            NSString *gp = [gg objectForKey:@"template"];
            NSString *gb = [gg objectForKey:@"baseURL"];
            NSString *gk = [gg objectForKey:@"apiKey"];
            if ([gp isEqualToString:provider] &&
                [gb isEqualToString:baseURL] &&
                [gk isEqualToString:apiKey]) {
                g = gg;
                break;
            }
        }
        if (!g) {
            g = [NSMutableDictionary dictionary];
            [g setObject:[self newProviderUUID] forKey:@"id"];
            [g setObject:[SettingsViewController formatForTemplate:provider] forKey:@"format"];
            [g setObject:provider forKey:@"template"];
            [g setObject:[SettingsViewController displayNameForTemplate:provider] forKey:@"displayName"];
            [g setObject:baseURL forKey:@"baseURL"];
            [g setObject:apiKey forKey:@"apiKey"];
            [g setObject:[NSNumber numberWithBool:NO] forKey:@"collapsed"];
            [g setObject:[NSMutableArray array] forKey:@"models"];
            [groups addObject:g];
        }
        NSMutableDictionary *mc = [NSMutableDictionary dictionary];
        [mc setObject:mid forKey:@"id"];
        [mc setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
        [mc setObject:kind forKey:@"kind"];
        if (displayName.length > 0) [mc setObject:displayName forKey:@"displayName"];
        [[g objectForKey:@"models"] addObject:mc];
    }
    NSArray *result = [NSArray arrayWithArray:groups];
    [self saveProviders:result];
    // Clear the legacy key so we don't re-migrate (it stays around for
    // one more downgrade-compat launch, then is dropped on next save).
    return result;
}

// Look up the provider entry owning a given model id.
+ (NSDictionary *)providerEntryContainingModel:(NSString *)modelID
{
    if (![modelID isKindOfClass:[NSString class]] || modelID.length == 0) return nil;
    for (NSDictionary *p in [self savedProviders]) {
        NSArray *models = [p objectForKey:@"models"];
        if (![models isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *m in models) {
            NSString *mid = [m objectForKey:@"id"];
            if ([mid isKindOfClass:[NSString class]] && [mid isEqualToString:modelID]) {
                return p;
            }
        }
    }
    return nil;
}

+ (void)toggleCollapsedForProviderID:(NSString *)providerUUID
{
    if (![providerUUID isKindOfClass:[NSString class]] || providerUUID.length == 0) return;
    NSMutableArray *arr = [[self savedProviders] mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)[arr count]; i++) {
        NSDictionary *p = [arr objectAtIndex:i];
        if ([[p objectForKey:@"id"] isEqualToString:providerUUID]) {
            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:p];
            BOOL was = [[m objectForKey:@"collapsed"] boolValue];
            [m setObject:[NSNumber numberWithBool:!was] forKey:@"collapsed"];
            [arr replaceObjectAtIndex:i withObject:m];
            [arr autorelease];
            [self saveProviders:arr];
            return;
        }
    }
    [arr autorelease];
}

+ (void)toggleStarredForModel:(NSString *)modelID
                inProviderID:(NSString *)providerUUID
{
    if (!modelID.length || !providerUUID.length) return;
    NSMutableArray *arr = [[self savedProviders] mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)[arr count]; i++) {
        NSDictionary *p = [arr objectAtIndex:i];
        if (![[p objectForKey:@"id"] isEqualToString:providerUUID]) continue;
        NSMutableDictionary *pm = [NSMutableDictionary dictionaryWithDictionary:p];
        NSMutableArray *models = [[p objectForKey:@"models"] mutableCopy];
        for (NSInteger j = 0; j < (NSInteger)[models count]; j++) {
            NSDictionary *m = [models objectAtIndex:j];
            if (![[m objectForKey:@"id"] isEqualToString:modelID]) continue;
            NSMutableDictionary *mm = [NSMutableDictionary dictionaryWithDictionary:m];
            BOOL was = [[mm objectForKey:@"starred"] boolValue];
            [mm setObject:[NSNumber numberWithBool:!was] forKey:@"starred"];
            [models replaceObjectAtIndex:j withObject:mm];
            break;
        }
        [pm setObject:models forKey:@"models"];
        [models release];
        [arr replaceObjectAtIndex:i withObject:pm];
        [arr autorelease];
        [self saveProviders:arr];
        return;
    }
    [arr autorelease];
}

+ (void)setActiveModel:(NSString *)modelID
{
    if (![modelID isKindOfClass:[NSString class]] || modelID.length == 0) return;
    NSDictionary *p = [self providerEntryContainingModel:modelID];
    NSString *key = SettingsKeyModel;
    for (NSDictionary *m in [p objectForKey:@"models"]) {
        if ([[m objectForKey:@"id"] isEqualToString:modelID]) {
            if ([[m objectForKey:@"kind"] isEqualToString:@"image"]) {
                key = SettingsKeyImageGenModel;
            }
            break;
        }
    }
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:modelID forKey:key];
    [d synchronize];
}

+ (void)addModel:(NSString *)modelID
            kind:(NSString *)kind
    toProviderID:(NSString *)providerUUID
{
    if (!modelID.length || !providerUUID.length) return;
    NSString *effectiveKind = ([kind isEqualToString:@"image"]) ? @"image" : @"chat";
    NSMutableArray *arr = [[self savedProviders] mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)[arr count]; i++) {
        NSDictionary *p = [arr objectAtIndex:i];
        if (![[p objectForKey:@"id"] isEqualToString:providerUUID]) continue;
        NSMutableDictionary *pm = [NSMutableDictionary dictionaryWithDictionary:p];
        NSMutableArray *models = [[p objectForKey:@"models"] mutableCopy];
        // Skip if already exists.
        for (NSDictionary *m in models) {
            if ([[m objectForKey:@"id"] isEqualToString:modelID]) {
                [models release];
                [arr autorelease];
                return;
            }
        }
        NSMutableDictionary *nm = [NSMutableDictionary dictionary];
        [nm setObject:modelID forKey:@"id"];
        [nm setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
        [nm setObject:effectiveKind forKey:@"kind"];
        [models addObject:nm];
        [pm setObject:models forKey:@"models"];
        [models release];
        [arr replaceObjectAtIndex:i withObject:pm];
        [arr autorelease];
        [self saveProviders:arr];
        return;
    }
    [arr autorelease];
}

+ (void)removeModel:(NSString *)modelID
     fromProviderID:(NSString *)providerUUID
{
    if (!modelID.length || !providerUUID.length) return;
    NSMutableArray *arr = [[self savedProviders] mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)[arr count]; i++) {
        NSDictionary *p = [arr objectAtIndex:i];
        if (![[p objectForKey:@"id"] isEqualToString:providerUUID]) continue;
        NSMutableDictionary *pm = [NSMutableDictionary dictionaryWithDictionary:p];
        NSMutableArray *models = [[p objectForKey:@"models"] mutableCopy];
        for (NSInteger j = 0; j < (NSInteger)[models count]; j++) {
            NSDictionary *m = [models objectAtIndex:j];
            if ([[m objectForKey:@"id"] isEqualToString:modelID]) {
                [models removeObjectAtIndex:j];
                break;
            }
        }
        [pm setObject:models forKey:@"models"];
        [models release];
        [arr replaceObjectAtIndex:i withObject:pm];
        [arr autorelease];
        [self saveProviders:arr];
        // Clear active pointers if they referenced the removed model.
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *curChat = [d stringForKey:SettingsKeyModel];
        if (curChat && [curChat isEqualToString:modelID]) {
            [d removeObjectForKey:SettingsKeyModel];
            [d synchronize];
        }
        NSString *curImg = [d stringForKey:SettingsKeyImageGenModel];
        if (curImg && [curImg isEqualToString:modelID]) {
            [d removeObjectForKey:SettingsKeyImageGenModel];
            [d synchronize];
        }
        return;
    }
    [arr autorelease];
}

+ (void)replaceProviderWithID:(NSString *)providerUUID
                    newEntry:(NSDictionary *)newEntry
{
    if (!providerUUID.length || ![newEntry isKindOfClass:[NSDictionary class]]) return;
    NSMutableArray *arr = [[self savedProviders] mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)[arr count]; i++) {
        if ([[[arr objectAtIndex:i] objectForKey:@"id"] isEqualToString:providerUUID]) {
            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:newEntry];
            [m setObject:providerUUID forKey:@"id"];
            [arr replaceObjectAtIndex:i withObject:m];
            [arr autorelease];
            [self saveProviders:arr];
            return;
        }
    }
    // Not found - append.
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:newEntry];
    [m setObject:providerUUID forKey:@"id"];
    [arr addObject:m];
    [arr autorelease];
    [self saveProviders:arr];
}

+ (void)removeProviderWithID:(NSString *)providerUUID
{
    if (!providerUUID.length) return;
    NSMutableArray *arr = [[self savedProviders] mutableCopy];
    NSMutableArray *clean = [NSMutableArray array];
    NSDictionary *removed = nil;
    for (NSDictionary *p in arr) {
        if ([[p objectForKey:@"id"] isEqualToString:providerUUID]) {
            removed = p;
            continue;
        }
        [clean addObject:p];
    }
    [arr autorelease];
    [self saveProviders:clean];
    // Clear active pointers if they pointed at one of this provider's models.
    if (removed) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *curChat = [d stringForKey:SettingsKeyModel];
        NSString *curImg = [d stringForKey:SettingsKeyImageGenModel];
        NSArray *models = [removed objectForKey:@"models"];
        for (NSDictionary *m in models) {
            NSString *mid = [m objectForKey:@"id"];
            if (curChat && [curChat isEqualToString:mid]) {
                [d removeObjectForKey:SettingsKeyModel];
            }
            if (curImg && [curImg isEqualToString:mid]) {
                [d removeObjectForKey:SettingsKeyImageGenModel];
            }
        }
        [d synchronize];
    }
}

#pragma mark - Legacy back-compat shims (v261025-7 callers)

// Build a FLAT view of all models across all providers, each carrying its
// parent provider's connection info. This is what old callers
// (savedModelEntries / savedModelList / saveModelEntries / addModelEntry /
//  removeModel / addTransitModels / removeAllTransitModels /
//  sourceForModel) used to read.
+ (NSArray *)savedModelEntries
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in [self savedProviders]) {
        NSString *provider = [p objectForKey:@"template"];
        NSString *baseURL = [p objectForKey:@"baseURL"];
        NSString *apiKey = [p objectForKey:@"apiKey"];
        NSString *providerUUID = [p objectForKey:@"id"];
        NSArray *models = [p objectForKey:@"models"];
        for (NSDictionary *m in models) {
            NSString *mid = [m objectForKey:@"id"];
            if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
            NSMutableDictionary *e = [NSMutableDictionary dictionary];
            [e setObject:mid forKey:@"id"];
            [e setObject:provider ?: ProviderIDOpenAI forKey:@"provider"];
            if (baseURL.length > 0) [e setObject:baseURL forKey:@"baseURL"];
            if (apiKey.length > 0) [e setObject:apiKey forKey:@"apiKey"];
            [e setObject:providerUUID ?: @"" forKey:@"providerUUID"];
            NSString *kind = [m objectForKey:@"kind"];
            if ([kind isKindOfClass:[NSString class]] && kind.length > 0) {
                [e setObject:kind forKey:@"kind"];
            }
            NSString *dn = [m objectForKey:@"displayName"];
            if ([dn isKindOfClass:[NSString class]] && dn.length > 0) {
                [e setObject:dn forKey:@"displayName"];
            }
            BOOL starred = [[m objectForKey:@"starred"] boolValue];
            [e setObject:[NSNumber numberWithBool:starred] forKey:@"starred"];
            [e setObject:@"user" forKey:@"source"];
            [out addObject:e];
        }
    }
    // First-launch seeding: if both keys were empty, seed with the global
    // provider's defaults so the user has something to pick from.
    if ([out count] == 0) {
        NSString *provider = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyProvider] ?: ProviderIDOpenAI;
        NSArray *seedIDs = [SettingsViewController _defaultModelListForProvider:provider];
        NSString *baseURL = [SettingsViewController defaultBaseURLForProvider:provider];
        NSString *pid = [self newProviderUUID];
        NSMutableArray *models = [NSMutableArray array];
        for (NSString *mid in seedIDs) {
            NSMutableDictionary *mc = [NSMutableDictionary dictionary];
            [mc setObject:mid forKey:@"id"];
            [mc setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
            [mc setObject:@"chat" forKey:@"kind"];
            [models addObject:mc];
            // Also push into the flat view we return.
            NSMutableDictionary *e = [NSMutableDictionary dictionary];
            [e setObject:mid forKey:@"id"];
            [e setObject:provider forKey:@"provider"];
            if (baseURL.length > 0) [e setObject:baseURL forKey:@"baseURL"];
            [e setObject:pid forKey:@"providerUUID"];
            [e setObject:@"user" forKey:@"source"];
            [out addObject:e];
        }
        // Persist as a single provider entry.
        NSDictionary *seedProvider = [NSDictionary dictionaryWithObjectsAndKeys:
                                       pid, @"id",
                                       [SettingsViewController formatForTemplate:provider], @"format",
                                       provider, @"template",
                                       [SettingsViewController displayNameForTemplate:provider], @"displayName",
                                       baseURL, @"baseURL",
                                       @"", @"apiKey",
                                       [NSNumber numberWithBool:NO], @"collapsed",
                                       [NSArray arrayWithArray:models], @"models",
                                       nil];
        [self saveProviders:[NSArray arrayWithObject:seedProvider]];
    }
    return out;
}

+ (NSArray *)savedModelList
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *e in [self savedModelEntries]) {
        NSString *mid = [e objectForKey:@"id"];
        if ([mid isKindOfClass:[NSString class]]) [out addObject:mid];
    }
    return out;
}

// Merges a flat entry into the matching provider entry (creating one if
// needed). Used by /v1/models search "add" + the legacy bare-id add path.
+ (void)saveModelEntries:(NSArray *)entries
{
    // Group the supplied flat entries by (provider, baseURL, apiKey) and
    // merge them into the existing provider list. Existing models inside
    // each provider are preserved; supplied entries are added if missing.
    NSMutableArray *existing = [[self savedProviders] mutableCopy];
    for (NSDictionary *e in entries) {
        NSString *mid = [e objectForKey:@"id"];
        if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
        NSString *provider = [e objectForKey:@"provider"];
        if (![provider isKindOfClass:[NSString class]] || provider.length == 0) {
            provider = ProviderIDOpenAI;
        }
        NSString *baseURL = [e objectForKey:@"baseURL"];
        if (![baseURL isKindOfClass:[NSString class]]) baseURL = @"";
        NSString *apiKey = [e objectForKey:@"apiKey"];
        if (![apiKey isKindOfClass:[NSString class]]) apiKey = @"";
        NSString *kind = [e objectForKey:@"kind"];
        if (![kind isKindOfClass:[NSString class]] || kind.length == 0) kind = @"chat";
        NSString *displayName = [e objectForKey:@"displayName"];
        BOOL starred = [[e objectForKey:@"starred"] boolValue];
        // Find a matching provider entry.
        NSMutableDictionary *g = nil;
        for (NSMutableDictionary *gg in existing) {
            NSString *gp = [gg objectForKey:@"template"];
            NSString *gb = [gg objectForKey:@"baseURL"];
            NSString *gk = [gg objectForKey:@"apiKey"];
            if ([gp isEqualToString:provider] &&
                [gb isEqualToString:baseURL] &&
                [gk isEqualToString:apiKey]) {
                g = gg;
                break;
            }
        }
        if (!g) {
            g = [NSMutableDictionary dictionary];
            [g setObject:[self newProviderUUID] forKey:@"id"];
            [g setObject:[SettingsViewController formatForTemplate:provider] forKey:@"format"];
            [g setObject:provider forKey:@"template"];
            [g setObject:[SettingsViewController displayNameForTemplate:provider] forKey:@"displayName"];
            [g setObject:baseURL forKey:@"baseURL"];
            [g setObject:apiKey forKey:@"apiKey"];
            [g setObject:[NSNumber numberWithBool:NO] forKey:@"collapsed"];
            [g setObject:[NSMutableArray array] forKey:@"models"];
            [existing addObject:g];
        }
        NSMutableArray *models = [[g objectForKey:@"models"] mutableCopy];
        // Skip if the model already exists; otherwise append.
        BOOL exists = NO;
        for (NSDictionary *m in models) {
            if ([[m objectForKey:@"id"] isEqualToString:mid]) { exists = YES; break; }
        }
        if (!exists) {
            NSMutableDictionary *mc = [NSMutableDictionary dictionary];
            [mc setObject:mid forKey:@"id"];
            [mc setObject:[NSNumber numberWithBool:starred] forKey:@"starred"];
            [mc setObject:kind forKey:@"kind"];
            if ([displayName isKindOfClass:[NSString class]] && displayName.length > 0) {
                [mc setObject:displayName forKey:@"displayName"];
            }
            [models addObject:mc];
            [g setObject:models forKey:@"models"];
        }
        [models release];
    }
    [existing autorelease];
    [self saveProviders:existing];
}

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

// Legacy bare-id add: appends to the FIRST provider entry whose template
// matches the global settings provider, or creates a new provider entry.
+ (void)addModel:(NSString *)model
{
    if (!model.length) return;
    // De-dupe across all providers.
    if ([self providerEntryContainingModel:model]) return;
    NSString *provider = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyProvider] ?: ProviderIDOpenAI;
    NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyBaseURL] ?: [SettingsViewController defaultBaseURLForProvider:provider];
    if (!baseURL.length) baseURL = [SettingsViewController defaultBaseURLForProvider:provider];
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyAPIKey] ?: @"";
    [self saveModelEntries:[NSArray arrayWithObject:
        [NSDictionary dictionaryWithObjectsAndKeys:
            model, @"id",
            provider, @"provider",
            baseURL, @"baseURL",
            apiKey, @"apiKey",
            @"chat", @"kind",
            @"user", @"source", nil]]];
}

+ (void)addModelEntry:(NSDictionary *)entry
{
    if (![entry isKindOfClass:[NSDictionary class]]) return;
    NSString *mid = [entry objectForKey:@"id"];
    if (![mid isKindOfClass:[NSString class]] || mid.length == 0) return;
    // Use saveModelEntries: which merges and de-dupes.
    [self saveModelEntries:[NSArray arrayWithObject:entry]];
}

+ (void)removeModel:(NSString *)model
{
    if (!model.length) return;
    NSDictionary *p = [self providerEntryContainingModel:model];
    if (!p) return;
    [self removeModel:model fromProviderID:[p objectForKey:@"id"]];
}

+ (void)addTransitModels:(NSArray *)modelIDs
{
    if (!modelIDs || [modelIDs count] == 0) return;
    // Transit models go into the "transit" pseudo-provider entry. We use
    // template="custom", displayName="中转自带", baseURL=transitURL.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *transitURL = [d stringForKey:SettingsKeyTransitURL];
    if (!transitURL.length) transitURL = @"https://ai-transit.awa.lat";
    NSMutableArray *existing = [[self savedProviders] mutableCopy];
    // Find or create the transit provider entry.
    NSMutableDictionary *g = nil;
    for (NSMutableDictionary *gg in existing) {
        NSString *t = [gg objectForKey:@"template"];
        NSString *b = [gg objectForKey:@"baseURL"];
        if ([t isEqualToString:ProviderTemplateCustom] && [b isEqualToString:transitURL]) {
            g = gg;
            break;
        }
    }
    if (!g) {
        g = [NSMutableDictionary dictionary];
        [g setObject:[self newProviderUUID] forKey:@"id"];
        [g setObject:ProviderFormatOpenAI forKey:@"format"];
        [g setObject:ProviderTemplateCustom forKey:@"template"];
        [g setObject:NSLocalizedString(@"中转自带", nil) forKey:@"displayName"];
        [g setObject:transitURL forKey:@"baseURL"];
        [g setObject:@"" forKey:@"apiKey"];
        [g setObject:[NSNumber numberWithBool:NO] forKey:@"collapsed"];
        [g setObject:[NSMutableArray array] forKey:@"models"];
        [existing addObject:g];
    }
    NSMutableArray *models = [[g objectForKey:@"models"] mutableCopy];
    for (NSString *mid in modelIDs) {
        if (![mid isKindOfClass:[NSString class]] || mid.length == 0) continue;
        BOOL exists = NO;
        for (NSDictionary *m in models) {
            if ([[m objectForKey:@"id"] isEqualToString:mid]) { exists = YES; break; }
        }
        if (exists) continue;
        NSMutableDictionary *mc = [NSMutableDictionary dictionary];
        [mc setObject:mid forKey:@"id"];
        [mc setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
        [mc setObject:@"chat" forKey:@"kind"];
        [models addObject:mc];
    }
    [g setObject:models forKey:@"models"];
    [models release];
    [existing autorelease];
    [self saveProviders:existing];
}

+ (void)removeAllTransitModels
{
    NSMutableArray *arr = [[self savedProviders] mutableCopy];
    NSMutableArray *clean = [NSMutableArray array];
    NSInteger removed = 0;
    for (NSDictionary *p in arr) {
        NSString *t = [p objectForKey:@"template"];
        NSString *b = [p objectForKey:@"baseURL"];
        NSString *dn = [p objectForKey:@"displayName"];
        if ([t isEqualToString:ProviderTemplateCustom] &&
            [dn isEqualToString:NSLocalizedString(@"中转自带", nil)] &&
            [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyTransitURL]
                ? [[[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyTransitURL] isEqualToString:b]
                : YES) {
            // This is the transit provider entry - drop it entirely.
            removed += [[p objectForKey:@"models"] count];
            continue;
        }
        [clean addObject:p];
    }
    [arr autorelease];
    [self saveProviders:clean];
    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelMgmt removeAllTransitModels - %d models removed", (int)removed]];
}

+ (NSString *)sourceForModel:(NSString *)model
{
    if (!model.length) return @"user";
    NSDictionary *p = [self providerEntryContainingModel:model];
    if (!p) return @"user";
    NSString *dn = [p objectForKey:@"displayName"];
    if ([dn isEqualToString:NSLocalizedString(@"中转自带", nil)]) return @"transit";
    return @"user";
}

#pragma mark - v261025-9 resolved connection for the chat / image paths

// Returns { format, template, baseURL, apiKey, model } for the ACTIVE chat
// model. Falls back to global settings defaults when the active model can't
// be found in any provider entry (legacy path).
+ (NSDictionary *)resolvedConnectionForChat
{
    NSDictionary *settings = [SettingsViewController loadSettings];
    NSString *model = [settings objectForKey:SettingsKeyModel];
    NSDictionary *provider = nil;
    if (model.length > 0) {
        provider = [self providerEntryContainingModel:model];
    }
    NSString *format = [provider objectForKey:@"format"];
    if (![format isKindOfClass:[NSString class]] || format.length == 0) {
        format = ProviderFormatOpenAI;
    }
    NSString *template = [provider objectForKey:@"template"];
    if (![template isKindOfClass:[NSString class]] || template.length == 0) {
        template = [settings objectForKey:SettingsKeyProvider];
    }
    NSString *baseURL = [provider objectForKey:@"baseURL"];
    if (![baseURL isKindOfClass:[NSString class]] || baseURL.length == 0) {
        baseURL = [settings objectForKey:SettingsKeyBaseURL];
    }
    NSString *apiKey = [provider objectForKey:@"apiKey"];
    if (![apiKey isKindOfClass:[NSString class]] || apiKey.length == 0) {
        apiKey = [settings objectForKey:SettingsKeyAPIKey];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
            format, @"format",
            template ?: ProviderIDOpenAI, @"template",
            baseURL   ?: @"https://api.openai.com", @"baseURL",
            apiKey    ?: @"", @"apiKey",
            model     ?: @"", @"model",
            nil];
}

// Returns { format, template, baseURL, apiKey, model } for the ACTIVE image
// model. model is @"" when no image model is configured.
+ (NSDictionary *)resolvedConnectionForImageGen
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *model = [d stringForKey:SettingsKeyImageGenModel];
    NSDictionary *provider = nil;
    if (model.length > 0) {
        provider = [self providerEntryContainingModel:model];
    }
    // Fallback: pick the first image-kind model across all providers.
    if (!provider) {
        for (NSDictionary *p in [self savedProviders]) {
            NSArray *models = [p objectForKey:@"models"];
            for (NSDictionary *m in models) {
                if ([[m objectForKey:@"kind"] isEqualToString:@"image"]) {
                    provider = p;
                    model = [m objectForKey:@"id"];
                    if (model.length > 0) {
                        [d setObject:model forKey:SettingsKeyImageGenModel];
                        [d synchronize];
                    }
                    break;
                }
            }
            if (provider) break;
        }
    }
    if (!provider) {
        // No image model configured anywhere.
        return [NSDictionary dictionaryWithObjectsAndKeys:
                ProviderFormatOpenAI, @"format",
                ProviderIDZhipu, @"template",
                @"", @"baseURL",
                @"", @"apiKey",
                @"", @"model",
                nil];
    }
    NSString *format = [provider objectForKey:@"format"];
    if (![format isKindOfClass:[NSString class]] || format.length == 0) format = ProviderFormatOpenAI;
    NSString *template = [provider objectForKey:@"template"];
    if (![template isKindOfClass:[NSString class]] || template.length == 0) template = ProviderIDZhipu;
    NSString *baseURL = [provider objectForKey:@"baseURL"];
    if (![baseURL isKindOfClass:[NSString class]]) baseURL = @"";
    NSString *apiKey = [provider objectForKey:@"apiKey"];
    if (![apiKey isKindOfClass:[NSString class]]) apiKey = @"";
    return [NSDictionary dictionaryWithObjectsAndKeys:
            format, @"format",
            template, @"template",
            baseURL, @"baseURL",
            apiKey, @"apiKey",
            model ?: @"", @"model",
            nil];
}

+ (BOOL)entryIsImageKind:(NSDictionary *)entry
{
    // entry here is a flat model entry (legacy callers).
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;
    NSString *k = [entry objectForKey:@"kind"];
    return [k isKindOfClass:[NSString class]] && [k isEqualToString:@"image"];
}

+ (BOOL)modelIsImageKind:(NSDictionary *)modelDict
{
    if (![modelDict isKindOfClass:[NSDictionary class]]) return NO;
    NSString *k = [modelDict objectForKey:@"kind"];
    return [k isKindOfClass:[NSString class]] && [k isEqualToString:@"image"];
}

#pragma mark - Lifecycle

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"模型管理", nil);
        _availableModels = [[NSMutableArray array] retain];
        _providerEntries = [[NSArray array] retain];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_tableView release];
    [_availableModels release];
    [_pendingDeleteModel release];
    [_pendingDeleteProviderID release];
    [_providerEntries release];
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
    // v261025-9: register a custom header class for reuse so the
    // tap-to-collapse / DetailDisclosure work without rebuilding from
    // scratch on every reload (and so we can find the disclosure button
    // reliably for hit-testing).
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellReuseID];
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
    [self _rebuildProviderCache];
    [_tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    [self _rebuildProviderCache];
    [_tableView reloadData];
}

- (BOOL)_hasAnyImageEntry
{
    for (NSDictionary *p in _providerEntries) {
        for (NSDictionary *m in [p objectForKey:@"models"]) {
            if ([[m objectForKey:@"kind"] isEqualToString:@"image"]) return YES;
        }
    }
    return NO;
}

#pragma mark - Provider cache

- (void)_rebuildProviderCache
{
    NSArray *fresh = [ModelManagementViewController savedProviders];
    [_providerEntries release];
    _providerEntries = [fresh retain];
}

// Map a displayed section index → provider entry index (NSNotFound if not).
- (NSInteger)_providerIndexForSection:(NSInteger)section
{
    if (section < 1 || section > (NSInteger)[_providerEntries count]) return NSNotFound;
    return section - 1;
}

- (NSInteger)_sectionForAdd  { return 1 + (NSInteger)[_providerEntries count]; }
- (NSInteger)_sectionForCaps { return 2 + (NSInteger)[_providerEntries count]; }

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1 + (NSInteger)[_providerEntries count] + 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) {
        // v261025-11 (#7): the 生图模型 row (and its section-0 companion
        // layout) hides when the global image-gen feature switch is OFF.
        BOOL igFeature = [[NSUserDefaults standardUserDefaults]
            objectForKey:SettingsKeyImageGenFeatureEnabled]
            ? [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyImageGenFeatureEnabled]
            : YES;
        return igFeature ? 2 : 1;   // 对话模型 (+ 生图模型 when feature ON)
    }
    NSInteger pIdx = [self _providerIndexForSection:section];
    if (pIdx != NSNotFound) {
        NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
        BOOL collapsed = [[p objectForKey:@"collapsed"] boolValue];
        if (collapsed) return 0;
        return (NSInteger)[[p objectForKey:@"models"] count];
    }
    if (section == [self _sectionForAdd])  return 1;
    if (section == [self _sectionForCaps]) return 2;
    return 0;
}

- (NSString *)_titleForHeaderInProviderSection:(NSInteger)pIdx
{
    if (pIdx < 0 || pIdx >= (NSInteger)[_providerEntries count]) return @"";
    NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
    NSString *dn = [p objectForKey:@"displayName"];
    NSInteger cnt = (NSInteger)[[p objectForKey:@"models"] count];
    BOOL collapsed = [[p objectForKey:@"collapsed"] boolValue];
    NSString *arrow = collapsed ? @"\u25B6" : @"\u25BC";  // ▶/▼
    return [NSString stringWithFormat:@"%@  %@ (%d)", arrow, dn ?: @"?", (int)cnt];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return NSLocalizedString(@"当前默认模型", nil);
    NSInteger pIdx = [self _providerIndexForSection:section];
    if (pIdx != NSNotFound) {
        return [self _titleForHeaderInProviderSection:pIdx];
    }
    if (section == [self _sectionForAdd]) return NSLocalizedString(@"添加", nil);
    if (section == [self _sectionForCaps]) return NSLocalizedString(@"能力（应用到所有模型）", nil);
    return @"";
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    // Provider sections get a CUSTOM header view (with tap-to-collapse +
    // an "编辑" DetailDisclosure button on the right).
    NSInteger pIdx = [self _providerIndexForSection:section];
    if (pIdx != NSNotFound) {
        NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
        CGRect hFrame = CGRectMake(0, 0, tableView.bounds.size.width, 36);
        UIView *hv = [[[UIView alloc] initWithFrame:hFrame] autorelease];
        hv.backgroundColor = [UIColor clearColor];
        hv.opaque = NO;
        NSString *title = [self _titleForHeaderInProviderSection:pIdx];
        UILabel *l = [[[UILabel alloc] initWithFrame:CGRectMake(12, 0,
                            hFrame.size.width - 12 - 80, 36)] autorelease];
        l.text = title;
        l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
        l.textColor = [iOS6Theme secondaryTextColor];
        l.backgroundColor = [UIColor clearColor];
        l.opaque = NO;
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.7f;
        [hv addSubview:l];
        // 编辑 button (right side).
        UIButton *edit = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        edit.frame = CGRectMake(hFrame.size.width - 30 - 6, (36 - 24) / 2, 24, 24);
        edit.tag = 1000 + pIdx;
        [edit addTarget:self action:@selector(_editProviderTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [hv addSubview:edit];
        // Tag the header view with the section index so a tap on the body
        // (not on the button) toggles collapse.
        hv.tag = 2000 + pIdx;
        // Install a tap recognizer on the header view.
        UITapGestureRecognizer *tr = [[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(_headerTapped:)] autorelease];
        [hv addGestureRecognizer:tr];
        return hv;
    }
    // Other sections: use the shared theme header (transparent, dark-mode-safe).
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return [iOS6Theme groupedSectionHeaderViewWithTitle:title
                                                  width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self _providerIndexForSection:section] != NSNotFound) return 36.0f;
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return (title.length > 0) ? 26.0f : 8.0f;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) {
        // v261025-11: image-gen feature OFF → the hint never mentions 生图.
        BOOL igFeature = [[NSUserDefaults standardUserDefaults]
            objectForKey:SettingsKeyImageGenFeatureEnabled]
            ? [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyImageGenFeatureEnabled]
            : YES;
        if (!igFeature) {
            return NSLocalizedString(@"点「测试」验证连接；点「搜索」从 /v1/models 拉取可选用模型。", nil);
        }
        if ([self _hasAnyImageEntry]) {
            return NSLocalizedString(@"点「测试」验证连接；点「搜索」从 /v1/models 拉取可选用模型。", nil);
        }
        return NSLocalizedString(@"点「测试」验证连接；点「搜索」从 /v1/models 拉取可选用模型。生图：先在「添加」里选生图模型类型。", nil);
    }
    NSInteger pIdx = [self _providerIndexForSection:section];
    if (pIdx != NSNotFound) {
        NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
        NSString *b = [p objectForKey:@"baseURL"];
        if (b.length > 0) {
            return [NSString stringWithFormat:
                NSLocalizedString(@"点模型设为默认；左滑删除。端点: %@", nil), b];
        }
        return NSLocalizedString(@"点模型设为默认；左滑删除。", nil);
    }
    if (section == [self _sectionForAdd]) {
        return NSLocalizedString(@"打开完整表单：选格式 + 模板 + 填 BaseURL / API Key / 模型。", nil);
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
    NSArray *oldSubviews = [cell.contentView.subviews copy];
    for (UIView *v in oldSubviews) [v removeFromSuperview];
    [oldSubviews release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
    cell.textLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        // Section 0 — current default chat model + image-gen model + 测试/搜索.
        BOOL isImageRow = (indexPath.row == 1);
        NSDictionary *conn = isImageRow
            ? [ModelManagementViewController resolvedConnectionForImageGen]
            : [ModelManagementViewController resolvedConnectionForChat];
        NSString *model = [conn objectForKey:@"model"];
        NSString *tpl  = [conn objectForKey:@"template"];
        BOOL hasModel = [model isKindOfClass:[NSString class]] && model.length > 0;
        NSString *display = hasModel ? model : NSLocalizedString(@"(未添加)", nil);

        UILabel *main = [[[UILabel alloc]
            initWithFrame:CGRectMake(12, 5, cell.contentView.bounds.size.width - 170, 20)] autorelease];
        main.text = isImageRow
            ? [NSString stringWithFormat:@"生图模型 · %@",
               ([tpl isKindOfClass:[NSString class]] && tpl.length > 0)
                   ? [SettingsViewController displayNameForTemplate:tpl] : @"?"]
            : [NSString stringWithFormat:@"对话模型 · %@",
               ([tpl isKindOfClass:[NSString class]] && tpl.length > 0)
                   ? [SettingsViewController displayNameForTemplate:tpl] : @"?"];
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
        testBtn.tag = 8888;
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
        btn.tag = 8889;
        CGRect f2 = cell.contentView.bounds;
        btn.frame = CGRectMake(f2.size.width - 76 - 12, (44 - 28) / 2, 76, 28);
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [btn addTarget:self action:@selector(_searchAvailableModels)
          forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:btn];
        return cell;
    }
    NSInteger pIdx = [self _providerIndexForSection:indexPath.section];
    if (pIdx != NSNotFound) {
        NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
        NSArray *models = [p objectForKey:@"models"];
        if (indexPath.row >= (NSInteger)[models count]) return cell;
        NSDictionary *m = [models objectAtIndex:indexPath.row];
        NSString *mid = [m objectForKey:@"id"];
        if (![mid isKindOfClass:[NSString class]]) return cell;
        NSString *dn = [m objectForKey:@"displayName"];
        cell.textLabel.text = [dn isKindOfClass:[NSString class]] && dn.length > 0 ? dn : mid;

        BOOL isImage = [ModelManagementViewController modelIsImageKind:m];
        BOOL starred = [[m objectForKey:@"starred"] boolValue];

        // Layout (right → left):
        //   checkmark/accessory (system)
        //   kind badge (生图)
        //   star toggle button
        CGFloat cw = cell.contentView.bounds.size.width;
        CGFloat x = cw - 12;
        // Star button (★/☆ toggle).
        UIButton *starBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [starBtn setTitle:starred ? @"\u2605" : @"\u2606"
                 forState:UIControlStateNormal];
        // v261025-9: Helvetica DOES have U+2605/U+2606 glyphs (unlike the
        // U+2713 checkmark we previously had to avoid). Tint them so the
        // "starred" state is visually distinct (gold vs grey).
        [starBtn setTitleColor:starred ? [UIColor colorWithRed:0.95f green:0.7f blue:0.1f alpha:1.0f]
                                            : [iOS6Theme secondaryTextColor]
                     forState:UIControlStateNormal];
        starBtn.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:20]];
        starBtn.frame = CGRectMake(x - 36, (44 - 30) / 2, 36, 30);
        starBtn.tag = 5000 + indexPath.row;
        starBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [starBtn addTarget:self action:@selector(_starTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:starBtn];
        x -= (36 + 6);

        if (isImage) {
            UILabel *imgBadge = [[[UILabel alloc]
                initWithFrame:CGRectMake(x - 40, (44 - 18) / 2, 40, 18)] autorelease];
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
            x -= (40 + 6);
        }

        // Checkmark if active.
        NSString *def = isImage
            ? [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyImageGenModel]
            : [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
        if (def && [def isEqualToString:mid]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    if (indexPath.section == [self _sectionForAdd]) {
        cell.textLabel.text = NSLocalizedString(@"+ 添加模型供应商", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    if (indexPath.section == [self _sectionForCaps]) {
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
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"iOS6ThemeDidChangeNotification" object:nil];
    }
}

#pragma mark - Section-header interactions (collapse + edit)

- (void)_headerTapped:(UITapGestureRecognizer *)tr
{
    UIView *hv = tr.view;
    NSInteger pIdx = hv.tag - 2000;
    if (pIdx < 0 || pIdx >= (NSInteger)[_providerEntries count]) return;
    NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
    NSString *pid = [p objectForKey:@"id"];
    [ModelManagementViewController toggleCollapsedForProviderID:pid];
    [self _rebuildProviderCache];
    // Reload just the affected section so the disclosure/collapse animation
    // is smooth (UITableView reloadSections is iOS 6 supported).
    NSIndexSet *idx = [NSIndexSet indexSetWithIndex:1 + pIdx];
    [_tableView reloadSections:idx withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)_editProviderTapped:(UIButton *)btn
{
    NSInteger pIdx = btn.tag - 1000;
    if (pIdx < 0 || pIdx >= (NSInteger)[_providerEntries count]) return;
    NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
    ProviderEditViewController *vc = [[[ProviderEditViewController alloc]
        initWithProviderEntry:p] autorelease];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)_starTapped:(UIButton *)btn
{
    // Walk up from the button to its section / row. The button is a direct
    // subview of the cell's contentView; we use its tag (5000+row) only to
    // identify the row inside the cell, but to find which section we need
    // the cell itself. We can't reliably get the section from the cell
    // without iterating the table, so we hit-test the button's frame.
    // Easier approach: re-discover via the button's window → table.
    UIView *v = btn;
    while (v && ![v isKindOfClass:[UITableViewCell class]]) v = v.superview;
    if (!v) return;
    NSIndexPath *ip = [_tableView indexPathForCell:(UITableViewCell *)v];
    if (!ip) return;
    NSInteger pIdx = [self _providerIndexForSection:ip.section];
    if (pIdx == NSNotFound) return;
    NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
    NSString *pid = [p objectForKey:@"id"];
    NSArray *models = [p objectForKey:@"models"];
    if (ip.row >= (NSInteger)[models count]) return;
    NSDictionary *m = [models objectAtIndex:ip.row];
    NSString *mid = [m objectForKey:@"id"];
    [ModelManagementViewController toggleStarredForModel:mid inProviderID:pid];
    [self _rebuildProviderCache];
    [_tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:ip]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table delegate

- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self _providerIndexForSection:indexPath.section] != NSNotFound;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSInteger pIdx = [self _providerIndexForSection:indexPath.section];
    if (pIdx == NSNotFound) return;
    NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
    NSArray *models = [p objectForKey:@"models"];
    if (indexPath.row >= (NSInteger)[models count]) return;
    NSDictionary *m = [models objectAtIndex:indexPath.row];
    NSString *toDel = [m objectForKey:@"id"];
    if (!toDel.length) return;
    UIAlertView *av = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"删除模型?", nil)
              message:[NSString stringWithFormat:@"%@ \"%@\"", NSLocalizedString(@"确定从列表删除", nil), toDel]
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
    otherButtonTitles:NSLocalizedString(@"删除", nil), nil] autorelease];
    [av setTag:700];
    self.pendingDeleteModel = toDel;
    self.pendingDeleteProviderID = [p objectForKey:@"id"];
    [av show];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger pIdx = [self _providerIndexForSection:indexPath.section];
    if (pIdx != NSNotFound) {
        NSDictionary *p = [_providerEntries objectAtIndex:pIdx];
        NSArray *models = [p objectForKey:@"models"];
        if (indexPath.row >= (NSInteger)[models count]) return;
        NSDictionary *m = [models objectAtIndex:indexPath.row];
        NSString *mid = [m objectForKey:@"id"];
        if (![mid isKindOfClass:[NSString class]] || mid.length == 0) return;
        [ModelManagementViewController setActiveModel:mid];
        [[Logger sharedLogger] info:[NSString stringWithFormat:
            @"Default %@ model set to %@ (provider %@)",
            [[m objectForKey:@"kind"] isEqualToString:@"image"] ? @"IMAGE" : @"chat",
            mid, [p objectForKey:@"template"] ?: @"(custom)"]];
        [_tableView reloadData];
        return;
    }
    if (indexPath.section == [self _sectionForAdd]) {
        ModelAddViewController *add = [[[ModelAddViewController alloc] init] autorelease];
        [self.navigationController pushViewController:add animated:YES];
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == 500) {
        _transitSearchCancelled = YES;
        return;
    }
    if (alertView.tag == 700 && buttonIndex == 1) {
        NSString *m = _pendingDeleteModel;
        NSString *pid = _pendingDeleteProviderID;
        if (!m.length || !pid.length) {
            self.pendingDeleteModel = nil;
            self.pendingDeleteProviderID = nil;
            return;
        }
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"ModelMgmt delete '%@' - start", m]];
        [ModelManagementViewController removeModel:m fromProviderID:pid];
        // Self-heal: if the active model was the deleted one, fall back to
        // the first remaining model (any kind) so the chat path still has
        // a default. resolvedConnectionForChat self-heals on next read.
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *curChat = [d stringForKey:SettingsKeyModel];
        if (curChat && [curChat isEqualToString:m]) {
            NSArray *all = [ModelManagementViewController savedModelList];
            if (all.count > 0) {
                [d setObject:[all objectAtIndex:0] forKey:SettingsKeyModel];
            } else {
                [d removeObjectForKey:SettingsKeyModel];
            }
        }
        NSString *curImg = [d stringForKey:SettingsKeyImageGenModel];
        if (curImg && [curImg isEqualToString:m]) {
            [d removeObjectForKey:SettingsKeyImageGenModel];
        }
        [d synchronize];
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"ModelMgmt delete '%@' - done", m]];
        [self _rebuildProviderCache];
        if (_tableView) [_tableView reloadData];
        self.pendingDeleteModel = nil;
        self.pendingDeleteProviderID = nil;
    }
}

#pragma mark - Pending property setters (manual retain/release)

- (void)setPendingDeleteModel:(NSString *)m
{
    if (_pendingDeleteModel != m) {
        [_pendingDeleteModel release];
        _pendingDeleteModel = [m retain];
    }
}

- (void)setPendingDeleteProviderID:(NSString *)m
{
    if (_pendingDeleteProviderID != m) {
        [_pendingDeleteProviderID release];
        _pendingDeleteProviderID = [m retain];
    }
}

#pragma mark - /v1/models search

- (void)_searchAvailableModels
{
    NSDictionary *conn = [ModelManagementViewController resolvedConnectionForChat];
    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];
    NSString *baseURL = [conn objectForKey:@"baseURL"];
    NSString *provider = [conn objectForKey:@"template"];
    NSString *apiKey = [conn objectForKey:@"apiKey"];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelMgmt search models - transit=%d template=%@", (int)useTransit, provider ?: @"?"]];

    UIAlertView *loading = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"搜索中…", nil)
              message:NSLocalizedString(@"正在从 /v1/models 拉取", nil)
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
                        @"ModelMgmt search failed - %@", errDesc ?: @"no models / empty response"]];
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
                NSInteger limit = MIN([resultsCopy count], (NSUInteger)8);
                NSMutableArray *picked = [NSMutableArray array];
                for (NSInteger i = 0; i < limit; i++) {
                    NSString *mid = [resultsCopy objectAtIndex:i];
                    if ([mid isKindOfClass:[NSString class]]) [picked addObject:mid];
                }
                self.availableModels = [NSMutableArray arrayWithArray:picked];
                [[Logger sharedLogger] info:[NSString stringWithFormat:
                    @"ModelMgmt search OK - %lu models", (unsigned long)[picked count]]];
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

#pragma mark - Test connection

- (void)_testConnection
{
    NSDictionary *conn = [ModelManagementViewController resolvedConnectionForChat];
    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];
    NSString *baseURL = [conn objectForKey:@"baseURL"];
    NSString *provider = [conn objectForKey:@"template"];
    NSString *apiKey = [conn objectForKey:@"apiKey"];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelMgmt test connection - transit=%d template=%@", (int)useTransit, provider ?: @"?"]];

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
                        @"ModelMgmt test connection FAIL - %@", errDesc ?: @"(no response)"]];
                    UIAlertView *fail = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"连接失败", nil)
                              message:errDesc ?: NSLocalizedString(@"无返回,请检查 BaseURL / API Key / 中转 URL", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [fail show];
                } else {
                    [[Logger sharedLogger] info:[NSString stringWithFormat:
                        @"ModelMgmt test connection OK - %lu models", (unsigned long)[resultsCopy count]]];
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
    if (actionSheet.tag != 400) return;
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (buttonIndex < 1) return;
    NSInteger modelIndex = buttonIndex - 1;
    if (modelIndex >= (NSInteger)[_availableModels count]) return;
    NSString *m = [_availableModels objectAtIndex:modelIndex];
    if (![m isKindOfClass:[NSString class]] || m.length == 0) return;
    // Add to the active chat provider entry, fall back to legacy bare-add.
    NSDictionary *p = [ModelManagementViewController providerEntryContainingModel:
                       [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel]];
    if (p) {
        [ModelManagementViewController addModel:m kind:@"chat"
                                  toProviderID:[p objectForKey:@"id"]];
    } else {
        [ModelManagementViewController addModel:m];
    }
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:SettingsKeyModel];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"Search added+default %@", m]];
    if (_tableView) [_tableView reloadData];
}

#pragma mark - Transit bundled model search (v261025-3)

- (void)searchTransitBundledModels
{
    if (_transitSearchInProgress) return;
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
                        @"Transit bundled model search failed - %@", errDesc ?: @"no response"]];
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
                [ModelManagementViewController addTransitModels:models];
                [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                                          forKey:SettingsKeyTransitModelsLastSearch];
                [[NSUserDefaults standardUserDefaults] synchronize];
                if (_tableView) [_tableView reloadData];
                [[Logger sharedLogger] info:[NSString stringWithFormat:
                    @"Transit bundled models added - %lu", (unsigned long)[models count]]];
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
