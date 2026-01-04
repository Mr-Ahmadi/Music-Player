# Music Player

A lightweight iOS/macOS music player app for playing locally stored audio files. Built with SwiftUI and AVFoundation.

## Features

- **Local Playback**: Play MP3, M4A, WAV, AAC, and FLAC audio files stored on your device
- **Library Management**: Import audio files and organize them into a persistent library
- **Playback Controls**: Play, pause, skip to next/previous track with intuitive buttons
- **Progress Slider**: Seek to any position in the current track
- **Persistent Storage**: Imported tracks are saved locally using UserDefaults
- **Clean UI**: Minimalist, responsive interface built with SwiftUI

## Requirements

- iOS 15.0+ or macOS 12.0+
- Xcode 13.0+
- Swift 5.5+

## Project Structure

```
OfflineMusicPlayer/
├── OfflineMusicPlayer/
│   ├── OfflineMusicPlayerApp.swift (MusicPlayerApp.swift)  # App entry point
│   ├── ContentView.swift                 # Main library and player UI
│   ├── AudioPlayer.swift                 # Core audio playback service
│   ├── PlayerView.swift                  # Player controls UI
│   ├── DocumentPicker.swift              # File import UI
│   └── Assets.xcassets/                  # App icons and colors
├── OfflineMusicPlayerTests/
│   └── OfflineMusicPlayerTests.swift     # Unit tests for AudioPlayer
└── OfflineMusicPlayerUITests/
    └── OfflineMusicPlayerUITests.swift   # UI tests
```

## Getting Started

### Building

1. Open `OfflineMusicPlayer.xcodeproj` in Xcode
2. Select the target and build configuration (Debug/Release)
3. Press **Cmd+B** to build

### Running

#### iOS Simulator
```bash
# Build and run on the default iOS simulator
xcodebuild -scheme OfflineMusicPlayer -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug
```

#### macOS
```bash
# Build and run on macOS
xcodebuild -scheme OfflineMusicPlayer -destination 'platform=macOS' -configuration Debug
```

#### Device
1. Connect your iOS device via USB
2. Select the device in Xcode
3. Press **Cmd+R** to run

### Testing

#### Unit Tests
```bash
xcodebuild -scheme OfflineMusicPlayer -configuration Debug test -only-testing=OfflineMusicPlayerTests
```

#### UI Tests
```bash
xcodebuild -scheme OfflineMusicPlayer -configuration Debug test -only-testing=OfflineMusicPlayerUITests
```

#### Run All Tests
```bash
xcodebuild -scheme OfflineMusicPlayer -configuration Debug test
```

## Usage

1. **Launch the App**: Open Offline Music Player
2. **Import Tracks**: Tap the download button (⬇) to select audio files from your device
3. **View Library**: Browse your imported tracks in the list
4. **Play a Track**: Tap any track to start playback
5. **Control Playback**:
   - Pause/Resume: Tap the play/pause button
   - Skip Forward: Tap the forward button (⏩)
   - Skip Backward: Tap the backward button (⏪)
   - Seek: Drag the progress slider
6. **Remove Tracks**: Swipe left on a track to delete it from the library

## Technical Details

### AudioPlayer (Observable Model)
- Uses `AVAudioPlayer` for audio playback
- Publishes playback state changes (progress, duration, current track)
- Manages a list of importable audio URLs
- Persists tracks to `UserDefaults` with key `"savedTracks"`

### Supported Formats
- MP3 (`.mp3`)
- M4A (`.m4a`)
- WAV (`.wav`)
- AAC (`.aac`)
- FLAC (`.flac`)

### State Management
- Uses Combine's `@Published` for reactive updates
- Track list automatically saves when modified
- Player state updates every 0.5 seconds during playback

## Architecture

- **MVVM Pattern**: Model-View-ViewModel architecture with SwiftUI
- **Observable Objects**: `AudioPlayer` publishes state for reactive UI updates
- **Cross-Platform**: Separate implementations for iOS and macOS using `#if canImport()`

## Limitations

- Single audio track playback at a time
- No playlist support (tracks are saved in import order)
- No metadata display (artist, album, duration on track cards)
- No background audio playback (suspends when app is backgrounded)
- Limited error handling for corrupted files

## Future Enhancements

- Add metadata display (artist, album, year)
- Implement playlists and smart collections
- Background audio playback support
- Volume control
- Audio visualization
- Shuffle and repeat modes
- Search functionality
- iCloud sync

## Testing

The project includes:
- **7 Unit Tests** for `AudioPlayer`:
  - Track management (add, remove, detect duplicates)
  - Navigation (next, previous, wraparound)
  - Playback control (pause, toggle)
- **5 UI Tests** for main user flows:
  - App launch verification
  - Navigation title visibility
  - Import button presence
  - Empty state display
  - Play button visibility

## Known Issues

- Seeking may be imprecise on very short files
- File picker on macOS blocks the main thread briefly
- No visual feedback for import operation completion

## Contributing

To contribute improvements:
1. Create a feature branch
2. Make your changes
3. Add/update tests
4. Create a pull request

## License

MIT License - see LICENSE file for details

---

**Version**: 1.0.0  
**Created**: January 2026  
**Last Updated**: January 4, 2026
