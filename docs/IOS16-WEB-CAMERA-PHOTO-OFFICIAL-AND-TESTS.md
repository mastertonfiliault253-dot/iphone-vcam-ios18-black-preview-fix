# iOS 16–16.5 网页相机拍照：官方说明与开源测试页

核验日期：2026-08-11

部署目标：iOS 16.0–16.5

范围：`getUserMedia()` + Canvas、Image Capture API、`<input type="file" capture>`

## 结论

1. iOS 16–16.5 的网页实时相机基线应使用 `navigator.mediaDevices.getUserMedia()`；网页取得的是浏览器按约束协商后的 `MediaStreamTrack`，并不保证等于摄像头传感器的最大或固定分辨率。
2. 网页拍照最兼容的实时方案是把 `<video>` 当前帧绘制到 Canvas。Canvas 的**位图尺寸**必须在每次拍照时跟随 `video.videoWidth` / `video.videoHeight`，不能使用 CSS 尺寸 `clientWidth` / `clientHeight`，也不能永远沿用第一次的尺寸。
3. `ImageCapture.takePhoto()` / `grabFrame()` 不能作为 iOS 16–16.5 方案。WebKit 官方明确说明 Image Capture API 是 Safari 18.4 才加入。
4. `<input type="file" accept="image/*" capture>` 在 iOS Safari 中受官方支持，但它属于文件选择/系统拍摄流程，不等同于网页持续运行的 WebRTC + Canvas 管线。`capture="user"` 和 `capture="environment"` 只是期望朝向，浏览器允许回退。
5. WebKit 官方缺陷库记录了 iOS 16.5 在相同 `1280×720 ideal` 约束下连续两次 `getUserMedia()` 得到不同方向/裁剪结果的问题。它足以说明 iOS 16.5 上必须记录每次调用的实际 settings，并在重新开流前停止旧轨道。

## 官方规范和 Apple/WebKit 说明

### 1. `getUserMedia()`、分辨率和方向

