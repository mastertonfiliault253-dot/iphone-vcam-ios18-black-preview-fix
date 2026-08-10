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

下列 live URL 与源码仓库在 2026-08-11 均已核验为 HTTPS，且返回 HTTP 200。核验分为两档：WebRTC Canvas、分辨率和 GoogleChrome Image Capture 页面已实际获取并解析页面内容；两个 WPT 页面因本次浏览器读取器限制未进行可视化打开，但已分别取得 HTTP 200，并读取了对应的 WPT 原始 HTML 源码。尚未在 iOS 真机点击相机权限或完成拍照。HTTP 200 只证明服务可达，不能替代摄像头、方向和保存结果验收。

| 用途 | HTTPS 在线测试 | 开源源码 | 本次链接核验 | iOS 16–16.5 预期与限制 |
|---|---|---|---|---|
| 实时视频 + Canvas 截图 | [WebRTC samples: getUserMedia to canvas](https://webrtc.github.io/samples/src/content/getusermedia/canvas/) | [webrtc/samples canvas](https://github.com/webrtc/samples/tree/gh-pages/src/content/getusermedia/canvas) | 页面内容已获取；HTTP 200 | 首选基线。源码每次点击都会把 Canvas 改为 `video.videoWidth × video.videoHeight`，适合与问题网页对比。只取得视频帧，不是原生静态照片。 |
| 不同分辨率约束 | [WebRTC samples: select resolution](https://webrtc.github.io/samples/src/content/getusermedia/resolution/) | [webrtc/samples resolution](https://github.com/webrtc/samples/tree/gh-pages/src/content/getusermedia/resolution) | 页面内容已获取；HTTP 200 | 可依次请求 320×240、640×480、1280×720、1920×1080 等 `exact` 尺寸，并显示实际 `videoWidth × videoHeight`。源码在切换前停止旧流；不支持的 exact 尺寸应报错。 |
| 后置相机文件拍照 | [WPT: capture environment image](https://wpt.live/html-media-capture/capture_image_environment-manual.html) | [WPT html-media-capture](https://github.com/web-platform-tests/wpt/tree/master/html-media-capture) | HTTP 200 + 原始源码；未可视化打开 | 使用 `accept="image/*" capture="environment"`。人工拍照后验证得到一个 `image/*` 文件；系统仍允许回退摄像头。60 秒内完成。 |
| 前置相机文件拍照 | [WPT: capture user image](https://wpt.live/html-media-capture/capture_image_user-manual.html) | [WPT html-media-capture](https://github.com/web-platform-tests/wpt/tree/master/html-media-capture) | HTTP 200 + 原始源码；未可视化打开 | 使用 `accept="image/*" capture="user"`。用途和限制同上。 |
| Image Capture API | [GoogleChrome sample: grabFrame / takePhoto](https://googlechrome.github.io/samples/image-capture/grab-frame-take-photo.html) | [GoogleChrome/samples image-capture](https://github.com/googlechrome/samples/tree/gh-pages/image-capture) | 页面内容已获取；HTTP 200 | 页面可打开，但 iOS 16–16.5 应不支持 `ImageCapture`。用于验证版本边界，不用于 VCAM 正式验收。页面本身标注面向 Chrome。 |

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
   oldStream?.getTracks().forEach(track => track.stop());
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
