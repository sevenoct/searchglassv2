// GlassSearch - search pill ala iOS 26 untuk iOS 15 (SpringBoard)
// Pill liquid glass di atas dock -> tap -> blur + search bar nempel di atas keyboard.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

@interface UIImage (GSPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(CGFloat)scale;
@end

#pragma mark - Pengaturan (Settings > GlassSearch), per permukaan: "Pill" dan "Field"

#define GS_DOMAIN CFSTR("com.hasan.glasssearch")

static id GSPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, GS_DOMAIN));
}
static CGFloat GSNum(NSString *k, CGFloat def) {
    id v = GSPref(k);
    return [v respondsToSelector:@selector(doubleValue)] ? (CGFloat)[v doubleValue] : def;
}
static BOOL GSBool(NSString *k, BOOL def) {
    id v = GSPref(k);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def;
}
static CGFloat GSClamp(CGFloat v, CGFloat lo, CGFloat hi) { return MAX(lo, MIN(hi, v)); }
static UIColor *GSHexColor(id hex, CGFloat a, UIColor *def) {
    if ([hex isKindOfClass:NSString.class]) {
        NSString *h = [hex stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# \n"]];
        unsigned v = 0;
        if (h.length == 6 && [[NSScanner scannerWithString:h] scanHexInt:&v])
            return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:a];
    }
    return [def colorWithAlphaComponent:a];
}

@interface GSStyle : NSObject
@property (nonatomic) BOOL enabled, dispersion;
@property (nonatomic) CGFloat blur, refraction, index, thickness, bezel, dispStrength, corner;
@property (nonatomic) NSInteger spec;   // 0 None, 1 Border, 2 Glass, 3 iOS 26, 4 iOS 27
@property (nonatomic, strong) UIColor *lightTint, *darkTint;
+ (instancetype)loadWithPrefix:(NSString *)p;
@end
@implementation GSStyle
+ (instancetype)loadWithPrefix:(NSString *)p {
    GSStyle *s = [GSStyle new];
    #define K(x) [NSString stringWithFormat:@"%@.%@", p, x]
    s.enabled = GSBool(K(@"Enabled"), YES);
    s.blur = GSClamp(GSNum(K(@"Blur"), 20), 0, 60);
    s.refraction = GSClamp(GSNum(K(@"Refraction"), 0.35), -2, 2);
    s.index = GSClamp(GSNum(K(@"RefractiveIndex"), 1.5), 1, 2.5);
    s.thickness = GSClamp(GSNum(K(@"GlassThickness"), 1), 0.1, 4);
    s.bezel = GSClamp(GSNum(K(@"BezelWidth"), 10), 2, 60);
    s.spec = (NSInteger)GSNum(K(@"SpecularType"), 2);
    s.dispersion = GSBool(K(@"DispersionEnabled"), NO);
    s.dispStrength = GSClamp(GSNum(K(@"DispersionStrength"), 0.5), 0, 1);
    s.corner = GSClamp(GSNum(K(@"CornerRadius"), 100), 0, 100);
    s.lightTint = GSHexColor(GSPref(K(@"LightTint")), GSClamp(GSNum(K(@"LightTintAlpha"), 0.25), 0, 1), UIColor.whiteColor);
    s.darkTint = GSHexColor(GSPref(K(@"DarkTint")), GSClamp(GSNum(K(@"DarkTintAlpha"), 0.10), 0, 1), UIColor.whiteColor);
    #undef K
    return s;
}
@end

static BOOL gsMaster = YES, gsMotion = NO;
static CGFloat gsLiquidity = 1, gsQuality = 0.5, gsMotionSens = 1;
static CGFloat gsOffset = 0;   // pill naik (+) / turun (-) dari posisi default di atas dock
static GSStyle *gsStylePill, *gsStyleField;

#pragma mark - Glass views (gaya Liquid Glass: backdrop blur + refraksi + specular rim + dispersi)

static id GSFilter(NSString *type) {
    Class CF = NSClassFromString(@"CAFilter");
    if (!CF) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(CF, NSSelectorFromString(@"filterWithType:"), type);
}

// Peta displacement: di tepi (selebar "bezel") cahaya dibelokkan; 128 = netral
static UIImage *GSDisplacementMap(CGSize sz, CGFloat radius, GSStyle *st) {
    static NSCache *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 24; }
    int W = MAX(2, (int)lround(sz.width)), H = MAX(2, (int)lround(sz.height));
    NSString *key = [NSString stringWithFormat:@"%d,%d,%.1f,%.1f,%.2f,%.2f,%.2f", W, H, radius, st.bezel, st.refraction, st.index, st.thickness];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    CGFloat strength = GSClamp((st.index - 1.0) * st.refraction * st.thickness * 1.6, -1, 1);
    uint8_t *buf = malloc((size_t)W * H * 4);
    float hx = W / 2.0f, hy = H / 2.0f;
    float r = (float)MIN(radius, MIN(hx, hy)), bz = (float)MAX(1, st.bezel);
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            float px = x + 0.5f - hx, py = y + 0.5f - hy;
            float qx = fabsf(px) - (hx - r), qy = fabsf(py) - (hy - r);
            float ox = MAX(qx, 0), oy = MAX(qy, 0);
            float outside = sqrtf(ox * ox + oy * oy);
            float sd = outside + MIN(MAX(qx, qy), 0) - r;     // negatif di dalam
            float d = -sd;
            uint8_t R = 128, G = 128;
            if (d >= 0 && d < bz) {
                float gx, gy;
                if (qx > 0 && qy > 0 && outside > 0) { gx = (px < 0 ? -ox : ox) / outside; gy = (py < 0 ? -oy : oy) / outside; }
                else if (qx > qy) { gx = px < 0 ? -1 : 1; gy = 0; }
                else { gx = 0; gy = py < 0 ? -1 : 1; }
                float t = 1.0f - d / bz;
                float m = powf(t, 2.2f) * (float)strength;
                R = (uint8_t)GSClamp(128 + 127 * gx * m, 0, 255);
                G = (uint8_t)GSClamp(128 + 127 * gy * m, 0, 255);
            }
            uint8_t *p = buf + ((size_t)y * W + x) * 4;
            p[0] = R; p[1] = G; p[2] = 128; p[3] = 255;
        }
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, (size_t)W * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef ci = CGBitmapContextCreateImage(ctx);
    UIImage *img = [UIImage imageWithCGImage:ci scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(ci); CGContextRelease(ctx); CGColorSpaceRelease(cs); free(buf);
    [cache setObject:img forKey:key];
    return img;
}

