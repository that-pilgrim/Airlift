[README.md](https://github.com/user-attachments/files/34342974/README.md)
# Airlift

Share your Android phone's mobile data with other devices, even when the phone has no built-in hotspot/tethering feature.

Airlift is a Cordova app with a small native Android plugin. It starts a local-only Wi-Fi hotspot and runs a proxy that sends all traffic out over your **mobile data**.

> **Status:** This is a hobby project. It has not been tested on every phone, Android version or OS. Please open an issue if something breaks.

## How it works

```
 Laptop / phone  ──Wi-Fi──►  Airlift phone (local-only hotspot)
                                   │  HTTP + SOCKS5 proxy
                                   ▼
                              Mobile data ──► Internet
```

1. Airlift starts Android's local-only hotspot (`startLocalOnlyHotspot`, Android 8+). Devices can join, but it has no internet by itself.
2. Airlift runs a proxy on ports **8080** and **1080**. Each port auto-detects HTTP or SOCKS5.
3. Connections and DNS lookups are forced over the phone's cellular network.
4. You point the other device's apps (or whole system) at the proxy.

### What it can and can't do

| Works | Doesn't work |
|---|---|
| Browsing (HTTP/HTTPS) | Ping (ICMP) |
| Any TCP port via SOCKS5: email (IMAP/SMTP), SSH, FTP, git | UDP: voice/video calls, most games, QUIC |
| Package managers and downloads: pacman, npm, pip, curl, docker, ollama (see below) | Apps with no proxy support (unless you use a VPN-to-SOCKS app on the client) |
| Running with the screen locked (see options below) | Real system-level tethering or transparent routing (needs root or system permissions) |

Some carriers throttle or block traffic they detect as tethering. Airlift can't get around that.

## Requirements

**On the phone running Airlift**
- Android 8.0 (API 26) or newer
- Mobile data enabled
- Location permission (Android requires it for hotspots). On Android 13+, also Nearby devices and notifications

**To build it**
- Node.js (LTS)
- JDK 17
- Android SDK (easiest via Android Studio)
- Git, only if you're cloning

## Get the source

```
git clone https://github.com/YOUR-USERNAME/airlift.git
cd airlift
```

Or click **Code → Download ZIP** on GitHub, unzip it, and open a terminal in the unzipped folder (for example `airlift-main`).

## Build setup

Pick your operating system. Do this once.

### Windows (PowerShell)

```powershell
winget install OpenJS.NodeJS.LTS
winget install EclipseAdoptium.Temurin.17.JDK
winget install Google.AndroidStudio
```

Open Android Studio once, then go to **More Actions → SDK Manager** and install:
- an **SDK Platform** (the API level `cordova requirements` asks for, see below)
- **Android SDK Build-Tools**
- **Android SDK Platform-Tools**
- **Android SDK Command-line Tools (latest)**

Set environment variables (then open a **new** terminal):

```powershell
setx ANDROID_HOME "$env:LOCALAPPDATA\Android\Sdk"
setx JAVA_HOME "C:\Program Files\Eclipse Adoptium\jdk-17.x.x.x-hotspot"
```

Adjust the JDK path to your installed folder. Then add these to your **PATH** through *Start → "Edit the system environment variables" → Environment Variables* (`setx` can truncate long PATH values):
- `%ANDROID_HOME%\platform-tools`
- `%ANDROID_HOME%\cmdline-tools\latest\bin`

### macOS (Terminal)

```bash
brew install node openjdk@17
brew install --cask android-studio
```

Open Android Studio once and install the same SDK pieces listed above using **Settings → Languages & Frameworks → Android SDK**. Then add to `~/.zshrc`:

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin
```

If `java_home` doesn't find JDK 17, Homebrew's Java may need linking:
```bash
sudo ln -sfn $(brew --prefix openjdk@17)/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-17.jdk
```

Then run `source ~/.zshrc`.

### Linux

Install Node.js and JDK 17 with your package manager:

```bash
# Debian / Ubuntu
sudo apt install nodejs npm openjdk-17-jdk unzip

# Fedora
sudo dnf install nodejs npm java-17-openjdk-devel

# Arch
sudo pacman -S nodejs npm jdk17-openjdk
```

For the Android SDK, either install Android Studio, or do a command-line-only install:

```bash
mkdir -p ~/Android/Sdk/cmdline-tools
# Download "Command line tools only" for Linux from https://developer.android.com/studio#command-line-tools-only
unzip commandlinetools-linux-*.zip -d ~/Android/Sdk/cmdline-tools
mv ~/Android/Sdk/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest
```

Add to `~/.bashrc` or `~/.zshrc`:

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk   # path differs per distro
export ANDROID_HOME=$HOME/Android/Sdk
export PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin
```

Then install SDK pieces and accept licenses (use the versions `cordova requirements` asks for; 34 is an example):

```bash
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"
sdkmanager --licenses
```

### Check your setup (all systems)

Run from the project folder:

```
npx cordova requirements android
```

It lists what's missing, including the exact Android API level and build-tools version your Cordova version needs. Install those in the SDK Manager if they're missing. If it complains about Gradle, install it (`brew install gradle`, `sudo apt install gradle`, `winget install Gradle.Gradle`, or via SDKMAN).

## Build the APK

From the project folder (same commands on every OS):

```
npx cordova platform add android
npx cordova build android
```

The debug APK ends up here:

```
platforms/android/app/build/outputs/apk/debug/app-debug.apk
```

A debug APK is already signed with Android's debug key and installs fine on your own phone. See [Signing a release build](#signing-a-release-build) if you want a release version.

## Install on the phone

**With USB (adb)**

1. On the phone: *Settings → About phone*, tap **Build number** 7 times, then enable **USB debugging** under *Developer options*.
2. Connect the phone and accept the prompt.
3. Run:
   ```
   adb devices
   adb install -r platforms/android/app/build/outputs/apk/debug/app-debug.apk
   ```

**Without a cable**

Copy the APK to the phone (cloud drive, messaging, USB file transfer), open it, and allow installs from unknown sources when asked.

## Using the app

1. Open **Airlift** and choose your options (below).
2. Tap **Start sharing** and grant the permissions.
3. The app shows a **Wi-Fi name**, **password**, one or more **IP addresses**, and the **HTTP** and **SOCKS5** ports.
4. On the other device, join that Wi-Fi.
5. Set that device's proxy to one of the listed IPs (try the next one if the first doesn't work).
6. Tap **Stop sharing** when you're done.

