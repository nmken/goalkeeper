// GoalKeeper shell: AppKit window + WKWebView + JSON persistence bridge.
// Saves the app's single JSON blob to ~/Library/Application Support/GoalKeeper/data.json
//
// 1.1 additions: self-updater (GitHub Releases feed -> App Support/app/index.html),
// rotating backups, export/import panels, menus, and the window-background hook.
// The native shell freezes after this release, so every hook a future UI-only update
// could need ships here.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>

// Feed of record. Overridden by env GK_UPDATE_URL, then App Support/update-url.txt.
#define GK_FEED_URL @"https://github.com/nmken/goalkeeper/releases/latest/download/version.json"

#define GK_LOG_PREFIX @"GoalKeeper update:"
#define GK_IMPORT_MAX (50ull * 1024ull * 1024ull)
#define GK_READY_TIMEOUT 10.0
#define GK_PERIODIC_INTERVAL (6 * 60 * 60.0)
#define GK_ACTIVATE_THROTTLE (60 * 60.0)

static NSString *SHA256Hex(NSData *data) {
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property (strong) NSWindow *window;
@property (strong) WKWebView *webView;
@property (strong) WKUserContentController *ucc;
@property (strong) id dragMonitor;
// updater state
@property (strong) NSURLSession *session;
@property (strong) NSDictionary *pendingUpdate;   // @{@"version":…, @"notes":…}
@property (copy)   NSString *activeVersion;       // version of the HTML currently loaded
@property (assign) BOOL loadedFromAppSupport;
@property (assign) BOOL pageReady;
@property (assign) BOOL checking;
@property (strong) NSTimer *readyTimer;
@property (strong) NSTimer *periodicTimer;
@property (strong) NSDate *lastCheck;
@property (copy)   NSString *lastDailyBackup;     // YYYY-MM-DD of the last daily backup
@end

@implementation AppDelegate

#pragma mark - paths

- (NSURL *)dataDir {
    NSURL *appSupport = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask][0];
    return [appSupport URLByAppendingPathComponent:@"GoalKeeper" isDirectory:YES];
}

- (NSURL *)dataFile   { return [[self dataDir] URLByAppendingPathComponent:@"data.json"]; }
- (NSURL *)backupFile { return [[self dataDir] URLByAppendingPathComponent:@"data.json.bak"]; }
- (NSURL *)backupsDir { return [[self dataDir] URLByAppendingPathComponent:@"backups" isDirectory:YES]; }
- (NSURL *)appDir     { return [[self dataDir] URLByAppendingPathComponent:@"app" isDirectory:YES]; }
- (NSURL *)appNewDir  { return [[self dataDir] URLByAppendingPathComponent:@"app.new" isDirectory:YES]; }
- (NSURL *)updatedHTML { return [[self appDir] URLByAppendingPathComponent:@"index.html"]; }
- (NSURL *)shellVersionFile { return [[self dataDir] URLByAppendingPathComponent:@"shell-version.txt"]; }
- (NSURL *)lastDailyFile { return [[self backupsDir] URLByAppendingPathComponent:@".lastdaily"]; }

- (NSString *)bundleVersion {
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return v.length ? v : @"0";
}

#pragma mark - JS plumbing

// NSJSONSerialization of @[s] minus the brackets: quotes, newlines and control
// characters can never break out of the call. U+2028/9 are escaped by hand.
- (NSString *)jsString:(NSString *)s {
    if (![s isKindOfClass:[NSString class]]) s = @"";
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:nil];
    NSString *wrapped = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    if (wrapped.length < 2) return @"\"\"";
    NSString *lit = [wrapped substringWithRange:NSMakeRange(1, wrapped.length - 2)];
    lit = [lit stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C", (unichar)0x2028]
                                        withString:@"\\u2028"];
    lit = [lit stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C", (unichar)0x2029]
                                        withString:@"\\u2029"];
    return lit;
}

- (void)runJS:(NSString *)js {
    if (!js) return;
    if ([NSThread isMainThread]) {
        [self.webView evaluateJavaScript:js completionHandler:nil];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.webView evaluateJavaScript:js completionHandler:nil];
        });
    }
}

// window.FN && window.FN(<already-literal args>)
- (void)callJS:(NSString *)fn rawArgs:(NSArray<NSString *> *)args {
    NSString *js = [NSString stringWithFormat:@"window.%@ && window.%@(%@)",
                    fn, fn, [args componentsJoinedByString:@","]];
    [self runJS:js];
}

- (void)callJS:(NSString *)fn stringArgs:(NSArray<NSString *> *)strings {
    NSMutableArray *lits = [NSMutableArray arrayWithCapacity:strings.count];
    for (NSString *s in strings) [lits addObject:[self jsString:s]];
    [self callJS:fn rawArgs:lits];
}