// Ring tipis berwarna gradient (specular / dispersi), di-mask jadi garis tepi
@interface GSRimView : UIView
@property (nonatomic) CGFloat lineWidth;
- (void)setColors:(NSArray *)colors locations:(NSArray *)loc width:(CGFloat)w angle:(CGFloat)a;
- (void)setAngle:(CGFloat)a;
@end
@implementation GSRimView { CAShapeLayer *_mask; }
+ (Class)layerClass { return [CAGradientLayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mask = [CAShapeLayer layer];
    _mask.fillColor = NULL;
    _mask.strokeColor = UIColor.whiteColor.CGColor;
    self.layer.mask = _mask;
    _lineWidth = 1;
    return self;
}
- (void)setColors:(NSArray *)colors locations:(NSArray *)loc width:(CGFloat)w angle:(CGFloat)a {
    CAGradientLayer *gl = (CAGradientLayer *)self.layer;
    NSMutableArray *cg = [NSMutableArray array];
    for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
    gl.colors = cg;
    gl.locations = loc;
    _lineWidth = w;
    [self setAngle:a];
    [self setNeedsLayout];
}
- (void)setAngle:(CGFloat)a {
    CAGradientLayer *gl = (CAGradientLayer *)self.layer;
    CGFloat dx = cos(a) * 0.5, dy = sin(a) * 0.5;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gl.startPoint = CGPointMake(0.5 - dx, 0.5 - dy);
    gl.endPoint = CGPointMake(0.5 + dx, 0.5 + dy);
    [CATransaction commit];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = _lineWidth, r = self.superview.layer.cornerRadius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _mask.frame = self.bounds;
    _mask.lineWidth = w;
    _mask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, w / 2, w / 2) cornerRadius:MAX(0, r - w / 2)].CGPath;
    [CATransaction commit];
}
@end

@interface GSGlassView : UIView
@property (nonatomic, readonly) UIView *content;
@property (nonatomic, copy) NSString *surface;          // @"Pill" atau @"Field"
@property (nonatomic) CGFloat maxRadius;                // 0 = tanpa batas
- (void)applyStyle;
- (void)setMotionAngle:(CGFloat)a;
- (CGFloat)radiusForSize:(CGSize)s;
@end

static NSHashTable<GSGlassView *> *GSRegistry(void) {
    static NSHashTable *t;
    if (!t) t = [NSHashTable weakObjectsHashTable];
    return t;
}

// Dasar kaca = UIVisualEffectView (backdrop yang pasti menangkap wallpaper), lalu filter
// backdrop-nya diganti (blur/saturasi/refraksi) dan lapisan gelap bawaannya disembunyikan
// supaya tampilannya ditentukan oleh tint + rim kita (lebih mirip dock / Control Center).
@implementation GSGlassView {
    UIVisualEffectView *_fx;
    UIView *_tint;
    GSRimView *_red, *_blue, *_spec;
    CGFloat _motion;
    NSString *_lastKey;
    BOOL _glassOn;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    _surface = @"Field";
    UIViewAutoresizing flex = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _fx = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _fx.frame = self.bounds; _fx.autoresizingMask = flex;
    [self addSubview:_fx];

    _tint = [[UIView alloc] initWithFrame:self.bounds];
    _tint.autoresizingMask = flex; _tint.userInteractionEnabled = NO;
    [self addSubview:_tint];

    _red = [[GSRimView alloc] initWithFrame:self.bounds];
    _blue = [[GSRimView alloc] initWithFrame:self.bounds];
    _spec = [[GSRimView alloc] initWithFrame:self.bounds];
    [self addSubview:_red]; [self addSubview:_blue]; [self addSubview:_spec];

    _content = [[UIView alloc] initWithFrame:self.bounds];
    _content.autoresizingMask = flex;
    [self addSubview:_content];

    [GSRegistry() addObject:self];
    [self applyStyle];
    return self;
}
- (void)setSurface:(NSString *)s { _surface = [s copy]; [self applyStyle]; }
- (GSStyle *)style {
    GSStyle *st = [_surface isEqualToString:@"Pill"] ? gsStylePill : gsStyleField;
    if (!st) st = [GSStyle loadWithPrefix:_surface];
    return st;
}
- (CGFloat)radiusForSize:(CGSize)s {
    CGFloat full = MIN(s.width, s.height) / 2;
    if (_maxRadius > 0) full = MIN(full, _maxRadius);
    return full * [self style].corner / 100.0;
}
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    [self applyStyle];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    _lastKey = nil;
    [self setNeedsLayout];
}
- (void)setMotionAngle:(CGFloat)a { _motion = a; [self updateSpecAngle]; }
- (void)updateSpecAngle { [_spec setAngle:M_PI_4 + _motion]; }

