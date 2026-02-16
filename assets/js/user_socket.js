import {Socket} from "phoenix"

let socket = null

export function getUserSocket() {
  if (socket) {
    return socket
  }

  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

  socket = new Socket("/socket", {
    params: csrfToken ? {_csrf_token: csrfToken} : {},
  })

  socket.connect()
  window.userSocket = socket

  return socket
}
