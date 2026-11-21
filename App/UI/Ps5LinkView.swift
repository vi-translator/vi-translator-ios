import SwiftUI

/**
 * Linking a PS5, once, in three steps, each done before the next opens (as the Android app): sign in
 * to PSN with a second account (in the app, or in a browser when Sony's check refuses the app), find
 * it on the home network (searched at once; or its address typed), then the PIN the PS5 shows, and
 * Link. Linked: the console, with Wake, the stream's quality and Unlink.
 */
struct Ps5LinkView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var saved = Ps5.saved
    @State private var account = Ps5.accountId
    @State private var address = Ps5.address
    @State private var name = Ps5.addressName
    @State private var editingAddress = false
    @State private var editingAccount = false
    @State private var hosts: [PsHost] = []
    @State private var searching = false
    @State private var discovery: PsDiscovery?
    @State private var regist: PsRegist?
    @State private var typedAddress = Ps5.address
    @State private var typedAccount = Ps5.accountId
    @State private var pin = ""
    @State private var linkMsg = ""
    @State private var linkErr = false
    @State private var linking = false
    @State private var signingIn = false
    @State private var browser = false
    @State private var toast: String?
    @State private var askUnlink = false
    @State private var resolution = Prefs.psResolution

    /** (the simulator and CI: the steps shown even with a PS5 linked) */
    private var showSteps: Bool { UserDefaults.standard.bool(forKey: "vitPs5Steps") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !Ps5.available {
                Callout(L("PS Remote Play isn't in this build of the app."), k.err).padding(.top, 12)
            } else if let c = saved, !showSteps {
                linked(c)
            } else {
                let addressOk = Ps5.validAddress(address)
                let accountOk = Ps5.validAccount(account)
                // (PSN first, as Sony's own app: the step that may take a few tries; finding the PS5 next,
                // then its PIN at once, which lasts only about 5 minutes)
                step(1, L("Sign in to PSN"), done: accountOk && !editingAccount, open: true) { signInStep(accountOk) }
                step(2, L("Find your PS5"), done: addressOk && !editingAddress, open: accountOk && !editingAccount) { findStep(addressOk) }
                step(3, L("Enter the PIN from the PS5"), done: false, open: addressOk && accountOk && !editingAddress && !editingAccount) { pinStep }
            }
            if let t = toast { Callout(t, k.warn).padding(.top, 10) }
        }
        .onAppear { if saved == nil && discovery == nil && Ps5.available { search() } }
        .onDisappear {
            discovery?.stop()
            discovery = nil
        }
        .sheet(isPresented: $signingIn) {
            NavigationStack {
                PsnLoginView { r in
                    signingIn = false
                    switch r {
                    case let .success(id): useAccount(id)
                    case let .failure(e): toast = L("PSN sign-in didn't work: {e}", ("e", e.localizedDescription))
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { signingIn = false } } }
            }
        }
        .sheet(isPresented: $browser) {
            BrowserSignIn { id in
                browser = false
                useAccount(id)
            }
            .environment(\.kit, k)
        }
    }

    // ---- the frame of a step: its number (or ✓), its title, then what it asks

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

    // ---- 1. PSN

    @ViewBuilder private func signInStep(_ accountOk: Bool) -> some View {
        if accountOk && !editingAccount {
            HStack(spacing: 10) {
                Image(systemName: Icon.check).foregroundColor(k.ok)
                VStack(alignment: .leading) {
                    Text(L("Signed in: the account ID is ready")).font(k.font(k.base, .bold)).foregroundColor(k.text)
                    Muted(account, small: true).environment(\.layoutDirection, .leftToRight)
                }
                Spacer()
                KLink(L("Change")) { editingAccount = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Callout(L("Sign in with a second PSN account, not the one you play with: Remote Play signs it in on the PS5. Only its account ID is kept."), k.warn)
                KButton(L("Sign in to PSN"), primary: true) { signingIn = true }.padding(.top, 10)
                Muted(L("If Sony says it can't connect, wait a few seconds and press Sign In again; or sign in with a browser."), small: true).padding(.top, 8)
                KLink(L("Sign in with a browser")) { browser = true }
                Field(label: L("Or type the account ID")) {
                    KInput(value: typedAccount, ltr: true) { typedAccount = $0 }
                }
                KButton(L("Use this account ID")) {
                    let v = typedAccount.trimmingCharacters(in: .whitespaces)
                    guard Ps5.validAccount(v) else {
                        toast = L("That isn't an account ID (12 letters and digits, ending in =).")
                        return
                    }
                    useAccount(v)
                }
                .padding(.top, 8)
            }
        }
    }

    private func useAccount(_ id: String) {
        Ps5.accountId = id
        account = id
        typedAccount = id
        editingAccount = false
        toast = nil
    }

    // ---- 2. find it

    @ViewBuilder private func findStep(_ addressOk: Bool) -> some View {
        if addressOk && !editingAddress {
            HStack(spacing: 10) {
                Image(systemName: Icon.source).foregroundColor(k.ok)
                VStack(alignment: .leading) {
                    Text(name.isEmpty ? "PS5" : name).font(k.font(k.base, .bold)).foregroundColor(k.text)
                    Muted(address, small: true).environment(\.layoutDirection, .leftToRight)
                }
                Spacer()
                KLink(L("Change")) { editingAddress = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Muted(L("The PS5 must be on (or in rest mode) and on the same network as this phone."), small: true)
                if searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Muted(L("Looking for PlayStation consoles…"), small: true)
                    }
                    .padding(.top, 10)
                }
                ForEach(hosts) { x in
                    HStack(spacing: 10) {
                        Image(systemName: Icon.source).foregroundColor(k.accentUi)
                        VStack(alignment: .leading) {
                            Text(x.name).font(k.font(k.base, .bold)).foregroundColor(k.text)
                            Muted("\(x.addr) · " + L(x.standby ? "rest mode" : "on"), small: true)
                        }
                        Spacer()
                        KButton(L("Choose"), primary: true, full: false) {
                            setAddress(x.addr, x.name)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(k.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(k.line, lineWidth: 1))
                    .padding(.top, 8)
                }
                if !searching && hosts.isEmpty {
                    Callout(L("No PS5 found yet. Is it on, with Remote Play allowed (Settings › System › Remote Play)? You can also type its address below.")).padding(.top, 10)
                    Muted(L("iOS asks once to let VI Translator find devices on your local network: allow it (Settings › VI Translator › Local Network)."), small: true).padding(.top, 6)
                }
                if !searching { KLink(L("Search again")) { search() } }
                Field(label: L("Or type its address"), help: L("On the PS5: Settings › Network › Connection Status › View Connection Status, IPv4 address.")) {
                    KInput(value: typedAddress, placeholder: "192.168.1.20", ltr: true) { typedAddress = $0 }
                }
                KButton(L("Use this address")) {
                    let a = typedAddress.trimmingCharacters(in: .whitespaces)
                    guard Ps5.validAddress(a) else {
                        toast = L("That isn't an address like 192.168.1.20.")
                        return
                    }
                    setAddress(a, hosts.first { $0.addr == a }?.name ?? "")
                }
                .padding(.top, 10)
            }
        }
    }

    private func setAddress(_ a: String, _ n: String) {
        Ps5.address = a
        Ps5.addressName = n
        address = a
        name = n
        typedAddress = a
        editingAddress = false
        toast = nil
    }

    private func search() {
        discovery?.stop()
        hosts = []
        searching = true
        discovery = PsDiscovery { found in
            hosts = found
            if !found.isEmpty {
                searching = false
                discovery?.stop()
                discovery = nil
            }
        }
        if discovery == nil { searching = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if searching {
                searching = false
                discovery?.stop()
                discovery = nil
            }
        }
    }

    // ---- 3. the PIN, and Link

    private var pinStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Muted(L("On the PS5: Settings › System › Remote Play › Link Device. It shows an 8-digit PIN, for about 5 minutes."), small: true)
            TextField("0000 0000", text: Binding(get: { pin }, set: { pin = String($0.filter(\.isNumber).prefix(8)) }))
                .keyboardType(.numberPad)
                .font(.system(size: k.base + 12, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .tracking(4)
                .foregroundColor(k.text)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9).fill(k.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(k.line, lineWidth: 1))
                .environment(\.layoutDirection, .leftToRight)
                .padding(.top, 10)
            if !linkMsg.isEmpty {
                Text(linkMsg).font(k.font(k.base - 0.5)).foregroundColor(linkErr ? k.err : k.muted).padding(.top, 8)
            }
            KButton(linking ? L("Linking…") : L("Link"), primary: true) { link() }.disabled(linking).padding(.top, 8)
        }
    }

    private func link() {
        guard !linking else { return }
        guard pin.count == 8, let p = UInt32(pin) else {
            linkMsg = L("The PIN has 8 digits.")
            linkErr = true
            return
        }
        linking = true
        linkMsg = L("Linking…")
        linkErr = false
        regist?.stop()
        regist = PsRegist(host: address, accountIdB64: account, pin: p) { console in
            linking = false
            regist?.stop()
            regist = nil
            if let console {
                Ps5.saved = console
                saved = console
                m.rev += 1
            } else {
                linkMsg = L("The PS5 refused: check the PIN (it changes every few minutes) and that Remote Play is on.")
                linkErr = true
            }
        }
        if regist == nil {
            linking = false
            linkMsg = L("The PS5 refused: check the PIN (it changes every few minutes) and that Remote Play is on.")
            linkErr = true
        }
    }

    // ---- linked

    private func linked(_ c: PsConsole) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                HStack(spacing: 12) {
                    IconTile(name: Icon.source, color: k.ok, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(k.font(k.base + 1.5, .bold)).foregroundColor(k.text)
                        Text("✓ " + L("Linked") + " · " + c.host).font(k.font(k.base - 1, .bold)).foregroundColor(k.ok)
                    }
                }
                Muted(L("Start translating connects to it with Remote Play. If it is in rest mode, Wake turns it on."), small: true).padding(.top, 10)
                HStack(spacing: 8) {
                    KButton(L("Wake the PS5")) {
                        Ps5.wakeup(c)
                        toast = L("Waking {name}…", ("name", c.name))
                    }
                    KButton(L("Unlink"), danger: true) { askUnlink = true }
                }
                .padding(.top, 12)
            }
            .padding(.top, 12)
            Field(label: L("Stream quality"), help: L("1080p reads small text best; 720p for a slower home network.")) {
                Select(options: [("1080", "1080p"), ("720", "720p")], value: String(resolution)) { v in
                    resolution = Int(v) ?? 720
                    Prefs.psResolution = resolution
                }
            }
        }
        .confirmationDialog(L("Unlink {name}? To use it again, link it with a new PIN.", ("name", c.name)), isPresented: $askUnlink, titleVisibility: .visible) {
            Button(L("Unlink"), role: .destructive) {
                Ps5.saved = nil
                saved = nil
                pin = ""
                linkMsg = ""
                m.rev += 1
                search()
            }
        }
    }
}