- (void)announceStatus:(NSString *)status version:(NSString *)version {
    [self callJS:@"__updateStatus" stringArgs:@[status, version ?: @""]];
}

#pragma mark - backups

- (NSString *)todayString {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate date]];
}

- (BOOL)ensureBackupsDir {
    return [[NSFileManager defaultManager] createDirectoryAtURL:[self backupsDir]
                                   withIntermediateDirectories:YES attributes:nil error:nil];
}

// First save of a calendar day: snapshot the *previous* data.json, then keep the newest 30.
- (void)maybeDailyBackup {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *today = [self todayString];
    if ([self.lastDailyBackup isEqualToString:today]) return;

    NSString *stored = [NSString stringWithContentsOfURL:[self lastDailyFile]
                                                encoding:NSUTF8StringEncoding error:nil];
    stored = [stored stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([stored isEqualToString:today]) { self.lastDailyBackup = today; return; }

    if ([fm fileExistsAtPath:[self dataFile].path]) {
        if (![self ensureBackupsDir]) return;
        NSURL *dest = [[self backupsDir] URLByAppendingPathComponent:
                       [NSString stringWithFormat:@"data-%@.json", today]];
        [fm removeItemAtURL:dest error:nil];
        NSError *err = nil;
        if (![fm copyItemAtURL:[self dataFile] toURL:dest error:&err]) {
            NSLog(@"GoalKeeper: daily backup failed: %@", err);
            return;
        }
        NSLog(@"GoalKeeper: daily backup -> %@", dest.lastPathComponent);
    } else {
        [self ensureBackupsDir];
    }
    self.lastDailyBackup = today;
    [today writeToURL:[self lastDailyFile] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self pruneDailyBackups];
}

- (void)pruneDailyBackups {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSURL *> *all = [fm contentsOfDirectoryAtURL:[self backupsDir]
                             includingPropertiesForKeys:nil options:0 error:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *u in all) {
        NSString *n = u.lastPathComponent;
        if ([n hasPrefix:@"data-"] && [n hasSuffix:@".json"]) [names addObject:n];
    }
    if (names.count <= 30) return;
    [names sortUsingSelector:@selector(compare:)];   // ISO dates sort chronologically
    NSUInteger extra = names.count - 30;
    for (NSUInteger i = 0; i < extra; i++) {
        NSURL *old = [[self backupsDir] URLByAppendingPathComponent:names[i]];
        [fm removeItemAtURL:old error:nil];
        NSLog(@"GoalKeeper: pruned old backup %@", names[i]);
    }
}

// Bundle version changed (or first run): keep a copy of the data as it was before the upgrade.
- (void)writePreUpgradeBackupIfNeeded {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ver = [self bundleVersion];
    NSString *prev = [NSString stringWithContentsOfURL:[self shellVersionFile]
                                              encoding:NSUTF8StringEncoding error:nil];
    prev = [prev stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([prev isEqualToString:ver]) return;

    NSLog(@"GoalKeeper: shell version %@ -> %@", prev.length ? prev : @"(none)", ver);
    if ([fm fileExistsAtPath:[self dataFile].path] && [self ensureBackupsDir]) {
        NSURL *dest = [[self backupsDir] URLByAppendingPathComponent:
                       [NSString stringWithFormat:@"pre-upgrade-%@.json", ver]];
        if (![fm fileExistsAtPath:dest.path]) {
            NSError *err = nil;
            if ([fm copyItemAtURL:[self dataFile] toURL:dest error:&err])
                NSLog(@"GoalKeeper: pre-upgrade backup -> %@", dest.lastPathComponent);
            else
                NSLog(@"GoalKeeper: pre-upgrade backup failed: %@", err);
        }
    }
    [fm createDirectoryAtURL:[self dataDir] withIntermediateDirectories:YES attributes:nil error:nil];
    [ver writeToURL:[self shellVersionFile] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - bridge

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
        [self maybeDailyBackup];   // snapshots the previous file, before it is overwritten
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
        NSString *starterArg = @"null";
        NSURL *starterURL = [[NSBundle mainBundle] URLForResource:@"starter-data" withExtension:@"json" subdirectory:@"app"];
        NSData *starter = starterURL ? [NSData dataWithContentsOfURL:starterURL] : nil;
        if (starter.length > 0) starterArg = [self jsString:[starter base64EncodedStringWithOptions:0]];
        [self callJS:@"__loadedB64" rawArgs:@[[self jsString:b64], existed ? @"true" : @"false", starterArg]];
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
        // plus a full-state close-out backup for the month that just ended
        if ([fm fileExistsAtPath:[self dataFile].path] && [self ensureBackupsDir]) {
            NSURL *dest = [[self backupsDir] URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"closeout-%@.json", safe]];
            [fm removeItemAtURL:dest error:nil];
            if ([fm copyItemAtURL:[self dataFile] toURL:dest error:nil])
                NSLog(@"GoalKeeper: close-out backup -> %@", dest.lastPathComponent);
        }
    } else if ([type isEqualToString:@"export"]) {
        [self exportJSON:body[@"data"] filename:body[@"filename"]];
    } else if ([type isEqualToString:@"import"]) {
        [self importJSON];
    } else if ([type isEqualToString:@"applyUpdate"]) {
        NSLog(@"GoalKeeper: applying update (JS already persisted)");
        self.pendingUpdate = nil;
        [self loadAppHTML];
    } else if ([type isEqualToString:@"checkUpdate"]) {
        [self announceStatus:@"checking" version:@""];
        [self checkForUpdates:YES];
    } else if ([type isEqualToString:@"ready"]) {
        self.pageReady = YES;
        [self.readyTimer invalidate];
        self.readyTimer = nil;
        NSLog(@"GoalKeeper: page ready (UI %@)", self.activeVersion ?: @"?");
        if (self.pendingUpdate) {
            [self callJS:@"__updateReady" stringArgs:@[self.pendingUpdate[@"version"] ?: @"",
                                                       self.pendingUpdate[@"notes"] ?: @""]];
        }
    } else if ([type isEqualToString:@"windowBg"]) {
        NSNumber *r = body[@"r"], *g = body[@"g"], *b = body[@"b"];
        if (![r isKindOfClass:[NSNumber class]] || ![g isKindOfClass:[NSNumber class]] ||
            ![b isKindOfClass:[NSNumber class]]) return;
        CGFloat rr = MIN(255, MAX(0, r.integerValue)) / 255.0;
        CGFloat gg = MIN(255, MAX(0, g.integerValue)) / 255.0;
        CGFloat bb = MIN(255, MAX(0, b.integerValue)) / 255.0;
        self.window.backgroundColor = [NSColor colorWithCalibratedRed:rr green:gg blue:bb alpha:1];
        NSLog(@"GoalKeeper: window background -> rgb(%ld,%ld,%ld)",
              (long)r.integerValue, (long)g.integerValue, (long)b.integerValue);
    } else if ([type isEqualToString:@"revealDataFolder"]) {
        [self revealDataFolder];
    } else if ([type isEqualToString:@"openURL"]) {
        NSString *s = body[@"url"];
        if (![s isKindOfClass:[NSString class]]) return;
        NSURL *u = [NSURL URLWithString:s];
        if (![u.scheme isEqualToString:@"https"]) {
            NSLog(@"GoalKeeper: refused to open non-https URL %@", s);
            return;
        }
        [[NSWorkspace sharedWorkspace] openURL:u];
    } else if ([type isEqualToString:@"resetToBundled"]) {
        [self resetToBundled];
    }
}

#pragma mark - export / import

- (void)exportJSON:(NSString *)json filename:(NSString *)filename {
    if (![json isKindOfClass:[NSString class]]) return;
    NSString *name = [filename isKindOfClass:[NSString class]] ? filename : nil;
    name = [name lastPathComponent];
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. "] invertedSet];
    name = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@""];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (name.length == 0) name = @"GoalKeeper-backup.json";

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.nameFieldStringValue = name;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        BOOL ok = NO;
        if (resp == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            ok = [json writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&err];
            if (ok) NSLog(@"GoalKeeper: exported backup -> %@", panel.URL.path);
            else NSLog(@"GoalKeeper: export failed: %@", err);
        } else {
            NSLog(@"GoalKeeper: export cancelled");
        }
        [self callJS:@"__exportDone" rawArgs:@[ok ? @"true" : @"false"]];
    }];
}

