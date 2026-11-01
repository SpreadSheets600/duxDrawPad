import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Services

PluginComponent {
    id: root

    pluginId: "drawPad"
    pluginService: PluginService

    // drawing/tool state lives here so it survives the popout closing
    property var store: ({ history: [], step: -1, tool: "pen", color: Theme.primary, size: 0.3 })

    popoutWidth: 620
    popoutHeight: 460

    popoutContent: Component {
        DrawPad {
            widget: root
            onCloseRequested: root.closePopout()
        }
    }

    horizontalBarPill: Component {
        DIcon {
            name: "draw"
            size: Theme.iconSize - 4
            color: Theme.surfaceText
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        }
    }

    verticalBarPill: Component {
        DIcon {
            name: "draw"
            size: Theme.iconSize - 4
            color: Theme.surfaceText
        }
    }
}
