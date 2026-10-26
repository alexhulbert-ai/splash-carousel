import QtQuick
import Quickshell
import qs.Common
import qs.Services
import "Rotation.js" as Rotation

Item {
    id: rotation
    required property var hub
    property var state: ({})
    property bool ready: false
    property bool busy: false
    property bool changingCycling: false
    property string session: ""
    property string error: ""
    property real retryAt: 0
    property real now: Date.now()
    property int generation: 0
    property string preparedStartup: ""
    readonly property bool active: hub.pluginData?.rotationEnabled ?? false
    readonly property string pool: hub.pluginData?.rotationPool || "saved"
    readonly property string cadence: hub.pluginData?.cadence || "session"
    readonly property real intervalMs: cadence === "weekly" ? 604800000 : cadence === "daily" ? 86400000 : cadence === "hourly" ? 3600000 : Rotation.interval(hub.pluginData?.intervalAmount || 1, hub.pluginData?.intervalUnit || "days")
    readonly property bool paused: SessionService.locked || SessionService.preparingForSleep || SettingsData.getPluginSettingsForPlugin("seaglassCanvas").preset?.name === "oled"
    readonly property var collections: (hub.pluginData?.collections || []).filter(item => item.enabled !== false)
    readonly property string context: JSON.stringify([pool, hub.folder, hub.pluginData?.blacklist, collections, active])
    readonly property string statusText: !active ? "Rotation off" : paused ? "Rotation paused" : busy ? "Choosing wallpaper…" : cadence === "session" ? "Changes each desktop session" : "Next change: " + new Date(state.nextAt || now).toLocaleString()

    function initialize() {
        state = hub.pluginService.loadPluginState(hub.pluginId, "rotation", {});
        hub.backend.call("session", {}, result => {
            ready = true;
            if (result.ok) {
                session = result.session;
                reconcile();
                check();
            } else {
                error = result.error;
            }
        });
    }

    function persist() {
        state = Object.assign({}, state);
        hub.pluginService.savePluginState(hub.pluginId, "rotation", state);
    }

    function reconcile() {
        if (!ready)
            return;
        if (active && SessionData.wallpaperCyclingEnabled) {
            hub.saveData("restoreCycling", true);
            changingCycling = true;
            SessionData.setWallpaperCyclingEnabled(false);
            changingCycling = false;
        } else if (!active && hub.pluginData?.restoreCycling) {
            hub.saveData("restoreCycling", false);
            changingCycling = true;
            SessionData.setWallpaperCyclingEnabled(true);
            changingCycling = false;
        }
    }

    function credentialsChanged() {
        state.sampleRetryAt = 0;
        retryAt = 0;
        persist();
        check();
    }

    function setEnabled(on) {
        hub.saveData("rotationEnabled", on);
        reconcile();
        if (on)
            check();
    }

    function record(item) {
        generation++;
        const bags = Object.assign({}, state.bags || {});
        for (const key of Object.keys(bags))
            bags[key] = Object.assign({}, bags[key], {remaining: bags[key].remaining.filter(id => id !== item.id)});
        state.bags = bags;
        state.recent = [{id: item.id, palette: item.palette || {}}].concat(state.recent || []).slice(0, 100);
        state.lastAt = Date.now();
        state.nextAt = state.lastAt + intervalMs;
        state.session = session;
        if (item.provider === "unsplash")
            state.currentRemote = item;
        persist();
    }

    function check() {
        now = Date.now();
        if (!ready || !active || paused || busy || now < retryAt || !session)
            return;
        if (Rotation.due(state, cadence, intervalMs, session, now))
            next(true);
        else
            prepareNext();
    }

    function prepareNext() {
        if (cadence !== "session" || Theme.currentTheme !== Theme.dynamic || Theme.workerRunning || SessionData.perMonitorWallpaper || SessionData.perModeWallpaper)
            return;
        const command = Theme._workerReproduceCommand();
        const key = JSON.stringify([hub.pluginData, hub.names, hub.currentPath, state.lastAt, command, SettingsData.getPluginSettingsForPlugin("seaglassCanvas")]);
        if (command && key !== preparedStartup)
            next(false, pool, {command: command, key: key});
    }

    function next(automatic, overridePool, startup) {
        if (!ready || busy || paused)
            return false;
        busy = true;
        error = "";
        const token = ++generation;
        const selectionContext = context;
        const valid = () => token === generation && context === selectionContext && !paused && (!automatic || active);
        const finish = message => {
            busy = false;
            if (message) {
                error = message;
                retryAt = Date.now() + 60000;
                if (!automatic && !startup)
                    ToastService.showInfo("Wallpaper Carousel", message);
            }
        };
        function use(items, key, remote, attempts) {
            if (!valid()) {
                finish();
                return;
            }
            const eligible = items.filter(item => !hub.blocked(item));
            const selection = Rotation.choose(eligible, state.bags?.[key], hub.currentItemId, state.recent || [], hub.pluginData?.colorVariety !== false);
            if (!selection.item) {
                finish("No other eligible wallpapers. Add images or adjust the blacklist.");
                return;
            }
            const item = selection.item;
            const apply = path => {
                if (!valid()) {
                    finish();
                    return;
                }
                const planned = Object.assign({}, state, {
                    bags: Object.assign({}, state.bags || {}, {[key]: selection.bag}),
                    sampleUsed: remote ? (state.sampleUsed || []).concat([item.id]) : state.sampleUsed
                });
                if (startup) {
                    hub.backend.call("prepare-startup", {
                        item: Object.assign({}, item, {path: path}),
                        rotation: planned,
                        lastAt: state.lastAt || 0,
                        intervalMs: intervalMs,
                        command: startup.command,
                        options: hub.pluginData
                    }, result => {
                        if (result.ok && valid())
                            preparedStartup = startup.key;
                        finish(result.ok ? "" : result.error);
                    });
                    return;
                }
                state = planned;
                hub.applyPath(path, Object.assign({}, item, {path: path}));
                finish();
            };
            if (!remote) {
                apply(item.path);
                return;
            }
            hub.backend.call("detail", {photoId: item.photoId}, result => {
                if (!valid()) {
                    finish();
                    return;
                }
                if (!result.ok) {
                    fallback(result.error);
                    return;
                }
                if (hub.blocked(result.item)) {
                    if (attempts >= 2) {
                        fallback("No matching collection photos passed the blacklist.");
                        return;
                    }
                    use(items.filter(other => other.id !== item.id), key, true, attempts + 1);
                    return;
                }
                Object.assign(item, result.item);
                hub.saveRemote(item, true, download => {
                    if (download.ok)
                        apply(download.path);
                    else if (valid())
                        fallback(download.error);
                    else
                        finish();
                });
            });
        };
        function saved(chosenPool) {
            const items = hub.names.filter(name => chosenPool !== "favorites" || hub.favoriteSet[name]).map(name => hub.localItem(name));
            use(items, chosenPool + ":" + hub.folder, false, 0);
        };
        function fallback(message) {
            error = message + " Using saved wallpapers.";
            state.sampleRetryAt = Date.now() + 3600000;
            persist();
            saved("saved");
        };
        if ((overridePool || pool) !== "collections") {
            saved(overridePool || pool);
            return true;
        }
        const signature = collections.map(item => item.collectionId).sort().join(",");
        const candidates = (state.samples || []).filter(item => !(state.sampleUsed || []).includes(item.id));
        if (state.sampleSignature === signature && now - (state.sampleAt || 0) < 86400000 && candidates.length) {
            use(candidates, "collections", true, 0);
        } else if (Date.now() < (state.sampleRetryAt || 0)) {
            saved("saved");
        } else {
            hub.backend.call("sample", {collections: collections.map(item => item.collectionId)}, result => {
                if (!valid()) {
                    finish();
                    return;
                }
                if (!result.ok) {
                    fallback(result.error);
                    return;
                }
                state.samples = result.items.map(item => Object.assign({}, item, {palette: Rotation.palette(item.colors)}));
                state.sampleAt = Date.now();
                state.sampleSignature = signature;
                state.sampleRetryAt = 0;
                state.sampleUsed = [];
                persist();
                if (state.samples.length)
                    use(state.samples, "collections", true, 0);
                else
                    fallback("These collections have no new eligible photos right now.");
            });
        }
        return true;
    }

    onActiveChanged: if (ready) { reconcile(); check(); }
    onPausedChanged: if (ready && !paused) check()
    onContextChanged: if (ready) {
        generation++;
        retryAt = 0;
        state.sampleRetryAt = 0;
    }
    onIntervalMsChanged: {
        if (ready && state.lastAt) {
            state.nextAt = state.lastAt + intervalMs;
            persist();
        }
    }

    Connections {
        target: SessionData
        function onWallpaperCyclingEnabledChanged() {
            if (rotation.ready && rotation.active && !rotation.changingCycling && SessionData.wallpaperCyclingEnabled) {
                rotation.hub.saveData("restoreCycling", false);
                rotation.setEnabled(false);
            }
        }
    }

    Timer {
        interval: 10000
        running: rotation.ready
        repeat: true
        onTriggered: rotation.check()
    }
}
