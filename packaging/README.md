# RootHide package target map

`targets.json` is the machine-checked map from process injection requirements to
one RootHide package containing two binaries. This keeps one install/update entry
while preventing the Camera control UI from loading into background processes.

| Target | Package | Current state |
| --- | --- | --- |
| `VCAMController` | `com.codex.vcam` / `VCAM.dylib` | Camera UI and Camera hooks; enabled by default |
| `VCAMAppClient` | `com.codex.vcam` / `VCAMProcessClient.dylib` | Safari and Chrome; selectable, default off |
| `VCAMWebKitClient` | `com.codex.vcam` / `VCAMProcessClient.dylib` | WebContent capture hooks; selectable, default off |
| `VCAMMediaServerClient` | `com.codex.vcam` / `VCAMProcessClient.dylib` | mediaserverd capture hooks; selectable, default off |

Only `com.codex.vcam` is emitted. `VCAM.dylib` owns the control UI;
`VCAMProcessClient.dylib` contains the capture pipeline without UIKit or PhotosUI.
The process client currently decodes the selected source inside each enabled
process. This makes the selection functional without a second package, at the
cost of one decoder per enabled process.

"Global injection" is an alias for the explicit Camera, Safari, Chrome, WebKit,
and mediaserverd targets; it never removes the plist allowlist. mediaserverd is
default-off and labelled high-risk because a failure can trigger Dopamine's
watchdog protection. Target changes require the target process to be relaunched.
