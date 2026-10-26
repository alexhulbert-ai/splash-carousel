import QtQuick
import Quickshell.Io

Item {
    id: backend
    required property string script

    function call(op, args, callback) {
        const job = task.createObject(backend, {input: Object.assign({op: op}, args || {}), callback: callback});
        job.running = true;
    }

    Component {
        id: task
        Process {
            id: job
            required property var input
            required property var callback
            property bool outputDone: false
            property bool exitDone: false
            property int code: -1
            property string output: ""
            command: ["python3", backend.script]
            stdinEnabled: true
            onStarted: {
                write(JSON.stringify(input));
                stdinEnabled = false;
                input = null;
            }
            function finish() {
                if (!outputDone || !exitDone)
                    return;
                let result;
                try {
                    result = JSON.parse(output);
                } catch (_) {
                    result = {ok: false, error: "Wallpaper helper failed (" + code + ")."};
                }
                try {
                    if (callback)
                        callback(result);
                } finally {
                    destroy();
                }
            }
            stdout: StdioCollector {
                onStreamFinished: {
                    job.output = text;
                    job.outputDone = true;
                    job.finish();
                }
            }
            stderr: StdioCollector {}
            onExited: exitCode => {
                code = exitCode;
                exitDone = true;
                finish();
            }
        }
    }
}
