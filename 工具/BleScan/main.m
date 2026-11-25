// BleScan/main.m — 阳性对照扫描器（bundle 版，声明 NSBluetoothAlwaysUsage）
// 目的：验证「带蓝牙权限的 bundle」用 CoreBluetooth 被动扫描能否真正发现广播外设，
//       作为 ble-scan-midi.m（无 bundle CLI）的对照，判断 CLI 的「0 个」是扫描失效还是真无广播。
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
    NSLog(@"[BLESCAN] state=%d", (int)central.state);
    if (central.state == CBCentralManagerStatePoweredOn) dispatch_semaphore_signal(g_powered);
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
            serviceData:(NSDictionary<CBUUID *, NSData *> *)serviceData
                    RSSI:(NSNumber *)RSSI {
    NSString *key = peripheral.identifier.UUIDString;
    NSMutableDictionary *rec = nil;
    for (NSDictionary *r in g_found) if ([r[@"id"] isEqualToString:key]) { rec = [r mutableCopy]; break; }
    if (!rec) {
        rec = [NSMutableDictionary dictionary];
        rec[@"id"] = key;
        rec[@"name"] = peripheral.name ?: @"(无名称)";
        rec[@"rssi"] = RSSI;
        NSMutableArray *sd = [NSMutableArray array];
        for (CBUUID *u in serviceData.allKeys) [sd addObject:[NSString stringWithFormat:@"%@", u]];
        rec[@"serviceUUIDs"] = sd;
        rec[@"serviceData"] = serviceData;
        [g_found addObject:rec];
        NSLog(@"[BLESCAN] 发现 id=%@ name=%@ rssi=%@", key, rec[@"name"], RSSI);
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
        double sec = (argc > 1) ? atof(argv[1]) : 10.0;
        NSLog(@"[BLESCAN] bundle 扫描，时长 %.0f 秒", sec);
        g_found = [NSMutableArray array];
        g_powered = dispatch_semaphore_create(0);
        g_q = dispatch_queue_create("blescan", DISPATCH_QUEUE_SERIAL);
        Scanner *scanner = [[Scanner alloc] init];
        g_mgr = [[CBCentralManager alloc] initWithDelegate:scanner queue:g_q options:nil];

        dispatch_time_t to = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
        BOOL powered = (dispatch_semaphore_wait(g_powered, to) == 0);
        if (!powered) { NSLog(@"[BLESCAN] 蓝牙未就绪"); }
        else {
            dispatch_async(g_q, ^{ [g_mgr scanForPeripheralsWithServices:nil options:nil]; });
            usleep((useconds_t)(sec * 1e6));
            dispatch_async(g_q, ^{ [g_mgr stopScan]; });
            usleep(200000);
        }
        printf("\n===== bundle 扫描结果（%lu 个）=====\n", (unsigned long)g_found.count);
        for (NSDictionary *r in g_found) {
            printf("外设: %s\n  id=%s\n  rssi=%s\n  服务UUID=%s\n",
                   [r[@"name"] UTF8String], [r[@"id"] UTF8String],
                   [[r[@"rssi"] stringValue] UTF8String],
                   [[r[@"serviceUUIDs"] componentsJoinedByString:@", "] UTF8String]);
            NSDictionary *sd = r[@"serviceData"];
            for (CBUUID *u in sd.allKeys) {
                NSString *line = [NSString stringWithFormat:@"  [数据] %@ = %@\n", u, hex(sd[u])];
                fputs([line UTF8String], stdout);
            }
        }
        if (!g_found.count) printf("（未发现任何 BLE 广播外设）\n");
        return 0;
    }
}