- (void)applyStyle {
    GSStyle *st = [self style];
    BOOL glass = st.enabled;
    if (_glassOn && !glass) {
        // kembali ke material bawaan: set ulang effect supaya UIKit memasang filter aslinya
        _fx.effect = nil;
        _fx.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    }
    _glassOn = glass;

    BOOL isDark = self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight;
    _tint.backgroundColor = glass ? (isDark ? st.darkTint : st.lightTint) : UIColor.clearColor;

    UIColor *(^W)(CGFloat) = ^UIColor *(CGFloat a) { return [UIColor colorWithWhite:1 alpha:a]; };
    _spec.hidden = !(glass && st.spec > 0);
    switch (st.spec) {
        // tipis & halus seperti dock / Control Center; terang hanya di sudut kiri-atas & kanan-bawah
        case 1: [_spec setColors:@[W(0.22), W(0.22)] locations:@[@0, @1] width:0.7 angle:M_PI_4]; break;
        case 2: [_spec setColors:@[W(0.50), W(0.12), W(0.05), W(0.10), W(0.30)] locations:@[@0, @0.3, @0.55, @0.8, @1] width:0.8 angle:M_PI_4]; break;
        case 3: [_spec setColors:@[W(0.70), W(0.10), W(0.03), W(0.08), W(0.55)] locations:@[@0, @0.25, @0.5, @0.75, @1] width:0.9 angle:M_PI_4]; break;
        case 4: [_spec setColors:@[W(0.45), W(0.14), W(0.06), W(0.14), W(0.40)] locations:@[@0, @0.3, @0.5, @0.7, @1] width:1.1 angle:M_PI_4]; break;
        default: break;
    }
    [self updateSpecAngle];

    BOOL disp = glass && st.dispersion && st.dispStrength > 0.01;
    _red.hidden = _blue.hidden = !disp;
    if (disp) {
        CGFloat a = 0.35 * st.dispStrength;
        UIColor *rc = [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:a], *bc = [UIColor colorWithRed:0.25 green:0.55 blue:1 alpha:a];
        [_red setColors:@[rc, rc] locations:@[@0, @1] width:0.9 angle:M_PI_4];
        [_blue setColors:@[bc, bc] locations:@[@0, @1] width:0.9 angle:M_PI_4];
        CGFloat o = 0.3 + 0.9 * st.dispStrength;
        _red.transform = CGAffineTransformMakeTranslation(-o, -o);
        _blue.transform = CGAffineTransformMakeTranslation(o, o);
    }
    _lastKey = nil;
    [self setNeedsLayout];
}

- (void)refreshFilters {
    GSStyle *st = [self style];
    if (!st.enabled) return;
    CGSize sz = self.bounds.size;
    if (sz.width < 2 || sz.height < 2) return;

    // backdrop internal milik UIVisualEffectView + sembunyikan lapisan warna bawaannya
    UIView *bd = nil;
    for (UIView *s in _fx.subviews) {
        if (strstr(object_getClassName(s), "Backdrop")) bd = s;
        else s.hidden = YES;
    }
    if (!bd) return;

    NSMutableArray *f = [NSMutableArray array];
    if (fabs(st.refraction) > 0.001 && st.index > 1.001) {
        id d = GSFilter(@"displacementMap");
        UIImage *map = GSDisplacementMap(sz, self.layer.cornerRadius, st);
        if (d && map) {
            @try {
                [d setValue:(__bridge id)map.CGImage forKey:@"inputImage"];
                [d setValue:@(st.bezel * 1.2) forKey:@"inputAmount"];
                [f addObject:d];
            } @catch (id e) {}
        }
    }
    id blur = GSFilter(@"gaussianBlur");
    if (blur) {
        @try {
            [blur setValue:@(MAX(0.5, st.blur * gsLiquidity)) forKey:@"inputRadius"];
            [blur setValue:@YES forKey:@"inputNormalizeEdges"];
            [f addObject:blur];
        } @catch (id e) {}
    }
    id sat = GSFilter(@"colorSaturate");
    if (sat) { @try { [sat setValue:@1.8 forKey:@"inputAmount"]; [f addObject:sat]; } @catch (id e) {} }
    if (!f.count) return;       // filter privat tidak ada -> biarkan material bawaan

    CALayer *bl = bd.layer;
    @try {
        bl.filters = f;
        if ([bl respondsToSelector:NSSelectorFromString(@"setScale:")]) [bl setValue:@(gsQuality) forKey:@"scale"];
    } @catch (id e) {}
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [_red setNeedsLayout]; [_blue setNeedsLayout]; [_spec setNeedsLayout];
    NSString *k = [NSString stringWithFormat:@"%.1f,%.1f,%.1f", self.bounds.size.width, self.bounds.size.height, self.layer.cornerRadius];
    if ([k isEqualToString:_lastKey]) return;
    _lastKey = k;
    [self refreshFilters];
}
@end

static UIImage *GSSymbol(NSString *name, CGFloat size) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:name withConfiguration:cfg];
}