- (void)importJSON {
    NSFileManager *fm = [NSFileManager defaultManager];
    // safety copy before the user can replace anything
    if ([fm fileExistsAtPath:[self dataFile].path]) {
        NSURL *pre = [[self dataDir] URLByAppendingPathComponent:@"data.json.pre-import"];
        [fm removeItemAtURL:pre error:nil];
        if ([fm copyItemAtURL:[self dataFile] toURL:pre error:nil])
            NSLog(@"GoalKeeper: wrote data.json.pre-import");
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSModalResponseOK || !panel.URL) {
            NSLog(@"GoalKeeper: import cancelled");
            return;   // cancel: JS is told nothing
        }
        NSNumber *size = nil;
        [panel.URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size && size.unsignedLongLongValue > GK_IMPORT_MAX) {
            NSLog(@"GoalKeeper: import refused, file larger than 50 MB");
            return;
        }
        NSData *data = [NSData dataWithContentsOfURL:panel.URL];
        if (!data || data.length == 0 || data.length > GK_IMPORT_MAX) {
            NSLog(@"GoalKeeper: import refused, unreadable or oversized file");
            return;
        }
        NSLog(@"GoalKeeper: importing %@ (%lu bytes)", panel.URL.lastPathComponent, (unsigned long)data.length);
        [self callJS:@"__importedB64" stringArgs:@[[data base64EncodedStringWithOptions:0]]];
    }];
}

