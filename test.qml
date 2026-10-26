import QtQuick
import Quickshell
import "." as Carousel
import "Rotation.js" as Rotation
ShellRoot {
    Carousel.Backend { id: backend; script: decodeURIComponent(String(Qt.resolvedUrl("wallpaper.py")).replace("file://", "")) }
    Timer {
        interval: 1; running: true
        onTriggered: {
            const items = [{id: "green", palette: {green: 1}}, {id: "brown", palette: {orange: 1}}, {id: "blue", palette: {blue: 1}}];
            if (Rotation.choose(items, null, "green", [items[0], items[1]], true).item.id !== "blue")
                throw new Error("Palette choice failed");
            if (Rotation.blocked({tags: ["CAFÉ"]}, "cafe\u0301") !== "café")
                throw new Error("Unicode keyword matching failed");
            if (Rotation.palette("#00ff00").green !== 1 || Rotation.interval(7, "days") !== 604800000)
                throw new Error("Palette or deadline failed");
            backend.call("key-status", {}, result => {
                if (!result.ok)
                    throw new Error("Helper failed");
                console.warn("CAROUSEL_QML_TESTS_PASSED");
                Qt.quit();
            });
        }
    }
}