// Highlight mengikuti arah perangkat (kompas)
@interface GSMotion : NSObject
+ (void)refresh;
@end
@implementation GSMotion
+ (void)refresh {
    static CMMotionManager *mm;
    BOOL want = gsMotion && gsMaster && GSRegistry().count > 0;
    if (want && !mm) {
        mm = [CMMotionManager new];
        mm.deviceMotionUpdateInterval = 1.0 / 30;
        CMAttitudeReferenceFrame fr = ([CMMotionManager availableAttitudeReferenceFrames] & CMAttitudeReferenceFrameXMagneticNorthZVertical)
            ? CMAttitudeReferenceFrameXMagneticNorthZVertical : CMAttitudeReferenceFrameXArbitraryZVertical;
        [mm startDeviceMotionUpdatesUsingReferenceFrame:fr toQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *m, NSError *e) {
            if (!m) return;
            CGFloat a = m.attitude.yaw * gsMotionSens;
            for (GSGlassView *v in GSRegistry().allObjects) [v setMotionAngle:a];
        }];
    } else if (!want && mm) {
        [mm stopDeviceMotionUpdates];
        mm = nil;
        for (GSGlassView *v in GSRegistry().allObjects) [v setMotionAngle:0];
    }
}
@end

static void GSLoadPrefs(void) {
    CFPreferencesAppSynchronize(GS_DOMAIN);
    gsMaster = GSBool(@"Enabled", YES);
    gsLiquidity = GSClamp(GSNum(@"Liquidity", 1), 0.2, 3);
    gsQuality = GSClamp(GSNum(@"Quality", 0.5), 0.15, 1);
    gsMotion = GSBool(@"MotionHighlights", NO);
    gsMotionSens = GSClamp(GSNum(@"MotionSensitivity", 1), 0, 3);
    gsOffset = GSClamp(GSNum(@"pillOffset", 0), -60, 400);
    gsStylePill = [GSStyle loadWithPrefix:@"Pill"];
    gsStyleField = [GSStyle loadWithPrefix:@"Field"];
    for (GSGlassView *v in GSRegistry().allObjects) [v applyStyle];
    [GSMotion refresh];
}

// Search bar bawah: ikon kaca pembesar + text field + mic
@interface GSBar : GSGlassView
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIImageView *mic;
@end
@implementation GSBar
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _icon = [[UIImageView alloc] initWithImage:GSSymbol(@"magnifyingglass", 16)];
    _icon.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    _icon.contentMode = UIViewContentModeCenter;
    _mic = [[UIImageView alloc] initWithImage:GSSymbol(@"mic.fill", 16)];
    _mic.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    _mic.contentMode = UIViewContentModeCenter;
    _field = [[UITextField alloc] init];
    _field.textColor = UIColor.whiteColor;
    _field.tintColor = UIColor.whiteColor;
    _field.font = [UIFont systemFontOfSize:17];
    _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search"
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    _field.returnKeyType = UIReturnKeySearch;
    _field.keyboardAppearance = UIKeyboardAppearanceDark;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.clearButtonMode = UITextFieldViewModeNever;
    [self.content addSubview:_icon];
    [self.content addSubview:_field];
    [self.content addSubview:_mic];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _icon.frame = CGRectMake(14, (h - 22) / 2, 22, 22);
    _mic.frame = CGRectMake(w - 14 - 22, (h - 22) / 2, 22, 22);
    _field.frame = CGRectMake(44, 0, MAX(0, w - 44 - 44), h);
}
@end

#pragma mark - Pill di home screen

static GSGlassView *gsPill;
static UIView *gsPillInner;          // ikon + teks "Search"
static UIView *gsDotsBox;            // titik halaman
static NSMutableArray<UIView *> *gsDots;
static BOOL gsPillSuppressed;
static __weak UIView *gsRoot;
static CGFloat gsMorph = 0;          // 0 = pill, 1 = titik dua
static CGFloat gsPageP = 0;          // posisi halaman (kontinu)
static NSInteger gsPageCount = 1;

static UIView *GSDockOf(UIView *root) {
    UIView *dock = nil;
    @try { if ([root respondsToSelector:NSSelectorFromString(@"dockView")]) dock = [root valueForKey:@"dockView"]; } @catch (id e) {}
    return [dock isKindOfClass:UIView.class] ? dock : nil;
}

