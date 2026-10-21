# Audio Router

Choose an audio output device for each app on macOS 14.2 or later. For example, send Spotify to a
Bluetooth receiver while Firefox plays into the headphone jack.

## Build and run

    ./build.sh
    open build/AudioRouter.app

The first time you route an app, macOS asks for permission to record system audio. You can review
it later in System Settings → Privacy & Security → Screen & System Audio Recording.
The default build is ad-hoc signed, so macOS may ask again after each rebuild. To avoid that, set
`CODESIGN_IDENTITY` to your Apple Development certificate before running `./build.sh`.

## How it works

For each routed app, Audio Router:

1. creates a Core Audio *process tap* on all of the app's audio processes, including browser helper
   processes. The tap captures the app's sound and mutes its normal output;
2. creates a private aggregate device that combines the tap with the device you chose;
3. copies the tapped audio to that device in real time.

Choices are saved per app. When a chosen device disconnects, the app goes back to the system output.
When the device reconnects, routing starts again. Routing works only while Audio Router is running.
Quit it from the menu bar icon, and every app goes back to the system output.
