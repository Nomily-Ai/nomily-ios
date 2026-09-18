# Running the Nomily iOS app locally

Nomily iOS is a native SwiftUI app; Xcode builds and runs it.

## Requirements

- macOS
- Xcode 15 or later
- An iPhone running iOS 16.0 or later
- [Homebrew](https://brew.sh/)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple ID

> Use a physical device. The simulator shows part of the UI but cannot scan for
> or connect to a D·NOTE device over BLE.

## 1. Install XcodeGen

If you do not have it yet:

```bash
brew install xcodegen
```

## 2. Generate and open the Xcode project

From the repository root:

```bash
xcodegen generate
open nomily_ios.xcodeproj
```

`xcodegen generate` builds `nomily_ios.xcodeproj` from `project.yml`. Run it
again whenever you change `project.yml`.

## 3. Set up code signing

With the project open in Xcode:

1. Select the `nomily_ios` project in the navigator on the left.
2. Select the `nomily_ios` target.
3. Open **Signing & Capabilities**.
4. Tick **Automatically manage signing**.
5. Under **Team**, choose the development team behind your Apple ID.
6. If the default bundle identifier is taken, replace `com.nomily.app` with one
   of your own:

   ```text
   com.yourname.nomily
   ```

If Xcode is not signed in to an Apple ID yet, add one here:

```text
Xcode → Settings → Accounts → +
```

## 4. Prepare the iPhone

1. Connect the iPhone to the Mac over USB.
2. Trust the Mac when the iPhone asks.
3. Enable Developer Mode on the iPhone if prompted:

   ```text
   Settings → Privacy & Security → Developer Mode
   ```

4. Back in Xcode, pick that iPhone as the run destination.
5. Press **⌘R**, or click the run button at the top left.

The first install may ask you to confirm Developer Mode or restart the device.

## 5. Grant permissions

Allow these when the app first asks for them:

- Bluetooth
- Local network (needed for local ASR)
- Joining Wi-Fi networks (needed for Fast Transfer)

Inside the app you can then scan for and connect to a nearby recorder.

## Troubleshooting

### `xcodegen: command not found`

Install XcodeGen, then regenerate the project:

```bash
brew install xcodegen
xcodegen generate
```

### `Signing requires a development team`

Open **Signing & Capabilities** in Xcode and choose your team under **Team**.

### Provisioning profile or Hotspot Configuration errors

The project uses the Hotspot Configuration and App Group capabilities. Hotspot
Configuration requires a paid Apple Developer account; a free Apple ID may not
be able to issue a valid provisioning profile for the full feature set.

To run only the basics, remove the capability you cannot sign. Wi-Fi Fast
Transfer and anything built on it stop working.

### The simulator finds no Bluetooth devices

Expected. BLE scanning and device connection require a physical device.

### `.opus` files do not play on iOS 16

Playback relies on the system's Ogg-Opus support. iOS 17 and later play these
natively; `.opus` playback on iOS 16 is not fully wired up yet.

## Shortest path

```bash
xcodegen generate
open nomily_ios.xcodeproj
```

Then set Team in Xcode, select a physical iPhone, and press **⌘R**.
