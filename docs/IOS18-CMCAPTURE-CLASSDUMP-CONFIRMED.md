# iOS 18.3.1 CMCapture 类 dump 确认：BWNodeOutput 仍在

日期：2026-08-17
分支：codex/ios18-adapt
设备：iPhone 11 Pro Max（A13 / iPhone12,5），iOS 18.3.1（Build 22D72）

## 结论（已坐实，非推测）

**`BWNodeOutput` 在 iOS 18.3.1 的 `CMCapture.framework` 里确认存在，类名、hook 方法签名均与 iOS 16 一致。**

`IOS18-CAMERA-CAPTURE-SURVEY.md` 里"BWNodeOutput 在 iOS 18 全部消失"的结论**错误，予以推翻**。该结论的证据（`grep BWNode cameracaptured/applecamerad = 0`）是量错了对象：`cameracaptured`/`applecamerad` 是薄启动守护进程，真正的 `BWNode*` 类实现在 `CMCapture.framework`（dyld 共享缓存）里。

---

## 复现方法（真机抽取 + ipsw 类 dump）

1. 缓存位置：`/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/`
   - 拆分缓存：主文件 + 66 个子缓存 + `.symbols`，目录 3.8GB。
2. SFTP 全量拉取到本地：`D:\work\ios18-dyld-cache\`（共 4.73GB / 68 文件）。
3. 工具：`ipsw` v3.1.709（blacktop，跨平台 Go 二进制）。
   - `ipsw dyld info` → 3799 镜像、66 子缓存、iOS 18.3。
   - `ipsw dyld str <DSC> "BWNodeOutput"` → 直接命中 CMCapture 镜像。
   - `ipsw class-dump <DSC> CMCapture --class "^BWNodeOutput$"` → 完整类定义。

---

## 关键证据

### 1. 字符串命中（`ipsw dyld str`）

```text
"BWNodeOutput"                        image=CMCapture
"BWNodeOutputConsumer"                image=CMCapture
"Owning BWNodeOutput must not be nil" image=CMCapture
"Output primary format has no requirements BWNodeOutput %p node: %@"  image=CMCapture
-[BWNodeOutput emitSampleBuffer:]
-[BWNodeOutput setConsumer:]
-[BWNodeOutput initWithMediaType:node:]
-[BWNodeOutput makeConfiguredFormatLive]
```

### 2. `BWNodeOutput` 完整类 dump（iOS 18.3.1 CMCapture）

```objc
@interface BWNodeOutput : NSObject <FigCaptureOSStateDataProvider> {
    NSString *_name;
    id <BWNodeOutputConsumer> _consumer;
    _Bool _consumerIsANodeConnection;
    _Bool _mediaTypeIsVideo;
    _Bool _mediaTypeIsPointCloud;
    unsigned int _mediaType;
    long long _configurationID;
    BWNode *_node;
    float _maxSampleDataOutputRate;
    _Bool _dropsSampleBuffersWithUnexpectedPTS;
    long long _liveConfigurationID;
    _Bool _discardsSampleData;
    unsigned int _numberOfBuffersEmitted;
    unsigned int _numberOfBuffersDropped;
    /* ... */
    BWNodeOutputMediaConfiguration *_primaryMediaConfiguration;
    BWNodeOutputMediaConfiguration *_unspecifiedAttachedMediaConfiguration;
    NSMutableDictionary *_attachedMediaConfigurations;
    BWNodeOutputMediaProperties *_primaryMediaProperties;
    NSMutableDictionary *_attachedMediaProperties;
    BWMemoryPool *_memoryPool;
}
/* 关键实例方法（与 iOS 16 vcam hook 完全对应） */
- (void)emitSampleBuffer:(struct opaqueCMSampleBuffer *)buffer;
- (void)makeConfiguredFormatLive;
- (void)prepareForConfiguredFormatToBecomeLive;
- (void)setConsumer:(id)consumer;
- (id)consumer;
- (id)node;
- (unsigned int)mediaType;
- (id)format;
- (id)liveFormat;
- (id)videoFormat;
- (void)markEndOfLiveOutput;
- (void)invalidate;
@end
```

vcam iOS16 的 hook 方法签名：

```objc
%hook BWNodeOutput
- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer { ... }
%end
```

**方法选择器 `emitSampleBuffer:` 与参数类型（`CMSampleBufferRef` == `struct opaqueCMSampleBuffer *`）完全一致，无需改签名。**

### 3. BW 类总量与关键类

`CMCapture` 里共 **586 个 `BW*` 类**，整条 BWNode 图完整保留：

- `BWNode` / `BWNodeInput` / `BWNodeOutput` / `BWNodeConnection` / `BWNodeEnumerator`
- `BWNodeMessage` / `BWNodeError` / `BWNodeInputMediaConfiguration` / `BWNodeOutputMediaConfiguration` / `BWNodeOutputMediaProperties`
- `BWMultiStreamCameraSourceNode`（相机源节点）
- `BWImageQueueSinkNode`（输出 sink）
- `BWAudioSourceNode` / `BWMetadataSourceNode` / `BWPreviewSinkNode` 等

### 4. 加载 CMCapture 的进程（`ipsw dyld imports`）

```text
/usr/libexec/cameracaptured
/usr/libexec/applecamerad
/usr/sbin/applecamerad
```

`mediaserverd` 不出现在导入列表里（iOS 18 该进程已不存在）。

---

## 对适配的影响

| 维度 | iOS 16（当前） | iOS 18（已确认） |
| --- | --- | --- |
| 注入目标进程 | `mediaserverd` | `cameracaptured`（+ 可能 `applecamerad`） |
| 帧输出 hook 类 | `BWNodeOutput` | `BWNodeOutput`（同名，仍在 CMCapture） |
| hook 方法 | `emitSampleBuffer:` | `emitSampleBuffer:`（签名不变） |
| 采集框架 | FigCapture / BWNode | `CMCapture.framework`（类名前缀仍 `BW*`） |

**结论：这不是"重写整条替换链"，而是"换注入进程 + 换 dylib filter + 保留 `%hook BWNodeOutput / emitSampleBuffer:`"的适配。**

需要改动的核心点（非框架重写）：

1. 注入 dylib 的进程目标/filter：`mediaserverd` → `cameracaptured`（`applecamerad` 视验证结果决定是否也注入）。
2. `vcaminjectd` 的进程匹配规则同步更新。
3. 确认 `BWNodeOutput` 所在的 CMCapture 在 `cameracaptured` 内可被 `%hook` 解析（类存在，但还需真机验证 hook 是否命中 + 连续出帧）。

---

## 本地产物清单

| 产物 | 路径 |
| --- | --- |
| 全量 dyld 缓存 | `D:\work\ios18-dyld-cache\`（68 文件，4.73GB） |
| 抽取的 CMCapture 二进制 | `D:\work\ios18-extracted\CMCapture`（14.8MB） |
| BW 类名清单（586 个） | `D:\work\ios18-bw-classes.txt` |
| BWNodeOutput 头文件 | `D:\work\ios18-cmcapture-headers\BWNodeOutput.h` |
| BWNode 头文件 | `D:\work\ios18-cmcapture-headers\BWNode.h` |
| 镜像列表 | `D:\work\ios18-images.txt` |
| ipsw 工具 | `D:\work\ipsw\ipsw.exe`（v3.1.709） |

---

## 待办（真机验证，非源码层）

- [ ] 把注入目标从 `mediaserverd` 换成 `cameracaptured`，真机验证 `%hook BWNodeOutput` 是否命中。
- [ ] 验证 `emitSampleBuffer:` 连续非空 `CVPixelBuffer` 出帧（复用 iOS16 的替换逻辑）。
- [ ] 决定是否同时注入 `applecamerad`。
