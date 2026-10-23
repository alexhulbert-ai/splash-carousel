import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "wallhavenCarousel"

    StyledText {
        width: parent.width
        text: "Wallhaven Carousel"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("wallhavenCarousel", "Open it with: dms ipc call wallhavenCarousel toggle. The plugin uses one folder, the same one as DMS's automatic wallpaper cycling.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "folder"
        label: I18n.trFor("wallhavenCarousel", "Wallpaper folder")
        description: I18n.trFor("wallhavenCarousel", "Empty: DMS's cycling folder, or the folder of the current wallpaper.")
        placeholder: "~/Pictures/Wallpapers"
    }

    StringSetting {
        settingKey: "apiKey"
        label: I18n.trFor("wallhavenCarousel", "Wallhaven API key")
        description: I18n.trFor("wallhavenCarousel", "Optional. Unlocks the Sketchy and NSFW filters. Get one at wallhaven.cc/settings/account. Stored in plain text.")
        placeholder: ""
    }

    SelectionSetting {
        settingKey: "favoritesInterval"
        label: I18n.trFor("wallhavenCarousel", "Shuffle favorites every")
        description: I18n.trFor("wallhavenCarousel", "Applies while the favorites shuffle is on.")
        options: [
            {
                label: I18n.trFor("wallhavenCarousel", "5 minutes"),
                value: "5"
            },
            {
                label: I18n.trFor("wallhavenCarousel", "15 minutes"),
                value: "15"
            },
            {
                label: I18n.trFor("wallhavenCarousel", "30 minutes"),
                value: "30"
            },
            {
                label: I18n.trFor("wallhavenCarousel", "1 hour"),
                value: "60"
            },
            {
                label: I18n.trFor("wallhavenCarousel", "3 hours"),
                value: "180"
            },
            {
                label: I18n.trFor("wallhavenCarousel", "6 hours"),
                value: "360"
            }
        ]
        defaultValue: "60"
    }
}
