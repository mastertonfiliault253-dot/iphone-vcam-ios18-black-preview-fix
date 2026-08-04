# VCAM device testing over VNC

This project uses a locally built TrollVNC 3.2 server package for the iPhone SE 2 on iOS 16.5 with Dopamine/RootHide.

Security decisions:

- TrollVNC binds only to `127.0.0.1` on the iPhone.
- TCP 5901 and the bundled noVNC HTTP endpoint on 5801 are not exposed to the Wi-Fi LAN.
- The Windows host reaches noVNC through an SSH local-forward tunnel.
- The SSH key and host-key record are project-scoped under `dist/trollvnc/ssh/`.
- The VNC launch profile disables Bonjour and enables orientation-aware input.

One-time setup:

1. Run `dist/trollvnc/setup-and-install-trollvnc.cmd`.
2. Compare the displayed iPhone host fingerprint and type `YES` only if it matches.
3. Enter the iPhone root password once. The script installs a project SSH public key and the RootHide package.

Starting a test session:

1. Run `dist/trollvnc/start-vnc-tunnel.ps1`.
2. Serve the bundled noVNC files locally and open `vnc_lite.html` with `host=127.0.0.1`, `port=5901`, and an empty `path` query value.
3. Use the remote screen to open Camera and run VCAM tests.

The package is built from `OwnGoalStudio/TrollVNC` tag/version `3.2-272`, with the preferences UI omitted because the Linux RootHide toolchain cannot link its macOS compiler-runtime helper. The VNC server, capture, orientation, and HID input components are included.