- (void)revealDataFolder {
    NSURL *dir = [self dataDir];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES
                                              attributes:nil error:nil];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[dir]];
}

- (void)resetToBundled {
    NSLog(@"GoalKeeper: reset to built-in version requested");
    [[NSFileManager defaultManager] removeItemAtURL:[self appDir] error:nil];
    self.pendingUpdate = nil;
    [self loadAppHTML];
}

#pragma mark - page loading

// Matches the exact literal <meta name="gk-version" content="X"> that build.sh,
// release.sh and the update validator all key off.
- (NSString *)metaVersionFromHTML:(NSString *)html {
    if (html.length == 0) return nil;
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"<meta name=\"gk-version\" content=\"([^\"]*)\">" options:0 error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!m) return nil;
    NSString *v = [html substringWithRange:[m rangeAtIndex:1]];
    return v.length ? v : nil;
}

- (NSString *)appSupportUIVersion {
    NSString *html = [NSString stringWithContentsOfURL:[self updatedHTML]
                                              encoding:NSUTF8StringEncoding error:nil];
    return [self metaVersionFromHTML:html];
}

- (void)installUserScripts {
    [self.ucc removeAllUserScripts];
    NSString *src = [NSString stringWithFormat:
        @"window.__shell = { version: %@, features: [\"export\",\"import\",\"update\",\"windowBg\","
        @"\"revealDataFolder\",\"openURL\",\"assets\",\"ready\",\"resetToBundled\"], uiSource: %@ };",
        [self jsString:[self bundleVersion]],
        [self jsString:self.loadedFromAppSupport ? @"appsupport" : @"bundle"]];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:src
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES];
    [self.ucc addUserScript:script];
}

- (void)loadAppHTML {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleVer = [self bundleVersion];
    NSURL *bundled = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html" subdirectory:@"app"];
    NSString *updVer = [self appSupportUIVersion];

    BOOL useUpdated = (updVer != nil &&
                       [bundleVer compare:updVer options:NSNumericSearch] == NSOrderedAscending);
    if (!useUpdated && [fm fileExistsAtPath:[self appDir].path]) {
        NSLog(@"%@ discarding App Support UI copy (its version %@, bundled %@)",
              GK_LOG_PREFIX, updVer ?: @"unreadable/absent", bundleVer);
        [fm removeItemAtURL:[self appDir] error:nil];
    }

    self.loadedFromAppSupport = useUpdated;
    self.activeVersion = useUpdated ? updVer : bundleVer;
    self.pageReady = NO;
    [self installUserScripts];

    if (useUpdated) {
        NSLog(@"GoalKeeper: loading updated UI %@ from App Support", updVer);
        [self.webView loadFileURL:[self updatedHTML] allowingReadAccessToURL:[self appDir]];
    } else if (bundled) {
        NSLog(@"GoalKeeper: loading bundled UI %@", bundleVer);
        [self.webView loadFileURL:bundled allowingReadAccessToURL:[bundled URLByDeletingLastPathComponent]];
    } else {
        NSLog(@"GoalKeeper: no bundled index.html found");
    }

    [self.readyTimer invalidate];
    self.readyTimer = [NSTimer scheduledTimerWithTimeInterval:GK_READY_TIMEOUT target:self
                                                     selector:@selector(readyTimedOut:)
                                                     userInfo:nil repeats:NO];
}

- (void)readyTimedOut:(NSTimer *)timer {
    self.readyTimer = nil;
    if (self.pageReady || !self.loadedFromAppSupport) return;
    NSLog(@"%@ updated UI did not report ready within %.0fs — falling back to the bundled UI",
          GK_LOG_PREFIX, GK_READY_TIMEOUT);
    [[NSFileManager defaultManager] removeItemAtURL:[self appDir] error:nil];
    [self loadAppHTML];
}

