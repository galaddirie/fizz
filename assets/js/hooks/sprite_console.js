import {Terminal} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"

import {getUserSocket} from "../user_socket"

function decodeBase64Chunk(encoded) {
  try {
    return atob(encoded)
  } catch (_error) {
    return ""
  }
}

export const SpriteConsole = {
  mounted() {
    this.consoleId = this.el.dataset.consoleId
    this.outputEl = this.el.querySelector("[data-console-output]")
    this.channelReady = false
    this.pendingCommands = []

    if (!this.consoleId || !this.outputEl) {
      return
    }

    this.term = new Terminal({
      cursorBlink: true,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
      fontSize: 12,
      rows: 30,
      cols: 120,
      theme: {
        background: "#101213",
        foreground: "#e9f7ee",
      },
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(this.outputEl)

    requestAnimationFrame(() => {
      this.fitAddon.fit()
      this.pushResize()
    })

    this.socket = getUserSocket()
    this.channel = this.socket.channel(`sprite_console:${this.consoleId}`, {})

    this.channel
      .join()
      .receive("ok", () => {
        this.channelReady = true
        this.term.writeln("\r\n[connected]")
        this.flushPendingCommands()
        this.pushResize()
      })
      .receive("error", ({reason}) => {
        this.term.writeln(`\r\n[connection failed: ${reason}]`)
      })

    this.channel.on("stdout", ({data}) => this.term.write(decodeBase64Chunk(data)))
    this.channel.on("stderr", ({data}) => this.term.write(decodeBase64Chunk(data)))
    this.channel.on("exit", ({exit_code}) => this.term.writeln(`\r\n[exit ${exit_code}]`))
    this.channel.on("error", ({reason}) => this.term.writeln(`\r\n[error: ${reason}]`))
    this.channel.on("closed", ({reason}) => this.term.writeln(`\r\n[closed: ${reason}]`))

    this.handleEvent("sprite_console_run_command", payload => {
      if (!payload || typeof payload.command !== "string") {
        return
      }

      if (payload.console_id && String(payload.console_id) !== this.consoleId) {
        return
      }

      this.pushStdin(payload.command)
    })

    this.termDataDispose = this.term.onData(data => {
      this.pushStdin(data)
    })

    this.resizeHandler = () => {
      this.fitAddon.fit()
      this.pushResize()
    }

    window.addEventListener("resize", this.resizeHandler)
  },

  pushResize() {
    if (!this.channel || !this.term) {
      return
    }

    this.channel.push("resize", {
      rows: this.term.rows,
      cols: this.term.cols,
    })
  },

  pushStdin(data) {
    if (!this.channel || typeof data !== "string" || data.length === 0) {
      return
    }

    if (!this.channelReady) {
      this.pendingCommands.push(data)
      return
    }

    this.channel.push("stdin", {data})
  },

  flushPendingCommands() {
    if (!this.channel || !this.channelReady || this.pendingCommands.length === 0) {
      return
    }

    this.pendingCommands.forEach(data => this.channel.push("stdin", {data}))
    this.pendingCommands = []
  },

  destroyed() {
    if (this.channel) {
      this.channel.push("close", {})
      this.channel.leave()
    }

    this.channelReady = false
    this.pendingCommands = []

    if (this.termDataDispose) {
      this.termDataDispose.dispose()
    }

    if (this.term) {
      this.term.dispose()
    }

    if (this.resizeHandler) {
      window.removeEventListener("resize", this.resizeHandler)
    }
  },
}
