// Renders the GoalKeeper app icon: glassy dark squircle + hand-drawn white tally
// marks with a red marker strike. Usage: makeicon <output.png>
#import <Cocoa/Cocoa.h>

static void Glow(CGFloat x, CGFloat y, CGFloat r, NSColor *color) {
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:color
                                                  endingColor:[color colorWithAlphaComponent:0]];
    [g drawFromCenter:NSMakePoint(x, y) radius:0 toCenter:NSMakePoint(x, y) radius:r options:0];
}

static void Stroke(CGFloat pts[4][2], CGFloat width, NSColor *color) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = width;
    p.lineCapStyle = NSLineCapStyleRound;
    p.lineJoinStyle = NSLineJoinStyleRound;
    [p moveToPoint:NSMakePoint(pts[0][0], pts[0][1])];
    [p curveToPoint:NSMakePoint(pts[3][0], pts[3][1])
      controlPoint1:NSMakePoint(pts[1][0], pts[1][1])
      controlPoint2:NSMakePoint(pts[2][0], pts[2][1])];
    [color setStroke];
    [p stroke];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"icon_1024.png";
        CGFloat S = 1024;

        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(S, S)];
        [image lockFocus];
        CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;

        // macOS icon grid: squircle with ~100px margin
        NSRect rect = NSMakeRect(100, 100, S - 200, S - 200);
        NSBezierPath *squircle = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:210 yRadius:210];
        [squircle addClip];

        NSGradient *grad = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithCalibratedRed:0.88 green:0.88 blue:1.0 alpha:1],
            [NSColor colorWithCalibratedRed:0.83 green:0.83 blue:1.0 alpha:1],
            [NSColor colorWithCalibratedRed:0.78 green:0.76 blue:1.0 alpha:1],
        ]];
        [grad drawInRect:rect angle:-70];

        Glow(760, 780, 360, [NSColor colorWithCalibratedRed:1.0 green:0.55 blue:0.78 alpha:0.40]);
        Glow(280, 260, 380, [NSColor colorWithCalibratedRed:0.65 green:0.45 blue:1.0 alpha:0.48]);
        Glow(700, 240, 300, [NSColor colorWithCalibratedRed:1.0 green:0.45 blue:0.75 alpha:0.25]);

        // frosted glass inner panel
        NSRect panelRect = NSMakeRect(212, 212, 600, 600);
        NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:panelRect xRadius:120 yRadius:120];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.42] setFill];
        [panel fill];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.85] setStroke];
        panel.lineWidth = 6;
        [panel stroke];

        // specular highlight strip on panel
        NSGradient *spec = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithCalibratedWhite:1 alpha:0.0],
            [NSColor colorWithCalibratedWhite:1 alpha:0.55],
            [NSColor colorWithCalibratedWhite:1 alpha:0.0],
        ]];
        [spec drawInRect:NSMakeRect(280, 800, 464, 7) angle:0];

        // hand-drawn tally marks (4 white strokes + red diagonal strike)
        CGContextSetShadowWithColor(ctx, CGSizeZero, 30,
            [NSColor colorWithCalibratedRed:0.80 green:0.60 blue:1.0 alpha:0.9].CGColor);
        CGFloat xs[4] = {352, 452, 552, 652};
        CGFloat jit[4] = {8, -6, 4, -9};
        for (int i = 0; i < 4; i++) {
            CGFloat pts[4][2] = {
                {xs[i] + jit[i], 700}, {xs[i] - 10, 580}, {xs[i] + 12, 450}, {xs[i] - jit[i], 330}
            };
            Stroke(pts, 42, [NSColor colorWithCalibratedRed:0.36 green:0.26 blue:0.72 alpha:0.96]);
        }
        CGContextSetShadowWithColor(ctx, CGSizeZero, 26,
            [NSColor colorWithCalibratedRed:1 green:0.3 blue:0.3 alpha:0.8].CGColor);
        CGFloat strike[4][2] = {{280, 380}, {420, 470}, {580, 560}, {740, 640}};
        Stroke(strike, 46, [NSColor colorWithCalibratedRed:1.0 green:0.30 blue:0.30 alpha:0.95]);

        [image unlockFocus];

        NSData *tiff = image.TIFFRepresentation;
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:out atomically:YES]) {
            fprintf(stderr, "failed to write %s\n", out.UTF8String);
            return 1;
        }
        printf("wrote %s\n", out.UTF8String);
    }
    return 0;
}
