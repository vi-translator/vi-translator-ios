import Foundation

/**
 * The settings, as the desktop app keeps them (its config.json, held by the core), with the
 * desktop's rules for game profiles (ui/app.js), as the Android app's Cfg: the profile in use gives
 * `areas`, `style` and `profile_opts`; a built-in profile can't be changed ("Make a copy"); the
 * player's own profiles get every change written back (syncProfile). Changes are saved to the core
 * shortly after they're made, only the keys that changed. Main thread only.
 *
 * The JSON is kept as mutable Foundation containers (NSMutableDictionary / NSMutableArray), so a
 * nested object can be changed in place, as org.json's are on Android.
 */
final class Cfg {
    private(set) var c = NSMutableDictionary()
    private var dirty = Set<String>()
    private let core: CoreHost?
    private let io = DispatchQueue(label: "cfg-save")
    private var pending: DispatchWorkItem?

    /** told after a save (the header's "Saved ✓") */
    var saved: ((Bool) -> Void)?
    /** told after any change (the screens redraw) */
    var changed: (() -> Void)?

    init(core: CoreHost?) {
        self.core = core
    }

    /** Read the settings from the core (blocking: off the main thread). */
    func loadBlocking() -> NSMutableDictionary {
        guard let core else { return NSMutableDictionary() }
        return Cfg.parse(core.configJson())
    }

    func set(_ json: NSMutableDictionary) {
        c = json
        dirty.removeAll()
    }

    // ---- plain settings
    func str(_ k: String, _ def: String = "") -> String { (c[k] as? String) ?? def }

    func bool(_ k: String, _ def: Bool = false) -> Bool {
        if let n = c[k] as? NSNumber { return n.boolValue }
        return def
    }

    func num(_ k: String, _ def: Double = 0) -> Double {
        if let n = c[k] as? NSNumber { return n.doubleValue }
        return def
    }

    func put(_ k: String, _ v: Any?, now: Bool = false) {
        c[k] = v ?? NSNull()
        dirty.insert(k)
        save(now: now)
        changed?()
    }

    /** Something inside an object or array setting changed (its key is saved whole). */
    func touched(_ keys: String...) {
        dirty.formUnion(keys)
        if keys.contains(where: { ["areas", "style", "profile_opts"].contains($0) }) { syncProfile() }
        save()
        changed?()
    }

    func save(now: Bool = false) {
        pending?.cancel()
        if now {
            flush()
            return
        }
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard !dirty.isEmpty, let core else { return }
        let patch = NSMutableDictionary()
        for k in dirty { patch[k] = c[k] ?? NSNull() }
        dirty.removeAll()
        let s = Cfg.string(patch)
        io.async { [weak self] in
            var ok = true
            do {
                try core.updateConfig(s)
            } catch {
                NSLog("Cfg: save failed: \(error)")
                ok = false
            }
            DispatchQueue.main.async { self?.saved?(ok) }
        }
    }

    // ---- game profiles (the desktop's activeProfile, isBuiltin, locked...)
    func builtins() -> [NSMutableDictionary] { list("builtins") }
    func profiles() -> [NSMutableDictionary] { list("profiles") }
    func allProfiles() -> [NSMutableDictionary] { builtins() + profiles() }

    func activeProfile() -> NSMutableDictionary? {
        allProfiles().first { Cfg.s($0, "id") == str("profile") } ?? builtins().first
    }

    func isBuiltin(_ p: NSDictionary?) -> Bool {
        guard let p else { return false }
        return builtins().contains { Cfg.s($0, "id") == Cfg.s(p, "id") }
    }

    func locked() -> Bool { isBuiltin(activeProfile()) }

    func profileGame() -> String {
        let g = activeProfile().map { Cfg.s($0, "game") } ?? ""
        return g.isEmpty ? "gta6" : g
    }

