import QtQuick
import Quickshell
import Quickshell.Io
import "plugin" as Neomarchy

ShellRoot {
  id: root

  Loader {
    id: service
    active: true
    sourceComponent: Component {
      Neomarchy.Service { volume: 0 }
    }
  }

  IpcHandler {
    target: "lifecycle"

    function status(): string {
      var p = service.item
      return JSON.stringify({
        shellPid: Quickshell.processId,
        loaded: p !== null,
        running: p ? p.mpvRunning : false,
        fileLoaded: p ? p.fileLoaded : false,
        playing: p ? p.playing : false,
        socket: p ? p.socketPath : "",
        error: p ? p.lastError : ""
      })
    }

    function start(): void {
      service.item.currentTrack = { id: "1", title: "Lifecycle regression" }
      service.item.startUrl("file://" + Quickshell.env("NEOMARCHY_TEST_AUDIO"))
    }

    function toggle(): void { service.item.togglePlayback() }
    function stop(): void { service.item.stop() }
    function unload(): void { service.active = false }
    function load(): void { service.active = true }
  }
}