- (void)fallbackToBundledAfterFailure:(NSString *)why {
    if (!self.loadedFromAppSupport) return;
    NSLog(@"%@ updated UI failed to load (%@) — falling back to the bundled UI", GK_LOG_PREFIX, why);
    [[NSFileManager defaultManager] removeItemAtURL:[self appDir] error:nil];
    [self loadAppHTML];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [self fallbackToBundledAfterFailure:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)nav withError:(NSError *)error {
    [self fallbackToBundledAfterFailure:error.localizedDescription];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    NSLog(@"GoalKeeper: web content process terminated — reloading");
    [self loadAppHTML];
}

#pragma mark - updater

- (NSURL *)feedURL {
    NSString *env = [NSProcessInfo processInfo].environment[@"GK_UPDATE_URL"];
    env = [env stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (env.length) return [NSURL URLWithString:env];
    NSString *file = [NSString stringWithContentsOfURL:
                      [[self dataDir] URLByAppendingPathComponent:@"update-url.txt"]
                                              encoding:NSUTF8StringEncoding error:nil];
    file = [file stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (file.length) return [NSURL URLWithString:file];
    return [NSURL URLWithString:GK_FEED_URL];
}

- (void)finishCheck:(NSString *)status version:(NSString *)version manual:(BOOL)manual {
    self.checking = NO;
    if (manual) [self announceStatus:status version:version];
}

- (void)checkForUpdates:(BOOL)manual {
    if ([[NSProcessInfo processInfo].environment[@"GK_NO_UPDATE"] isEqualToString:@"1"]) {
        NSLog(@"%@ checks disabled by GK_NO_UPDATE=1", GK_LOG_PREFIX);
        if (manual) [self announceStatus:@"error" version:@""];
        return;
    }
    if (self.checking) {
        NSLog(@"%@ a check is already running", GK_LOG_PREFIX);
        return;
    }
    NSURL *feed = [self feedURL];
    if (!feed) {
        NSLog(@"%@ feed URL is not a valid URL", GK_LOG_PREFIX);
        if (manual) [self announceStatus:@"error" version:@""];
        return;
    }
    self.checking = YES;
    self.lastCheck = [NSDate date];
    NSLog(@"%@ checking %@ (%@)", GK_LOG_PREFIX, feed.absoluteString, manual ? @"manual" : @"automatic");

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:feed
        cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData timeoutInterval:15];
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        // hop off the session queue: the install path blocks on the asset downloads
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self handleFeedData:data response:resp error:err feed:feed manual:manual];
        });
    }] resume];
}

- (void)handleFeedData:(NSData *)data response:(NSURLResponse *)resp error:(NSError *)err
                  feed:(NSURL *)feed manual:(BOOL)manual {
    if (err) {
        NSLog(@"%@ feed request failed: %@", GK_LOG_PREFIX, err.localizedDescription);
        [self finishCheck:@"error" version:@"" manual:manual];
        return;
    }
    NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
    if (code != 200) {
        NSLog(@"%@ feed returned HTTP %ld", GK_LOG_PREFIX, (long)code);
        [self finishCheck:@"error" version:@"" manual:manual];
        return;
    }
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"%@ feed is not a JSON object", GK_LOG_PREFIX);
        [self finishCheck:@"error" version:@"" manual:manual];
        return;
    }
    NSDictionary *feedDict = json;
    NSString *version = feedDict[@"version"], *htmlPath = feedDict[@"html"], *htmlSha = feedDict[@"sha256"];
    NSString *minShell = feedDict[@"minShell"], *notes = feedDict[@"notes"];
    if (![version isKindOfClass:[NSString class]] || version.length == 0 ||
        ![htmlPath isKindOfClass:[NSString class]] || htmlPath.length == 0 ||
        ![htmlSha isKindOfClass:[NSString class]] || htmlSha.length == 0) {
        NSLog(@"%@ feed is missing version/html/sha256", GK_LOG_PREFIX);
        [self finishCheck:@"error" version:@"" manual:manual];
        return;
    }
    if (![minShell isKindOfClass:[NSString class]]) minShell = nil;
    if (![notes isKindOfClass:[NSString class]]) notes = @"";
    id rawAssets = feedDict[@"assets"];
    NSArray *assets = [rawAssets isKindOfClass:[NSArray class]] ? rawAssets : @[];

    NSString *bundleVer = [self bundleVersion];
    if (minShell && [minShell compare:bundleVer options:NSNumericSearch] == NSOrderedDescending) {
        NSLog(@"%@ %@ needs shell %@ but this shell is %@ — installer required",
              GK_LOG_PREFIX, version, minShell, bundleVer);
        [self finishCheck:@"needsInstaller" version:version manual:manual];
        return;
    }

    NSString *onDisk = [self appSupportUIVersion];
    NSString *installed = bundleVer;
    if (onDisk && [onDisk compare:installed options:NSNumericSearch] == NSOrderedDescending) installed = onDisk;

    if ([version compare:installed options:NSNumericSearch] != NSOrderedDescending) {
        NSString *active = self.activeVersion ?: bundleVer;
        if (onDisk && [onDisk compare:active options:NSNumericSearch] == NSOrderedDescending) {
            NSLog(@"%@ %@ is already downloaded and waiting to be applied", GK_LOG_PREFIX, onDisk);
            NSString *pendingNotes = [onDisk isEqualToString:version] ? notes : @"";
            [self announcePending:@{@"version": onDisk, @"notes": pendingNotes} manual:manual];
        } else {
            NSLog(@"%@ up to date (feed %@, installed %@)", GK_LOG_PREFIX, version, installed);
            [self finishCheck:@"uptodate" version:installed manual:manual];
        }
        return;
    }

    NSLog(@"%@ %@ available (installed %@) — downloading", GK_LOG_PREFIX, version, installed);
    [self downloadAndInstall:version notes:notes htmlPath:htmlPath htmlSha:htmlSha
                      assets:assets feed:feed manual:manual];
}

