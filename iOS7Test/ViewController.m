// iOS7Test — Minimal iOS 7 UI rendering test.
// NO custom styling. Pure system controls.
// If this renders FLAT on iOS 7 → SDK + deployment target correct.
// If this renders iOS 6 STYLE → SDK or deployment target issue.

#import "ViewController.h"

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"iOS 7 Test";
    // White background — NO custom pattern.
    self.view.backgroundColor = [UIColor whiteColor];

    // System grouped table view — should render flat on iOS 7.
    UITableView *table = [[[UITableView alloc]
        initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width,
                                  self.view.bounds.size.height - 100)
        style:UITableViewStyleGrouped] autorelease];
    table.dataSource = self;
    table.delegate = self;
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                              UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:table];

    // System rounded-rect button — should be borderless on iOS 7.
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [btn setTitle:@"System Button" forState:UIControlStateNormal];
    btn.frame = CGRectMake(80, self.view.bounds.size.height - 80, 160, 44);
    btn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:btn];

    // System switch — should be flat on iOS 7.
    UISwitch *sw = [[[UISwitch alloc] init] autorelease];
    sw.frame = CGRectMake(20, self.view.bounds.size.height - 75, 79, 27);
    sw.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:sw];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Section 1" : @"Section 2";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 3 : 2;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"cell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) {
        c = [[[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:id] autorelease];
    }
    c.textLabel.text = [NSString stringWithFormat:@"Row %d", (int)(ip.row + 1)];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)dealloc {
    [super dealloc];
}

@end
