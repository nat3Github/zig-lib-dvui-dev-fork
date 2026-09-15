## Running
1. Install Android Studio and Android NDK
    - https://developer.android.com/studio
    - https://developer.android.com/studio/projects/install-ndk

### Android Side
1. Download the latest android zip (called something similar to `SDL3-devel-<version>-android.zip`) from the [SDL releases](https://github.com/libsdl-org/SDL/releases) 
1. Extract and move the `.aar` to `android-project/app/libs/`
1. Update `android-project/app/build.gradle` to reflect the version of the `.aar`. The line should be at the end and is `implementation files('libs/SDL3-3.4.0.aar')`

### Zig side
Nothing to do: the gradle build runs `zig build lib` (Debug for debug, ReleaseFast for release) with Android Studio's NDK.
`zig` must be on the PATH Android Studio sees. If it isn't (common on macOS when launched from the Dock), add `zig=<path to zig>` to your user-level `~/.gradle/gradle.properties` (Windows: `%USERPROFILE%\.gradle\gradle.properties`).

To build the lib by hand, in `zig-project`: `zig build lib -Dandroid_ndk=<android_sdk>/ndk/<version>` (or set `ANDROID_NDK_HOME`)
- Defaults to `aarch64-linux-android`; pass `-Dtarget=x86_64-linux-android` for an x86_64 emulator
- Installs `libsdl_hello.a` into `android-project/app/src/main/c/prebuilt/<abi>/`

### Testing
1. Open the project in Android studio and run the app
    - If the emulated phone has a notch, you might need to use [SDL_GetWindowSafeArea](https://wiki.libsdl.org/SDL3/SDL_GetWindowSafeArea)