- (void)announcePending:(NSDictionary *)pending manual:(BOOL)manual {
    self.checking = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pendingUpdate = pending;
        if (self.pageReady) {
            [self callJS:@"__updateReady" stringArgs:@[pending[@"version"] ?: @"", pending[@"notes"] ?: @""]];
        }
        if (manual) [self announceStatus:@"ready" version:pending[@"version"] ?: @""];
    });
}

// Only https, unless the feed itself is http (local dev override).
- (BOOL)allowScheme:(NSURL *)url feed:(NSURL *)feed {
    if ([url.scheme isEqualToString:@"https"]) return YES;
    if ([url.scheme isEqualToString:@"http"] && [feed.scheme isEqualToString:@"http"]) return YES;
    return NO;
}

- (BOOL)validRelativePath:(NSString *)path {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return NO;
    if ([path hasPrefix:@"/"] || [path hasPrefix:@"~"]) return NO;
    for (NSString *comp in [path pathComponents]) {
        if ([comp isEqualToString:@".."] || [comp isEqualToString:@"/"]) return NO;
    }
    return YES;
}

- (void)downloadAndInstall:(NSString *)version notes:(NSString *)notes
                  htmlPath:(NSString *)htmlPath htmlSha:(NSString *)htmlSha
                    assets:(NSArray *)assets feed:(NSURL *)feed manual:(BOOL)manual {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *staging = [[self dataDir] URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"staging-%@", [[NSUUID UUID] UUIDString]] isDirectory:YES];
    NSURL *appNew = [self appNewDir];

    // ---- collect every download: the HTML plus each asset ----
    NSURL *htmlURL = [NSURL URLWithString:htmlPath relativeToURL:feed];
    if (!htmlURL || ![self allowScheme:htmlURL feed:feed]) {
        NSLog(@"%@ refusing html URL %@", GK_LOG_PREFIX, htmlPath);
        [self finishCheck:@"error" version:version manual:manual];
        return;
    }
    NSMutableArray<NSDictionary *> *plan = [NSMutableArray array];   // path/url/sha/dest
    for (id a in assets) {
        if (![a isKindOfClass:[NSDictionary class]]) { plan = nil; break; }
        NSString *path = a[@"path"], *sha = a[@"sha256"], *urlStr = a[@"url"];
        if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) urlStr = path;
        if (![self validRelativePath:path] || ![sha isKindOfClass:[NSString class]] || sha.length == 0) {
            NSLog(@"%@ asset entry rejected (%@)", GK_LOG_PREFIX, path);
            plan = nil; break;
        }
        NSURL *aURL = [NSURL URLWithString:urlStr relativeToURL:feed];
        if (!aURL || ![self allowScheme:aURL feed:feed]) {
            NSLog(@"%@ refusing asset URL %@", GK_LOG_PREFIX, urlStr);
            plan = nil; break;
        }
        [plan addObject:@{@"path": path, @"sha256": sha, @"url": aURL,
                          @"file": [staging URLByAppendingPathComponent:
                                    [NSString stringWithFormat:@"asset-%lu", (unsigned long)plan.count]]}];
    }
    if (!plan) {
        [self finishCheck:@"error" version:version manual:manual];
        return;
    }

    if (![fm createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil]) {
        NSLog(@"%@ could not create staging dir", GK_LOG_PREFIX);
        [self finishCheck:@"error" version:version manual:manual];
        return;
    }
    NSURL *htmlFile = [staging URLByAppendingPathComponent:@"index.html"];

    __block BOOL failed = NO;
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray arrayWithObject:
        @{@"url": htmlURL, @"file": htmlFile}];
    for (NSDictionary *p in plan) [jobs addObject:@{@"url": p[@"url"], @"file": p[@"file"]}];

    for (NSDictionary *job in jobs) {
        dispatch_group_enter(group);
        NSURL *src = job[@"url"], *dest = job[@"file"];
        [[self.session downloadTaskWithURL:src completionHandler:^(NSURL *loc, NSURLResponse *r, NSError *e) {
            NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r statusCode] : 0;
            if (e || code != 200 || !loc) {
                NSLog(@"%@ download failed for %@ (HTTP %ld, %@)", GK_LOG_PREFIX,
                      src.absoluteString, (long)code, e.localizedDescription ?: @"no error");
                failed = YES;
            } else {
                NSError *mv = nil;
                // must move synchronously, the temp file disappears when this handler returns
                if (![[NSFileManager defaultManager] moveItemAtURL:loc toURL:dest error:&mv]) {
                    NSLog(@"%@ could not stage %@: %@", GK_LOG_PREFIX, src.absoluteString, mv);
                    failed = YES;
                }
            }
            dispatch_group_leave(group);
        }] resume];
    }
    long waited = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)));
    if (waited != 0) {
        NSLog(@"%@ downloads timed out", GK_LOG_PREFIX);
        failed = YES;
    }
    if (failed) {
        [fm removeItemAtURL:staging error:nil];
        [self finishCheck:@"error" version:version manual:manual];
        return;
    }

    // ---- validate ----
    NSData *html = [NSData dataWithContentsOfURL:htmlFile];
    NSString *reject = nil;
    NSString *text = nil;
    if (!html || html.length == 0) reject = @"empty html";
    else if (![[SHA256Hex(html) lowercaseString] isEqualToString:[htmlSha lowercaseString]])
        reject = [NSString stringWithFormat:@"html sha256 mismatch (got %@, feed says %@)",
                  SHA256Hex(html), [htmlSha lowercaseString]];
    if (!reject) {
        text = [[NSString alloc] initWithData:html encoding:NSUTF8StringEncoding];
        if (!text) reject = @"html is not valid UTF-8";
    }
    if (!reject && ![text containsString:@"<title>GoalKeeper</title>"]) reject = @"html has no GoalKeeper title";
    if (!reject) {
        NSString *meta = [NSString stringWithFormat:@"<meta name=\"gk-version\" content=\"%@\">", version];
        if (![text containsString:meta])
            reject = [NSString stringWithFormat:@"html does not carry the %@ version meta", version];
    }
    if (!reject && ![text containsString:@"window.__loadedB64"]) reject = @"html has no window.__loadedB64";
    for (NSDictionary *p in plan) {
        if (reject) break;
        NSData *d = [NSData dataWithContentsOfURL:p[@"file"]];
        if (!d) { reject = [NSString stringWithFormat:@"asset %@ missing", p[@"path"]]; break; }
        if (![[SHA256Hex(d) lowercaseString] isEqualToString:[p[@"sha256"] lowercaseString]])
            reject = [NSString stringWithFormat:@"asset %@ sha256 mismatch", p[@"path"]];
    }
    if (reject) {
        NSLog(@"%@ rejected %@: %@ — nothing written", GK_LOG_PREFIX, version, reject);
        [fm removeItemAtURL:staging error:nil];
        [fm removeItemAtURL:appNew error:nil];
        [self finishCheck:@"error" version:version manual:manual];
        return;
    }

    // ---- build app.new, then swap ----
    NSString *problem = nil;
    [fm removeItemAtURL:appNew error:nil];
    if (![fm createDirectoryAtURL:appNew withIntermediateDirectories:YES attributes:nil error:nil])
        problem = @"could not create app.new";
    if (!problem) {
        NSURL *bundledFonts = [[NSBundle mainBundle] URLForResource:@"fonts" withExtension:nil subdirectory:@"app"];
        if (bundledFonts) {
            NSError *cp = nil;
            if (![fm copyItemAtURL:bundledFonts toURL:[appNew URLByAppendingPathComponent:@"fonts" isDirectory:YES] error:&cp])
                problem = [NSString stringWithFormat:@"could not copy bundled fonts: %@", cp.localizedDescription];
        }
    }
    for (NSDictionary *p in plan) {
        if (problem) break;
        NSURL *dest = [appNew URLByAppendingPathComponent:p[@"path"]];
        [fm createDirectoryAtURL:[dest URLByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtURL:dest error:nil];
        NSData *d = [NSData dataWithContentsOfURL:p[@"file"]];
        if (![d writeToURL:dest options:NSDataWritingAtomic error:nil])
            problem = [NSString stringWithFormat:@"could not write asset %@", p[@"path"]];
    }
    if (!problem) {
        NSError *w = nil;
        if (![html writeToURL:[appNew URLByAppendingPathComponent:@"index.html"]
                      options:NSDataWritingAtomic error:&w])
            problem = [NSString stringWithFormat:@"could not write index.html: %@", w.localizedDescription];
    }
    if (!problem) {
        [fm removeItemAtURL:[self appDir] error:nil];
        NSError *mv = nil;
        if (![fm moveItemAtURL:appNew toURL:[self appDir] error:&mv])
            problem = [NSString stringWithFormat:@"could not swap app.new into place: %@", mv.localizedDescription];
    }
    if (problem) {
        NSLog(@"%@ install of %@ failed: %@", GK_LOG_PREFIX, version, problem);
        [fm removeItemAtURL:staging error:nil];
        [fm removeItemAtURL:appNew error:nil];
        [self finishCheck:@"error" version:version manual:manual];
        return;
    }

    [fm removeItemAtURL:staging error:nil];
    NSLog(@"%@ installed %@ — ready to apply", GK_LOG_PREFIX, version);
    [self announcePending:@{@"version": version, @"notes": notes ?: @""} manual:manual];
}

