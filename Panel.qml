import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "oribi.windscribe"
  ipcTarget: "oribi.windscribe"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: ws.unavailable || !ws.loggedIn ? urgent : (ws.active ? foreground : dim)
  readonly property color barIconColor: ws.unavailable || !ws.loggedIn
    ? Qt.darker(barForeground, 1.2)
    : (ws.active ? barForeground : Qt.darker(barForeground, 1.55))
  readonly property string toggleHint: ws.active ? "Disconnect" : "Connect"
  readonly property string tooltip: {
    if (!ws.loggedIn) return "Windscribe \u2014 not logged in"
    var head = ws.connected && ws.serverCity !== ""
      ? "Windscribe \u2014 " + ws.serverCity
      : "Windscribe \u2014 " + ws.statusText
    var geo = ws.homeGeo
    if (geo && geo.isp) head += "\nfrom " + String(geo.city || "") + " \u00b7 " + String(geo.isp)
    return head
  }

  property bool firewallConfirmOpen: false
  property bool freeOnly: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: ws
    settings: root.settings
  }

  onOpenedChanged: if (opened) {
    ws.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    root.firewallConfirmOpen = false
  }

  function requestFirewall() {
    if (ws.firewallOn) { ws.setFirewall(false); return }
    if (ws.connected) { ws.setFirewall(true); return }
    root.firewallConfirmOpen = true
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(): string { ws.connect(); return "ok" }
    function disconnect(): string { ws.disconnect(); return "ok" }
    function refresh(): string { ws.refresh(); return "ok" }
    function status(): string { return ws.statusText }
    function serverStats(): string {
      var free = 0, pro = 0
      for (var i = 0; i < ws.servers.length; i++) {
        if (ws.servers[i].value === Model.BEST) continue
        if (ws.servers[i].pro) { pro += 1 } else { free += 1 }
      }
      return "free: " + free + " / pro: " + pro + " / total: " + ws.servers.length
    }
    function firewall(on: bool): string { ws.setFirewall(on); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ws.active ? "\uf0e8" : "\uf019"
    foreground: root.barIconColor
    tooltipText: root.tooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) ws.refresh()
      else if (buttonCode === Qt.MiddleButton) ws.toggle()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: serverPicker.popupOpen || root.firewallConfirmOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") ws.refresh()
        else if (t === "c" || t === "C") ws.toggle()
        else if (t === "f" || t === "F") root.requestFirewall()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: "Windscribe"
          meta: ws.connected && ws.serverCity !== ""
            ? ws.statusText + " \u00b7 " + ws.serverCity
            : ws.statusText
          detail: ws.connected ? ws.protocolLabel : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: ws.unavailable ? 0.5 : (ws.active ? 1.0 : 0.6)
          iconComponent: Component {
            Text {
              text: "\uf0e8"
              color: root.iconColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch
              checked: ws.active
              busy: ws.busy || ws.unavailable
              interactive: !ws.unavailable && ws.loggedIn
              foreground: hero.foreground
              onToggled: ws.toggle()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: hero.fontFamily
              }
            }
          }
        }

        Text {
          visible: ws.actionStatus !== "" || ws.lastError !== "" || !ws.loggedIn || ws.unavailable
          width: parent.width
          text: ws.unavailable
            ? "Windscribe is not responding \u2014 check: systemctl status windscribe"
            : (!ws.loggedIn
              ? "Not logged in \u2014 run: windscribe-cli login"
              : (ws.actionStatus !== "" ? ws.actionStatus : ws.lastError))
          color: (ws.unavailable || !ws.loggedIn || (ws.lastError !== "" && ws.actionStatus === "")) ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        WorldMap {
          id: map
          width: parent.width
          foreground: root.foreground
          accent: root.accent
          home: ws.homeCoords
          server: ws.serverCoords
          hop: null
          connected: ws.connected
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Column {
            width: (parent.width - Style.space(10)) / 2
            spacing: Style.space(2)
            Text {
              text: "\u2575 " + (ws.homeLabel !== "" ? ws.homeLabel : "Home")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              text: ws.homeDetail
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Column {
            width: (parent.width - Style.space(10)) / 2
            spacing: Style.space(2)
            Text {
              text: "\u25c9 " + (ws.connected && ws.serverCity !== "" ? ws.serverCity : "No exit")
              color: ws.connected ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              text: ws.connected ? ws.vpnIp : "not connected"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          visible: ws.connected || ws.dataUsage !== ""
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: [
              { k: "Protocol", v: ws.protocolLabel },
              { k: "VPN IP", v: ws.vpnIp },
              { k: "Uptime", v: ws.durationText },
              { k: "Data Usage", v: ws.dataUsage }
            ]
            Item {
              required property var modelData
              visible: String(modelData.v || "") !== ""
              width: column.width
              height: visible ? detailRow.implicitHeight : 0

              Row {
                id: detailRow
                width: parent.width
                Text {
                  width: parent.width * 0.4
                  text: modelData.k
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  width: parent.width * 0.6
                  text: modelData.v
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "SERVER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          SearchableDropdown {
            id: serverPicker
            width: parent.width
            showLabel: false
            placeholderText: "Search servers..."
            fontFamily: root.fontFamily
            options: root.freeOnly
              ? ws.servers.filter(function(s) { return s.value === Model.BEST || !s.pro })
              : ws.servers
            value: ws.selectedServer
            onChanged: function(v) { ws.selectServer(v) }
          }

          Toggle {
            width: parent.width
            label: "Free servers only"
            description: "Show only locations included in the free plan"
            checked: root.freeOnly
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.freeOnly = !root.freeOnly
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Toggle {
            width: parent.width
            label: "Firewall"
            description: "Block all traffic outside the VPN"
            checked: ws.firewallOn
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.requestFirewall()
          }
        }
      }

      ConfirmDialog {
        id: firewallConfirm
        anchors.fill: parent
        opened: root.firewallConfirmOpen
        z: 10
        message: "Enable the firewall while disconnected? This blocks all network traffic until you connect."
        confirmText: "Enable"
        background: Color.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onConfirmed: {
          root.firewallConfirmOpen = false
          ws.setFirewall(true)
        }
        onCanceled: root.firewallConfirmOpen = false
      }
    }
  }
}
