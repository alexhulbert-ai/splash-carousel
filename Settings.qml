import QtQuick
import QtQuick.Controls as Controls
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: settings
    pluginId: "wallhavenCarousel"
    property bool keyConfigured: false
    property bool keyBusy: false
    property bool collectionBusy: false
    property string message: ""
    property var sources: []
    property bool initialized: false

    function refresh() {
        sources = loadValue("collections", []);
        if (!blacklist.activeFocus)
            blacklist.text = loadValue("blacklist", "");
    }

    Backend {
        id: backend
        script: (settings.pluginService?.getPluginPath(settings.pluginId) || "") + "/wallpaper.py"
    }

    Component.onCompleted: {
        refresh();
        initialized = true;
        backend.call("key-status", {}, result => settings.keyConfigured = !!result.configured);
    }

    Connections {
        target: settings.pluginService
        function onPluginDataChanged(id) {
            if (id === settings.pluginId)
                settings.refresh();
        }
    }

    StyledText {
        width: parent.width
        text: "Wallpaper Carousel"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "rotationEnabled"
        label: "Automatic rotation"
        description: "Pauses while locked and while the OLED preset is active."
    }

    SelectionSetting {
        settingKey: "rotationPool"
        label: "Rotate from"
        options: [{label: "Saved wallpapers", value: "saved"}, {label: "Favorites", value: "favorites"}, {label: "Unsplash collections", value: "collections"}]
        defaultValue: "saved"
    }

    SelectionSetting {
        id: cadence
        settingKey: "cadence"
        label: "Change every"
        description: "A session is a desktop login. Restarting DMS does not count."
        options: [{label: "Desktop session", value: "session"}, {label: "Hour", value: "hourly"}, {label: "Day", value: "daily"}, {label: "7 days", value: "weekly"}, {label: "Custom interval", value: "interval"}]
        defaultValue: "session"
    }

    StringSetting {
        visible: cadence.value === "interval"
        settingKey: "intervalAmount"
        label: "Interval amount"
        description: "A positive number, from 1 to 36500."
        defaultValue: "1"
    }

    SelectionSetting {
        visible: cadence.value === "interval"
        settingKey: "intervalUnit"
        label: "Interval unit"
        options: [{label: "Minutes", value: "minutes"}, {label: "Hours", value: "hours"}, {label: "Days", value: "days"}]
        defaultValue: "days"
    }

    ToggleSetting {
        settingKey: "colorVariety"
        label: "Vary the colors"
        description: "Saved wallpapers get equal turns. Prefer different palettes within each round."
        defaultValue: true
    }

    StringSetting {
        settingKey: "folder"
        label: "Wallpaper folder"
        description: "Empty: DMS's cycling folder, or the folder of the current wallpaper."
        placeholder: "~/Pictures/Wallpapers"
    }

    StringSetting {
        settingKey: "apiKey"
        label: I18n.trFor("wallhavenCarousel", "Wallhaven API key")
        description: I18n.trFor("wallhavenCarousel", "Optional. Unlocks the Sketchy and NSFW filters. Get one at wallhaven.cc/settings/account. Stored in plain text.")
        placeholder: ""
    }

    StyledText {
        text: "Keyword blacklist"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeMedium
    }

    StyledText {
        width: parent.width
        text: "One word or phrase per line. Matches available filenames, descriptions, and tags. Saved matches stay accessible in the library."
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        font.pixelSize: Theme.fontSizeSmall
    }

    Controls.TextArea {
        id: blacklist
        width: parent.width
        implicitHeight: Math.max(110, contentHeight + 24)
        wrapMode: TextEdit.Wrap
        color: Theme.surfaceText
        placeholderText: "anime\ncars\ntext overlay"
        placeholderTextColor: Theme.surfaceVariantText
        selectByMouse: true
        padding: 12
        background: Rectangle {
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.color: blacklist.activeFocus ? Theme.primary : Theme.outline
        }
        onActiveFocusChanged: {
            if (!activeFocus && settings.initialized)
                settings.saveValue("blacklist", text.trim());
        }
    }

    StyledText {
        text: settings.keyConfigured ? "Unsplash access key configured" : "Unsplash access key"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeMedium
    }

    DankTextField {
        id: key
        width: parent.width
        placeholderText: settings.keyConfigured ? "Paste a replacement key" : "Paste your access key"
        echoMode: TextInput.Password
    }

    PillButton {
        label: "Save key"
        icon: "key"
        busy: settings.keyBusy
        onClicked: {
            settings.keyBusy = true;
            backend.call("key-save", {key: key.text}, result => {
                settings.keyBusy = false;
                if (result.ok) {
                    key.text = "";
                    settings.keyConfigured = true;
                    settings.pluginService?.pluginDaemonInstances?.wallhavenCarousel?.rotation.credentialsChanged();
                    settings.message = "Key saved.";
                } else {
                    settings.message = result.error;
                }
            });
        }
    }

    StyledText {
        text: "Collection sources"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeMedium
    }

    DankTextField {
        id: collection
        width: parent.width
        placeholderText: "Unsplash collection URL or ID"
    }

    PillButton {
        label: "Add collection"
        icon: "add"
        busy: settings.collectionBusy
        onClicked: {
            settings.collectionBusy = true;
            backend.call("collection", {value: collection.text}, result => {
                settings.collectionBusy = false;
                if (result.ok) {
                    if (!settings.sources.some(item => item.collectionId === result.item.collectionId))
                        settings.saveValue("collections", settings.sources.concat([{collectionId: result.item.collectionId, title: result.item.title, enabled: true}]));
                    collection.text = "";
                    settings.message = "Collection added. Choose Unsplash collections under Rotate from to use it.";
                } else {
                    settings.message = result.error;
                }
            });
        }
    }

    Repeater {
        model: settings.sources
        delegate: Row {
            required property var modelData
            width: parent.width
            spacing: Theme.spacingS
            PillButton {
                label: modelData.title
                active: modelData.enabled !== false
                icon: "check"
                onClicked: settings.saveValue("collections", settings.sources.map(item => item.collectionId === modelData.collectionId ? Object.assign({}, item, {enabled: item.enabled === false}) : item))
            }
            PillButton {
                icon: "close"
                onClicked: settings.saveValue("collections", settings.sources.filter(item => item.collectionId !== modelData.collectionId))
            }
        }
    }

    StyledText {
        width: parent.width
        visible: settings.message !== ""
        text: settings.message
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        font.pixelSize: Theme.fontSizeSmall
    }
}
