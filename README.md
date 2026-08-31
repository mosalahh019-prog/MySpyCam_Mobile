# MySpyCam Mobile v2

## What changed
- Real Android camera capture using Flutter `camera` plugin.
- Camera + microphone permissions are requested when needed.
- Front/back camera switching.
- Resolution settings.
- Manual Start/Stop recording.
- Local copy remains on the phone after successful PC upload.
- Network dialog appears only when the Network button is pressed.
- Remote commands require an explicit confirmation on the phone.
- Terminal/Logs dialog.

## Important privacy behavior
Remote start/stop, camera switching and delete requests are confirmed on the phone. The app does not perform hidden recording or silent remote camera control.

## Run
```bash
flutter pub get
flutter run
```