// Susun ulang pill: lebar/tinggi/ikon/titik mengikuti gsMorph (diikat ke offset scroll)
static void GSLayoutPill(void) {
    UIView *root = gsRoot;
    if (!gsPill || !root) return;
    UIView *dock = GSDockOf(root);
    CGFloat y = CGRectGetHeight(root.bounds) - 150;
    if (dock) {
        CGRect df = [root convertRect:dock.bounds fromView:dock];
        y = CGRectGetMinY(df) - 16 - 30;
        gsPill.alpha = dock.alpha;
    }
    y -= gsOffset;

    NSInteger n = MAX(1, gsPageCount);
    CGFloat dotsInnerW = n * 7.0 + (n - 1) * 9.0;
    CGFloat dotsW = dotsInnerW + 28;
    CGFloat t = MAX(0, MIN(1, gsMorph));
    CGFloat e = t * t * (3 - 2 * t);
    CGFloat w = 92 + (dotsW - 92) * e;
    CGFloat h = 30 + (22 - 30) * e;
    CGFloat cy = y + 15;

    gsPill.frame = CGRectMake(CGRectGetMidX(root.bounds) - w / 2, cy - h / 2, w, h);
    gsPill.layer.cornerRadius = [gsPill radiusForSize:CGSizeMake(w, h)];

    CGPoint c = CGPointMake(w / 2, h / 2);
    gsPillInner.center = c;
    gsPillInner.alpha = MAX(0, 1 - e * 2.2);
    gsDotsBox.bounds = CGRectMake(0, 0, dotsInnerW, 7);
    gsDotsBox.center = c;
    gsDotsBox.alpha = MAX(0, e * 2.2 - 1.2) / 0.8;

    while ((NSInteger)gsDots.count < n) {
        UIView *d = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 7, 7)];
        d.backgroundColor = UIColor.whiteColor;
        d.layer.cornerRadius = 3.5;
        [gsDotsBox addSubview:d];
        [gsDots addObject:d];
    }
    while ((NSInteger)gsDots.count > n) { [gsDots.lastObject removeFromSuperview]; [gsDots removeLastObject]; }
    for (NSInteger i = 0; i < n; i++) {
        UIView *d = gsDots[i];
        CGFloat a = 1 - MIN(1, fabs(gsPageP - i));
        d.bounds = CGRectMake(0, 0, 7, 7);
        d.center = CGPointMake(3.5 + i * 16.0, 3.5);
        d.alpha = 0.38 + 0.62 * a;
        d.transform = CGAffineTransformMakeScale(1 + 0.3 * a, 1 + 0.3 * a);
    }
}

// Pantau scroll halaman home: morph pill <-> titik mengikuti geseran jari/kecepatan scroll
@interface GSScrollWatcher : NSObject
+ (instancetype)shared;
- (void)watch:(UIScrollView *)sv;
@end
@implementation GSScrollWatcher { __weak UIScrollView *_sv; }
+ (instancetype)shared {
    static GSScrollWatcher *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [GSScrollWatcher new]; });
    return s;
}
- (void)watch:(UIScrollView *)sv {
    if (_sv == sv) return;
    if (_sv) { @try { [_sv removeObserver:self forKeyPath:@"contentOffset"]; } @catch (id e) {} }
    _sv = sv;
    if (sv) [sv addObserver:self forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:NULL];
    [self update];
}
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx { [self update]; }
- (void)update {
    UIScrollView *sv = _sv;
    if (!sv || !gsPill) return;
    CGFloat pw = sv.bounds.size.width;
    if (pw < 1) return;
    CGFloat p = sv.contentOffset.x / pw;
    NSInteger n = (NSInteger)lround(sv.contentSize.width / pw);
    gsPageCount = MAX(1, MIN(15, n));
    gsPageP = p;
    CGFloat frac = fabs(p - round(p));            // 0 di tengah halaman, 0.5 di antara dua halaman
    gsMorph = MIN(1, frac / 0.22);                // cepat/lambat geser = cepat/lambat berubah
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    GSLayoutPill();
    [CATransaction commit];
}
@end

#pragma mark - Overlay controller

@interface GSController : UIViewController <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)presentFromRect:(CGRect)rect;
- (void)dismissThen:(void (^)(void))then;
- (void)pillTapped;
@end

static UIImage *GSIcon(NSString *bid) {
    static NSMutableDictionary *cache;
    @synchronized ([GSController class]) {
        if (!cache) cache = [NSMutableDictionary dictionary];
        if (cache[bid]) return cache[bid];
    }
    UIImage *raw = [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:UIScreen.mainScreen.scale];
    if (!raw) return nil;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)]
        imageWithActions:^(UIGraphicsImageRendererContext *c) { [raw drawInRect:CGRectMake(0, 0, 40, 40)]; }];
    @synchronized ([GSController class]) { cache[bid] = img; }
    return img;
}

// Daftar app + ikon di-cache di background supaya buka search & buka app tidak nge-lag
static NSArray<NSDictionary *> *gsAppsCache;
static BOOL gsAppsLoading;

static NSArray<NSDictionary *> *GSFetchApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        LSApplicationWorkspace *ws = [c performSelector:@selector(defaultWorkspace)];
        for (id p in [ws allInstalledApplications]) {
            NSString *bid = [p valueForKey:@"applicationIdentifier"];
            NSString *name = [p valueForKey:@"localizedName"];
            if (!bid.length || !name.length) continue;
            NSArray *tags = nil;
            @try { tags = [p valueForKey:@"appTags"]; } @catch (id e) {}
            if ([tags containsObject:@"hidden"]) continue;
            [out addObject:@{@"name": name, @"bid": bid}];
        }
    } @catch (id e) {}
    return out;
}

static void GSReloadAppsAsync(void) {
    if (gsAppsLoading) return;
    gsAppsLoading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *apps = GSFetchApps();
        for (NSDictionary *a in apps) GSIcon(a[@"bid"]);
        dispatch_async(dispatch_get_main_queue(), ^{ gsAppsCache = apps; gsAppsLoading = NO; });
    });
}

// Buka app langsung lewat SpringBoard (jauh lebih cepat dari LSApplicationWorkspace di main thread)
static void GSOpenApp(NSString *bid) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL s = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:s]) {
        ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, s, bid, NO);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        LSApplicationWorkspace *ws = [c performSelector:@selector(defaultWorkspace)];
        [ws openApplicationWithBundleID:bid];
    });
}

@implementation GSController {
    UIWindow *_window, *_prevKey;
    UIVisualEffectView *_backdrop;
    UIView *_dim;
    GSBar *_bar;
    GSGlassView *_card;
    UITableView *_table;
    NSArray<NSDictionary *> *_allApps, *_results;
    CGRect _pillRect;
    CGFloat _kbTop;
    BOOL _dismissing, _kbSeen;
}

