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
   name *GitHub TestFlight*, access **App Manager**. Download the `.p8` file (only once!).
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

## 5. What to know before the App Store review

- The app reads the console's picture with PS Remote Play (chiaki-ng) and Microsoft's web player.
  Apple may ask how the user connects to their own console: point them to the README's Setup.
- The app is AGPL-3.0: the source is public, which the App Store's terms allow for the developer's
  own app.
- iOS's multicast permission (`com.apple.developer.networking.multicast`) would let the app find a
  PS5 by broadcast; without it, the app asks every address of the home network, which works on most
  home networks. Request it only if testing shows it's needed (developer.apple.com/contact/request/networking-multicast).
