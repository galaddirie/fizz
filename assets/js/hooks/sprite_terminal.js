import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"

function normalizeChunk(chunk) {
  if (!chunk || typeof chunk !== "object") {
    return ""
  }

  if (chunk.stream === "stderr") {
    return chunk.data || ""
  }

  return chunk.data || ""
}

export const SpriteTerminal = {
  mounted() {
    this.terminalContainer = document.createElement("div")
    this.terminalContainer.className = "h-full w-full"
    this.el.replaceChildren(this.terminalContainer)

    this.fitAddon = new FitAddon()
    this.terminal = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      lineHeight: 1.3,
      convertEol: true,
      theme: {
        background: "transparent",
      },
    })

    this.terminal.loadAddon(this.fitAddon)
    this.terminal.open(this.terminalContainer)
    this.fitAddon.fit()
    this.terminal.focus()

    this.focusListener = () => this.terminal.focus()
    this.terminalContainer.addEventListener("click", this.focusListener)

    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
      this.pushResize()
    })

    this.resizeObserver.observe(this.el)

    this.inputDisposable = this.terminal.onData((data) => {
      if (!this.currentSessionId()) {
        return
      }

      this.pushEvent("console_input", {
        session_id: this.currentSessionId(),
        data,
      })
    })

    this.handleEvent("console_bootstrap", ({ session_id, chunks }) => {
      if (session_id !== this.currentSessionId()) {
        return
      }

      this.terminal.clear()

      if (Array.isArray(chunks)) {
        chunks.forEach((chunk) => {
          this.terminal.write(normalizeChunk(chunk))
        })
      }

      this.pushResize()
      this.terminal.focus()
    })

    this.handleEvent("console_output", ({ session_id, chunk }) => {
      if (session_id !== this.currentSessionId()) {
        return
      }

      this.terminal.write(normalizeChunk(chunk))
    })

    this.handleEvent("console_exit", ({ session_id, exit_code, reason }) => {
      if (session_id !== this.currentSessionId()) {
        return
      }

      this.terminal.writeln("")
      this.terminal.writeln(
        `[session exited] code=${exit_code == null ? "n/a" : exit_code} reason=${reason || "unknown"}`
      )
    })
  },

  updated() {
    if (this.terminal && this.currentSessionId()) {
      this.pushResize()
      this.terminal.focus()
    }
  },

  destroyed() {
    if (this.focusListener) {
      this.terminalContainer.removeEventListener("click", this.focusListener)
    }

    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }

    if (this.inputDisposable) {
      this.inputDisposable.dispose()
    }

    if (this.terminal) {
      this.terminal.dispose()
    }
  },

  currentSessionId() {
    return this.el.dataset.sessionId || null
  },

  pushResize() {
    const sessionId = this.currentSessionId()

    if (!sessionId || !this.terminal) {
      return
    }

    this.pushEvent("console_resize", {
      session_id: sessionId,
      rows: this.terminal.rows,
      cols: this.terminal.cols,
    })
  },
}