+ (instancetype)shared {
    static GSController *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [GSController new]; });
    return s;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _backdrop.frame = self.view.bounds;
    _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_backdrop];

    _dim = [[UIView alloc] initWithFrame:self.view.bounds];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_dim];

    _card = [[GSGlassView alloc] initWithFrame:CGRectZero];
    _card.maxRadius = 26;
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.12];
    _table.rowHeight = 56;
    _table.dataSource = self;
    _table.delegate = self;
    _table.frame = _card.content.bounds;
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_card.content addSubview:_table];
    [self.view addSubview:_card];

    _bar = [[GSBar alloc] initWithFrame:CGRectZero];
    _bar.field.delegate = self;
    [_bar.field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
    [self.view addSubview:_bar];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped)];
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    swipe.delegate = self;
    [self.view addGestureRecognizer:swipe];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return ![t.view isDescendantOfView:_bar] && ![t.view isDescendantOfView:_card];
}
- (void)bgTapped { [self dismissThen:nil]; }

#pragma mark Data

- (void)loadApps {
    if (gsAppsCache) _allApps = gsAppsCache;        // cache siap -> tidak ada kerja berat di main thread
    else _allApps = GSFetchApps();
    GSReloadAppsAsync();                            // segarkan cache di background
}

- (void)updateResults {
    NSString *q = [_bar.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!q.length) { _results = @[]; return; }
    NSMutableArray *pre = [NSMutableArray array], *con = [NSMutableArray array];
    for (NSDictionary *a in _allApps) {
        NSRange r = [a[@"name"] rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        if (r.location == NSNotFound) continue;
        [(r.location == 0 ? pre : con) addObject:a];
    }
    NSSortDescriptor *sd = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *list = [NSMutableArray array];
    [list addObjectsFromArray:[pre sortedArrayUsingDescriptors:@[sd]]];
    [list addObjectsFromArray:[con sortedArrayUsingDescriptors:@[sd]]];
    if (list.count > 6) [list removeObjectsInRange:NSMakeRange(6, list.count - 6)];
    [list addObject:@{@"name": [NSString stringWithFormat:@"Search Web for “%@”", q], @"q": q}];
    _results = list;
}

- (void)textChanged {
    [self updateResults];
    [_table reloadData];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ [self layoutCard]; } completion:nil];
}

#pragma mark Layout

- (void)layoutCard {
    CGFloat W = self.view.bounds.size.width;
    CGFloat top = self.view.safeAreaInsets.top + 8;
    CGFloat avail = MAX(0, CGRectGetMinY(_bar.frame) - 10 - top);
    CGFloat h = MIN(_results.count * 56.0, avail);
    _card.frame = CGRectMake(16, CGRectGetMinY(_bar.frame) - 10 - h, W - 32, h);
    _card.layer.cornerRadius = [_card radiusForSize:_card.frame.size];
    _card.alpha = _results.count ? 1 : 0;
}

- (void)applyLayoutWithDuration:(double)d options:(UIViewAnimationOptions)o {
    [UIView animateWithDuration:d delay:0 options:o | UIViewAnimationOptionBeginFromCurrentState animations:^{
        CGFloat W = self.view.bounds.size.width;
        self->_bar.frame = CGRectMake(16, self->_kbTop - 10 - 46, W - 32, 46);
        self->_bar.layer.cornerRadius = [self->_bar radiusForSize:self->_bar.frame.size];
        self->_bar.icon.alpha = self->_bar.field.alpha = self->_bar.mic.alpha = 1;
        [self layoutCard];
    } completion:nil];
}

- (void)kbChange:(NSNotification *)n {
    if (_dismissing || !_window) return;
    _kbSeen = YES;
    CGRect end = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat H = CGRectGetHeight(self.view.bounds);
    _kbTop = end.origin.y >= H - 1 ? H - self.view.safeAreaInsets.bottom : end.origin.y;
    double d = [n.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSUInteger c = [n.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue];
    [self applyLayoutWithDuration:d options:(UIViewAnimationOptions)(c << 16)];
}

#pragma mark Present / dismiss

- (void)pillTapped {
    CGRect r = gsPill ? [gsPill convertRect:gsPill.bounds toView:nil] : CGRectZero;
    [self presentFromRect:r];
}

- (void)presentFromRect:(CGRect)rect {
    if (_window) return;
    GSLoadPrefs();
    CGRect scr = UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(rect)) rect = CGRectMake(CGRectGetMidX(scr) - 46, CGRectGetHeight(scr) - 150, 92, 30);
    _pillRect = rect; _dismissing = NO; _kbSeen = NO;
    _prevKey = UIApplication.sharedApplication.keyWindow;
    [self loadApps];

    _window = [[UIWindow alloc] initWithFrame:scr];
    _window.windowLevel = UIWindowLevelAlert + 50;
    _window.backgroundColor = UIColor.clearColor;
    _window.rootViewController = self;
    [_window makeKeyAndVisible];
    [self.view layoutIfNeeded];

    gsPillSuppressed = YES; gsPill.hidden = YES;
    _results = @[]; [_table reloadData];
    _bar.field.text = @"";
    _backdrop.alpha = 0; _dim.alpha = 0; _card.alpha = 0;
    _bar.frame = rect; _bar.layer.cornerRadius = [_bar radiusForSize:rect.size];
    _bar.icon.alpha = _bar.field.alpha = _bar.mic.alpha = 0;
    _kbTop = CGRectGetHeight(scr) - 300;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbChange:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    [UIView animateWithDuration:0.30 animations:^{ self->_backdrop.alpha = 1; self->_dim.alpha = 1; }];
    [_bar.field becomeFirstResponder];

    // cadangan kalau notifikasi keyboard tidak datang (mis. keyboard hardware)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_kbSeen && !self->_dismissing && self->_window)
            [self applyLayoutWithDuration:0.3 options:UIViewAnimationOptionCurveEaseInOut];
    });
}

