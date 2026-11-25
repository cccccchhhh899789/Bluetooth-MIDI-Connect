// main.m — 蓝牙 MIDI 连接助手 App（多选版 · 稳定版）
// 双击运行 → 弹出本机所有蓝牙 MIDI 设备（复选框多选，三态：在线/离线/未配对）
//          → 点「连接」→ 并行等待 → 弹结果框（按每台真实状态报）→ 点「好」退出
//
// 原理：给 CoreMIDI BLE null 设备设 "BLE MIDI Remote Peripheral" 属性，
//       AppleMIDIBluetoothDriver 消费后自己去连对应外设（本机已验证）。
//
// v0.2 三个修复：
//  A. 不再串行干等：多台设备并行等待，最多 30 秒，不会点完假死
//  B. 不再停在「正在读取」：单实例锁(flock)防多开抢 MIDIServer + 缓存先行 + 后台刷新
//  C. 三态状态：● 在线 / ○ 离线 / ✗ 未配对
//
// v0.3 关键修复（本次）：启动时创建一个「常驻 MIDIClient，全程不销毁」。
//  病根：CoreMIDI 的枚举(MIDIGetNumberOfDevices / 读属性)在 MIDIServer「冷启动」时
//  会被卡住数十秒（本机实测：不建 MIDIClient 直接枚举耗时 ~52279ms；先建 MIDIClient
//  再枚举仅 ~13ms，差约 4000 倍）。此前 App 从不创建 MIDIClient，于是每次读列表都卡在
//  「正在读取蓝牙 MIDI 设备…」。用户打开「音频MIDI设置」后之所以能显示，正是因为它创建
//  了 MIDIClient、唤醒了 MIDIServer。开源库同款结论：rtmidi #155 确认反复建/销 MIDIClient
//  会弄乱 MIDIServer 状态，保留一个不销毁的 MIDIClient 是标准做法。
//  做法：启动时 MIDIClientCreate 一次，常驻到进程退出（不重复创建、不中途销毁）。
//
// v0.4 可连接判断（置灰）：官方「音频MIDI设置」把设备置灰的依据，是驱动内部的
//   centralManufacturerOutstanding / centralModelOutstanding 标志——只有收到广播、
//   成功发现设备身份后，驱动才填入真实 manufacturer/model；收不到信号则留占位符
//   "Manufacturer Unavailable" / "Model Unavailable"（本机 dump-all-props 实测：
//   MidiPortA 两个占位符 → 官方置灰；MidiPortB = sincoaudio / ble device → 可连）。
//   故：manufacturer 与 model 都不是占位符 → 有广播信号、可达 → 可连接；否则置灰不可选。
#import <Cocoa/Cocoa.h>
#import <CoreMIDI/CoreMIDI.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

static int g_lockFD = -1;
static BOOL acquireSingleInstanceLock(void) {
    NSString *lockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"blemidi-connect.lock"];
    g_lockFD = open(lockPath.UTF8String, O_CREAT | O_RDWR, 0644);
    if (g_lockFD < 0) return NO;
    if (flock(g_lockFD, LOCK_EX | LOCK_NB) != 0) return NO;  // 已被另一实例锁住
    return YES;
}