### Options

| Option | What it does |
|---|---|
| **Keep running in background** | Runs a foreground service with a notification so Android doesn't kill Airlift when you leave the app. On by default. |
| **Stay awake when screen is locked** | Holds a CPU wake lock and Wi-Fi lock so transfers don't stall when the screen turns off. Uses more battery. Also enables the background option. |
| **Exempt from battery optimization** | Opens Android's prompt to let Airlift ignore battery restrictions. |

Options apply the next time you tap **Start sharing**. Keep the phone plugged in for big downloads. On some phones (Xiaomi, Huawei, Oppo, Samsung and others) you also need to set the app's battery mode to "Unrestricted" in the phone's own settings. See [dontkillmyapp.com](https://dontkillmyapp.com).

If you swipe the app away, sharing keeps running. Reopen the app and tap **Stop sharing** to end it.

## Setting the proxy on the other device

Replace `192.168.43.1` with the IP shown in the app. HTTP port is `8080`, SOCKS5 port is `1080`. The app also shows ready-to-copy versions of these at the bottom of its screen.

### Linux

```bash
export http_proxy=http://192.168.43.1:8080
export https_proxy=http://192.168.43.1:8080
export no_proxy=localhost,127.0.0.1

sudo -E pacman -Syu        # -E keeps the variables under sudo

unset http_proxy https_proxy no_proxy    # undo
```

### macOS

```bash
# Terminal, this session only
export http_proxy=http://192.168.43.1:8080
export https_proxy=http://192.168.43.1:8080

# System-wide
networksetup -setwebproxy "Wi-Fi" 192.168.43.1 8080
networksetup -setsecurewebproxy "Wi-Fi" 192.168.43.1 8080
networksetup -setsocksfirewallproxy "Wi-Fi" 192.168.43.1 1080

# Undo system-wide
networksetup -setwebproxystate "Wi-Fi" off
networksetup -setsecurewebproxystate "Wi-Fi" off
networksetup -setsocksfirewallproxystate "Wi-Fi" off
```

### Windows

```powershell
# PowerShell, this window only
$env:http_proxy = "http://192.168.43.1:8080"
$env:https_proxy = "http://192.168.43.1:8080"

# Undo
Remove-Item Env:http_proxy, Env:https_proxy

# System-wide for Windows tools (Admin)
netsh winhttp set proxy 192.168.43.1:8080
netsh winhttp reset proxy
```

Browsers and many apps also have a proxy setting under *Settings → Network & Internet → Proxy*.

### Phones and tablets

Wi-Fi settings → the network → **Proxy → Manual**, then enter the IP and the HTTP port. This covers browsers and apps that respect the system proxy.

## Tool-specific tips

| Tool | How |
|---|---|
| **curl** | `curl -x http://IP:8080 URL` or `curl --socks5-hostname IP:1080 URL` |
| **pacman** | `sudo env http_proxy=http://IP:8080 https_proxy=http://IP:8080 pacman -Syu`. Or set `XferCommand = /usr/bin/curl --socks5-hostname IP:1080 -L -C - -f -o %o %u` in `/etc/pacman.conf`. |
| **npm** | `npm config set proxy http://IP:8080` and `npm config set https-proxy http://IP:8080` |
| **pip** | `pip install --proxy http://IP:8080 package` |
| **git** | `git config --global http.proxy http://IP:8080` |
| **Docker** | The *daemon* pulls images, so shell variables don't help. Set `HTTP_PROXY`/`HTTPS_PROXY` in a systemd drop-in for `docker.service`, then restart it. Containers need their own proxy settings in `~/.docker/config.json`. |
| **Ollama** | The *server* downloads models, so set `HTTPS_PROXY=http://IP:8080` on the server process (`systemctl edit ollama`, or `HTTPS_PROXY=... ollama serve`) and restart it. Set only `HTTPS_PROXY`. |
| **Email** | Use a client with a SOCKS5 setting (for example Thunderbird): SOCKS5, host IP, port 1080. |
| **Apps with no proxy option** | Run a VPN-to-SOCKS app such as a tun2socks-based tool on that device, pointed at `IP:1080`. |

For command-line tools, the key idea is: **the proxy must be set on the process that actually does the download**. Settings in your shell don't reach a background service started elsewhere.

## Troubleshooting

**Ping fails.** Expected. Ping uses ICMP, and Airlift only relays TCP. Test with curl instead:

```
ping -c 3 192.168.43.1                                  # reaches the phone itself
curl -x http://192.168.43.1:8080 -I https://example.com        # HTTP proxy test
curl --socks5-hostname 192.168.43.1:1080 -I https://example.com  # SOCKS5 test
```

**`503` from the proxy.** The app can't find a mobile data connection. Check that mobile data is on and has signal.

**Connection refused or times out.** Try the other IP addresses shown in the app. Make sure the app still shows "Stop sharing" and wasn't killed (see the options above). Disconnect the phone from other Wi-Fi networks, because some phones can't run a local-only hotspot and a Wi-Fi connection at once.

**"Temporary failure in name resolution" from a tool.** The tool is resolving names itself instead of using the proxy. Check that the proxy variable is set on the process that downloads (and that `sudo` hasn't stripped it), and that the value includes `http://`.

**Hotspot fails to start.** Turn on **Location** in Android's quick settings, turn off any other hotspot or tethering, and try again. A few manufacturers disable local-only hotspots entirely.

**Build errors.**
- `npx cordova requirements android` shows what's missing.
- `JAVA_HOME` must point at JDK 17.
- `ANDROID_HOME` must point at your SDK folder.
- "Failed to find Build Tools" or "license not accepted": install the build-tools version it names and run `sdkmanager --licenses`.
- After changing the app ID or renaming the project, reset the platform: `npx cordova platform rm android && npx cordova platform add android`.

## Signing a release build

You don't need this for personal use. For a release build:

```
keytool -genkeypair -v -keystore airlift.keystore -alias airlift -keyalg RSA -keysize 2048 -validity 10000
```

Create `build.json` in the project root (it's in `.gitignore`):

```json
{
  "android": {
    "release": {
      "keystore": "airlift.keystore",
      "storePassword": "YOUR_STORE_PASSWORD",
      "alias": "airlift",
      "password": "YOUR_KEY_PASSWORD",
      "keystoreType": ""
    }
  }
}
```

```
npx cordova build android --release --buildConfig=build.json -- --packageType=apk
```

The signed APK is at `platforms/android/app/build/outputs/apk/release/app-release.apk`.

**Back up your keystore and password.** You need the same key to update an installed app later. Never commit it.

## Security notes

- The proxy listens on all network interfaces, not only the hotspot. Don't run it while the phone is on a Wi-Fi network you don't trust.
- The hotspot password is generated by Android and changes each time you start sharing.
- Anyone who joins the hotspot can use your mobile data.
- Large downloads (Docker images, Ollama models, system updates) can use gigabytes of data. Check your plan first.

## Project layout

```
config.xml                                   Cordova app config (ID, name, plugin)
www/index.html                               The app's UI
plugins/cordova-plugin-hotspotproxy/
  plugin.xml                                 Permissions and service declaration
  www/hotspotproxy.js                        JS API
  src/android/HotspotProxy.java              Hotspot + HTTP/SOCKS5 proxy
  src/android/ProxyService.java              Foreground service and wake locks
```

## License

Add a `LICENSE` file before publishing.
