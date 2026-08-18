import QtQuick
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property var home: null
  property var server: null
  property var hop: null
  property bool connected: false

  implicitHeight: Math.round(width * Model.MAP_H / Model.MAP_W)

  onForegroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  onHomeChanged: canvas.requestPaint()
  onServerChanged: canvas.requestPaint()
  onHopChanged: canvas.requestPaint()
  onConnectedChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      if (w <= 0 || h <= 0) return

      var cw = w / Model.MAP_W
      var ch = h / Model.MAP_H
      var dot = Math.max(0.7, Math.min(cw, ch) * 0.34)

      ctx.fillStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.34)
      for (var r = 0; r < Model.LAND.length; r++) {
        var row = Model.LAND[r]
        for (var c = 0; c < row.length; c++) {
          if (row.charAt(c) !== "1") continue
          ctx.beginPath()
          ctx.arc((c + 0.5) * cw, (r + 0.5) * ch, dot, 0, Math.PI * 2)
          ctx.fill()
        }
      }

      function pt(coord) {
        if (!coord) return null
        var p = Model.project(coord.lat, coord.lon)
        return p ? { x: p.x * w, y: p.y * h } : null
      }

      var a = pt(root.home)
      var b = pt(root.server)
      var c2 = pt(root.hop)

      function link(p, q) {
        if (!p || !q) return
        ctx.strokeStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.9)
        ctx.lineWidth = Math.max(1, h * 0.012)
        ctx.beginPath()
        ctx.moveTo(p.x, p.y)
        var mx = (p.x + q.x) / 2
        var my = (p.y + q.y) / 2 - Math.abs(q.x - p.x) * 0.18
        ctx.quadraticCurveTo(mx, my, q.x, q.y)
        ctx.stroke()
      }

      if (root.connected) {
        if (c2) { link(a, b); link(b, c2) }
        else link(a, b)
      }

      function marker(p, fill, ring) {
        if (!p) return
        var rad = Math.max(2, h * 0.045)
        if (ring) {
          ctx.strokeStyle = Qt.rgba(fill.r, fill.g, fill.b, 0.45)
          ctx.lineWidth = Math.max(1, h * 0.01)
          ctx.beginPath(); ctx.arc(p.x, p.y, rad * 1.9, 0, Math.PI * 2); ctx.stroke()
        }
        ctx.fillStyle = fill
        ctx.beginPath(); ctx.arc(p.x, p.y, rad, 0, Math.PI * 2); ctx.fill()
      }

      marker(a, root.foreground, false)
      if (root.connected) {
        marker(b, root.accent, true)
        marker(c2, root.accent, true)
      }
    }
  }
}
