# Bluetooth-MIDI-Connect

让 macOS 的蓝牙 MIDI 设备一键连接，替代去「音频MIDI设置 → MIDI 工作室 → 配置蓝牙」手动点 Connect；
另附一个扫描 / 清理「MIDI 与蓝牙占用」的小工具。

## 为什么需要它

macOS 只对「支持配对（pairing）」的 BLE MIDI 设备自动重连；不支持配对的无线 MIDI 设备每次开机都灰着，
得手动去音频MIDI设置点 Connect。本项目把「点 Connect」自动化：给 CoreMIDI 的蓝牙驱动下一个连接请求即可，
连完进程退出，不影响已建立的连接。

## 原理

CoreMIDI 内建一个 `is BLE MIDI null device` = 1 的隐藏设备（由 `AppleMIDIBluetoothDriver` 持有）。
给它设置私有属性：

```
BLE MIDI Remote Peripheral = { "BLE MIDI Device UUID": …, "name": … }
```

驱动消费该属性后自己去连对应外设（本机 2026-11-26 实测：属性被消费 = 请求已送达驱动，设备随后上线）。

> ⚠️ `name` 会改显示名，务必传设备原本的名字，**不要传 UUID**（传 UUID 会把设备显示名改成一串 UUID）。

## 目录

- `App/` — 原生 Cocoa App（源码 + 代码生成图标 + 构建脚本）
- `工具/` — 命令行工具（ObjC + shell：扫描 / 连接 / 属性转储 / 占用清理）
- `说明.md` — 简短入口（完整内容见本 README）

## App

双击 `App/build/蓝牙MIDI连接.app` → 弹出本机所有蓝牙 MIDI 设备（勾选可多台）→ 点「连接」→ 全部连上、弹通知。

- 支持多选：勾几台连几台
- 列表动态：新增蓝牙 MIDI 设备会自动出现
- **单实例锁**：防多开抢 MIDIServer（多开是「一直正在读取、卡死」的根因）
- **可连接判断 / 置灰**：按驱动内部 `centralManufacturerOutstanding` 判据——收到广播、成功发现身份
  （真实 manufacturer / model）的设备才可勾选；收不到广播、显示 `Manufacturer / Model Unavailable` 的
  设备置灰，与官方「音频MIDI设置」行为一致。

## 命令行工具

```
./工具/bluetooth-midi.sh list                          # 列出所有 BLE MIDI 设备 + UUID + 状态
./工具/bluetooth-midi.sh connect <uuid> [名字] [--watch 秒]   # 连接单台并等待上线
./工具/bluetooth-midi.sh status                         # 查看状态
```

## 占用清理

各 App 占用 MIDI / 蓝牙导致连不上时，用 `工具/cleanup-midi-bt.sh` 排查并清理：

```
./工具/cleanup-midi-bt.sh scan                       # 只读扫描：MIDIServer / 占用进程 / 蓝牙授权 / 已连设备 / 驱动
./工具/cleanup-midi-bt.sh clean                      # 预览将执行的动作（dry-run，不动手）
./工具/cleanup-midi-bt.sh clean --apply --all       # 真正执行
./工具/cleanup-midi-bt.sh clean --apply --midiserver # 只重启 MIDIServer
```

- **默认 dry-run**，必须显式 `--apply` 才动；脚本不删除任何文件
- MIDIServer 在「没有 App 在用 MIDI」时退出最安全，launchd 会自动重启；
  **运行中退出会静默切断**正在用 MIDI 的 App（连接变哑，且无报错）
- CoreMIDI **没有**「谁持有 MIDIClient」的枚举 API，占用情况靠**进程 + 蓝牙授权（TCC）** 间接判断，脚本会如实标注

## 构建与自检

```
cd App && bash build.sh        # 编译 → App/build/蓝牙MIDI连接.app（universal2）
cd App && bash verify.sh       # 自检 10 项
```

> 设备必须先在这台 Mac 上用「音频MIDI设置 → 配置蓝牙」连接过一次（有 UUID），脚本 / App 才能连上它；
> 没有 UUID 的需先手动配对一次。
