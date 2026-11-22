# TestFlight and the App Store

The TestFlight workflow (`.github/workflows/testflight.yml`) runs the whole build and its checks,
then archives the app, signs it for the App Store and uploads it to App Store Connect, on a tag
like `v1.0.0` or when started by hand (Actions › TestFlight › Run workflow). Xcode makes the
signing certificate and the provisioning profile itself, with an App Store Connect API key, so no
certificate or profile is kept anywhere.

These steps need your Apple account; you do them yourself.

## 1. The Apple Developer Program (once, 99 USD a year)

1. https://developer.apple.com/programs/enroll/ with your Apple ID (two-factor authentication on).
   As an individual (the apps are listed under your name) or as an organisation (needs a D-U-N-S
   number; the apps are listed under the organisation's name).
2. Apple confirms the enrolment, usually within two days.
3. Note the **Team ID**: developer.apple.com › Account › Membership details (10 characters).

## 2. The app in App Store Connect (once)

1. https://appstoreconnect.apple.com › Apps › ＋ › New App: platform iOS, name *VI Translator*
   (or another, if it's taken), primary language, bundle ID **app.vitranslator.phone** (if it isn't
   in the list yet: developer.apple.com › Certificates, IDs & Profiles › Identifiers › ＋ › App IDs ›
   App, with that bundle ID; no capabilities needed), SKU e.g. `vi-translator-ios`.
2. App Privacy: "Data Not Collected" (the app sends no data to the developer; the translation
   services the user picks get the game's text with the user's own keys).

## 3. The API key the workflow signs and uploads with (once)

1. App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › ＋:
   name *GitHub TestFlight*, access **Admin** (Xcode signs with Apple-managed certificates, which
   only an Admin key may use). Download the `.p8` file (only once!).
2. Note the key's **Key ID** and the **Issuer ID** shown above the list.
3. Keep the `.p8` with the other keys in `C:\dev\vitranslator.app` (and add it to its README).
4. In the repository on GitHub › Settings › Secrets and variables › Actions › New repository secret:

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | the Team ID |
   | `ASC_KEY_ID` | the Key ID |
   | `ASC_ISSUER_ID` | the Issuer ID |
   | `ASC_KEY_P8_B64` | the `.p8` file in base64: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXX.p8"))` in PowerShell |

## 4. A build in TestFlight

1. Actions › TestFlight › Run workflow (or push a tag `v1.0.0`).
2. After Apple's processing (10–30 minutes) the build is in App Store Connect › TestFlight. The
   first time, answer the export compliance question if asked (the app declares it uses no
   non-exempt encryption).
3. Internal testing: add yourself (and up to 100 people of the team) as testers; install the
   TestFlight app on the iPhone and iPad and accept. External testers (up to 10,000, by e-mail or a
   public link) need Apple's beta review of the first build.

## 5. The App Store page and the review

**By the workflow** (Actions › *App Store page* › Run workflow, version `1.0.0`): the name,
description, keywords, support / marketing / privacy URLs in 30 languages (`fastlane/metadata`,
made by `tools/store_texts.py` from the Play listing), the categories (Utilities, Entertainment),
the copyright, and the screenshots for iPhone 6.9" and iPad 13". It submits nothing.

**By hand in App Store Connect** (the app › the iOS version being prepared, unless noted):

1. **Build:** under *Build*, ＋, choose the latest TestFlight build (its version must be the same:
   1.0.0).
2. **App Privacy** (app › App Privacy): *Get Started* › "No, we do not collect data from this app"
   (the developer collects nothing; game text goes to the translation service the user picks with
   their own key). Privacy policy URL: https://vitranslator.app/privacy/ › Publish.
3. **Age rating** (app › App Information › Age Rating): answer *None / No* everywhere (no violence,
   no user-generated content shown to others, no web browsing other than Sony's and Microsoft's
   sign-in and Microsoft's player). Expected: 4+.
4. **Content rights** (App Information): "Does your app contain, show, or access third-party
   content?" Yes, and you have the necessary rights: the app shows the user's own console's picture
   and reads its text, for that user only.
5. **Pricing and Availability:** Price *Free* (USD 0); the countries (all, or a choice).
6. **EU trader status** (Business, Account Holder only): declare whether you are a trader. A
   non-trader (a hobby project, no income from it) can still distribute in the EU; a trader's
   address and contact details are shown on the App Store in the EU.
7. **App Review Information:** sign-in not required; your contact name, phone and e-mail; the notes
   below; and, strongly advised, a link to a short unlisted video (YouTube, Drive) of the whole flow:
   linking the PS5, *Start translating*, the subtitles on the TV.
8. **Version release:** manually or automatically after approval.
9. **Add for Review** › **Submit to App Review**.

Notes for App Review:

> VI Translator translates a console game's subtitles and shows them over the game on the user's
> TV. It needs the user's own PlayStation 5 or Xbox on the same home network, and a TV running the
> VI Translator TV app, so it can't be used fully without them: a video of the whole flow is here:
> <link>. Without a console, the app's settings, languages and translation services can be seen in
> Setup, and *Show on › Share on my home network* shows the live page other devices can open.
> 1. Setup › Source: PlayStation 5 (sign in to PSN, find the PS5, type the PIN it shows under
>    Settings › System › Remote Play › Link Device), or Xbox (sign in to Microsoft's own Remote
>    Play player, shown in the app).
> 2. Setup › Show on › Connect a TV: open VI Translator on the TV and type the 6-digit code it shows.
> 3. Play › Start translating: the translations show on the TV and on the phone.
> Background audio: with Setup › Source › "Keep translating with the screen off" (off by default),
> the app plays the game's own sound, received from the console with the picture, so translating
> goes on with the screen locked; the sound is the user's game audio.
> No account with the developer is needed. The app is an unofficial, open-source project (AGPL-3.0),
> not affiliated with Sony or Microsoft.

## 6. What to know before the App Store review

- The app reads the console's picture with PS Remote Play (chiaki-ng) and Microsoft's web player.
  Apple may ask how the user connects to their own console: point them to the README's Setup.
- The app is AGPL-3.0: the source is public, which the App Store's terms allow for the developer's
  own app.
- iOS's multicast permission (`com.apple.developer.networking.multicast`) would let the app find a
  PS5 by broadcast; without it, the app asks every address of the home network, which works on most
  home networks. Request it only if testing shows it's needed (developer.apple.com/contact/request/networking-multicast).