[W3C Media Capture and Streams](https://www.w3.org/TR/mediacapture-streams/) 规定：

- `getUserMedia()` 是 Secure Context API；正式测试页应使用 HTTPS。
- `width`、`height`、`aspectRatio`、`frameRate`、`facingMode` 和 `resizeMode` 都是轨道约束。
- `ideal` 是偏好；`min`、`max`、`exact` 才参与必需约束判断。无法满足 `exact` 时应拒绝请求，而不是保证返回该尺寸。
- 同一个相机源可以连接多个轨道；浏览器允许为不同轨道做降采样，并且每条轨道的 `getSettings()` 可能不同。
- 浏览器允许用裁剪和缩放满足轨道约束；发生横竖屏轴交换时，`getSettings()` 返回的宽高应匹配当前输出方向。

[WebKit: A Closer Look Into WebRTC](https://webkit.org/blog/7763/a-closer-look-into-webrtc/) 说明 Safari 11 / iOS 11 已支持 WebRTC 相机采集；首次 `getUserMedia()` 会请求相机权限，返回的设备由约束决定，前后摄像头切换应由网页提供明确 UI。

[Apple iPhone 用户指南：Safari 隐私设置](https://support.apple.com/guide/iphone/browse-the-web-privately-iphb01fc3c85/ios) 说明 Safari 的 Camera 设置可设为 Ask、Deny 或 Allow，并可按网站设置例外。测试失败时应先确认该网站没有被设为 Deny。

若目标是应用内 `WKWebView` 而非 Safari，[Apple WWDC21: Explore WKWebView additions](https://developer.apple.com/videos/play/wwdc2021/10032/?time=815) 说明 `getUserMedia()` 从 iOS 14.3 起可在 WKWebView 中使用；宿主应用还可通过 [`WKUIDelegate` 媒体权限回调](https://developer.apple.com/documentation/webkit/wkuidelegate/webview%28_%3Arequestmediacapturepermissionfor%3Ainitiatedbyframe%3Atype%3Adecisionhandler%3A%29) 决定网站是否能访问摄像头和麦克风。

### 2. Canvas 拍照

[WHATWG HTML Standard：Canvas](https://html.spec.whatwg.org/multipage/canvas.html) 区分：

- `canvas.width` / `canvas.height` 控制 Canvas 位图的像素尺寸；CSS 只控制显示尺寸。
- `drawImage(video, ...)` 使用视频当前帧，源尺寸是视频资源的自然宽高。
- 指定目标宽高的 `drawImage()` 会把源矩形缩放到目标矩形。

因此，若视频从 `1280×720` 重协商成 `720×1280` 或 `640×480`，而网页仍把帧画进旧 Canvas，浏览器会按旧目标矩形缩放，直接产生拉伸或额外模糊。可靠写法是：

```js
function takeSnapshot(video, canvas) {
  if (!video.videoWidth || !video.videoHeight) {
    throw new Error("video metadata/frame is not ready");
  }
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  canvas.getContext("2d").drawImage(
    video,
    0,
    0,
    canvas.width,
    canvas.height
  );
}
```

这只能保存**视频轨道当前分辨率**的帧，不会获得原生相机静态照片的传感器分辨率。

### 3. Image Capture API

[W3C MediaStream Image Capture](https://www.w3.org/TR/image-capture/) 定义了 `new ImageCapture(track)`、`grabFrame()`、`takePhoto()` 和照片能力/设置接口；规范存在不等于浏览器已经实现。

[WebKit Features in Safari 18.4](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/) 的官方原文是“WebKit for Safari 18.4 adds support for Image Capture API”。因此：

- iOS 16.0–16.5：不要把 `ImageCapture` 作为正式或回退路径。
- 在目标机上应预期 `typeof ImageCapture === "undefined"`，或构造/调用不可用。
- Image Capture 开源页面仍有价值，但只能用于确认“不支持”的版本边界。

### 4. `<input capture>`

[W3C HTML Media Capture](https://www.w3.org/TR/html-media-capture/) 规定 `capture` 扩展的是文件上传控件：

```html
<input type="file" accept="image/*" capture="user">
<input type="file" accept="image/*" capture="environment">
```

- `user` / `environment` 表示期望的前置/后置方向。
- 浏览器无法满足时可以使用实现默认值。
- 规范用的是“SHOULD invoke”，不是必须保证直接打开指定摄像头。
- 网页最终得到一个 `FileList`，不是持续的 `MediaStreamTrack`。

[WebKit: New Web Features in Safari 10.1](https://webkit.org/blog/7477/new-web-features-in-safari-10-1/) 明确确认 iOS Safari 支持通过 file input 拍摄图片、视频或音频。

## iOS 16.5 官方已知问题

[WebKit Bug 258312](https://bugs.webkit.org/show_bug.cgi?id=258312) 针对 Safari 16 / iOS 16，报告环境为 iPhone XS + iOS 16.5：

- 连续两次使用相同的 `width: { ideal: 1280 }`、`height: { ideal: 720 }`；
- 第一次可能返回竖屏轨道并忽略横屏偏好；
- 未停止第一条流时，第二条轨道可能被裁剪以满足约束；
- 截至本次核验，WebKit 状态仍为 `NEW`，严重程度为 Major。

缺陷单中的代码明确提供了“停止/不停止第一条流”两种路径。它是问题证据，但不等于已确认 VCAM 的拉伸一定由该缺陷造成。

缺陷单原来的 Replit 在线复现已不可用：源码页当前返回 404，旧 `repl.co` 站点 TLS 连接失败。因此不要把它列为现场验收链接；需要时应根据缺陷单中的短代码在自有 HTTPS 页面重建。

## 已核验的开源在线测试页

下列 live URL 与源码仓库在 2026-08-11 均已核验为 HTTPS，且返回 HTTP 200。WebRTC Canvas 和分辨率页随后已在 iOS 16.5 真机完成授权、取帧与保存验证；GoogleChrome Image Capture 页面仅完成页面内容核验。两个 WPT 页面已取得 HTTP 200 并读取原始 HTML，尚未完成真机交互。HTTP 200 只证明服务可达，不能替代摄像头、方向和保存结果验收。

| 用途 | HTTPS 在线测试 | 开源源码 | 本次链接核验 | iOS 16–16.5 预期与限制 |
|---|---|---|---|---|
| 实时视频 + Canvas 截图 | [WebRTC samples: getUserMedia to canvas](https://webrtc.github.io/samples/src/content/getusermedia/canvas/) | [webrtc/samples canvas](https://github.com/webrtc/samples/tree/gh-pages/src/content/getusermedia/canvas) | 页面内容已获取；HTTP 200 | 首选基线。源码每次点击都会把 Canvas 改为 `video.videoWidth × video.videoHeight`，适合与问题网页对比。只取得视频帧，不是原生静态照片。 |
| 不同分辨率约束 | [WebRTC samples: select resolution](https://webrtc.github.io/samples/src/content/getusermedia/resolution/) | [webrtc/samples resolution](https://github.com/webrtc/samples/tree/gh-pages/src/content/getusermedia/resolution) | 页面内容已获取；HTTP 200 | 可依次请求 320×240、640×480、1280×720、1920×1080 等 `exact` 尺寸，并显示实际 `videoWidth × videoHeight`。源码在切换前停止旧流；不支持的 exact 尺寸应报错。 |
| 后置相机文件拍照 | [WPT: capture environment image](https://wpt.live/html-media-capture/capture_image_environment-manual.html) | [WPT html-media-capture](https://github.com/web-platform-tests/wpt/tree/master/html-media-capture) | HTTP 200 + 原始源码；未可视化打开 | 使用 `accept="image/*" capture="environment"`。人工拍照后验证得到一个 `image/*` 文件；系统仍允许回退摄像头。60 秒内完成。 |
| 前置相机文件拍照 | [WPT: capture user image](https://wpt.live/html-media-capture/capture_image_user-manual.html) | [WPT html-media-capture](https://github.com/web-platform-tests/wpt/tree/master/html-media-capture) | HTTP 200 + 原始源码；未可视化打开 | 使用 `accept="image/*" capture="user"`。用途和限制同上。 |
| Image Capture API | [GoogleChrome sample: grabFrame / takePhoto](https://googlechrome.github.io/samples/image-capture/grab-frame-take-photo.html) | [GoogleChrome/samples image-capture](https://github.com/googlechrome/samples/tree/gh-pages/image-capture) | 页面内容已获取；HTTP 200 | 页面可打开，但 iOS 16–16.5 应不支持 `ImageCapture`。用于验证版本边界，不用于 VCAM 正式验收。页面本身标注面向 Chrome。 |

## iOS 16.5 真机分辨率与清晰度 A/B

测试机为 iOS 16.5。输入使用同一张 `2160×3840` JPEG 测试图，网页保存均为无损 PNG：

| 网页请求 | Safari 实际视频/Canvas | 保存文件 | 结果 |
|---|---:|---:|---|
| Canvas 示例默认约束 | `480×640` | `480×640` PNG，22,390 bytes | 清晰度上限已在协商阶段降到 VGA 级；保存格式不是首因。 |
| Resolution 示例 Full HD exact | `1080×1920` | `1080×1920` PNG，75,259 bytes | 硬边梯度与同尺寸 Lanczos 参考接近；没有发现额外的强模糊。 |

mediaserverd 同期证据与网页结果一致：默认页面的 RemoteQueue 为 `640×480 420f`，Full HD 页面为 `1920×1080 420f`。VCAM 把真实相机图保留为协商外壳，只替换网页已经协商出的目标缓冲区像素；它不会伪造能力表或把任意会话强制成固定分辨率，也不能在 `640×480` 缓冲区内保留 1080p 细节。WebKit 终端保留目标格式、时间戳和附件，对竖向规范源只做已验证的横向存储补偿，再按真实相机的 full-bleed 行为居中裁剪并填满；源与目标比例不同时会裁掉边缘，但不会拉伸或添加 VCAM 黑边。

后续多宿主验收推翻了“仅按目标宽高判断宿主并补偿方向”的假设。当前方案把 ImageIO/视频轨元数据解析收敛到生产端，发布统一的视觉方向；`mediaserverd` 不对 Camera、录像或 still 路径猜旋转，只在已明确识别且经过真机 A/B 的 WebKit 横向存储终端，把规范竖向像素转换成该真实相机图所需的存储基准。目标宽高只校验这一已识别终端的存储形状，不能单独触发补偿。still 路径不覆盖系统最终照片元数据；VCAM 只替换未压缩像素，保存文件的横竖方向由系统相机决定。

## 方案评分

| 方案 | 分数 | 结论 |
|---|---:|---|
| 业务网页显式请求 Full HD，并在每次拍照时令 Canvas 位图等于 `videoWidth×videoHeight` | 96/100 | 已由同源真机 A/B 验证；效果最好、零 VCAM 运行成本，但必须由网页采用。 |
| VCAM 按源方向和源尺寸发布：图片单 IOSurface、视频三 IOSurface，再按消费者目标一次适配 | 94/100 | 当前正式方案；避免 12MP 图片先降为 2MP，也避免各宿主重复猜方向。 |
| VCAM 保持 1080×1920 共享画布并按消费者原生目标一次适配 | 78/100 | 结构简单，但会让高分辨率图片先降采样，并放大到 Camera/网页目标。 |
| VCAM 强行把任意 WebKit 会话改成 1080p | 55/100 | 私有相机图协商，容易破坏不支持 1080p 的页面、前后摄切换和功耗预算。 |
| 全链路固定升级为 4K | 38/100 | 对 `640×480` 网页仍无收益，却显著增加内存带宽和发热。 |
| 对低分辨率结果锐化或 AI 放大 | 18/100 | 不能恢复未采集细节，并会制造光晕、延迟和额外发热。 |

因此，VCAM 侧选择动态源尺寸 + 真实相机协商外壳：不伪造网页协商分辨率，也不增加锐化滤镜；生产端只解析一次源方向，WebKit 消费者按真实相机行为在网页给定目标尺寸内做一次居中裁剪并填满。源与目标比例不同时，完整画面与无黑边不可同时满足；正式策略选择不拉伸、无黑边，并明确接受边缘裁剪。目标缓冲区尺寸、格式和时序保持不变，因此不会再发生第二次 VCAM 缩放。业务网页仍应按下面的最小标准写法请求并核验实际分辨率：

```js
video.srcObject?.getTracks().forEach(track => track.stop());
const stream = await navigator.mediaDevices.getUserMedia({
  video: {
    width: { exact: 1920 },
    height: { exact: 1080 },
    frameRate: { ideal: 30, max: 30 }
  }
});
video.srcObject = stream;
await new Promise(resolve => video.addEventListener("loadedmetadata", resolve, { once: true }));
await video.play();

const shortEdge = Math.min(video.videoWidth, video.videoHeight);
const longEdge = Math.max(video.videoWidth, video.videoHeight);
if (shortEdge < 1080 || longEdge < 1920) {
  stream.getTracks().forEach(track => track.stop());
  throw new Error(`Full HD unavailable: ${video.videoWidth}x${video.videoHeight}`);
}

// 每次拍照都重新读取协商后的自然尺寸。
canvas.width = video.videoWidth;
canvas.height = video.videoHeight;
canvas.getContext("2d").drawImage(video, 0, 0, canvas.width, canvas.height);
const snapshot = await new Promise(resolve => canvas.toBlob(resolve, "image/png"));
console.log(stream.getVideoTracks()[0].getSettings(), snapshot);
```

`exact` 在设备或并发会话无法满足时会拒绝请求；业务页应把失败明确显示给用户，而不是静默退到低分辨率继续拍照。即使浏览器返回成功，仍应读取 `getSettings()` 和 `videoWidth×videoHeight` 作为清晰度门槛。

## 相册与文件重复选择 A/B

iOS 16.5 真机分别完成了图片、视频的连续两次选择：

- Photos 图片和 Files 图片均生成不同 UUID 路径，扩展名保持 `.jpeg`、`.png`、`.jpg`；导入文件与原件 SHA-256 一致。
- Photos 两段视频均保持 `.mov`，与 DCIM 原件 SHA-256 一致；编码、`1920×1440` 存储尺寸及 `rotation=-90` 等原始方向元数据未被改写。
- Files 两段 `170.9 MB`、`300.5 MB` MP4 均保持 `.mp4` 并生成不同 UUID 路径。
- 第二段 Photos 视频间隔 1 秒的预览区域有 `47.3%` 像素变化；第二段 Files 视频间隔 4 秒的 Camera 画面有 `71.77%` 像素变化，均证明切换后仍在播放。
- broker 只保留当前文件和最近前一文件；既避免 AVFoundation 复用旧稳定路径，又限制磁盘增长。

这里的“保留原始格式和分辨率”首先指**导入资产 fidelity**：broker 文件没有转码、改扩展名或重写容器/方向元数据。播放时仍会解码为未压缩像素，但正式 IOSurface 使用解码后的源方向和源尺寸：静态图片一个 BGRA 槽，视频三个 NV12 槽。最终网页或 Camera 仍受其协商出的目标缓冲区尺寸限制。

后续设备隔离还确认：第二次导入和生产端均继续出帧，但控制面板预览只读取兼容 mmap；当 `mediaserverd` 接管 IOSurface 后，mmap 合法地停在 bootstrap 首帧，表现成“第二次选择后不播放”。最高分修复是让预览被动比较 mmap/IOSurface 时间戳并读取较新的帧，同时不声明主消费者心跳；它不会抢占 `mediaserverd` 的 surface 租约，也不会恢复每帧 BGRA 镜像复制。

| 重复选择方案 | 分数 | 结论 |
|---|---:|---|
| `PHPicker` current representation / Files 原文件 → broker UUID 路径 → 原生 `AVPlayer` | 98/100 | 已真机验证原字节、原扩展名、方向元数据与连续播放；当前正式方案。 |
| 同上，并让控制面板被动预览最新 mmap/IOSurface | 97/100 | 修正只停在 bootstrap 首帧的 UI 假冻结；零转码、无额外每帧 BGRA 镜像，已完成代码与 WSL 双架构编译验证。 |
| 固定 `selected.mov` / `selected.jpg` 覆盖 | 42/100 | 代码最少，但会让已有播放器、映射或缓存继续引用旧 inode/旧资源。 |
| 每次统一转成 H.264 MP4 / JPEG | 31/100 | 能统一格式，却损失原始编码、方向、色彩和图片质量，并增加等待与发热。 |
| 全文件常驻内存后播放 | 14/100 | 大视频内存代价不可接受，也不解决资源身份与播放器切换问题。 |

选择第一项。它复用系统选择器和 AVFoundation，只增加文件身份所需的 UUID；不新增播放器框架、转码器或缓存层。

## 拍照保存方向方案评分

| 方案 | 分数 | 结论 |
|---|---:|---|
| still 像素不旋转、不覆盖系统照片元数据 | 96/100 | 完全服从系统相机当次拍摄方向，避免横持时被 VCAM 二次旋转；已选择，待真机复验。 |
| VCAM 根据设备姿态再旋转 still 像素 | 48/100 | 与系统相机自己的方向处理重复，存在二次旋转和姿态竞态。 |
| 左转 still 像素并强写 `Orientation=Right` | 20/100 | 0.8.58 真机验收失败，会覆盖用户实际横持姿态；已撤销。 |
| 只旋转像素，不写方向附件 | 48/100 | 与系统相机的最终方向决策叠加后结果不可控，仍可能得到横向或二次旋转的照片。 |
| 拍照后再编辑 Photos 资产 | 12/100 | 越过系统相机保存边界、需要额外权限和编码，且不解决网页实时截图。 |

选择第一项；同时所有实时宿主统一消费生产端发布的视觉方向，不再保留 WebKit/预览专用反射补偿。

## 推荐真机测试顺序

1. 使用 Safari 打开 Canvas 基线页，允许相机，连续拍 10 次；确认预览和每张 Canvas 都不改变宽高比。
2. 打开分辨率页，依次测试 VGA、720p、1080p；记录成功尺寸和错误。不要把 `exact` 请求失败误判成 VCAM 没有输出。
3. 在控制台或问题网页中，每次拍照前记录：

   ```js
   const track = video.srcObject?.getVideoTracks()[0];
   console.table({
     video: `${video.videoWidth}x${video.videoHeight}`,
     settings: JSON.stringify(track?.getSettings()),
     constraints: JSON.stringify(track?.getConstraints()),
     canvasBitmap: `${canvas.width}x${canvas.height}`,
     canvasCSS: `${canvas.clientWidth}x${canvas.clientHeight}`
   });
   ```

4. 若页面会重复调用 `getUserMedia()`，先执行：

   ```js
   video.srcObject?.getTracks().forEach(track => track.stop());
   ```

   再建立新流，并等待 `loadedmetadata` 或 `resize` 后才允许拍照。
5. 分别运行 WPT 的 `environment` 和 `user` 页面，确认系统相机流程、方向和返回图片类型。该结果不要与 WebRTC + Canvas 结果混为一条管线。
6. 最后打开 Image Capture 页面，确认 iOS 16–16.5 上 API 不可用；若页面意外可用，应记录 Safari/WebKit 的实际版本，而不是只记录 iOS 设置页显示值。

## 对 VCAM 排查的判定标准

- WebRTC Canvas 基线页连续正常，但业务网页拉伸：优先检查业务网页的 Canvas 位图尺寸、旧轨道未停止和重复开流逻辑。
- Canvas 基线页的**预览本身**也发生宽高比变化：同时抓取 `getSettings()` 与 mediaserverd 输出签名，检查 WebKit 轨道重协商和 VCAM 目标适配。
- WebRTC Canvas 正常，WPT `<input capture>` 异常：说明系统文件拍照/静态照片路径与实时 WebRTC 路径存在差异，不能只修 Canvas。
- 所有网页都只在 1080p 以上结果模糊、但比例正确：优先判断共享源实际细节不足和放大，不应归为 Canvas 拉伸。
- Image Capture 页面失败：在 iOS 16–16.5 属于预期结果，不是 VCAM 回归。
