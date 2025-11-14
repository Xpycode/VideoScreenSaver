# Video Screen Saver - Installation Guide

## Overview

Video Screen Saver is a macOS screen saver that plays videos from your selected folders with customizable transitions and playback options.

## System Requirements

- **macOS 15.0 or later**
- Compatible with both Intel and Apple Silicon Macs

## Installation Methods

### Method 1: Install Pre-built Binary (Recommended)

1. **Download the screen saver file:**
   - Navigate to the `DerivedData` folder:
     ```bash
     ~/Library/Developer/Xcode/DerivedData/Video_Screen_Saver-*/Build/Products/Debug/
     ```
   - Or use the release build from the project repository

2. **Install the screen saver:**
   - **Double-click** `Video Screen Saver.saver`
   - macOS will ask if you want to install it for **This User Only** or **All Users**
   - Choose your preference and click **Install**

3. **Configure the screen saver:**
   - Open **System Settings**
   - Go to **Wallpaper** (or **Screen Saver** on older macOS versions)
   - Select **Video Screen Saver** from the list
   - Click **Options...** to configure settings

### Method 2: Build from Source

1. **Open the project:**
   ```bash
   cd /path/to/VideoScreenSaver
   open "Video Screen Saver.xcodeproj"
   ```

2. **Build in Xcode:**
   - Select the **Video Screen Saver** scheme
   - Choose **Product** → **Build** (⌘B)
   - Or build from command line:
     ```bash
     xcodebuild -project "Video Screen Saver.xcodeproj" \
                -scheme "Video Screen Saver" \
                -configuration Debug \
                build
     ```

3. **Install the built screen saver:**
   - The compiled `.saver` file will be in:
     ```
     ~/Library/Developer/Xcode/DerivedData/Video_Screen_Saver-*/Build/Products/Debug/
     ```
   - Double-click to install

## Configuration

Once installed, open the **Options** panel to configure:

### Source Folders
- **Add folders** containing your video files
- Click **+** to add, **−** to remove
- **Search Subfolders** option to scan nested directories
- Supports all QuickTime-compatible video formats (MP4, MOV, M4V, etc.)

### Playback Options
- **Shuffle Videos**: Randomize playback order
- **Loop Playlist**: Restart from beginning when all videos played

### Display Settings
- **Video Scaling**:
  - **Fill Screen**: Crop video to fill screen (maintains aspect ratio)
  - **Fit to Screen**: Letterbox to fit entire video (maintains aspect ratio)
  - **Stretch**: Distort to fill screen (may look stretched)

- **Transition**: Choose transition effect between videos
  - None, Fade, or Cross Dissolve

- **Duration**: Transition length (0.5 - 5.0 seconds)

## Folder Permissions

macOS requires permission to access folders in sandboxed environments:

1. When you add a folder, macOS will request permission
2. Grant access to allow the screen saver to read your videos
3. If videos don't appear, check **System Settings** → **Privacy & Security** → **Files and Folders**

## Troubleshooting

### Screen saver not appearing
- Make sure you've selected it in System Settings → Wallpaper
- Try restarting System Settings

### No videos playing
- Verify folders are added in Options
- Check that folders contain supported video files
- Ensure folder permissions are granted
- Enable "Search Subfolders" if videos are in nested directories

### Version compatibility error
- The screen saver requires macOS 15.0 or later
- If you see a version error, you may be running an older macOS version

### Videos appear black or don't transition
- Check video file compatibility (use QuickTime-compatible formats)
- Try disabling transitions temporarily
- Ensure videos aren't corrupted

## Uninstallation

To remove the screen saver:

1. **Quit System Settings** if open

2. **Delete the screen saver file:**
   ```bash
   # For current user only:
   rm -rf ~/Library/Screen\ Savers/Video\ Screen\ Saver.saver

   # For all users (requires admin):
   sudo rm -rf /Library/Screen\ Savers/Video\ Screen\ Saver.saver
   ```

3. **Remove preferences (optional):**
   ```bash
   defaults delete ~/Library/Preferences/ByHost/com.apple.screensaver.*
   ```

## Features

- ✅ Multiple folder support
- ✅ Recursive subfolder scanning
- ✅ Shuffle and loop playback
- ✅ Three scaling modes
- ✅ Smooth transitions (fade/cross-dissolve)
- ✅ Real-time statistics display
- ✅ Sandbox-compliant security
- ✅ macOS 15.0+ compatibility

## Support

For issues, feature requests, or contributions:
- **GitHub**: https://github.com/Xpycode/VideoScreenSaver
- **Issues**: https://github.com/Xpycode/VideoScreenSaver/issues

## License

[Add your license information here]

## Credits

Developed by Xpycode with assistance from Claude Code.
