# QR Scanner (iOS 6.0 – 10.x)

A small native Objective‑C QR code scanner.

- **iOS 7–10:** uses Apple's built-in detector (`AVCaptureMetadataOutput`).
- **iOS 6:** that API doesn't exist yet, so camera frames are decoded with the bundled
  [quirc](https://github.com/dlbeer/quirc) library (ISC license, see `quirc/LICENSE`).
- **Scan from Photos:** works on every version, using quirc.
- **Results:** shows the decoded text with *Open* (links, phone, email, SMS), *Copy* and *Scan Again*.
- **Other:** flashlight toggle on devices that have a torch; iPhone and iPad; portrait only.
- **Binary:** fat `armv7` (iOS 6+) + `arm64` (iOS 7+) Mach‑O, built against the iOS 10.3 SDK.

## Installing

The IPA is ad-hoc ("fake") signed, so how you install it depends on the device:

- **Jailbroken device with AppSync Unified:** install directly (Filza, `appinst`, etc.).
- **Stock device:** re-sign it with your own Apple ID or certificate using a sideloading tool
  (for example Sideloadly or ESign), or with `codesign` and a provisioning profile on a Mac.
  Change the bundle ID if the tool asks.

## Building

`build.sh` needs an ld64/cctools-based iOS toolchain (clang, ld, lipo, strip, ldid) and an
iPhoneOS SDK that includes armv7 stubs, e.g. iPhoneOS10.3.sdk. Set `TOOLCHAIN` and `SDK`, then run:

```sh
pip install pillow && python3 make_assets.py assets   # icons + launch images
TOOLCHAIN=/path/to/toolchain/bin SDK=/path/to/iPhoneOS10.3.sdk ./build.sh
```

Note: the SDK folder must be named like `iPhoneOS10.3.sdk` because clang reads the SDK version
from the folder name. Without it, iOS 7+ shows the app in legacy iOS 6 style.