#pragma mark - menu actions

- (void)showAbout:(id)sender {
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationVersion: [self bundleVersion],
        NSAboutPanelOptionVersion: [NSString stringWithFormat:@"UI %@", self.activeVersion ?: [self bundleVersion]]
    }];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)menuCheckUpdate:(id)sender { [self callJS:@"__menu" stringArgs:@[@"checkUpdate"]]; }
- (void)menuExport:(id)sender      { [self callJS:@"__menu" stringArgs:@[@"export"]]; }
- (void)menuImport:(id)sender      { [self callJS:@"__menu" stringArgs:@[@"import"]]; }
- (void)menuReveal:(id)sender      { [self revealDataFolder]; }
- (void)menuResetToBundled:(id)sender { [self resetToBundled]; }

#pragma mark - lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self writePreUpgradeBackupIfNeeded];   // before anything can touch data.json

    self.ucc = [WKUserContentController new];
    [self.ucc addScriptMessageHandler:self name:@"bridge"];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.userContentController = self.ucc;

    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    self.webView.navigationDelegate = self;
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

    NSURLSessionConfiguration *sc = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sc.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    sc.timeoutIntervalForRequest = 15;
    self.session = [NSURLSession sessionWithConfiguration:sc];

    [self loadAppHTML];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [self checkForUpdates:NO];   // runs in parallel with the page load
    self.periodicTimer = [NSTimer scheduledTimerWithTimeInterval:GK_PERIODIC_INTERVAL target:self
                                                        selector:@selector(periodicCheck:)
                                                        userInfo:nil repeats:YES];
    [self installDebugHooks];
}

