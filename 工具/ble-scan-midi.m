// ble-scan-midi.m — BLE MIDI 广播可达性探针（只读、不连接）
// 目的：确认「设备当前是否在广播配对信号」，并观察广播包里的 UUID / 服务数据，
//       据此判定官方软件「置灰 vs 可连接」的判据，为 App 的置灰逻辑提供实证。
// 原理：CBCentralManager 被动扫描，didDiscoverPeripheral 的 serviceData 是解码后的
//       广播 AD 结构（键=服务 UUID，值=该服务的数据）。BLE MIDI 广播含
//       Complete List of 128-bit Service Class UUIDs（AD 0x03）。
// 用法：./ble-scan-midi [扫描秒数，默认 8]
// 注意：CBCentralManager 回调跑在自建串行队列上，不依赖主运行循环（CLI 友好）。
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <dispatch/dispatch.h>

static CBCentralManager *g_mgr = nil;
static dispatch_queue_t g_q = nil;
static dispatch_semaphore_t g_powered = nil;
static NSMutableArray *g_found = nil;

@interface Scanner : NSObject <CBCentralManagerDelegate>
@end

@implementation Scanner
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSLog(@"[BLESCAN] centralManagerDidUpdateState state=%d", (int)central.state);
    if (central.state == CBCentralManagerStatePoweredOn) {
        dispatch_semaphore_signal(g_powered);
    }
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
            serviceData:(NSDictionary<CBUUID *, NSData *> *)serviceData
                    RSSI:(NSNumber *)RSSI {
    NSString *key = peripheral.identifier.UUIDString;
    NSMutableDictionary *rec = nil;
    for (NSDictionary *r in g_found) {
        if ([r[@"id"] isEqualToString:key]) { rec = [r mutableCopy]; break; }
    }
    if (!rec) {
        rec = [NSMutableDictionary dictionary];
        rec[@"id"] = key;
        rec[@"name"] = peripheral.name ?: @"(无名称)";
        rec[@"state"] = @(peripheral.state);
        rec[@"rssi_last"] = RSSI;
        NSMutableArray *sd = [NSMutableArray array];
        for (CBUUID *u in serviceData.allKeys) [sd addObject:[NSString stringWithFormat:@"%@", u]];
        rec[@"serviceUUIDs"] = sd;
        rec[@"serviceData"] = serviceData;
        [g_found addObject:rec];
        NSLog(@"[BLESCAN] 新发现 id=%@ name=%@ rssi=%@", key, rec[@"name"], RSSI);
    } else {
        NSNumber *prev = rec[@"rssi_last"];
        if (!prev || [RSSI intValue] > prev.intValue) rec[@"rssi_last"] = RSSI;
    }
    NSLog(@"[BLESCAN] 广播服务键=%@", serviceData.allKeys);
}
@end

static NSString *hex(NSData *d) {
    if (!d) return @"";
    const unsigned char *b = d.bytes;
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < d.length; i++) [s appendFormat:@"%02X", b[i]];
    return s;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        double sec = (argc > 1) ? atof(argv[1]) : 8.0;
        NSLog(@"[BLESCAN] 开始扫描，时长 %.0f 秒", sec);

        g_found = [NSMutableArray array];
        g_powered = dispatch_semaphore_create(0);
        g_q = dispatch_queue_create("blescan", DISPATCH_QUEUE_SERIAL);

        Scanner *scanner = [[Scanner alloc] init];
        g_mgr = [[CBCentralManager alloc] initWithDelegate:scanner queue:g_q options:nil];

        // 等蓝牙就绪（最多 5 秒）：didResetState 里发信号
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
        BOOL powered = (dispatch_semaphore_wait(g_powered, timeout) == 0);
        if (!powered) {
            NSLog(@"[BLESCAN] 蓝牙未就绪（5 秒内未到 PoweredOn），检查蓝牙是否开启");
        } else {
            dispatch_async(g_q, ^{
                [g_mgr scanForPeripheralsWithServices:nil options:nil];
                NSLog(@"[BLESCAN] 已开始被动扫描");
            });
            usleep((useconds_t)(sec * 1e6));   // 扫描期间串行队列自由处理回调
            dispatch_async(g_q, ^{ [g_mgr stopScan]; });
            usleep(200000);
            NSLog(@"[BLESCAN] 扫描结束，发现 %lu 个外设", (unsigned long)g_found.count);
        }

        printf("\n===== 扫描结果汇总（%lu 个外设）=====\n", (unsigned long)g_found.count);
        for (NSDictionary *r in g_found) {
            printf("外设: %s\n", [r[@"name"] UTF8String]);
            printf("  id        = %s\n", [r[@"id"] UTF8String]);
            printf("  地址状态 = %s (0=待发现 2=已连接)\n", [[r[@"state"] stringValue] UTF8String]);
            printf("  RSSI      = %s dBm\n", [[r[@"rssi_last"] stringValue] UTF8String]);
            printf("  服务UUID  = %s\n", [[r[@"serviceUUIDs"] componentsJoinedByString:@", "] UTF8String]);
            NSDictionary *sd = r[@"serviceData"];
            for (CBUUID *u in sd.allKeys) {
                NSString *line = [NSString stringWithFormat:@"  [服务数据] %@ = %@\n", u, hex(sd[u])];
                fputs([line UTF8String], stdout);
            }
            printf("\n");
        }
        if (g_found.count == 0) {
            printf("（未发现任何 BLE 广播外设）\n");
        }
        return 0;
    }
}
