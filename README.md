# HD Camera USC-CAM - iPhone as a USB webcam

iPhone app streams camera video over the USB cable; the Windows app turns it into a virtual webcam
called **HD Camera USC-CAM**.

## Build
Push to GitHub -> Actions -> *Build USC-CAM* -> download `USC-CAM-Package`
(contains `USC-CAM.ipa`, `USC-CAM.exe`, `driver/` and `Install-HD-Camera.bat`).

## Install / use
1. iPhone: sideload `USC-CAM.ipa` (Sideloadly / AltStore - unsigned). Open the app, allow the camera.
2. PC (one time): install **iTunes** or **Apple Devices** (USB driver).
3. PC (one time): run `Install-HD-Camera.bat` (admin) -> the webcam appears as **HD Camera USC-CAM**.
   (Without it the app falls back to OBS Studio's *OBS Virtual Camera*, which needs OBS installed.)
4. Plug in the iPhone, tap *Trust*, keep USC-CAM open, run `USC-CAM.exe`.
5. In Zoom / Discord / Teams etc. pick **HD Camera USC-CAM**.

## On the phone
The app shows the live camera image. Pick **Resolution** (720p / 1080p / 4K) and **Quality**
(Low / Medium / High) right on the screen - lower values = less lag. Default: 1080p, Medium.
On the PC you can additionally downscale the output.

Note: iOS pauses the camera when the app is in the background - keep it open (use *Dim screen* to save battery).