- (void)periodicCheck:(NSTimer *)t { [self checkForUpdates:NO]; }

- (void)applicationDidBecomeActive:(NSNotification *)note {
    if (self.lastCheck && [[NSDate date] timeIntervalSinceDate:self.lastCheck] < GK_ACTIVATE_THROTTLE) return;
    [self checkForUpdates:NO];
}

// Env-gated manual-test hooks; they post through the real bridge so the tested path is
// the production one. Never active unless the variable is set (Terminal launches only).
- (void)installDebugHooks {
    NSDictionary *env = [NSProcessInfo processInfo].environment;
    NSString *js = nil;
    if ([env[@"GK_DEBUG_EXPORT"] isEqualToString:@"1"]) {
        js = @"window.webkit.messageHandlers.bridge.postMessage({type:'export',"
             @"data:JSON.stringify({app:'GoalKeeper',debug:true,shell:window.__shell}),filename:'GoalKeeper-backup-debug.json'})";
    } else if ([env[@"GK_DEBUG_BG"] isEqualToString:@"1"]) {
        js = @"window.webkit.messageHandlers.bridge.postMessage({type:'windowBg',r:20,g:20,b:30})";
    } else if ([env[@"GK_DEBUG_IMPORT"] isEqualToString:@"1"]) {
        js = @"window.webkit.messageHandlers.bridge.postMessage({type:'import'})";
    }
    if ([env[@"GK_DEBUG_SHELL"] isEqualToString:@"1"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.webView evaluateJavaScript:@"JSON.stringify(window.__shell)"
                           completionHandler:^(id result, NSError *e) {
                NSLog(@"GoalKeeper: window.__shell = %@ (err %@)", result, e.localizedDescription ?: @"none");
            }];
        });
    }
    if (!js) return;
    NSString *script = js;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"GoalKeeper: debug hook firing");
        [self runJS:script];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

// Main menu: Cmd+Q / Cmd+C / Cmd+V inside the web view, plus the File and update items.
static NSMenu *BuildMenu(id target) {
    NSMenu *main = [NSMenu new];

    NSMenuItem *appItem = [NSMenuItem new];
    [main addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [[appMenu addItemWithTitle:@"About GoalKeeper" action:@selector(showAbout:) keyEquivalent:@""] setTarget:target];
    [[appMenu addItemWithTitle:@"Check for Updates…" action:@selector(menuCheckUpdate:) keyEquivalent:@""] setTarget:target];
    [[appMenu addItemWithTitle:@"Reset to Built-in Version" action:@selector(menuResetToBundled:) keyEquivalent:@""] setTarget:target];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide GoalKeeper" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit GoalKeeper" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [NSMenuItem new];
    [main addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [[fileMenu addItemWithTitle:@"Export Backup…" action:@selector(menuExport:) keyEquivalent:@"E"] setTarget:target];
    [[fileMenu addItemWithTitle:@"Import Backup…" action:@selector(menuImport:) keyEquivalent:@"I"] setTarget:target];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [[fileMenu addItemWithTitle:@"Reveal Data Folder" action:@selector(menuReveal:) keyEquivalent:@""] setTarget:target];
    fileItem.submenu = fileMenu;

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
        AppDelegate *delegate = [AppDelegate new];
        app.mainMenu = BuildMenu(delegate);
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
