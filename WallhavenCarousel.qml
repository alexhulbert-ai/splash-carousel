import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Qt.labs.folderlistmodel
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Wallhaven Carousel: a carousel of the wallpaper folder, with favorites,
// Trash, color and tag filters, Wallhaven downloads and a shuffle among
// favorites only. DMS still owns the wallpaper (SessionData); this only
// picks which one.
PluginComponent {
    id: root

    property var popoutService: null

    readonly property string userAgent: "wallhavenCarousel/1.0"

    // ── Folder ────────────────────────────────────────────────────────────
    // One folder: the plugin's own setting, else DMS's cycling folder, else
    // the folder of the current wallpaper.
    function stripFile(p) {
        return String(p ?? "").replace(/^file:\/\//, "");
    }

    function expandHome(p) {
        return p.replace(/^~(?=\/|$)/, Quickshell.env("HOME") || "~");
    }

    readonly property string folder: {
        const own = expandHome(stripFile(pluginData?.folder).trim());
        if (own)
            return own.replace(/\/+$/, "");
        const cycling = stripFile(SessionData.wallpaperCyclingFolderPath).trim();
        if (cycling)
            return cycling.replace(/\/+$/, "");
        const current = stripFile(SessionData.wallpaperPath);
        if (current && !current.startsWith("#") && current.lastIndexOf("/") > 0)
            return current.substring(0, current.lastIndexOf("/"));
        return stripFile(Paths.pictures);
    }

    readonly property string currentPath: {
        const p = stripFile(SessionData.wallpaperPath);
        return p.startsWith("#") ? "" : p;
    }
    readonly property string currentName: currentPath.substring(currentPath.lastIndexOf("/") + 1)

    function urlFor(name) {
        return "file://" + folder + "/" + encodeURIComponent(name);
    }

    // ── Files in the folder ───────────────────────────────────────────────
    property var names: []
    property var nameSet: ({})

    FolderListModel {
        id: folderModel
        folder: "file://" + root.folder
        nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.gif", "*.bmp", "*.jxl", "*.avif", "*.heif"]
        caseSensitive: false
        showDirs: false
        sortField: FolderListModel.Name
        onCountChanged: scanTimer.restart()
        onStatusChanged: scanTimer.restart()
    }

    Timer {
        id: scanTimer
        interval: 60
        onTriggered: root.scan()
    }

    function scan() {
        const out = [];
        const set = {};
        for (let i = 0; i < folderModel.count; i++) {
            const n = folderModel.get(i, "fileName");
            out.push(n);
            set[n] = true;
        }
        if (out.join("\n") === names.join("\n"))
            return;
        names = out;
        nameSet = set;
        analyzeTimer.restart();
        tagTimer.restart();
    }

    // ── Favorites ─────────────────────────────────────────────────────────
    // Stored by file name in plugin_settings.json: there is only one folder.
    property var favorites: []
    readonly property var favoriteSet: {
        const s = {};
        for (const n of favorites)
            s[n] = true;
        return s;
    }
    readonly property int favoriteCount: {
        let c = 0;
        for (const n of names)
            if (favoriteSet[n])
                c++;
        return c;
    }

    function loadFavorites() {
        const v = pluginData?.favorites;
        const arr = v ? Array.from(v) : [];
        if (JSON.stringify(arr) !== JSON.stringify(favorites))
            favorites = arr;
    }

    onPluginDataChanged: {
        loadFavorites();
        loadTags();
    }

    function saveFavorites(arr) {
        favorites = arr;
        pluginService?.savePluginData(pluginId, "favorites", arr);
    }

    function setFavorite(name, on) {
        const has = !!favoriteSet[name];
        if (on === has)
            return;
        saveFavorites(on ? favorites.concat([name]) : favorites.filter(n => n !== name));
    }

    function toggleFavorite(name) {
        setFavorite(name, !favoriteSet[name]);
    }

    // ── Colors and tags (for the filters) ─────────────────────────────────
    // Colors come from the image itself (colors.py, cached in ~/.local/state);
    // tags come from Wallhaven, only for what was downloaded from there.
    property var colors: ({})
    property bool analyzing: false
    property bool analyzeAgain: false
    readonly property string colorCache: stripFile(Paths.state) + "/wallhavenCarousel/colors.json"

    Timer {
        id: analyzeTimer
        interval: 2000
        onTriggered: root.analyzeColors()
    }

    function analyzeColors() {
        const dir = pluginService ? pluginService.getPluginPath(pluginId) : "";
        if (!dir || names.length === 0)
            return;
        if (analyzing) {
            analyzeAgain = true;
            return;
        }
        analyzing = true;
        analyzeAgain = false;
        Proc.runCommand("wallhavenCarousel.colors", ["nice", "-n", "10", "python3", dir + "/colors.py", folder, colorCache], (out, code) => {
            root.analyzing = false;
            if (code === 0) {
                try {
                    root.colors = JSON.parse(out);
                } catch (e) {
                    console.warn("wallhavenCarousel: colors.py returned something that is not JSON");
                }
            }
            if (root.analyzeAgain)
                analyzeTimer.restart();
        }, 0, 600000, root);
    }

    property var tags: ({})

    function loadTags() {
        const v = pluginData?.tags;
        const t = v ? JSON.parse(JSON.stringify(v)) : {};
        if (JSON.stringify(t) !== JSON.stringify(tags))
            tags = t;
    }

    function setTags(name, list) {
        const t = Object.assign({}, tags);
        if (list === null)
            delete t[name];
        else
            t[name] = list;
        tags = t;
        saveData("tags", t);
    }

    property var tagQueue: []
    property bool tagBusy: false

    Timer {
        id: tagTimer
        interval: 3000
        onTriggered: root.queueTags()
    }

    Timer {
        id: tagNext
        interval: 1500
        onTriggered: root.nextTag()
    }

    // `dms dl` with its errors on stdout, the only stream Proc hands back,
    // so "HTTP 429" tells a rate limit from a dropped connection.
    function fetch(url) {
        return ["sh", "-c", 'exec dms dl --connect-timeout 10 --timeout 30 --user-agent "$1" "$2" 2>&1', "sh", userAgent, url];
    }

    // The name wallhaven-<id>.<ext> says where it came from; fetch the
    // missing tags.
    function queueTags() {
        const q = [];
        for (const n of names) {
            const m = /^wallhaven-([a-z0-9]+)\./i.exec(n);
            if (m && tags[n] === undefined)
                q.push({
                    name: n,
                    wid: m[1]
                });
        }
        tagQueue = q;
        nextTag();
    }

    function nextTag() {
        if (tagBusy || tagQueue.length === 0)
            return;
        tagBusy = true;
        const it = tagQueue[0];
        tagQueue = tagQueue.slice(1);
        Proc.runCommand("wallhavenCarousel.tags", fetch("https://wallhaven.cc/api/v1/w/" + it.wid), (out, code) => {
            root.tagBusy = false;
            if (code === 0) {
                try {
                    root.setTags(it.name, JSON.parse(out).data.tags.map(t => t.name).slice(0, 12));
                } catch (e) {}
            }
            tagNext.restart();
        }, 0, 40000, root);
    }

    // ── Apply, delete ─────────────────────────────────────────────────────
    function apply(name, screenName) {
        const path = folder + "/" + name;
        if (SessionData.perMonitorWallpaper) {
            if (screenName) {
                SessionData.setMonitorWallpaper(screenName, path);
            } else {
                for (const s of Quickshell.screens)
                    SessionData.setMonitorWallpaper(s.name, path);
            }
        } else {
            SessionData.setWallpaper(path);
        }
        restartDmsCycle();
    }

    property int _seq: 0

    // Goes to the Trash, never deleted for good. If it was the wallpaper in
    // use, `replacement` takes its place first.
    function deleteWallpaper(name, replacement) {
        if (name === currentName && replacement)
            apply(replacement);
        Proc.runCommand("wallhavenCarousel.trash." + (++_seq), ["sh", "-c", 'exec dms trash put "$1" 2>&1', "sh", folder + "/" + name], (out, code) => {
            if (code !== 0) {
                ToastService?.showError(I18n.trFor("wallhavenCarousel", "Couldn't move it to the Trash"), String(out));
                return;
            }
            setFavorite(name, false);
            if (tags[name] !== undefined)
                setTags(name, null);
            scanTimer.restart();
            ToastService?.showInfo(I18n.trFor("wallhavenCarousel", "Moved to the Trash: %1").arg(name));
        }, 0, 15000, root);
    }

    // ── Countdown of DMS's own wallpaper cycling ──────────────────────────
    // The DMS server keeps the schedule; this only reads its deadline
    // (wallpaper.getState). Picking a wallpaper by hand restarts the
    // interval: the server only resets the deadline when the schedule
    // changes, so cycling is turned off and back on with the same config.
    property real nextCycleAt: 0
    property real nowMs: Date.now()

    readonly property bool dmsCycleShown: SessionData.wallpaperCyclingEnabled && !SessionData.perMonitorWallpaper && nextCycleAt > 0
    readonly property string cycleCountdown: {
        if (!dmsCycleShown)
            return "";
        const seconds = Math.max(0, Math.ceil((nextCycleAt - nowMs) / 1000));
        const hours = Math.floor(seconds / 3600);
        const tail = String(Math.floor(seconds / 60) % 60).padStart(2, "0") + ":" + String(seconds % 60).padStart(2, "0");
        return I18n.trFor("wallhavenCarousel", "next change in %1").arg((hours ? hours + ":" : "") + tail);
    }

    function setNextCycle(iso) {
        nowMs = Date.now();
        nextCycleAt = iso ? Date.parse(iso) : 0;
    }

    function refreshDmsCycle() {
        if (!DMSService.capabilities.includes("wallpaper"))
            return;
        DMSService.sendRequest("wallpaper.getState", null, response => setNextCycle(response.result?.nextRotation));
    }

    function restartDmsCycle() {
        if (!SessionData.wallpaperCyclingEnabled || !DMSService.capabilities.includes("wallpaper"))
            return;
        const off = WallpaperCyclingService.buildServerConfig();
        off.global.enabled = false;
        DMSService.sendRequest("wallpaper.setConfig", {
            "config": off
        }, () => {
            WallpaperCyclingService.pushConfigToServer();
            refreshDmsCycle();
        });
    }

    Connections {
        target: DMSService
        function onWallpaperCycleUpdate(data) {
            root.setNextCycle(data?.nextRotation);
        }
    }

    Connections {
        target: SessionData
        function onWallpaperCyclingEnabledChanged() {
            root.refreshDmsCycle();
        }
        function onWallpaperCyclingIntervalChanged() {
            root.refreshDmsCycle();
        }
    }

    Timer {
        interval: 1000
        running: root.overlayVisible && root.dmsCycleShown
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    onOverlayVisibleChanged: {
        if (overlayVisible)
            refreshDmsCycle();
    }

    // ── Shuffle among favorites only ──────────────────────────────────────
    // DMS's timer cycles through every file in the folder. While this one is
    // on, DMS's is off (and comes back as it was when this is turned off).
    readonly property bool favoritesRandom: !!pluginData?.favoritesRandom
    readonly property int favoritesIntervalMin: parseInt(pluginData?.favoritesInterval) || 60
    property bool _changingCycling: false

    function saveData(key, value) {
        pluginService?.savePluginData(pluginId, key, value);
    }

    function setDmsCycling(on) {
        _changingCycling = true;
        SessionData.setWallpaperCyclingEnabled(on);
        _changingCycling = false;
    }

    function pickRandomFavorite() {
        const pool = favorites.filter(n => nameSet[n] && n !== currentName);
        if (pool.length === 0)
            return false;
        apply(pool[Math.floor(Math.random() * pool.length)]);
        return true;
    }

    function setFavoritesRandom(on) {
        if (on === favoritesRandom)
            return;
        if (on) {
            if (favoriteCount === 0) {
                ToastService?.showInfo(I18n.trFor("wallhavenCarousel", "Mark a few favorites first (F key)"));
                return;
            }
            if (SessionData.wallpaperCyclingEnabled) {
                saveData("restoreCycling", true);
                setDmsCycling(false);
            }
            saveData("favoritesRandom", true);
            pickRandomFavorite();
            ToastService?.showInfo(I18n.trFor("wallhavenCarousel", "Favorites shuffle on"));
        } else {
            saveData("favoritesRandom", false);
            if (pluginData?.restoreCycling) {
                saveData("restoreCycling", false);
                setDmsCycling(true);
            }
            ToastService?.showInfo(I18n.trFor("wallhavenCarousel", "Favorites shuffle off"));
        }
    }

    // If DMS's cycling is turned on from elsewhere, it wins: this turns off.
    Connections {
        target: SessionData
        function onWallpaperCyclingEnabledChanged() {
            if (root._changingCycling || !root.favoritesRandom || !SessionData.wallpaperCyclingEnabled)
                return;
            root.saveData("restoreCycling", false);
            root.saveData("favoritesRandom", false);
        }
    }

    Timer {
        interval: root.favoritesIntervalMin * 60000
        running: root.favoritesRandom && !SessionService.locked
        repeat: true
        onTriggered: root.pickRandomFavorite()
    }

    // ── Wallhaven downloads ───────────────────────────────────────────────
    // Originals fetched for the full-size preview, kept 30 minutes (see
    // DiscoverView.fetchFull); a download reuses them instead of fetching again.
    readonly property string previewDir: stripFile(Paths.cache) + "/wallhavenCarousel/preview"

    property var downloading: ({})

    signal downloaded(string name)

    // item: { wid, full, fileName }
    function download(item, thenApply, thenFavorite) {
        const name = item.fileName;
        const finish = () => {
            if (thenFavorite)
                setFavorite(name, true);
            if (thenApply)
                apply(name);
            downloaded(name);
        };
        if (nameSet[name]) {
            finish();
            return;
        }
        if (downloading[item.wid])
            return;
        downloading = Object.assign({}, downloading, {
            [item.wid]: true
        });
        const dest = folder + "/" + name;
        // Downloads to .part and only then renames, so the folder never shows
        // a half-written file. Three tries, for a flaky connection. An
        // original already fetched for the preview is copied instead.
        const script = 'mkdir -p "$(dirname "$1")" || exit 1; if [ -s "$4" ] && cp "$4" "$1.part"; then exec mv "$1.part" "$1"; fi; for i in 1 2 3; do dms dl --connect-timeout 10 --timeout 180 --user-agent "$3" -o "$1.part" "$2" >/dev/null 2>&1 && exec mv "$1.part" "$1"; sleep 2; done; rm -f "$1.part"; exit 1';
        Proc.runCommand("wallhavenCarousel.download." + item.wid, ["sh", "-c", script, "sh", dest, item.full, userAgent, previewDir + "/" + name], (out, code) => {
            const d = Object.assign({}, root.downloading);
            delete d[item.wid];
            root.downloading = d;
            if (code !== 0) {
                ToastService?.showError(I18n.trFor("wallhavenCarousel", "Download failed"), item.full);
                return;
            }
            scanTimer.restart();
            finish();
        }, 0, 600000, root);
    }

    // ── Overlay ───────────────────────────────────────────────────────────
    property string mode: "library"
    readonly property bool overlayVisible: overlay.visible

    function open(m) {
        mode = m || "library";
        const s = CompositorService.getFocusedScreen();
        if (s)
            overlay.screen = s;
        library.reset();
        overlay.visible = true;
        Qt.callLater(focusMode);
    }

    function close() {
        overlay.visible = false;
    }

    function toggle() {
        if (overlay.visible)
            close();
        else
            open("library");
    }

    function showLibrary() {
        mode = "library";
        Qt.callLater(focusMode);
    }

    function showDiscover() {
        mode = "discover";
        discover.enter();
        Qt.callLater(focusMode);
    }

    function focusMode() {
        if (mode === "discover")
            discover.focusGrid();
        else
            library.focusList();
    }

    IpcHandler {
        target: "wallhavenCarousel"

        function toggle(): string {
            root.toggle();
            return overlay.visible ? "opened" : "closed";
        }
        function open(): string {
            if (!overlay.visible)
                root.open("library");
            return "opened";
        }
        function discover(): string {
            if (!overlay.visible)
                root.open("discover");
            root.showDiscover();
            return "opened";
        }
        function close(): string {
            root.close();
            return "closed";
        }
        // Marks or unmarks the wallpaper in use.
        function favorite(): string {
            if (!root.currentName || !root.nameSet[root.currentName])
                return "no-current";
            root.toggleFavorite(root.currentName);
            return root.favoriteSet[root.currentName] ? "favorited" : "unfavorited";
        }
        // Switches now to a random favorite.
        function random(): string {
            return root.pickRandomFavorite() ? "changed" : "no-favorites";
        }
        // on, off or toggle.
        function favoritesRandom(mode: string): string {
            const on = mode === "toggle" ? !root.favoritesRandom : mode === "on";
            root.setFavoritesRandom(on);
            return root.favoritesRandom ? "on" : "off";
        }
    }

    PanelWindow {
        id: overlay
        visible: false
        color: "transparent"

        WlrLayershell.namespace: "dms:plugins:wallhavenCarousel"
        WlrLayershell.layer: WlrLayershell.Overlay
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        // The backdrop: the theme's background, nearly opaque.
        Rectangle {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.background, 0.94)
            opacity: overlay.visible ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: 150
                }
            }
        }

        // A click outside everything closes.
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        LibraryView {
            id: library
            anchors.fill: parent
            hub: root
            visible: root.mode === "library"
            screenName: overlay.screen ? overlay.screen.name : ""
        }

        DiscoverView {
            id: discover
            anchors.fill: parent
            hub: root
            visible: root.mode === "discover"
        }
    }

    Component.onCompleted: {
        loadFavorites();
        loadTags();
        scanTimer.restart();
        console.info("wallhavenCarousel: ready (dms ipc call wallhavenCarousel toggle)");
    }
}
