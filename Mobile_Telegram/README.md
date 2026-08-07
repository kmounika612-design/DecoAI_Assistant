# DecoAI Assistant – Android Setup Guide

This guide explains how to install the **DecoAI Assistant** Android application onto a device using **Android Debug Bridge (ADB)**.

## Prerequisites

Download and install the latest **Android SDK Platform-Tools**, which include `adb`.

Android Developers: https://developer.android.com/tools/releases/platform-tools

After downloading:

1. Extract the Platform-Tools ZIP.

2. Open a terminal or PowerShell inside the extracted `platform-tools` folder.

3. Verify ADB is installed:

```bash
adb version
```

---

## Install the DecoAI Assistant APK

Download the APK from this repository:
https://github.com/kmounika612-design/DecoAI_Assistant/blob/main/Mobile_Telegram/app-debug.apk

### Enable USB Debugging

On your Android device:

1. Open **Settings** → **About phone**

2. Tap **Build Number** seven times to enable Developer Options.

3. Go to **Developer Options**

4. Enable **USB Debugging**.

Connect your Android device to your computer via USB.

Verify the device is detected:

```bash
adb devices
```

You should see your device listed.

Install the application:

```bash
adb install app-debug.apk
```

If reinstalling over an existing version:

```bash
adb install -r app-debug.apk
```

---

## Windows PowerShell Setup

If you're using Windows, run the provided PowerShell setup script before using the application.

Script location:
https://github.com/kmounika612-design/DecoAI_Assistant/blob/main/Mobile_Telegram/setup-node.ps1

Run the script from PowerShell:

```powershell
.\setup-node.ps1
```

If PowerShell blocks execution, temporarily allow local scripts:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Then run:

```powershell
.\setup-node.ps1
```

---

## Troubleshooting

### Device not detected

Check your connection:

```bash
adb devices
```

If no devices appear:

- Ensure USB Debugging is enabled.

- Accept the USB debugging prompt on your phone.

- Try a different USB cable or USB port.

### APK installation fails

Try reinstalling:

```bash
adb install -r app-debug.apk
```

Or uninstall the previous version:

```bash
adb uninstall <package_name>
adb install app-debug.apk
```

---

## Resources

- Android SDK Platform-Tools  
https://developer.android.com/tools/releases/platform-tools

- DecoAI Assistant APK  
https://github.com/kmounika612-design/DecoAI_Assistant/blob/main/Mobile_Telegram/app-debug.apk

- Windows Setup Script  
https://github.com/kmounika612-design/DecoAI_Assistant/blob/main/Mobile_Telegram/setup-node.ps1
SDK Platform Tools release notes  |  Android Studio  |  Android Developers
Android SDK Platform-Tools is a component for the Android SDK. 
