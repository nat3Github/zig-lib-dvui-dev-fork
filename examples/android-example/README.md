## Running

1. Install Android Studio and Android NDK
   - https://developer.android.com/studio
   - https://developer.android.com/studio/projects/install-ndk

### Android Side

SDL is built from source by the zig build and linked into `libsdl_hello.a`.
The SDL Java glue in `app/src/main/java/org/libsdl/app/` is copied from SDL's `android-project` and must match the SDL version dvui pins (currently 3.4.4), or the app crashes on launch with a JNI error.

### Zig side

the gradle build runs `zig build lib` (Debug for debug, ReleaseFast for release) with Android Studio's NDK.
`zig` must be on the PATH Android Studio sees. If it isn't (common on macOS when launched from the Dock), add `zig=<path to zig>` to your user-level `~/.gradle/gradle.properties` (Windows: `%USERPROFILE%\.gradle\gradle.properties`).

To build the lib by hand, in `zig-project`: `zig build lib -Dandroid_ndk=<android_sdk>/ndk/<version>` (or set `ANDROID_NDK_HOME`)

- Defaults to `aarch64-linux-android`; pass `-Dtarget=x86_64-linux-android` for an x86_64 emulator
- Installs `libsdl_hello.a` into `android-project/app/src/main/c/prebuilt/<abi>/`

### Testing

1. Open the project in Android studio and run the app
   - If the emulated phone has a notch, you might need to use [SDL_GetWindowSafeArea](https://wiki.libsdl.org/SDL3/SDL_GetWindowSafeArea)
