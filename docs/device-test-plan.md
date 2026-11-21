# Testing on a real iPhone and iPad

CI checks what a Mac can check without a console: the app builds for iPhones, its unit tests pass
in the Simulator (H.264 decoding through VideoToolbox and the GPU copy, Vision reading text, the
settings, the PSN account ID), and the app, run in the Simulator as an iPhone and an iPad, reads a
game-like picture and feeds a stand-in TV it was connected to with a code. What follows needs your
devices, your consoles and your accounts.

## 0. Getting the app onto the device

Pick one (all need a Mac with Xcode, or a sideloading tool, and your Apple ID; Claude can't sign in
for you):

| Way | Cost | Lasts | How |
|---|---|---|---|
| Xcode, free Apple ID | free | 7 days, then reinstall | `native/build-*.sh`, `xcodegen`, open the project, Signing & Capabilities › Team: your Apple ID, change the bundle ID (e.g. `app.vitranslator.phone.<you>`), Run on the plugged-in device. On the device: Settings › General › VPN & Device Management › trust the developer. |
| Sideloading the CI's unsigned IPA | free | 7 days | The `VITranslator-unsigned-ipa` artifact of a CI run, with a tool such as Sideloadly or AltStore that signs it with your Apple ID. |
| TestFlight | Apple Developer Program, 99 USD a year | 90 days per build | Needs the program, an App Store Connect app record and signing in CI (ask before any of this). |

Turn on Developer Mode on the device when iOS asks (Settings › Privacy & Security › Developer Mode).

## 1. First start

- [ ] The app opens in the phone's language (or English); the globe button changes the language;
      Arabic, Persian and Urdu lay the screens out right to left.
- [ ] Light / dark switch works and is kept.
- [ ] iOS asks to **find devices on your local network**: allow it. (If refused: Settings ›
      VI Translator › Local Network.)
- [ ] On an iPad: Setup's tabs are a rail on the side; Play is two columns; rotating works.

## 2. TV

On a TV with the VI Translator TV app open (it shows a 6-digit code), phone and TV on the same Wi-Fi:

- [ ] Setup › Show on › Connect a TV: the TV is found (if not: Type the TV's address, its IP).
- [ ] Type the code: "Connected"; the TV shows "Connected to iPhone".
- [ ] Wrong code: "That isn't the code the TV shows."
- [ ] The TV is listed under Connected TVs, "Showing the translations" while the TV app is open.
- [ ] Remove disconnects it (the TV shows a new code).
- [ ] Quit and reopen the phone app: the TV reconnects by itself.

## 3. PS5 (PS Remote Play)

Needs: the PS5 on the same network, Remote Play on (Settings › System › Remote Play), and a
**second PSN account** (not the one you play with: Remote Play signs it in on the PS5).

- [ ] Source › PlayStation 5 › Sign in to PSN: Sony's page opens in the app; after signing in the
      step shows ✓ with the account ID. If Sony says it can't connect: wait, Sign In again; or *Sign
      in with a browser* and paste the address it ends on.
- [ ] Find your PS5: the PS5 is listed within a few seconds (on or in rest mode). **If not:** iOS
      gives broadcasts only to apps with Apple's multicast permission; the app also asks every
      address of the home network directly, which works on most /24 home networks. Otherwise type
      its address (PS5: Settings › Network › Connection Status). Note which happened.
- [ ] PS5: Settings › System › Remote Play › Link Device shows a PIN; type it, Link: "✓ Linked".
- [ ] Put the PS5 in rest mode; Wake the PS5 turns it on.
- [ ] Play › Start translating: "Connecting to the PS5…", then "Translating"; the picture shows in
      the app within a few seconds (Preview on). The TV keeps the console's own HDMI picture.
- [ ] Subtitles and objectives in GTA VI are read and translated; the TV draws them.
- [ ] The pause menu (GTA VI) is recognised and translated, at 720p and at 1080p (Stream quality).
      This depends on the studio-levels stretch (as on Android): if it isn't recognised, take a
      Snapshot of it and note the stream quality.
- [ ] Colours look right in the app's preview (not washed out, not too dark).
- [ ] Leave the app (home screen) for a few seconds and come back: "Stopped (iOS paused the app in
      the background)" while away, then translating starts again by itself.
- [ ] Lock button pressed while translating: same as above on unlocking. (iOS can't keep the stream
      with the screen off; the screen doesn't dim by itself while translating.)
- [ ] Reading speed: Show on › Preview › fps badge shows "n read · ms". In CI's Simulator (no Neural
      Engine) one pass takes ~7 s; on an iPhone it should be well under a second. If it stays slow,
      say so: Vision's faster mode can be used instead.
- [ ] 30 minutes of play: the phone's warmth and battery use (plugged in or not), the frames read
      (Show on › Preview › fps badge shows "n read · ms").
- [ ] An account with a login passcode on the PS5: the app asks for it.
- [ ] Unlink, then link again with a new PIN.

Send `Library/Caches/chiaki.log` from the app's container (Xcode › Devices › the app › Download
Container) if something fails.

## 4. Xbox

Needs: the Xbox with remote features on (Settings › Devices & connections › Remote features), Sleep
power mode, and your Microsoft account.

- [ ] Source › Xbox › Open the Xbox player: Microsoft's player loads (not a "get the app" page);
      sign in; choose the console under Remote play. Close: "Signed in to Microsoft in the Xbox player."
- [ ] Play › Start translating: the player opens and streams; the bar under it counts frames read.
- [ ] Text in the game is read and the TV shows the translations.
- [ ] If after ~10 s the bar offers "The video can't be read: record the screen": accept iOS's
      screen recording prompt; frames are then read again. Note whether this was needed.
- [ ] Sign out of Microsoft works.

## 5. The rest

- [ ] Translator: language list, a service with your own key (e.g. DeepL), memory numbers update.
- [ ] Reviewed translations download on the first start with a game (memory "remembered lines" > 0
      after a minute with Wi-Fi).
- [ ] Snapshot: Translate the whole picture while the PS5 streams; Original / Translated; Save puts
      it in Photos (iOS asks once).
- [ ] Read areas: drag a box and its corner on a copy of the profile; the change is kept.
- [ ] Game pages: the switches show; turning one off is kept.
- [ ] Share on my home network: the address and QR code show; another device opens the page.
