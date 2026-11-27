import SwiftUI

/**
 * Setup's Xbox, as the Android app's XboxLink: which player (the app's own, the default, or
 * Microsoft's web player, the old way); with the app's own, sign in to Microsoft with a code (typed at
 * microsoft.com/link on any device: no password in the app), choose the console once, the stream's
 * quality and the screen-off option. Start translating then goes straight to that console.
 */
struct XboxLinkView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @Environment(\.openURL) var openURL
    @State private var web = Prefs.xboxWebPlayer
    @State private var signed = XboxAuth.signedIn
    @State private var saved = XboxConsole.saved
    @State private var code: XboxAuth.DeviceCode?
    @State private var codeError: String?
    @State private var signIn: Task<Void, Never>?
    @State private var consoles: [XboxConsole]?
    @State private var listing = false
    @State private var listError: String?
    @State private var choosing = false
    @State private var askSignOut = false
    @State private var resolution = Prefs.xboxResolution
    @State private var screenOff = Prefs.screenOff
    @State private var phoneVolume = Prefs.phoneVolume
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabelText(L("Xbox player")).padding(.top, 14)
            clientChoice(false, L("VI Translator's player (recommended)"), L("Sign in with a code and choose the console once."))
                .padding(.top, 8)
            clientChoice(true, L("Microsoft's web player"), L("xbox.com's own player in the app: sign in and choose the console there. The phone's screen stays on."))
                .padding(.top, 8)
            if web {
                XboxWebSetup()
            } else {
                own
            }
        }
        .onDisappear {
            signIn?.cancel()
            signIn = nil
            code = nil
        }
    }

    /** One of the two Xbox players, as a card to tap (as Source's console choice). */
    private func clientChoice(_ isWeb: Bool, _ name: String, _ about: String) -> some View {
        let on = web == isWeb
        return Button {
            guard web != isWeb else { return }
            // (a stream running with the other player stops: the next Start uses this one)
            if m.state.running && Prefs.console == "xbox" { m.stop() }
            Prefs.xboxWebPlayer = isWeb
            web = isWeb
            m.rev += 1
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(name).font(k.font(k.base, .bold)).foregroundColor(k.text).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: Icon.check).foregroundColor(on ? k.accentUi : .clear)
                }
                Muted(about, small: true).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? k.accentSoft : k.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? k.accentUi : k.line, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isWeb ? "xbox-web" : "xbox-own")
    }

    // ---- the app's own player

    private var own: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, L("Sign in to Microsoft"), done: signed, open: true) { signInStep }
            step(2, L("Choose your Xbox"), done: signed && saved != nil && !choosing, open: signed) { consoleStep }
            Field(label: L("Stream quality"), help: L("1080p reads small text best; 720p for a slower home network.")) {
                Select(options: [("1080", "1080p"), ("720", "720p")], value: String(resolution)) { v in
                    resolution = Int(v) ?? 1080
                    Prefs.xboxResolution = resolution
                }
            }
            Check(label: L("Keep translating with the screen off"), on: screenOff) {
                screenOff = $0
                Prefs.screenOff = $0
            }
            .padding(.top, 8)
            Muted(L("The game's sound plays on the phone as well, so iOS lets the app go on with the screen locked or in another app. Uses more battery: keep the phone charging. Takes effect at the next Start translating."), small: true)
            if screenOff {
                Field(label: L("The game's sound on the phone")) {
                    KSlider(range: 0...1, step: 0.05, value: phoneVolume, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                        phoneVolume = v
                        m.setPhoneVolume(v)
                    }
                }
            }
            LabelText(L("On the Xbox, once")).padding(.top, 14)
            Muted("1. " + L("Settings › Devices & connections › Remote features: turn on Enable remote features."))
            Muted("2. " + L("Settings › General › Power options: choose Sleep, so the player can wake the console."))
            Muted("3. " + L("Sign in on the Xbox with the same Microsoft account as in the player."))
            Callout(L("The phone streams the Xbox's picture to read it (no controller: keep playing with your controller on the Xbox).")).padding(.top, 12)
        }
        .confirmationDialog(L("Sign out of Microsoft for the Xbox?"), isPresented: $askSignOut, titleVisibility: .visible) {
            Button(L("Sign out"), role: .destructive) {
                if m.state.running && Prefs.console == "xbox" { m.stop() }
                XboxAuth.signOut()
                signed = false
                saved = nil
                consoles = nil
                m.rev += 1
            }
        }
    }

    // ---- the frame of a step (as the PS5's)

    private func step<C: View>(_ n: Int, _ title: String, done: Bool, open: Bool, @ViewBuilder content: () -> C) -> some View {
        let active = open && !done
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(done ? "✓" : String(n)).font(k.font(k.base, .bold)).foregroundColor(done || open ? .white : k.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(done ? AnyShapeStyle(k.ok) : open ? AnyShapeStyle(Kit.sunset) : AnyShapeStyle(k.panel3)))
                Text(title).font(k.font(k.base + 1, .bold)).foregroundColor(open || done ? k.text : k.muted)
                Spacer()
            }
            if open || done { content().padding(.top, 10) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(k.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? k.accentUi : k.line, lineWidth: active ? 1.5 : 1))
        .opacity(!open && !done ? 0.6 : 1)
        .padding(.top, 12)
    }

    // ---- 1. sign in with a code

    @ViewBuilder private var signInStep: some View {
        if signed {
            HStack(spacing: 10) {
                Text(L("Signed in to Microsoft.")).font(k.font(k.base)).foregroundColor(k.text)
                Spacer()
                KLink(L("Sign out")) { askSignOut = true }
            }
        } else if let dc = code {
            VStack(alignment: .leading, spacing: 0) {
                Muted(L("Go to {url} and enter this code, then sign in with the Microsoft account of your Xbox:", ("url", dc.verificationUri.replacingOccurrences(of: "https://", with: ""))))
                Text(dc.userCode).font(.system(size: k.base + 12, weight: .bold, design: .monospaced)).foregroundColor(k.text)
                    .kerning(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("xbox-code")
                HStack(spacing: 8) {
                    KButton(L("Open microsoft.com/link"), primary: true) {
                        UIPasteboard.general.string = dc.userCode
                        if let u = URL(string: dc.verificationUri) { openURL(u) }
                    }
                    KButton(L("Copy code"), full: false) {
                        UIPasteboard.general.string = dc.userCode
                        copied = true
                    }
                }
                if copied { Muted(L("Copied."), small: true).padding(.top, 6) }
                Muted(L("Waiting for you to sign in…"), small: true).padding(.top, 8)
                KLink(L("Cancel")) {
                    signIn?.cancel()
                    signIn = nil
                    code = nil
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Muted(L("You'll get a short code to enter at microsoft.com/link, on this phone or any other device. No password is typed in this app."))
                if let e = codeError { Callout(e, k.warn).padding(.top, 8) }
                KButton(L("Get a sign-in code"), primary: true) { getCode() }.padding(.top, 10)
                    .accessibilityIdentifier("xbox-get-code")
            }
        }
    }

    private func getCode() {
        codeError = nil
        signIn?.cancel()
        signIn = Task { @MainActor in
            do {
                let dc = try await XboxAuth.requestCode()
                code = dc
                let ok = await XboxAuth.waitForSignIn(dc)
                guard !Task.isCancelled, code == dc else { return }
                code = nil
                if ok {
                    signed = true
                    m.rev += 1
                    listConsoles()
                } else {
                    codeError = L("The code expired or the sign-in was declined. Get a new code.")
                }
            } catch {
                if !Task.isCancelled { codeError = L("Couldn't reach Microsoft: {error}", ("error", error.localizedDescription)) }
            }
        }
    }

    // ---- 2. the console

    @ViewBuilder private var consoleStep: some View {
        if let c = saved, !choosing {
            HStack(spacing: 10) {
                Image(systemName: Icon.tv).foregroundColor(k.ok)
                Text(c.title).font(k.font(k.base, .bold)).foregroundColor(k.text)
                Spacer()
                KLink(L("Change")) {
                    choosing = true
                    if consoles == nil { listConsoles() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if listing {
                    Muted(L("Looking for your consoles…"))
                } else if let e = listError {
                    Callout(e, k.warn)
                } else if let list = consoles {
                    if list.isEmpty {
                        Callout(L("No Xbox on this Microsoft account allows Remote Play. Turn on remote features on the Xbox (below), then look again."), k.warn)
                    }
                    ForEach(list, id: \.serverId) { x in
                        HStack(spacing: 10) {
                            Image(systemName: Icon.tv).foregroundColor(k.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(x.title).font(k.font(k.base, .bold)).foregroundColor(k.text)
                                Muted([x.type, x.powerState].filter { !$0.isEmpty }.joined(separator: " · "), small: true)
                            }
                            Spacer()
                            KButton(L("Use this one"), primary: true, full: false) { use(x) }
                        }
                        .padding(.top, 8)
                    }
                }
                KLink(consoles == nil && !listing ? L("Find my consoles") : L("Look again")) { listConsoles() }.padding(.top, 8)
            }
            .onAppear { if consoles == nil && !listing { listConsoles() } }
        }
    }

    private func use(_ x: XboxConsole) {
        XboxConsole.saved = x
        saved = x
        choosing = false
        m.rev += 1
    }

    private func listConsoles() {
        guard !listing else { return }
        listing = true
        listError = nil
        Task { @MainActor in
            do {
                let list = try await XboxHome(try await XboxAuth.streaming(), resolution: 1080).consoles()
                consoles = list
                // (just one: it's the one)
                if list.count == 1 && XboxConsole.saved == nil { use(list[0]) }
            } catch is XboxAuth.SignedOut {
                signed = false
                listError = L("Signed out of Microsoft. Sign in again.")
            } catch {
                listError = L("Couldn't get your consoles: {error}", ("error", error.localizedDescription))
            }
            listing = false
        }
    }
}

/**
 * Microsoft's web player (the old way): nothing to link in the app. The player (in the app) signs in
 * with the Microsoft account and connects to the console itself; the console only needs its remote
 * features on. Signing in here first makes Start go straight to the game.
 */
struct XboxWebSetup: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var xboxSigned: Bool?
    @State private var askSignOut = false

    var body: some View {
        let signed = xboxSigned ?? false
        return VStack(alignment: .leading, spacing: 4) {
            Callout(signed ? L("Signed in to Microsoft in the Xbox player.") : L("Not signed in to the Xbox player yet."), signed ? k.ok : nil)
                .padding(.top, 12)
            LabelText(L("On the Xbox, once")).padding(.top, 14)
            Muted("1. " + L("Settings › Devices & connections › Remote features: turn on Enable remote features."))
            Muted("2. " + L("Settings › General › Power options: choose Sleep, so the player can wake the console."))
            Muted("3. " + L("Sign in on the Xbox with the same Microsoft account as in the player."))
            LabelText(L("In the app")).padding(.top, 14)
            Muted(L("Open the player, sign in with your Microsoft account and choose your Xbox under Remote play. The sign-in stays in the app: next time, Start translating goes straight to the game."))
            KButton(L("Open the Xbox player"), icon: Icon.tv, primary: true) { m.xbox = .setup }.padding(.top, 12)
            if signed { KLink(L("Sign out of Microsoft")) { askSignOut = true } }
            Callout(L("While translating, the app copies the player's picture to read it. If the copies come out black, the player offers to record the screen instead (iOS asks you to allow it).")).padding(.top, 12)
        }
        .task(id: m.xbox == nil) { xboxSigned = await XboxPlayer.signedIn() }
        .confirmationDialog(L("Sign out of Microsoft in the Xbox player?"), isPresented: $askSignOut, titleVisibility: .visible) {
            Button(L("Sign out"), role: .destructive) {
                Task {
                    await XboxPlayer.signOut()
                    xboxSigned = await XboxPlayer.signedIn()
                }
            }
        }
    }
}