static int iprop(MIDIObjectRef obj, CFStringRef prop) {
    int v = -1;
    if (MIDIObjectGetIntegerProperty(obj, prop, &v) == noErr) return v;
    return -1;
}
static NSString *sprop(MIDIObjectRef obj, CFStringRef prop) {
    CFStringRef v = NULL;
    if (MIDIObjectGetStringProperty(obj, prop, &v) == noErr && v) return (__bridge NSString *)v;
    return @"";
}
static MIDIDeviceRef findBLENullDevice(void) {
    int nDev = MIDIGetNumberOfDevices();
    for (int i = 0; i < nDev; i++) {
        MIDIDeviceRef d = MIDIGetDevice(i);
        if (iprop(d, CFSTR("is BLE MIDI null device")) == 1) return d;
    }
    return 0;
}
// 判断「指定 UUID」的那台 BLE 设备是否真的上线（不掺和别的设备）
static BOOL deviceOnlineByUUID(NSString *targetUUID) {
    int nDev = MIDIGetNumberOfDevices();
    for (int i = 0; i < nDev; i++) {
        MIDIDeviceRef d = MIDIGetDevice(i);
        if (iprop(d, CFSTR("is BLE MIDI null device")) == 1) continue;
        NSString *uuid = sprop(d, CFSTR("BLE MIDI Device UUID"));
        if (![uuid isEqualToString:targetUUID]) continue;
        if (iprop(d, kMIDIPropertyOffline) == 0) return YES;
        int nEnt = MIDIDeviceGetNumberOfEntities(d);
        for (int e = 0; e < nEnt; e++) {
            MIDIEntityRef ent = MIDIDeviceGetEntity(d, e);
            for (int s = 0; s < MIDIEntityGetNumberOfSources(ent); s++)
                if (iprop(MIDIEntityGetSource(ent, s), kMIDIPropertyOffline) == 0) return YES;
            for (int t = 0; t < MIDIEntityGetNumberOfDestinations(ent); t++)
                if (iprop(MIDIEntityGetDestination(ent, t), kMIDIPropertyOffline) == 0) return YES;
        }
    }
    return NO;
}

// v0.4：可连接判据（见文件头）。manufacturer 与 model 都不是占位符 → 有广播信号、可达。
static BOOL isConnectableDevice(NSString *manufacturer, NSString *model) {
    if (manufacturer.length > 0 && ![manufacturer isEqualToString:@"Manufacturer Unavailable"] &&
        model.length > 0 &&       ![model isEqualToString:@"Model Unavailable"]) {
        return YES;
    }
    return NO;
}

// 列出当前全部 BLE MIDI 设备（含 UUID、名字、offline、manufacturer/model、可连接）
// 注意：必须在后台线程调用（同一病根：主线程访问 CoreMIDI 会阻塞）
static NSArray<NSDictionary *> *listBLE(void) {
    NSMutableArray *arr = [NSMutableArray array];
    int nDev = MIDIGetNumberOfDevices();
    for (int i = 0; i < nDev; i++) {
        MIDIDeviceRef d = MIDIGetDevice(i);
        if (iprop(d, CFSTR("is BLE MIDI null device")) == 1) continue;
        NSString *driver = sprop(d, kMIDIPropertyDriverOwner);
        if (![driver containsString:@"Bluetooth"]) continue;
        NSString *uuid = sprop(d, CFSTR("BLE MIDI Device UUID"));
        if (!uuid.length) uuid = @"(无 UUID)";
        NSString *manufacturer = sprop(d, kMIDIPropertyManufacturer);
        NSString *model = sprop(d, kMIDIPropertyModel);
        [arr addObject:@{
            @"name": sprop(d, kMIDIPropertyName),
            @"uuid": uuid,
            @"offline": @(iprop(d, kMIDIPropertyOffline)),
            @"manufacturer": manufacturer,
            @"model": model,
            @"connectable": @(isConnectableDevice(manufacturer, model)),
        }];
    }
    return arr;
}
// 四态状态文案：在线 / 无信号不可连 / 未配对 / 离线可连
static NSString *stateText(NSDictionary *d) {
    if ([d[@"offline"] intValue] == 0) return @"● 在线";
    if (![d[@"connectable"] boolValue]) return @"✗ 无信号（不可连接）";
    if ([d[@"uuid"] hasPrefix:@"("])   return @"✗ 未配对";
    return @"○ 离线（可连接）";
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSWindow *_win;
    NSArray<NSDictionary *> *_devices;
    NSMutableArray<NSButton *> *_checks;
    NSButton *_connectBtn;
    NSButton *_quitBtn;
    NSButton *_refreshBtn;
    NSScrollView *_scroll;
    NSView *_listHost;
    NSTextField *_statusLabel;   // 列表区的状态文案
    MIDIClientRef _midiClient;    // v0.3：常驻 MIDIClient，唤醒/维持 MIDIServer（全程不销毁）
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSLog(@"[BLEMIDI] applicationDidFinishLaunching 开始");
    // 单实例锁：防止多开抢 MIDIServer（用户实测的多开卡死根源）
    if (!acquireSingleInstanceLock()) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"已有实例在运行";
        a.informativeText = @"蓝牙 MIDI 连接助手已在运行。请先退出那个实例，再打开新的。";
        [a runModal];
        [NSApp terminate:nil];
        return;
    }
    _checks = [NSMutableArray array];
    [self buildUI];
    // v0.3：创建常驻 MIDIClient —— 这是唤醒 MIDIServer 的关键动作。
    // 没有它，CoreMIDI 枚举会被 MIDIServer 卡住数十秒（实测 ~52s vs ~13ms）。
    // 只创建一次、常驻到进程退出，绝不中途销毁（反复建/销会弄乱 MIDIServer，见 rtmidi #155）。
    if (_midiClient == 0) {
        OSStatus st = MIDIClientCreate(CFSTR("蓝牙 MIDI 连接助手"), NULL, NULL, &_midiClient);
        NSLog(@"[BLEMIDI] MIDIClientCreate: OSStatus=%d client=%d", (int)st, (int)_midiClient);
    }
    // 缓存先行：先显示上次设备（不访问 CoreMIDI，秒开）
    NSArray *cached = [[NSUserDefaults standardUserDefaults] arrayForKey:@"lastDevicesV2"];
    if (cached.count > 0) {
        _devices = cached;
        [self fillDeviceList];
    }
    // 后台刷新真实列表（不阻塞 UI；若再失败，用户还可点「刷新」）
    [self refreshDevices];
}