/**
 * Sony's sign-in in a browser instead of in the app (its bot check sometimes refuses the app's):
 * the browser ends on remoteplay.dl.playstation.net/remoteplay/redirect?code=…; that address pasted
 * here gives the account ID (the code is used once, within a few minutes).
 */
struct BrowserSignIn: View {
    @Environment(\.kit) var k
    @Environment(\.openURL) var openURL
    @Environment(\.dismiss) var dismiss
    let done: (String) -> Void
    @State private var pasted = ""
    @State private var msg = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Sign in with a browser")).font(k.font(k.base + 1, .bold)).foregroundColor(k.text)
                Muted(L("1. Open Sony's sign-in in a browser (on this phone or a PC) and sign in with your second PSN account."), small: true)
                HStack(spacing: 8) {
                    KButton(L("Open in the browser")) { if let u = URL(string: Psn.loginUrl) { openURL(u) } }
                    KButton(L("Copy the link")) {
                        UIPasteboard.general.string = Psn.loginUrl
                        msg = L("Copied.")
                    }
                }
                Muted(L("2. It ends on a page whose address starts with https://remoteplay.dl.playstation.net (the page itself may be blank). Copy that address and paste it here:"), small: true)
                KInput(value: pasted, placeholder: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=…", ltr: true) { pasted = $0 }
                if !msg.isEmpty { Muted(msg, small: true) }
                KButton(L("Get the account ID"), primary: true) { get() }.disabled(busy)
                KButton(L("Cancel")) { dismiss() }
            }
            .sheetCard(k)
        }
        .background(k.bg.ignoresSafeArea())
    }

    private func get() {
        guard let code = Psn.code(in: pasted.trimmingCharacters(in: .whitespaces)) else {
            msg = L("That address has no sign-in code: copy the whole address of the page you ended on.")
            return
        }
        busy = true
        msg = L("Getting the account ID…")
        Task { @MainActor in
            do {
                done(try await Psn.accountId(code: code))
            } catch {
                msg = L("PSN sign-in didn't work: {e}", ("e", error.localizedDescription)) + "\n" + L("The code works once and only for a few minutes: sign in again and paste the new address.")
            }
            busy = false
        }
    }
}
