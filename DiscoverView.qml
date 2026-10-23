import QtQuick
import Quickshell.Widgets
import qs.Common
import qs.Widgets

// Adding wallpapers: a Wallhaven search (SFW only). Picking one opens the
// controls; downloading puts the file in the folder and, if asked, uses and
// favorites it right away.
FocusScope {
    id: view

    required property var hub

    readonly property string api: "https://wallhaven.cc/api/v1"
    readonly property int detailW: 440

    property string query: ""
    property string categories: "111"
    property string sorting: "toplist"
    property string atleast: "1920x1080"
    property int page: 1
    property int lastPage: 1
    property int total: -1
    property string seed: ""
    property bool loading: false
    property string errorText: ""
    property int serial: 0
    property bool loaded: false

    ListModel {
        id: results
    }

    readonly property var selected: (grid.currentIndex >= 0 && grid.currentIndex < results.count) ? results.get(grid.currentIndex) : null
    readonly property bool selectedInLibrary: !!selected && !!hub.nameSet[selected.fileName]
    readonly property bool selectedBusy: !!selected && !!hub.downloading[selected.wid]
    readonly property bool selectedIsFavorite: !!selected && !!hub.favoriteSet[selected.fileName]

    // Details of the selected one (tags, uploader), fetched on demand.
    property string detailFor: ""
    property var detail: ({})

    // The preview: the selected wallpaper at full size, before downloading.
    property bool previewing: false
    property bool previewFill: false
    readonly property var previewSize: {
        const m = /^(\d+)x(\d+)$/.exec(selected ? selected.resolution : "");
        return m ? {
            w: Number(m[1]),
            h: Number(m[2])
        } : {
            w: 16,
            h: 9
        };
    }

    function focusGrid() {
        previewing = false;
        grid.forceActiveFocus();
    }

    function openPreview() {
        if (!selected)
            return;
        previewing = true;
        preview.forceActiveFocus();
    }

    function closePreview() {
        previewing = false;
        grid.forceActiveFocus();
    }

    function step(delta) {
        const i = Math.max(0, Math.min(results.count - 1, grid.currentIndex + delta));
        if (i !== grid.currentIndex) {
            grid.currentIndex = i;
            grid.positionViewAtIndex(i, GridView.Contain);
        }
    }

    // Enter, F and D do the same in the grid and in the preview.
    function act(key) {
        if (!selected)
            return false;
        if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            if (selectedInLibrary)
                hub.apply(selected.fileName);
            else
                downloadSelected(true, false);
        } else if (key === Qt.Key_F) {
            if (selectedInLibrary)
                hub.toggleFavorite(selected.fileName);
            else
                downloadSelected(true, true);
        } else if (key === Qt.Key_D) {
            downloadSelected(false, false);
        } else {
            return false;
        }
        return true;
    }

    function enter() {
        if (!loaded)
            search();
    }

    function leave() {
        hub.showLibrary();
    }

    function url(pageNumber) {
        const p = [];
        p.push("categories=" + categories);
        p.push("purity=100");
        p.push("sorting=" + sorting);
        if (query.trim() !== "")
            p.push("q=" + encodeURIComponent(query.trim()));
        if (atleast !== "")
            p.push("atleast=" + atleast);
        if (sorting === "toplist")
            p.push("topRange=1M");
        p.push("order=desc");
        p.push("page=" + pageNumber);
        if (sorting === "random" && seed !== "" && pageNumber > 1)
            p.push("seed=" + seed);
        return api + "/search?" + p.join("&");
    }

    // `dms dl` puts its error on stdout (see hub.fetch): "HTTP 429" is
    // Wallhaven's limit of 45 requests a minute.
    function explain(out) {
        const http = /HTTP (\d+)/.exec(String(out));
        if (http && http[1] === "429")
            return I18n.trFor("wallhavenCarousel", "Wallhaven is rate limiting searches. Wait a minute.");
        if (http)
            return I18n.trFor("wallhavenCarousel", "Wallhaven answered with an error (HTTP %1).").arg(http[1]);
        return I18n.trFor("wallhavenCarousel", "No connection to Wallhaven.");
    }

    function search() {
        const mine = ++serial;
        page = 1;
        lastPage = 1;
        loading = true;
        errorText = "";
        loaded = true;
        results.clear();
        grid.currentIndex = -1;
        Proc.runCommand("wallhavenCarousel.search", hub.fetch(url(1)), (out, code) => {
            if (mine !== view.serial)
                return;
            view.loading = false;
            if (code !== 0) {
                view.errorText = view.explain(out);
                return;
            }
            view.take(out);
            if (results.count > 0)
                grid.currentIndex = 0;
        }, 0, 40000, view);
    }

    function loadMore() {
        if (loading || page >= lastPage || results.count === 0)
            return;
        const mine = ++serial;
        const next = page + 1;
        loading = true;
        errorText = "";
        Proc.runCommand("wallhavenCarousel.search", hub.fetch(url(next)), (out, code) => {
            if (mine !== view.serial)
                return;
            view.loading = false;
            if (code !== 0) {
                view.errorText = view.explain(out);
                return;
            }
            view.page = next;
            view.take(out);
        }, 0, 40000, view);
    }

    function take(text) {
        let js;
        try {
            js = JSON.parse(text);
        } catch (e) {
            errorText = I18n.trFor("wallhavenCarousel", "Wallhaven sent an answer that isn't JSON.");
            return;
        }
        if (!js.data) {
            errorText = js.error ? String(js.error) : I18n.trFor("wallhavenCarousel", "Wallhaven sent an unexpected answer.");
            return;
        }
        if (js.meta) {
            lastPage = js.meta.last_page || 1;
            total = js.meta.total !== undefined ? js.meta.total : -1;
            if (js.meta.seed)
                seed = js.meta.seed;
        }
        for (const it of js.data) {
            const ext = String(it.path).split(".").pop();
            results.append({
                wid: String(it.id),
                thumb: String((it.thumbs && (it.thumbs.large || it.thumbs.small)) || it.path),
                // "large" is always cropped to 16:9; "original" keeps the shape.
                shape: String((it.thumbs && it.thumbs.original) || it.path),
                full: String(it.path),
                resolution: String(it.resolution || ""),
                size: Number(it.file_size || 0),
                category: String(it.category || ""),
                colors: (it.colors || []).join(","),
                views: Number(it.views || 0),
                favs: Number(it.favorites || 0),
                fileName: "wallhaven-" + it.id + "." + ext
            });
        }
    }

    function fetchDetail(wid) {
        if (detailFor === wid)
            return;
        detailFor = wid;
        detail = ({});
        Proc.runCommand("wallhavenCarousel.detail", hub.fetch(api + "/w/" + wid), (out, code) => {
            if (code !== 0 || view.detailFor !== wid)
                return;
            try {
                const d = JSON.parse(out).data;
                view.detail = {
                    tags: (d.tags || []).map(t => t.name),
                    uploader: d.uploader ? d.uploader.username : ""
                };
            } catch (e) {}
        }, 250, 30000, view);
    }

    onSelectedChanged: {
        if (selected)
            fetchDetail(selected.wid);
        else if (previewing)
            closePreview();
        prefetchAround();
    }

    onPreviewingChanged: prefetchAround()

    // ── Preview cache ─────────────────────────────────────────────────────
    // The preview's originals go to hub.previewDir with `dms dl` and stay 30
    // minutes. The one on screen and its neighbors are fetched ahead, and the
    // neighbors decoded too, so stepping through doesn't wait.
    readonly property int cacheMinutes: 30
    property var cachedFull: ({}) // wid -> time it was fetched
    property var fetchingFull: ({}) // wid -> true
    property var failedFull: ({}) // wid -> true, until the next try
    property real fullProgress: 0

    function cachedPath(it) {
        return hub.previewDir + "/" + it.fileName;
    }

    // A few minutes short of the prune, so a file is never used as it goes.
    function isCached(wid) {
        const t = cachedFull[wid];
        return !!t && Date.now() - t < (cacheMinutes - 5) * 60000;
    }

    function fullSource(it) {
        return it && isCached(it.wid) ? "file://" + cachedPath(it) : "";
    }

    // The width the original is decoded at: the same for the picture and the
    // neighbors, so they share one decoded copy.
    function decodeWidth(resolution) {
        const m = /^(\d+)x/.exec(resolution || "");
        const w = Math.round(preview.width * 2);
        return m ? Math.min(Number(m[1]), w) : w;
    }

    function prefetchAround() {
        if (!previewing || grid.currentIndex < 0)
            return;
        for (const d of [0, 1, -1])
            fetchFull(grid.currentIndex + d);
    }

    function fetchFull(i) {
        if (i < 0 || i >= results.count)
            return;
        const it = results.get(i);
        const wid = it.wid;
        if (isCached(wid) || fetchingFull[wid])
            return;
        fetchingFull = Object.assign({}, fetchingFull, {
            [wid]: true
        });
        if (failedFull[wid]) {
            const g = Object.assign({}, failedFull);
            delete g[wid];
            failedFull = g;
        }
        // Prunes what's older than the limit, reuses a file still there, and
        // otherwise downloads to .part and renames.
        const script = 'd="$(dirname "$1")"; mkdir -p "$d" || exit 1; find "$d" -type f -mmin +"$4" -delete 2>/dev/null; [ -s "$1" ] && exit 0; for i in 1 2; do dms dl --connect-timeout 10 --timeout 180 --user-agent "$3" -o "$1.part" "$2" >/dev/null 2>&1 && exec mv "$1.part" "$1"; sleep 1; done; rm -f "$1.part"; exit 1';
        Proc.runCommand("wallhavenCarousel.preview." + wid, ["sh", "-c", script, "sh", cachedPath(it), it.full, hub.userAgent, String(cacheMinutes)], (out, code) => {
            const f = Object.assign({}, view.fetchingFull);
            delete f[wid];
            view.fetchingFull = f;
            if (code === 0)
                view.cachedFull = Object.assign({}, view.cachedFull, {
                    [wid]: Date.now()
                });
            else
                view.failedFull = Object.assign({}, view.failedFull, {
                    [wid]: true
                });
        }, 0, 400000, view);
    }

    readonly property bool selectedFetching: !!selected && !!fetchingFull[selected.wid]

    onSelectedFetchingChanged: fullProgress = 0

    // `dms dl` has no progress of its own: the .part file's size against the
    // size Wallhaven reported.
    Timer {
        interval: 250
        repeat: true
        running: view.previewing && view.selectedFetching
        onTriggered: {
            const wid = view.selected.wid;
            const size = view.selected.size;
            Proc.runCommand("wallhavenCarousel.previewProgress", ["sh", "-c", 'stat -c %s "$1.part" 2>/dev/null || echo 0', "sh", view.cachedPath(view.selected)], (out, code) => {
                if (view.selected && view.selected.wid === wid && size > 0)
                    view.fullProgress = Math.min(1, Number(String(out).trim()) / size);
            }, 0, 5000, view);
        }
    }

    function item() {
        return {
            wid: selected.wid,
            full: selected.full,
            fileName: selected.fileName
        };
    }

    function downloadSelected(thenApply, thenFavorite) {
        if (selected)
            hub.download(item(), thenApply, thenFavorite);
    }

    function megabytes(b) {
        return (b / 1048576).toFixed(1) + " MB";
    }

    function toggleCategory(i) {
        const c = categories.split("");
        c[i] = c[i] === "1" ? "0" : "1";
        if (c.join("") === "000")
            return;
        categories = c.join("");
        search();
    }

    // ── Header: back, search and filters ──────────────────────────────────
    Item {
        id: head
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.spacingL * 2
        height: 112

        MouseArea {
            anchors.fill: parent
        }

        PillButton {
            id: back
            icon: "arrow_back"
            label: I18n.trFor("wallhavenCarousel", "Library")
            hint: "Esc"
            onClicked: view.leave()
        }

        StyledText {
            anchors.left: back.right
            anchors.leftMargin: Theme.spacingL
            anchors.verticalCenter: back.verticalCenter
            text: "Wallhaven"
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeXLarge
            font.weight: Font.Bold
        }

        SearchPill {
            id: searchBox
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: back.verticalCenter
            width: 420
            placeholder: I18n.trFor("wallhavenCarousel", "Search Wallhaven (Enter)")
            text: view.query
            onAccepted: {
                view.query = text;
                view.search();
                grid.forceActiveFocus();
            }
            onEscaped: grid.forceActiveFocus()
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: back.verticalCenter
            spacing: Theme.spacingM

            PillButton {
                icon: "close"
                onClicked: view.hub.close()
            }
        }

        Flow {
            id: filters
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Theme.spacingS

            Repeater {
                model: [
                    {
                        label: I18n.trFor("wallhavenCarousel", "General"),
                        i: 0
                    },
                    {
                        label: I18n.trFor("wallhavenCarousel", "Anime"),
                        i: 1
                    },
                    {
                        label: I18n.trFor("wallhavenCarousel", "People"),
                        i: 2
                    }
                ]
                delegate: PillButton {
                    required property var modelData
                    implicitHeight: Theme.iconSize + Theme.spacingS
                    label: modelData.label
                    active: view.categories[modelData.i] === "1"
                    onClicked: view.toggleCategory(modelData.i)
                }
            }

            Item {
                width: Theme.spacingL
                height: 1
            }

            Repeater {
                model: [
                    {
                        label: I18n.trFor("wallhavenCarousel", "Top this month"),
                        v: "toplist"
                    },
                    {
                        label: I18n.trFor("wallhavenCarousel", "Latest"),
                        v: "date_added"
                    },
                    {
                        label: I18n.trFor("wallhavenCarousel", "Most viewed"),
                        v: "views"
                    },
                    {
                        label: I18n.trFor("wallhavenCarousel", "Most favorited"),
                        v: "favorites"
                    },
                    {
                        label: I18n.trFor("wallhavenCarousel", "Relevance"),
                        v: "relevance"
                    },
                    {
                        label: I18n.trFor("wallhavenCarousel", "Random"),
                        v: "random"
                    }
                ]
                delegate: PillButton {
                    required property var modelData
                    implicitHeight: Theme.iconSize + Theme.spacingS
                    label: modelData.label
                    active: view.sorting === modelData.v
                    onClicked: {
                        view.sorting = modelData.v;
                        view.search();
                    }
                }
            }

            Item {
                width: Theme.spacingL
                height: 1
            }

            Repeater {
                model: [
                    {
                        label: I18n.trFor("wallhavenCarousel", "Any size"),
                        v: ""
                    },
                    {
                        label: "1080p+",
                        v: "1920x1080"
                    },
                    {
                        label: "1440p+",
                        v: "2560x1440"
                    },
                    {
                        label: "4K+",
                        v: "3840x2160"
                    }
                ]
                delegate: PillButton {
                    required property var modelData
                    implicitHeight: Theme.iconSize + Theme.spacingS
                    label: modelData.label
                    active: view.atleast === modelData.v
                    onClicked: {
                        view.atleast = modelData.v;
                        view.search();
                    }
                }
            }
        }
    }

    // ── Results grid ──────────────────────────────────────────────────────
    DankGridView {
        id: grid
        anchors.top: head.bottom
        anchors.topMargin: Theme.spacingL
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.spacingL * 2
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingL * 2
        anchors.right: detailPanel.left
        anchors.rightMargin: Theme.spacingXL
        clip: true
        focus: true
        model: results
        cacheBuffer: 600
        keyNavigationEnabled: true
        highlightMoveDuration: 0

        footer: Item {
            width: grid.width
            height: view.page < view.lastPage || view.errorText !== "" ? more.implicitHeight + Theme.spacingXL * 2 : Theme.spacingXL

            Column {
                id: more
                visible: view.page < view.lastPage || view.errorText !== ""
                anchors.centerIn: parent
                spacing: Theme.spacingS

                StyledText {
                    visible: view.errorText !== "" && results.count > 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: view.errorText
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                }
                PillButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    icon: view.errorText !== "" ? "refresh" : "expand_more"
                    label: view.loading ? I18n.trFor("wallhavenCarousel", "Loading…") : view.errorText !== "" ? I18n.trFor("wallhavenCarousel", "Try again") : I18n.trFor("wallhavenCarousel", "Load more")
                    busy: view.loading
                    onClicked: view.loadMore()
                }
            }
        }

        readonly property int cols: Math.max(1, Math.round(width / 230))
        cellWidth: Math.floor(width / cols)
        cellHeight: Math.round(cellWidth * 0.62)

        Keys.onPressed: event => {
            if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                return;
            event.accepted = true;
            switch (event.key) {
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_F:
            case Qt.Key_D:
                view.act(event.key);
                break;
            case Qt.Key_Space:
                view.openPreview();
                break;
            case Qt.Key_Slash:
                searchBox.focusInput();
                break;
            case Qt.Key_Escape:
                view.leave();
                break;
            default:
                event.accepted = false;
            }
        }

        delegate: Item {
            id: cell

            required property int index
            required property string wid
            required property string thumb
            required property string resolution
            required property string fileName

            width: grid.cellWidth
            height: grid.cellHeight

            readonly property bool current: GridView.isCurrentItem
            readonly property bool inLibrary: !!view.hub.nameSet[fileName]
            readonly property bool busy: !!view.hub.downloading[wid]
            readonly property bool fav: !!view.hub.favoriteSet[fileName]

            ClippingRectangle {
                anchors.fill: parent
                anchors.margins: Theme.spacingXS
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer
                border.width: cell.current ? 3 : 0
                border.color: Theme.primary

                Image {
                    anchors.fill: parent
                    source: cell.thumb
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    opacity: cell.busy ? 0.5 : 1
                }

                // Chips drawn on the picture stay dark with light text on every theme,
                // so they read over any wallpaper.
                Rectangle {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingS
                    height: Theme.iconSize - 2
                    width: resLabel.implicitWidth + Theme.spacingL
                    radius: height / 2
                    color: Qt.rgba(0, 0, 0, 0.6)

                    StyledText {
                        id: resLabel
                        anchors.centerIn: parent
                        text: cell.resolution
                        color: "#F2F2F2"
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingS

                    Rectangle {
                        visible: cell.fav
                        width: Theme.iconSize
                        height: Theme.iconSize
                        radius: height / 2
                        color: Theme.primary
                        DankIcon {
                            anchors.centerIn: parent
                            name: "star"
                            filled: true
                            size: Theme.iconSizeSmall
                            color: Theme.onPrimary
                        }
                    }
                    Rectangle {
                        visible: cell.inLibrary || cell.busy
                        width: Theme.iconSize
                        height: Theme.iconSize
                        radius: height / 2
                        color: Qt.rgba(0, 0, 0, 0.6)
                        DankIcon {
                            anchors.centerIn: parent
                            name: cell.busy ? "downloading" : "check_circle"
                            size: Theme.iconSize - 6
                            color: "#F2F2F2"
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        grid.currentIndex = cell.index;
                        grid.forceActiveFocus();
                    }
                    onDoubleClicked: {
                        grid.currentIndex = cell.index;
                        view.openPreview();
                    }
                }
            }
        }
    }

    StyledText {
        anchors.centerIn: grid
        visible: results.count === 0
        color: Theme.surfaceText
        opacity: 0.7
        font.pixelSize: Theme.fontSizeLarge
        horizontalAlignment: Text.AlignHCenter
        width: grid.width - Theme.spacingXL * 2
        wrapMode: Text.WordWrap
        text: view.errorText !== "" ? view.errorText : view.loading ? I18n.trFor("wallhavenCarousel", "Searching…") : I18n.trFor("wallhavenCarousel", "Nothing found.")
    }

    // ── Panel of the selected wallpaper ───────────────────────────────────
    Rectangle {
        id: detailPanel
        anchors.top: head.bottom
        anchors.topMargin: Theme.spacingL
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.spacingL * 2
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingL * 2
        width: view.detailW
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceText, 0.06)

        MouseArea {
            anchors.fill: parent
        }

        Column {
            visible: view.selected !== null
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            ClippingRectangle {
                width: parent.width
                height: Math.round(width * 0.62)
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer

                Image {
                    anchors.fill: parent
                    source: view.selected ? view.selected.thumb : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }

                // On the picture, so dark with light text on every theme.
                Rectangle {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingM
                    width: Theme.iconSize + Theme.spacingM
                    height: Theme.iconSize + Theme.spacingM
                    radius: height / 2
                    color: Qt.rgba(0, 0, 0, 0.6)
                    opacity: thumbMouse.containsMouse ? 1 : 0.7

                    DankIcon {
                        anchors.centerIn: parent
                        name: "open_in_full"
                        size: Theme.iconSize - 4
                        color: "#F2F2F2"
                    }
                }

                MouseArea {
                    id: thumbMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.openPreview()
                }
            }

            StyledText {
                width: parent.width
                text: view.selected ? view.selected.resolution + "  ·  " + view.megabytes(view.selected.size) + "  ·  " + view.selected.category : ""
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
            }

            StyledText {
                width: parent.width
                text: view.selected ? I18n.trFor("wallhavenCarousel", "%1 views  ·  %2 favorites on Wallhaven").arg(view.selected.views).arg(view.selected.favs) : ""
                color: Theme.surfaceText
                opacity: 0.6
                font.pixelSize: Theme.fontSizeSmall
            }

            Row {
                spacing: Theme.spacingS
                Repeater {
                    model: view.selected && view.selected.colors !== "" ? view.selected.colors.split(",") : []
                    delegate: Rectangle {
                        required property string modelData
                        width: Theme.iconSize - 2
                        height: Theme.iconSize - 2
                        radius: height / 2
                        color: modelData
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.surfaceText, 0.25)
                    }
                }
            }

            Flow {
                width: parent.width
                spacing: Theme.spacingS
                Repeater {
                    model: view.detailFor === (view.selected ? view.selected.wid : "") && view.detail.tags ? view.detail.tags.slice(0, 12) : []
                    delegate: Rectangle {
                        required property string modelData
                        height: Theme.iconSize
                        width: tagLabel.implicitWidth + Theme.spacingL
                        radius: height / 2
                        color: Theme.withAlpha(Theme.surfaceText, 0.10)
                        StyledText {
                            id: tagLabel
                            anchors.centerIn: parent
                            text: modelData
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }
                }
            }

            Item {
                width: 1
                height: Theme.spacingXS
            }

            PillButton {
                width: parent.width
                icon: "open_in_full"
                label: I18n.trFor("wallhavenCarousel", "View larger")
                hint: I18n.trFor("wallhavenCarousel", "Space")
                onClicked: view.openPreview()
            }

            // Not in the folder yet: download.
            Column {
                visible: !view.selectedInLibrary
                width: parent.width
                spacing: Theme.spacingM

                PillButton {
                    width: parent.width
                    icon: "download"
                    label: view.selectedBusy ? I18n.trFor("wallhavenCarousel", "Downloading…") : I18n.trFor("wallhavenCarousel", "Download and use")
                    hint: "Enter"
                    active: true
                    busy: view.selectedBusy
                    onClicked: view.downloadSelected(true, false)
                }
                PillButton {
                    width: parent.width
                    icon: "star"
                    label: I18n.trFor("wallhavenCarousel", "Download, use and favorite")
                    hint: "F"
                    busy: view.selectedBusy
                    onClicked: view.downloadSelected(true, true)
                }
                PillButton {
                    width: parent.width
                    icon: "download"
                    label: I18n.trFor("wallhavenCarousel", "Download only")
                    hint: "D"
                    busy: view.selectedBusy
                    onClicked: view.downloadSelected(false, false)
                }
            }

            // Already in the folder: use or favorite.
            Column {
                visible: view.selectedInLibrary
                width: parent.width
                spacing: Theme.spacingM

                StyledText {
                    text: I18n.trFor("wallhavenCarousel", "Already in your folder.")
                    color: Theme.surfaceText
                    opacity: 0.7
                    font.pixelSize: Theme.fontSizeMedium
                }
                PillButton {
                    width: parent.width
                    icon: "wallpaper"
                    label: I18n.trFor("wallhavenCarousel", "Use")
                    hint: "Enter"
                    active: true
                    onClicked: view.hub.apply(view.selected.fileName)
                }
                PillButton {
                    width: parent.width
                    icon: "star"
                    filledIcon: view.selectedIsFavorite
                    label: view.selectedIsFavorite ? I18n.trFor("wallhavenCarousel", "Unfavorite") : I18n.trFor("wallhavenCarousel", "Favorite")
                    hint: "F"
                    onClicked: view.hub.toggleFavorite(view.selected.fileName)
                }
            }
        }

        StyledText {
            anchors.centerIn: parent
            visible: view.selected === null
            text: I18n.trFor("wallhavenCarousel", "Pick a wallpaper")
            color: Theme.surfaceText
            opacity: 0.5
            font.pixelSize: Theme.fontSizeMedium
        }
    }

    // ── Preview ───────────────────────────────────────────────────────────
    // A small copy shows at once and the original fades in over it. The
    // original is decoded once, at most twice the screen width; fit and fill
    // only resize the item, so switching never downloads it again.
    FocusScope {
        id: preview
        anchors.fill: parent
        visible: view.previewing
        z: 10

        Rectangle {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.background, 0.97)
        }

        // A click outside the picture and the buttons closes.
        MouseArea {
            anchors.fill: parent
            onClicked: view.closePreview()
        }

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => view.step(event.angleDelta.y + event.angleDelta.x > 0 ? -1 : 1)
        }

        Item {
            id: stage
            anchors.fill: parent
            anchors.topMargin: view.previewFill ? 0 : Theme.spacingL * 2
            anchors.leftMargin: view.previewFill ? 0 : Theme.spacingL * 2
            anchors.rightMargin: view.previewFill ? 0 : Theme.spacingL * 2
            anchors.bottomMargin: view.previewFill ? 0 : previewControls.height + Theme.spacingXL * 2
            clip: true

            Item {
                id: picture
                readonly property real aspect: view.previewSize.w / view.previewSize.h
                anchors.centerIn: parent
                width: view.previewFill ? Math.max(stage.width, stage.height * aspect) : Math.min(stage.width, stage.height * aspect)
                height: width / aspect

                Image {
                    anchors.fill: parent
                    source: view.previewing && view.selected ? view.selected.shape : ""
                    asynchronous: true
                    visible: full.status !== Image.Ready
                }

                // From the preview cache, once fetched; the small copy shows
                // until then.
                Image {
                    id: full
                    anchors.fill: parent
                    source: view.previewing ? view.fullSource(view.selected) : ""
                    sourceSize.width: view.decodeWidth(view.selected ? view.selected.resolution : "")
                    asynchronous: true
                    opacity: status === Image.Ready ? 1 : 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 180
                        }
                    }
                }

                // The neighbors, decoded ahead out of sight: same source and
                // size as the picture would use, so it picks up their copy.
                Repeater {
                    model: view.previewing ? [-1, 1] : []
                    delegate: Image {
                        required property int modelData
                        readonly property int at: grid.currentIndex + modelData
                        readonly property var it: at >= 0 && at < results.count ? results.get(at) : null
                        visible: false
                        source: view.fullSource(it)
                        sourceSize.width: view.decodeWidth(it ? it.resolution : "")
                        asynchronous: true
                    }
                }

                // A click on the picture switches between fit and fill.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.previewFill = !view.previewFill
                }
            }
        }

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            height: Theme.spacingXS
            width: parent.width * view.fullProgress
            color: Theme.primary
            visible: view.selectedFetching
        }

        // In fill mode the picture runs under the controls; this keeps them
        // readable.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 240
            visible: view.previewFill
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: "transparent"
                }
                GradientStop {
                    position: 1
                    color: Theme.withAlpha(Theme.background, 0.9)
                }
            }
        }

        Item {
            id: previewKeys
            focus: true

            Keys.onPressed: event => {
                if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                    return;
                event.accepted = true;
                switch (event.key) {
                case Qt.Key_Left:
                case Qt.Key_H:
                    view.step(-1);
                    break;
                case Qt.Key_Right:
                case Qt.Key_L:
                    view.step(1);
                    break;
                case Qt.Key_Tab:
                    view.previewFill = !view.previewFill;
                    break;
                case Qt.Key_Space:
                case Qt.Key_Escape:
                    view.closePreview();
                    break;
                default:
                    event.accepted = view.act(event.key);
                }
            }
        }

        Column {
            id: previewControls
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.spacingXL
            spacing: Theme.spacingM

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    if (!view.selected)
                        return "";
                    const info = view.selected.resolution + "  ·  " + view.megabytes(view.selected.size) + "  ·  " + view.selected.category;
                    if (view.selectedFetching)
                        return info + "  ·  " + I18n.trFor("wallhavenCarousel", "loading the full size… %1%").arg(Math.round(view.fullProgress * 100));
                    if (full.status === Image.Error || view.failedFull[view.selected.wid])
                        return info + "  ·  " + I18n.trFor("wallhavenCarousel", "couldn't load the full size");
                    return info;
                }
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingM

                PillButton {
                    visible: !view.selectedInLibrary
                    icon: "download"
                    label: view.selectedBusy ? I18n.trFor("wallhavenCarousel", "Downloading…") : I18n.trFor("wallhavenCarousel", "Download and use")
                    hint: "Enter"
                    active: true
                    busy: view.selectedBusy
                    onClicked: view.downloadSelected(true, false)
                }
                PillButton {
                    visible: !view.selectedInLibrary
                    icon: "star"
                    label: I18n.trFor("wallhavenCarousel", "Download, use and favorite")
                    hint: "F"
                    busy: view.selectedBusy
                    onClicked: view.downloadSelected(true, true)
                }
                PillButton {
                    visible: !view.selectedInLibrary
                    icon: "download"
                    label: I18n.trFor("wallhavenCarousel", "Download only")
                    hint: "D"
                    busy: view.selectedBusy
                    onClicked: view.downloadSelected(false, false)
                }
                PillButton {
                    visible: view.selectedInLibrary
                    icon: "wallpaper"
                    label: I18n.trFor("wallhavenCarousel", "Use")
                    hint: "Enter"
                    active: true
                    onClicked: view.hub.apply(view.selected.fileName)
                }
                PillButton {
                    visible: view.selectedInLibrary
                    icon: "star"
                    filledIcon: view.selectedIsFavorite
                    label: view.selectedIsFavorite ? I18n.trFor("wallhavenCarousel", "Unfavorite") : I18n.trFor("wallhavenCarousel", "Favorite")
                    hint: "F"
                    onClicked: view.hub.toggleFavorite(view.selected.fileName)
                }
                PillButton {
                    icon: view.previewFill ? "fit_screen" : "fullscreen"
                    label: I18n.trFor("wallhavenCarousel", "Fill the screen")
                    hint: "Tab"
                    active: view.previewFill
                    onClicked: view.previewFill = !view.previewFill
                }
                PillButton {
                    icon: "close"
                    hint: "Esc"
                    onClicked: view.closePreview()
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: I18n.trFor("wallhavenCarousel", "← → previous and next    Tab or a click on the picture: fit or fill    Esc close")
                color: Theme.surfaceText
                opacity: 0.45
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }
}