- (void)dismissThen:(void (^)(void))then {
    if (!_window || _dismissing) return;
    _dismissing = YES;
    [_bar.field resignFirstResponder];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_backdrop.alpha = 0; self->_dim.alpha = 0; self->_card.alpha = 0;
        self->_bar.frame = self->_pillRect;
        self->_bar.layer.cornerRadius = [self->_bar radiusForSize:self->_pillRect.size];
        self->_bar.icon.alpha = self->_bar.field.alpha = self->_bar.mic.alpha = 0;
    } completion:^(BOOL f) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        self->_window.hidden = YES;
        self->_window.rootViewController = nil;
        self->_window = nil;
        [self->_prevKey makeKeyWindow];
        self->_prevKey = nil;
        gsPillSuppressed = NO; gsPill.hidden = NO;
        if (then) then();
    }];
}

- (void)launch:(NSDictionary *)d {
    // Buka dulu (tanpa menunggu animasi tutup), baru tutup overlay -> terasa instan
    NSString *bid = d[@"bid"];
    if (bid) {
        GSOpenApp(bid);
    } else {
        NSString *q = [d[@"q"] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        NSURL *u = [NSURL URLWithString:[@"https://www.google.com/search?q=" stringByAppendingString:q ?: @""]];
        if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    }
    [self dismissThen:nil];
}

#pragma mark Text field / table

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    if (_results.count) [self launch:_results.firstObject]; else [self dismissThen:nil];
    return NO;
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _results.count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.imageView.layer.cornerRadius = 9;
        cell.imageView.clipsToBounds = YES;
        cell.selectedBackgroundView = [UIView new];
        cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    }
    NSDictionary *d = _results[ip.row];
    cell.textLabel.text = d[@"name"];
    if (d[@"bid"]) { cell.imageView.image = GSIcon(d[@"bid"]); cell.imageView.tintColor = nil; }
    else { cell.imageView.image = [GSSymbol(@"magnifyingglass", 20) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]; cell.imageView.tintColor = UIColor.whiteColor; }
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:NO];
    [self launch:_results[ip.row]];
}
@end

#pragma mark - Pull-down (geser layar atas ke bawah) -> search baru

static void GSPresentFromNative(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[GSController shared] pillTapped]; });
}

@interface GSPull : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end
@implementation GSPull
+ (instancetype)shared {
    static GSPull *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [GSPull new]; });
    return s;
}
- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)g {
    if (gsPillSuppressed || !gsMaster) return NO;
    UIView *v = g.view;
    @try { if ([[v valueForKey:@"isEditing"] boolValue]) return NO; } @catch (id e) {}
    CGPoint vel = [g velocityInView:v];
    return vel.y > 0 && fabs(vel.y) > fabs(vel.x) * 1.2;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }
- (void)pan:(UIPanGestureRecognizer *)g {
    static BOOL fired;
    if (g.state == UIGestureRecognizerStateBegan) { fired = NO; return; }
    if (g.state == UIGestureRecognizerStateChanged && !fired) {
        CGPoint t = [g translationInView:g.view];
        if (t.y > 60 && t.y > fabs(t.x) * 1.5) { fired = YES; GSPresentFromNative(); }
    }
}
@end

static NSMutableString *gsLog;

// Matikan recognizer bawaan yang target-nya kelas Search/Spotlight (swipe-down lama)
static void GSDisableNativeSearch(UIView *v, int depth) {
    if (!v || depth > 3) return;
    for (UIGestureRecognizer *g in [v.gestureRecognizers copy]) {
        if (g.delegate == (id)[GSPull shared] || !g.enabled) continue;
        NSArray *targets = nil;
        @try { targets = [g valueForKey:@"_targets"]; } @catch (id e) {}
        for (id t in targets) {
            id tgt = nil;
            @try { tgt = [t valueForKey:@"_target"]; } @catch (id e) {}
            const char *nm = tgt ? object_getClassName(tgt) : "";
            if (strcasestr(nm, "search") || strcasestr(nm, "spotlight")) {
                g.enabled = NO;
                [gsLog appendFormat:@"disabled %s on %s\n", nm, object_getClassName(v)];
                break;
            }
        }
    }
    if (depth < 2) for (UIView *s in v.subviews) GSDisableNativeSearch(s, depth + 1);
}

static BOOL GSInRootFolder(UIView *v) {
    for (UIView *p = v.superview; p; p = p.superview) {
        const char *nm = object_getClassName(p);
        if (strstr(nm, "RootFolderView")) return YES;
        if (strstr(nm, "FloatyFolder") || strstr(nm, "FolderView")) return NO;
    }
    return NO;
}

#pragma mark - Hook: pill di atas dock

