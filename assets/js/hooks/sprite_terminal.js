import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"

const CLIENT_ID_KEY = "sprite_console_client_id"

function randomId(prefix) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`
}

function getClientId() {
  const existing = sessionStorage.getItem(CLIENT_ID_KEY)

  if (existing && existing.length > 0) {
    return existing
  }

  const generated = randomId("client")
  sessionStorage.setItem(CLIENT_ID_KEY, generated)
  return generated
}

function normalizeChunk(chunk) {
  if (!chunk || typeof chunk !== "object") {
    return ""
  }

  return chunk.data || ""
}

function parseNonNegativeInt(value, fallback = 0) {
  if (typeof value === "number" && Number.isInteger(value) && value >= 0) {
    return value
  }

  if (typeof value === "string") {
    const parsed = Number.parseInt(value, 10)

    if (Number.isInteger(parsed) && parsed >= 0) {
      return parsed
    }
  }

  return fallback
}

export const SpriteTerminal = {
  mounted() {
    this.clientId = this.el.dataset.clientId || getClientId()
    this.paneId = this.el.dataset.paneId
    this.sessionId = this.el.dataset.sessionId || null
    this.leaseState = this.el.dataset.leaseState || "viewer"
    this.lastSeq = parseNonNegativeInt(this.el.dataset.lastSeq, 0)
    this.lastTakeLeaseAt = 0

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

    this.focusListener = () => {
      this.terminal.focus()
      this.pushHeartbeat(true)
    }

    this.blurListener = () => this.pushHeartbeat(false)
    this.visibilityListener = () => {
      this.pushHeartbeat(this.isFocused())
    }

    this.terminalContainer.addEventListener("click", this.focusListener)
    window.addEventListener("blur", this.blurListener)
    document.addEventListener("visibilitychange", this.visibilityListener)

    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
      this.pushResize()
    })

    this.resizeObserver.observe(this.el)

    this.inputDisposable = this.terminal.onData((data) => {
      if (!this.sessionId) {
        return
      }

      if (!this.isWriter()) {
        this.maybeRequestLease()
        return
      }

      this.pushEvent("console_input", {
        pane_id: this.paneId,
        session_id: this.sessionId,
        client_id: this.clientId,
        data,
      })
    })

    this.handleEvent("console_v2_bootstrap", (payload) => {
      if (payload.pane_id !== this.paneId) {
        return
      }

      this.sessionId = payload.session_id || this.sessionId
      this.leaseState = payload.lease_state || this.leaseState

      this.terminal.clear()

      if (payload.message) {
        this.terminal.writeln(`\x1b[38;5;109m${payload.message}\x1b[0m`)
      }

      if (Array.isArray(payload.chunks)) {
        payload.chunks.forEach((chunk) => {
          this.acceptChunk(chunk)
          this.terminal.write(normalizeChunk(chunk))
        })
      }

      this.persistSeq()
      this.pushResize()
      this.pushHeartbeat(this.isFocused())
    })

    this.handleEvent("console_v2_output", ({ session_id, chunk }) => {
      if (!this.sessionId || this.sessionId !== session_id) {
        return
      }

      this.acceptChunk(chunk)
      this.terminal.write(normalizeChunk(chunk))
      this.persistSeq()
    })

    this.handleEvent("console_v2_replay", ({ pane_id, session_id, chunks }) => {
      if (pane_id !== this.paneId || !this.sessionId || this.sessionId !== session_id) {
        return
      }

      if (Array.isArray(chunks)) {
        chunks.forEach((chunk) => {
          this.acceptChunk(chunk)
          this.terminal.write(normalizeChunk(chunk))
        })
      }

      this.persistSeq()
    })

    this.handleEvent("console_v2_state", ({ session_id, state, reason }) => {
      if (!this.sessionId || this.sessionId !== session_id) {
        return
      }

      if (state === "detached") {
        this.terminal.writeln("")
        this.terminal.writeln("[detached: no focused clients]")
      }

      if (state === "attached" && reason === "reattached") {
        this.terminal.writeln("")
        this.terminal.writeln("[reattached to existing session]")
      }
    })

    this.handleEvent("console_v2_exit", ({ session_id, reason, exit_code }) => {
      if (!this.sessionId || this.sessionId !== session_id) {
        return
      }

      this.terminal.writeln("")
      this.terminal.writeln(
        `[session exited] code=${exit_code == null ? "n/a" : exit_code} reason=${reason || "unknown"}`
      )
    })

    this.handleEvent("console_v2_lease", ({ session_id, lease_client_id }) => {
      if (!this.sessionId || this.sessionId !== session_id) {
        return
      }

      this.leaseState = lease_client_id === this.clientId ? "writer" : "viewer"
    })

    this.startHeartbeatLoop()
    this.bootstrap()
  },

  updated() {
    const nextSessionId = this.el.dataset.sessionId || null
    const nextLeaseState = this.el.dataset.leaseState || this.leaseState

    if (nextSessionId !== this.sessionId) {
      this.sessionId = nextSessionId
      this.lastSeq = parseNonNegativeInt(this.el.dataset.lastSeq, this.lastSeq)
      this.bootstrap()
    }

    this.leaseState = nextLeaseState
    this.fitAddon.fit()
    this.pushResize()
  },

  destroyed() {
    if (this.heartbeatTimer) {
      clearTimeout(this.heartbeatTimer)
    }

    if (this.focusListener) {
      this.terminalContainer.removeEventListener("click", this.focusListener)
    }

    if (this.blurListener) {
      window.removeEventListener("blur", this.blurListener)
    }

    if (this.visibilityListener) {
      document.removeEventListener("visibilitychange", this.visibilityListener)
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

  bootstrap() {
    this.pushEvent("console_client_init", {
      pane_id: this.paneId,
      client_id: this.clientId,
      focused: this.isFocused(),
      last_seq: this.lastSeq,
    })
  },

  startHeartbeatLoop() {
    const tick = () => {
      this.pushHeartbeat(this.isFocused())
      const delay = this.isFocused() ? 5000 : 15000
      this.heartbeatTimer = setTimeout(tick, delay)
    }

    tick()
  },

  pushHeartbeat(focused) {
    if (!this.sessionId) {
      return
    }

    this.pushEvent("console_heartbeat", {
      pane_id: this.paneId,
      session_id: this.sessionId,
      client_id: this.clientId,
      focused,
    })
  },

  maybeRequestLease() {
    const now = Date.now()

    if (now - this.lastTakeLeaseAt < 1000) {
      return
    }

    this.lastTakeLeaseAt = now

    this.pushEvent("console_take_lease", {
      pane_id: this.paneId,
      session_id: this.sessionId,
      client_id: this.clientId,
    })
  },

  pushResize() {
    if (!this.sessionId || !this.terminal || !this.isWriter()) {
      return
    }

    this.pushEvent("console_resize", {
      pane_id: this.paneId,
      session_id: this.sessionId,
      client_id: this.clientId,
      rows: this.terminal.rows,
      cols: this.terminal.cols,
    })
  },

  acceptChunk(chunk) {
    if (!chunk || typeof chunk !== "object") {
      return
    }

    const nextSeq = parseNonNegativeInt(chunk.seq, this.lastSeq)

    if (nextSeq > this.lastSeq) {
      this.lastSeq = nextSeq
    }
  },

  persistSeq() {
    if (!this.paneId) {
      return
    }

    this.el.dataset.lastSeq = String(this.lastSeq)
  },

  isFocused() {
    return document.visibilityState === "visible" && this.el.dataset.active === "true"
  },

  isWriter() {
    return this.leaseState === "writer"
  },
}