- (void)refreshDevices {
    _statusLabel.stringValue = @"正在读取蓝牙 MIDI 设备…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *devs = listBLE();
        NSLog(@"[BLEMIDI] listBLE 完成, 找到 %lu 台", (unsigned long)devs.count);
        dispatch_async(dispatch_get_main_queue(), ^{
            // 只有真的读到了（哪怕 0 台明确知道没有），才替换缓存
            _devices = devs;
            [[NSUserDefaults standardUserDefaults] setObject:devs forKey:@"lastDevicesV2"];
            [self fillDeviceList];
        });
    });
}

- (void)buildUI {
    NSRect frame = NSMakeRect(0, 0, 560, 380);
    _win = [[NSWindow alloc] initWithContentRect:frame
                                       styleMask:(NSWindowStyleMaskTitled |
                                                  NSWindowStyleMaskClosable |
                                                  NSWindowStyleMaskMiniaturizable)
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    [_win setTitle:@"蓝牙 MIDI 连接助手（多选）"];
    [_win center];
    NSView *content = [_win contentView];

    NSTextField *label = [NSTextField labelWithString:@"勾选要连接的蓝牙 MIDI 设备（可多选）："];
    label.frame = NSMakeRect(20, 336, 520, 24);
    label.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    [content addSubview:label];

    // 列表区
    _listHost = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 240)];
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.frame = NSMakeRect(8, 200, 500, 24);
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    [_listHost addSubview:_statusLabel];
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 88, 520, 236)];
    [_scroll setDocumentView:_listHost];
    [_scroll setHasVerticalScroller:YES];
    [_scroll setAutohidesScrollers:YES];
    [_scroll setDrawsBackground:NO];
    [content addSubview:_scroll];

    _connectBtn = [NSButton buttonWithTitle:@"连接" target:self action:@selector(connectClicked:)];
    _connectBtn.frame = NSMakeRect(20, 28, 120, 32);
    _connectBtn.bezelStyle = NSBezelStyleRounded;
    _connectBtn.enabled = NO;
    [content addSubview:_connectBtn];

    _refreshBtn = [NSButton buttonWithTitle:@"刷新" target:self action:@selector(refreshClicked:)];
    _refreshBtn.frame = NSMakeRect(150, 28, 90, 32);
    _refreshBtn.bezelStyle = NSBezelStyleRounded;
    [content addSubview:_refreshBtn];

    _quitBtn = [NSButton buttonWithTitle:@"退出" target:self action:@selector(quitClicked:)];
    _quitBtn.frame = NSMakeRect(250, 28, 100, 32);
    _quitBtn.bezelStyle = NSBezelStyleRounded;
    [content addSubview:_quitBtn];

    [_win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshClicked:(id)sender { [self refreshDevices]; }

// 后台线程取回设备后填充列表（主线程调用）
- (void)fillDeviceList {
    // 清空旧复选框：否则刷新后 _checks 与 _devices 索引错位，勾选了却说没勾选
    [_checks removeAllObjects];
    for (NSView *v in _listHost.subviews) [v removeFromSuperview];
    if (_devices.count == 0) {
        _statusLabel.frame = NSMakeRect(8, 200, 520, 24);
        _statusLabel.stringValue = @"未发现蓝牙 MIDI 设备 — 先去「音频MIDI设置 → MIDI工作室 → 配置蓝牙」配对一次。";
        _statusLabel.font = [NSFont systemFontOfSize:13];
        [_listHost addSubview:_statusLabel];
        _connectBtn.enabled = NO;
        return;
    }
    // 状态行固定在顶部（y=0），设备行从 y=28 起，互不遮挡
    _statusLabel.frame = NSMakeRect(8, 0, 520, 22);
    _statusLabel.stringValue = [NSString stringWithFormat:@"共 %lu 台设备", (unsigned long)_devices.count];
    _statusLabel.font = [NSFont systemFontOfSize:12];
    [_listHost addSubview:_statusLabel];
    CGFloat y = 28;
    for (NSDictionary *d in _devices) {
        NSString *line = [NSString stringWithFormat:@"%@   (%@)   %@", d[@"name"], stateText(d), d[@"uuid"]];
        BOOL connectable = [d[@"connectable"] boolValue];
        NSButton *cb = [NSButton checkboxWithTitle:line target:nil action:nil];
        cb.frame = NSMakeRect(8, y, 520, 26);
        cb.font = [NSFont systemFontOfSize:13];
        cb.enabled = connectable;   // v0.4：无信号设备置灰不可选（与官方一致）
        if ([d[@"offline"] intValue] == 0) [cb setState:NSControlStateValueOn];  // 在线默认勾上
        [_listHost addSubview:cb];
        [_checks addObject:cb];
        y += 28;
    }
    NSRect hostRect = _listHost.frame;
    hostRect.size.height = MAX(y, 60);
    _listHost.frame = hostRect;
    _connectBtn.enabled = (_devices.count > 0);
    NSLog(@"[BLEMIDI] 列表填充完成 %lu 台", (unsigned long)_devices.count);
}

- (void)connectClicked:(id)sender {
    if (_devices.count == 0) return;
    // 收集勾选的设备
    NSMutableArray *selected = [NSMutableArray array];
    for (NSUInteger i = 0; i < _checks.count && i < _devices.count; i++) {
        if (_checks[i].state == NSControlStateValueOn) {
            [selected addObject:_devices[i]];
        }
    }
    if (selected.count == 0) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"没有勾选设备";
        a.informativeText = @"请先勾选要连接的设备。";
        [a runModal];
        return;
    }
    // 校验：勾选的设备必须有 UUID
    for (NSDictionary *d in selected) {
        if ([d[@"uuid"] hasPrefix:@"("]) {
            NSAlert *a = [NSAlert new];
            a.messageText = [NSString stringWithFormat:@"「%@」未配对", d[@"name"]];
            a.informativeText = @"请先在 音频MIDI设置 → MIDI工作室 → 配置蓝牙 里连一次，有了 UUID 才能脚本连接。";
            [a runModal];
            return;
        }
    }
    // 校验：勾选的设备必须可连接（有广播信号），否则会白等 30 秒超时
    for (NSDictionary *d in selected) {
        if (![d[@"connectable"] boolValue]) {
            NSAlert *a = [NSAlert new];
            a.messageText = [NSString stringWithFormat:@"「%@」当前不可连接", d[@"name"]];
            a.informativeText = @"该设备没有广播配对信号。请确认设备已开机、在蓝牙范围内，再点「刷新」重试。";
            [a runModal];
            return;
        }
    }
    // 不藏窗口！切成「正在连接」状态；所有 CoreMIDI 调用放后台线程（主线程调用会死锁，hang 报告实锤）
    for (NSView *v in _listHost.subviews) [v removeFromSuperview];
    _statusLabel.frame = NSMakeRect(8, 200, 520, 24);
    _statusLabel.stringValue = @"正在连接，请稍候…（最多 30 秒）";
    _statusLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
    _statusLabel.textColor = [NSColor labelColor];
    [_listHost addSubview:_statusLabel];
    _connectBtn.enabled = NO;
    _refreshBtn.enabled = NO;
    _quitBtn.enabled = NO;
    [_win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    NSArray *selectedCopy = [selected copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MIDIDeviceRef nullDev = findBLENullDevice();
        if (!nullDev) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *a = [NSAlert new];
                a.messageText = @"找不到蓝牙 MIDI 驱动";
                [a runModal];
                [NSApp terminate:nil];
            });
            return;
        }
        // 1) 全部先发连接请求（后台）
        NSMutableArray *reqFailNames = [NSMutableArray array];
        NSMutableArray *pending = [NSMutableArray array];
        for (NSDictionary *d in selectedCopy) {
            NSString *devUUID = d[@"uuid"];
            NSString *devName = d[@"name"];
            NSDictionary *periph = @{ @"BLE MIDI Device UUID": devUUID, @"name": devName };
            OSStatus st = MIDIObjectSetDictionaryProperty(nullDev,
                                                          CFSTR("BLE MIDI Remote Peripheral"),
                                                          (__bridge CFDictionaryRef)periph);
            if (st != noErr) { [reqFailNames addObject:devName]; }
            else { [pending addObject:d]; }
        }
        // 2) 并行轮询：所有 pending 设备同时等，最多 30 秒（0.5s 一次）
        NSMutableArray *okNames = [NSMutableArray array];
        for (int i = 0; i < 60 && pending.count > 0; i++) {
            usleep(500000);
            NSMutableArray *still = [NSMutableArray array];
            for (NSDictionary *d in pending) {
                if (deviceOnlineByUUID(d[@"uuid"])) [okNames addObject:d[@"name"]];
                else [still addObject:d];
            }
            pending = still;
        }
        // 3) 剩下的没上线 = 超时
        NSMutableArray *timeoutNames = [NSMutableArray array];
        for (NSDictionary *d in pending) [timeoutNames addObject:d[@"name"]];

        // 4) 回主线程弹结果（只报真实状态）
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [NSAlert new];
            NSMutableArray *lines = [NSMutableArray array];
            if (okNames.count > 0)
                [lines addObject:[NSString stringWithFormat:@"✅ 已连接：%@", [okNames componentsJoinedByString:@"、"]]];
            if (timeoutNames.count > 0)
                [lines addObject:[NSString stringWithFormat:@"⏳ 未上线：%@（请确认设备已开机且在蓝牙范围）", [timeoutNames componentsJoinedByString:@"、"]]];
            if (reqFailNames.count > 0)
                [lines addObject:[NSString stringWithFormat:@"❌ 请求失败：%@", [reqFailNames componentsJoinedByString:@"、"]]];
            if (lines.count == 0) { lines = [NSMutableArray arrayWithObject:@"没有任何设备被勾选。"]; }
            a.messageText = (okNames.count > 0) ? @"连接完成" : @"连接未成功";
            a.informativeText = [lines componentsJoinedByString:@"\n"];
            [a addButtonWithTitle:@"好"];
            [a runModal];
            [NSApp terminate:nil];
        });
    });
}

- (void)quitClicked:(id)sender { [NSApp terminate:nil]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}