%hook SBRootFolderView
- (void)layoutSubviews {
    %orig;
    UIView *root = (UIView *)self;
    gsRoot = root;
    if (!gsPill) {
        gsLog = [NSMutableString string];
        GSLoadPrefs();
        GSReloadAppsAsync();
        gsDots = [NSMutableArray array];
        gsPill = [[GSGlassView alloc] initWithFrame:CGRectMake(0, 0, 92, 30)];
        gsPill.surface = @"Pill";
        gsPill.layer.cornerRadius = 15;

        gsPillInner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 92, 30)];
        UIImageView *ic = [[UIImageView alloc] initWithImage:GSSymbol(@"magnifyingglass", 11)];
        ic.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
        ic.frame = CGRectMake(14, 8, 14, 14);
        ic.contentMode = UIViewContentModeCenter;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(32, 0, 52, 30)];
        l.text = @"Search";
        l.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        l.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        [gsPillInner addSubview:ic];
        [gsPillInner addSubview:l];
        [gsPill.content addSubview:gsPillInner];

        gsDotsBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 7, 7)];
        gsDotsBox.userInteractionEnabled = NO;
        gsDotsBox.alpha = 0;
        [gsPill.content addSubview:gsDotsBox];

        [gsPill addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:[GSController shared] action:@selector(pillTapped)]];
        [GSMotion refresh];
    }
    if (gsPill.superview != root) [root addSubview:gsPill];

    // swipe-down baru
    static const void *kPullKey = &kPullKey;
    if (!objc_getAssociatedObject(root, kPullKey)) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[GSPull shared] action:@selector(pan:)];
        pan.delegate = [GSPull shared];
        pan.cancelsTouchesInView = NO;
        [root addGestureRecognizer:pan];
        objc_setAssociatedObject(root, kPullKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    GSDisableNativeSearch(root, 0);
    GSDisableNativeSearch(root.superview, 1);

    // pantau scroll halaman
    UIScrollView *sv = nil;
    @try { id x = [root valueForKey:@"scrollView"]; if ([x isKindOfClass:UIScrollView.class]) sv = x; } @catch (id e) {}
    if (!sv) for (UIView *s in root.subviews) if ([s isKindOfClass:UIScrollView.class]) { sv = (UIScrollView *)s; break; }
    [[GSScrollWatcher shared] watch:sv];

    UIView *dock = GSDockOf(root);
    GSLayoutPill();
    gsPill.hidden = gsPillSuppressed || !gsMaster || (dock && dock.hidden);
    [root bringSubviewToFront:gsPill];
}
%end

#pragma mark - Titik halaman bawaan: disembunyikan, diganti morph pill

%hook SBIconListPageControl
- (void)setAlpha:(CGFloat)a { %orig(GSInRootFolder((UIView *)self) ? 0 : a); }
- (void)setHidden:(BOOL)h { %orig(GSInRootFolder((UIView *)self) ? YES : h); }
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (GSInRootFolder(v)) { v.alpha = 0; v.hidden = YES; }
}
%end

#pragma mark - Swipe-down lewat file konfigurasi (cadangan, lihat README)

static void GSNoopV(id self, SEL _cmd) { GSPresentFromNative(); }
static BOOL GSNoopB(id self, SEL _cmd) { GSPresentFromNative(); return YES; }

// Baca /var/mobile/GlassSearch_hooks.txt: tiap baris "NamaKelas namaSelector"
static void GSInstallConfiguredHooks(void) {
    NSString *txt = [NSString stringWithContentsOfFile:@"/var/mobile/GlassSearch_hooks.txt" encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *ln = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!ln.length || [ln hasPrefix:@"#"]) continue;
        NSArray *p = [ln componentsSeparatedByString:@" "];
        if (p.count != 2) continue;
        Class c = NSClassFromString(p[0]);
        SEL s = NSSelectorFromString(p[1]);
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        if (!m) continue;
        char rt[8] = {0};
        method_getReturnType(m, rt, sizeof rt);
        IMP imp = rt[0] == 'v' ? (IMP)GSNoopV : (rt[0] == 'B' ? (IMP)GSNoopB : NULL);
        if (imp) class_replaceMethod(c, s, imp, method_getTypeEncoding(m));
    }
}

// Kalau file /var/mobile/GlassSearch_dump ada, tulis daftar kelas/metode Search & Spotlight
static void GSDumpIfRequested(void) {
    if (![NSFileManager.defaultManager fileExistsAtPath:@"/var/mobile/GlassSearch_dump"]) return;
    NSMutableString *out = [NSMutableString string];
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    for (unsigned i = 0; i < n; i++) {
        const char *nm = class_getName(list[i]);
        if (!(strncmp(nm, "SB", 2) == 0 || strncmp(nm, "SPUI", 4) == 0)) continue;
        if (!(strcasestr(nm, "search") || strcasestr(nm, "spotlight"))) continue;
        [out appendFormat:@"%s\n", nm];
        unsigned mc = 0;
        Method *ms = class_copyMethodList(list[i], &mc);
        for (unsigned j = 0; j < mc; j++)
            [out appendFormat:@"    %s\n", sel_getName(method_getName(ms[j]))];
        free(ms);
    }
    free(list);
    if (gsLog.length) [out appendFormat:@"\n== recognizer dimatikan ==\n%@", gsLog];
    [out writeToFile:@"/var/mobile/GlassSearch_classes.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void GSPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{
        GSLoadPrefs();
        [UIView animateWithDuration:0.2 animations:^{ GSLayoutPill(); }];
    });
}

%ctor {
    @autoreleasepool {
        GSLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, GSPrefsChanged,
            CFSTR("com.hasan.glasssearch/prefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        GSDumpIfRequested();
        GSInstallConfiguredHooks();
    }
}
