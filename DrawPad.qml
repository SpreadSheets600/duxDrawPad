import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.DCommon.Widgets
import qs.Services

FocusScope {
    id: pad
    focus: true
    implicitWidth: widget ? widget.popoutWidth : 620
    implicitHeight: widget ? widget.popoutHeight : 460

    signal closeRequested

    // owning bar widget; holds state so the drawing survives popout close
    property var widget: null

    property string tool: widget ? widget.store.tool : "pen"   // pen | marker | eraser
    property color penColor: widget ? widget.store.color : Theme.primary
    property real sizeRatio: widget ? widget.store.size : 0.3
    onToolChanged: if (widget) widget.store.tool = tool
    onPenColorChanged: if (widget) widget.store.color = penColor
    onSizeRatioChanged: if (widget) widget.store.size = sizeRatio
    property bool showColors: false

    readonly property real toolSize: tool === "eraser" ? 8 + sizeRatio * 60
                                   : tool === "marker" ? 6 + sizeRatio * 40
                                   : 1.5 + sizeRatio * 20

    // action history for undo/redo; each: {tool,color,size,pts:[[x,y]...]} or {clear:true}
    property var history: widget ? widget.store.history : []
    property int step: widget ? widget.store.step : -1
    onHistoryChanged: if (widget) widget.store.history = history
    onStepChanged: if (widget) widget.store.step = step
    property var live: null
    readonly property bool canUndo: step >= 0
    readonly property bool canRedo: step < history.length - 1

    readonly property var palette: [
        Theme.primary, Theme.error, Theme.secondary, Theme.tertiary,
        "#f2c94c", "#6fcf97", "#56ccf2", Theme.surfaceText
    ]

    function commit(a) {
        const h = history.slice(0, step + 1);
        h.push(a);
        history = h;
        step = h.length - 1;
    }
    function undo() { if (canUndo) { step--; canvas.replay(); } }
    function redo() { if (canRedo) { step++; canvas.replay(); } }
    function clearAll() { commit({ clear: true }); canvas.replay(); }

    function savePng() {
        const dir = Paths.expandTilde("~/Pictures");
        const path = dir + "/drawpad_" + Date.now() + ".png";
        Proc.runCommand("drawPad.mkdir", ["mkdir", "-p", dir], () => {
            canvas.save(path);
            ToastService.showInfo("Drawing saved", path);
        });
    }
    function copyPng() {
        const path = "/tmp/drawpad_clip.png";
        canvas.save(path);
        Proc.runCommand("drawPad.copy", ["sh", "-c", 'wl-copy --type image/png < "$1"', "_", path],
            (o, code) => ToastService.showInfo(code === 0 ? "Copied to clipboard" : "wl-copy failed"));
    }

    Keys.onPressed: event => {
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Z) {
            if (event.modifiers & Qt.ShiftModifier) redo(); else undo();
            event.accepted = true;
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Y) {
            redo(); event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.surfaceContainerLowest
        radius: Theme.cornerRadiusLarge
    }

    // dot grid backdrop
    Canvas {
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.fillStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.14);
            for (let x = 12; x < width; x += 20)
                for (let y = 12; y < height; y += 20)
                    ctx.fillRect(x, y, 1.6, 1.6);
        }
        Component.onCompleted: requestPaint()
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderTarget: Canvas.FramebufferObject
        onAvailableChanged: if (available) replay()

        function style(ctx, a) {
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            ctx.lineWidth = a.size;
            if (a.tool === "eraser") {
                ctx.globalCompositeOperation = "destination-out";
                ctx.strokeStyle = "rgba(0,0,0,1)";
                ctx.globalAlpha = 1;
            } else {
                ctx.globalCompositeOperation = "source-over";
                ctx.strokeStyle = a.color;
                ctx.globalAlpha = a.tool === "marker" ? 0.45 : 1;
            }
        }

        function drawStroke(ctx, a) {
            style(ctx, a);
            ctx.beginPath();
            ctx.moveTo(a.pts[0][0], a.pts[0][1]);
            if (a.pts.length === 1) ctx.lineTo(a.pts[0][0] + 0.1, a.pts[0][1]);
            for (let i = 1; i < a.pts.length; i++) ctx.lineTo(a.pts[i][0], a.pts[i][1]);
            ctx.stroke();
        }

        property bool replayPending: false
        function replay() { replayPending = true; requestPaint(); }

        property var segQueue: []   // [{a, from, to}]

        onPaint: {
            const ctx = getContext("2d");
            if (replayPending) {
                ctx.clearRect(0, 0, width, height);
                let start = 0;
                for (let i = pad.step; i >= 0; i--)
                    if (pad.history[i].clear) { start = i; break; }
                for (let j = start; j <= pad.step; j++) {
                    const a = pad.history[j];
                    if (a.clear) ctx.clearRect(0, 0, width, height);
                    else drawStroke(ctx, a);
                }
                ctx.globalAlpha = 1;
                replayPending = false;
                segQueue = [];
                return;
            }
            for (let i = 0; i < segQueue.length; i++) {
                const s = segQueue[i];
                style(ctx, s.a);
                ctx.beginPath();
                ctx.moveTo(s.from[0], s.from[1]);
                ctx.lineTo(s.to[0], s.to[1]);
                ctx.stroke();
            }
            ctx.globalAlpha = 1;
            segQueue = [];
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPressed: mouse => {
                pad.showColors = false;
                pad.forceActiveFocus();
                const useTool = mouse.button === Qt.RightButton ? "eraser" : pad.tool;
                pad.live = {
                    tool: useTool,
                    color: pad.penColor.toString(),
                    size: useTool === "eraser" && pad.tool !== "eraser" ? 8 + pad.sizeRatio * 60 : pad.toolSize,
                    pts: [[mouse.x, mouse.y]]
                };
                canvas.segQueue.push({ a: pad.live, from: [mouse.x, mouse.y], to: [mouse.x + 0.1, mouse.y] });
                canvas.requestPaint();
            }
            onPositionChanged: mouse => {
                if (!pressed || !pad.live) return;
                const last = pad.live.pts[pad.live.pts.length - 1];
                pad.live.pts.push([mouse.x, mouse.y]);
                canvas.segQueue.push({ a: pad.live, from: last, to: [mouse.x, mouse.y] });
                canvas.requestPaint();
            }
            onReleased: finish()
            onCanceled: finish()
            function finish() {
                if (pad.live) { pad.commit(pad.live); pad.live = null; }
            }
        }
    }

    // ---- top-right actions
    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS
        z: 10

        Repeater {
            model: [
                { icon: "download", tip: "save", act: "save" },
                { icon: "content_copy", tip: "copy", act: "copy" },
                { icon: "close", tip: "close", act: "close" }
            ]
            delegate: Rectangle {
                required property var modelData
                width: 36; height: 36
                radius: Theme.cornerRadius
                color: ma.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                DIcon { anchors.centerIn: parent; name: modelData.icon; size: 18; color: Theme.surfaceText }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (modelData.act === "save") pad.savePng();
                        else if (modelData.act === "copy") pad.copyPng();
                        else pad.closeRequested();
                    }
                }
            }
        }
    }

    // ---- size popup
    Rectangle {
        visible: pad.sizeOpen
        z: 20
        width: 240; height: 56
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        anchors.bottom: toolbar.top
        anchors.bottomMargin: Theme.spacingS
        anchors.horizontalCenter: parent.horizontalCenter

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.right: dot.left
            anchors.margins: Theme.spacingL
            height: 6; radius: 3
            color: Theme.outlineVariant
            Rectangle { width: parent.width * pad.sizeRatio; height: parent.height; radius: 3; color: Theme.primary }
            Rectangle {
                width: 16; height: 16; radius: 8; color: Theme.primary
                x: parent.width * pad.sizeRatio - 8
                anchors.verticalCenter: parent.verticalCenter
            }
            MouseArea {
                anchors.fill: parent; anchors.margins: -12
                cursorShape: Qt.PointingHandCursor
                function upd(m) { pad.sizeRatio = Math.max(0, Math.min(1, (m.x - 12) / (width - 24))); }
                onPressed: m => upd(m)
                onPositionChanged: m => { if (pressed) upd(m); }
            }
        }
        Item {
            id: dot
            width: 40; height: 40
            anchors.right: parent.right; anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
                anchors.centerIn: parent
                width: Math.min(36, pad.toolSize); height: width; radius: width / 2
                color: pad.tool === "eraser" ? "transparent" : pad.penColor
                border.width: pad.tool === "eraser" ? 1 : 0
                border.color: Theme.surfaceText
            }
        }
    }
    property bool sizeOpen: false

    // ---- color popup
    Rectangle {
        visible: pad.showColors
        z: 20
        width: 280; height: 130
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        anchors.bottom: toolbar.top
        anchors.bottomMargin: Theme.spacingS
        anchors.horizontalCenter: parent.horizontalCenter

        Column {
            anchors.centerIn: parent
            spacing: Theme.spacingM
            Grid {
                columns: 8
                spacing: Theme.spacingS
                anchors.horizontalCenter: parent.horizontalCenter
                Repeater {
                    model: pad.palette
                    delegate: Rectangle {
                        required property var modelData
                        width: 26; height: 26; radius: 13
                        color: modelData
                        border.width: Qt.colorEqual(modelData, pad.penColor) ? 2 : 0
                        border.color: Theme.surfaceText
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pad.penColor = parent.color;
                                if (pad.tool === "eraser") pad.tool = "pen";
                            }
                        }
                    }
                }
            }
            Rectangle {
                width: 150; height: 30
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.cornerRadiusSmall
                color: Theme.surfaceContainerHighest
                TextInput {
                    anchors.fill: parent; anchors.margins: 4
                    horizontalAlignment: TextInput.AlignHCenter
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.surfaceText
                    text: pad.penColor.toString()
                    onEditingFinished: {
                        const c = Qt.color(text);
                        if (c.valid !== false) pad.penColor = c;
                    }
                }
            }
        }
    }

    // ---- bottom toolbar
    Rectangle {
        id: toolbar
        z: 10
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.margins: Theme.spacingL
        width: row.width + 32
        height: 48
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.spacingM

            component TBtn: Rectangle {
                id: b
                property string icon
                property bool active: false
                property bool dim: false
                property color fg: Theme.surfaceText
                signal clicked
                width: 34; height: 34
                radius: Theme.cornerRadius
                color: active ? Theme.primaryContainer : (m.containsMouse && !dim ? Theme.surfaceContainerHighest : "transparent")
                opacity: dim ? 0.35 : 1
                DIcon { anchors.centerIn: parent; name: b.icon; size: 18; color: b.active ? Theme.primary : b.fg }
                MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (!b.dim) b.clicked() }
            }

            TBtn { icon: "undo"; dim: !pad.canUndo; onClicked: pad.undo() }
            TBtn { icon: "redo"; dim: !pad.canRedo; onClicked: pad.redo() }

            Rectangle { width: 1; height: 22; anchors.verticalCenter: parent.verticalCenter; color: Theme.outlineVariant }

            Repeater {
                model: [
                    { id: "pen", icon: "edit" },
                    { id: "marker", icon: "ink_highlighter" },
                    { id: "eraser", icon: "ink_eraser" }
                ]
                delegate: TBtn {
                    required property var modelData
                    icon: modelData.icon
                    active: pad.tool === modelData.id
                    onClicked: {
                        if (pad.tool === modelData.id) pad.sizeOpen = !pad.sizeOpen;
                        else { pad.tool = modelData.id; pad.sizeOpen = true; }
                        pad.showColors = false;
                    }
                }
            }

            Rectangle { width: 1; height: 22; anchors.verticalCenter: parent.verticalCenter; color: Theme.outlineVariant }

            Rectangle {
                width: 26; height: 26; radius: 13
                anchors.verticalCenter: parent.verticalCenter
                color: pad.penColor
                border.width: 2; border.color: Theme.outline
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { pad.showColors = !pad.showColors; pad.sizeOpen = false; }
                }
            }

            Rectangle { width: 1; height: 22; anchors.verticalCenter: parent.verticalCenter; color: Theme.outlineVariant }

            TBtn { icon: "delete"; fg: Theme.error; onClicked: { pad.clearAll(); pad.showColors = false; pad.sizeOpen = false; } }
        }
    }
}
