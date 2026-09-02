// GoalKeeper shell: AppKit window + WKWebView + JSON persistence bridge.
// Saves the app's single JSON blob to ~/Library/Application Support/GoalKeeper/data.json
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler>
@property (strong) NSWindow *window;
@property (strong) WKWebView *webView;
@property (strong) id dragMonitor;
@end

@implementation AppDelegate

- (NSURL *)dataDir {
    NSURL *appSupport = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask][0];
    return [appSupport URLByAppendingPathComponent:@"GoalKeeper" isDirectory:YES];
}

- (NSURL *)dataFile {
    return [[self dataDir] URLByAppendingPathComponent:@"data.json"];
}

- (NSURL *)backupFile {
    return [[self dataDir] URLByAppendingPathComponent:@"data.json.bak"];
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *type = body[@"type"];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([type isEqualToString:@"save"]) {
        NSString *json = body[@"data"];
        if (![json isKindOfClass:[NSString class]]) return;
        NSError *err = nil;
        [fm createDirectoryAtURL:[self dataDir] withIntermediateDirectories:YES attributes:nil error:&err];
        // keep the previous good version: one bad write never destroys data
        if ([fm fileExistsAtPath:[self dataFile].path]) {
            [fm removeItemAtURL:[self backupFile] error:nil];
            [fm copyItemAtURL:[self dataFile] toURL:[self backupFile] error:nil];
        }
        [json writeToURL:[self dataFile] atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (err) NSLog(@"GoalKeeper save failed: %@", err);
    } else if ([type isEqualToString:@"load"]) {
        BOOL existed = [fm fileExistsAtPath:[self dataFile].path] || [fm fileExistsAtPath:[self backupFile].path];
        NSData *data = [NSData dataWithContentsOfURL:[self dataFile]];
        if (!data || data.length == 0) data = [NSData dataWithContentsOfURL:[self backupFile]];
        if (!data || data.length == 0) data = [@"null" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *b64 = [data base64EncodedStringWithOptions:0];
        // pass the bundled starter board (if this build ships one) so JS can adopt it
        // when there is no user data or the existing board has never been used
        NSString *starterB64 = @"null";
        NSURL *starterURL = [[NSBundle mainBundle] URLForResource:@"starter-data" withExtension:@"json" subdirectory:@"app"];
        NSData *starter = starterURL ? [NSData dataWithContentsOfURL:starterURL] : nil;
        if (starter.length > 0) starterB64 = [NSString stringWithFormat:@"'%@'", [starter base64EncodedStringWithOptions:0]];
        NSString *js = [NSString stringWithFormat:@"window.__loadedB64('%@', %@, %@)", b64, existed ? @"true" : @"false", starterB64];
        [self.webView evaluateJavaScript:js completionHandler:nil];
    } else if ([type isEqualToString:@"drag"]) {
        // Script messages arrive asynchronously, so the mousedown NSEvent is long gone —
        // performWindowDragWithEvent: can't be used. Instead track the (still-held) mouse
        // ourselves with a local monitor and move the window 1:1 until the button releases.
        if (self.dragMonitor) return; // already dragging
        NSPoint startMouse = [NSEvent mouseLocation];
        NSPoint startOrigin = self.window.frame.origin;
        __weak AppDelegate *weakSelf = self;
        self.dragMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
            (NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
            handler:^NSEvent *(NSEvent *ev) {
                AppDelegate *strongSelf = weakSelf;
                if (!strongSelf) return ev;
                if (ev.type == NSEventTypeLeftMouseUp) {
                    [NSEvent removeMonitor:strongSelf.dragMonitor];
                    strongSelf.dragMonitor = nil;
                    return ev;
                }
                NSPoint now = [NSEvent mouseLocation];
                [strongSelf.window setFrameOrigin:
                    NSMakePoint(startOrigin.x + (now.x - startMouse.x),
                                startOrigin.y + (now.y - startMouse.y))];
                return ev;
            }];
    } else if ([type isEqualToString:@"zoomWindow"]) {
        [self.window performZoom:nil]; // double-click-titlebar behavior
    } else if ([type isEqualToString:@"archive"]) {
        // standalone per-month archive, belt & suspenders beyond history[] in data.json
        NSString *month = body[@"month"], *json = body[@"data"];
        if (![month isKindOfClass:[NSString class]] || ![json isKindOfClass:[NSString class]]) return;
        NSString *safe = [[month componentsSeparatedByCharactersInSet:
            [[NSCharacterSet characterSetWithCharactersInString:@"0123456789-"] invertedSet]] componentsJoinedByString:@""];
        if (safe.length == 0) return;
        NSURL *dir = [[self dataDir] URLByAppendingPathComponent:@"archives" isDirectory:YES];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *out = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"archive-%@.json", safe]];
        [json writeToURL:out atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    [config.userContentController addScriptMessageHandler:self name:@"bridge"];

    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    @try { [self.webView setValue:@NO forKey:@"drawsBackground"]; } @catch (NSException *e) {}

    NSRect rect = NSMakeRect(0, 0, 1200, 780);
    NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    self.window = [[NSWindow alloc] initWithContentRect:rect styleMask:mask
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"GoalKeeper";
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.minSize = NSMakeSize(980, 640);
    self.window.backgroundColor = [NSColor colorWithCalibratedRed:0.83 green:0.83 blue:1.0 alpha:1];
    self.window.contentView = self.webView;
    [self.window center];
    [self.window setFrameAutosaveName:@"GoalKeeperMain"];

    NSURL *html = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html" subdirectory:@"app"];
    if (html) {
        [self.webView loadFileURL:html allowingReadAccessToURL:[html URLByDeletingLastPathComponent]];
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

// Minimal main menu so Cmd+Q / Cmd+C / Cmd+V work inside the web view.
static NSMenu *BuildMenu(void) {
    NSMenu *main = [NSMenu new];

    NSMenuItem *appItem = [NSMenuItem new];
    [main addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Hide GoalKeeper" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit GoalKeeper" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *editItem = [NSMenuItem new];
    [main addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:NSSelectorFromString(@"redo:") keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;

    return main;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        app.mainMenu = BuildMenu();
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