    func gameName(_ g: String) -> String {
        builtins().first { Cfg.s($0, "id") == g }.map { Cfg.s($0, "name") } ?? g
    }

    func areas() -> NSMutableArray { child("areas", NSMutableArray()) }
    func style() -> NSMutableDictionary { child("style", NSMutableDictionary()) }
    func profileOpts() -> NSMutableDictionary { child("profile_opts", NSMutableDictionary()) }

    static let cover = "translation_cover"

    /** The look "Over the game's text" (a built-in profile's choice in Game profile; the desktop's AS.coverLook). */
    func coverLook() -> Bool { Cfg.b(profileOpts()["more"] as? NSDictionary, Cfg.cover) }

    func setCoverLook(_ on: Bool) {
        let o = profileOpts()
        let more = (o["more"] as? NSMutableDictionary) ?? { let d = NSMutableDictionary(); o["more"] = d; return d }()
        more[Cfg.cover] = on
        setShown(kind: "page", id: Cfg.cover, on: on)
        touched("profile_opts")
    }

    /** How an area's translation comes on screen (the core's AreaFx; the desktop's AS.fxOf), kept by area id
     *  for every profile, built-in ones too. */
    func fxOf(_ id: String) -> NSMutableDictionary {
        let f: NSMutableDictionary = ["cover_min": true, "cover_early": true, "fade_ms": 150]
        if let o = (c["area_fx"] as? NSDictionary)?[id] as? [AnyHashable: Any] { f.addEntries(from: o) }
        f["fade_ms"] = min(max(Int(Cfg.d(f, "fade_ms")), 0), 2000)
        let isBool: (String) -> Bool = { k in (f[k] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
        if !isBool("stack_up") { f["stack_up"] = id == "subtitles" }
        if !isBool("ride") { f["ride"] = id == "subtitles" || id == "instructions" }
        if !isBool("accent") { f["accent"] = id == "instructions" }
        if !isBool("reviewed_only") { f["reviewed_only"] = id == "instructions" }
        return f
    }

    func setFx(_ id: String, _ key: String, _ v: Any) {
        let all = child("area_fx", NSMutableDictionary())
        let f = fxOf(id)
        f[key] = v
        all[id] = f
        touched("area_fx")
    }

    func areaList() -> [NSMutableDictionary] { areas().compactMap { $0 as? NSMutableDictionary } }

    private func child<V: AnyObject>(_ k: String, _ make: @autoclosure () -> V) -> V {
        if let v = c[k] as? V { return v }
        let v = make()
        c[k] = v
        return v
    }

    /** One of the player's profiles is in use: keep it equal to what is being edited. */
    private func syncProfile() {
        guard let arr = c["profiles"] as? NSMutableArray else { return }
        for case let p as NSMutableDictionary in arr where Cfg.s(p, "id") == str("profile") {
            p["areas"] = Cfg.clone(areas())
            p["style"] = Cfg.clone(style())
            p["pages"] = Cfg.clone(profileOpts())
            dirty.insert("profiles")
        }
    }

    /** Use another profile: its areas, style and pages become the ones in use. */
    func useProfile(_ id: String) {
        syncProfile()
        guard let p = allProfiles().first(where: { Cfg.s($0, "id") == id }) else { return }
        c["profile"] = id
        c["areas"] = Cfg.clone(p["areas"] as? NSArray ?? NSArray())
        c["style"] = Cfg.clone(p["style"] as? NSDictionary ?? NSDictionary())
        c["profile_opts"] = Cfg.clone(p["pages"] as? NSDictionary ?? NSDictionary())
        dirty.formUnion(["profile", "areas", "style", "profile_opts"])
        save()
        changed?()
    }

    /** A copy of a profile (built-in or not) that the player can change; it is put in use. */
    func copyProfile(_ from: NSDictionary) {
        syncProfile()
        let id = "custom-" + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let arr = child("profiles", NSMutableArray())
        let p = NSMutableDictionary()
        p["id"] = id
        p["name"] = L("{name} (copy)", ("name", Cfg.s(from, "name")))
        p["game"] = Cfg.s(from, "game")
        p["areas"] = Cfg.clone(from["areas"] as? NSArray ?? NSArray())
        p["style"] = Cfg.clone(from["style"] as? NSDictionary ?? NSDictionary())
        p["pages"] = Cfg.clone(from["pages"] as? NSDictionary ?? NSDictionary())
        p["timing"] = Cfg.clone(from["timing"] as? NSDictionary ?? NSDictionary())
        arr.add(p)
        dirty.insert("profiles")
        useProfile(id)
    }

    func deleteProfile(_ p: NSDictionary) {
        guard let arr = c["profiles"] as? NSMutableArray else { return }
        let keep = NSMutableArray()
        for case let x as NSDictionary in arr where Cfg.s(x, "id") != Cfg.s(p, "id") { keep.add(x) }
        c["profiles"] = keep
        dirty.insert("profiles")
        let game = Cfg.s(p, "game")
        useProfile(builtins().contains { Cfg.s($0, "id") == game } ? game : "gta6")
    }

    func renameProfile(_ name: String) {
        guard let arr = c["profiles"] as? NSMutableArray else { return }
        for case let p as NSMutableDictionary in arr where Cfg.s(p, "id") == str("profile") { p["name"] = name }
        dirty.insert("profiles")
        save()
        changed?()
    }

    /** Show or hide a read area or a game page of the profile in use: the player's own choice, kept apart from the profile. */
    func setShown(kind: String, id: String, on: Bool) {
        let shown = child("shown", NSMutableDictionary())
        let prof = str("profile")
        let s = (shown[prof] as? NSMutableDictionary) ?? { let d = NSMutableDictionary(); shown[prof] = d; return d }()
        let key = kind == "area" ? "areas" : "pages"
        let part = (s[key] as? NSMutableDictionary) ?? { let d = NSMutableDictionary(); s[key] = d; return d }()
        part[id] = on
        dirty.insert("shown")
    }

    private func list(_ k: String) -> [NSMutableDictionary] {
        (c[k] as? NSArray)?.compactMap { $0 as? NSMutableDictionary } ?? []
    }

    // ---- JSON helpers (org.json's optString / optDouble / optBoolean)
    static func s(_ o: NSDictionary?, _ k: String, _ def: String = "") -> String {
        if let v = o?[k] as? String { return v }
        if let v = o?[k] as? NSNumber { return v.stringValue }
        return def
    }

    static func d(_ o: NSDictionary?, _ k: String, _ def: Double = 0) -> Double {
        if let v = o?[k] as? NSNumber { return v.doubleValue }
        if let v = o?[k] as? String, let x = Double(v) { return x }
        return def
    }

    static func b(_ o: NSDictionary?, _ k: String, _ def: Bool = false) -> Bool {
        if let v = o?[k] as? NSNumber { return v.boolValue }
        return def
    }

    static func has(_ o: NSDictionary?, _ k: String) -> Bool {
        guard let v = o?[k] else { return false }
        return !(v is NSNull)
    }

    static func parse(_ s: String) -> NSMutableDictionary {
        guard let data = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? NSMutableDictionary else {
            return NSMutableDictionary()
        }
        return o
    }

    static func string(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let data = try? JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func clone(_ o: NSDictionary) -> NSMutableDictionary {
        parse(string(o))
    }

    static func clone(_ a: NSArray) -> NSMutableArray {
        guard let data = try? JSONSerialization.data(withJSONObject: a),
              let r = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? NSMutableArray else {
            return NSMutableArray()
        }
        return r
    }

    /** the style an area uses: its own, or the profile's */
    static func styleOf(_ a: NSDictionary, _ profileStyle: NSMutableDictionary) -> NSMutableDictionary {
        (a["style"] as? NSMutableDictionary) ?? profileStyle
    }
}
