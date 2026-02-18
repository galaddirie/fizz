import React from "react"
import {createRoot} from "react-dom/client"
import {
  AdminPortalDomainVerification,
  AdminPortalSsoConnection,
  OrganizationSwitcher,
  Pipes,
  UserProfile,
  UserSecurity,
  UserSessions,
  UsersManagement,
  WorkOsWidgets,
} from "@workos-inc/widgets"
import "@radix-ui/themes/styles.css"
import "@workos-inc/widgets/styles.css"

const DEFAULT_WIDGET = "pipes"

const WIDGET_COMPONENTS = {
  pipes: Pipes,
  "organization-switcher": OrganizationSwitcher,
  "admin-portal-sso-connection": AdminPortalSsoConnection,
  "admin-portal-domain-verification": AdminPortalDomainVerification,
  "user-profile": UserProfile,
  "user-security": UserSecurity,
  "user-sessions": UserSessions,
  "users-management": UsersManagement,
}

function parseJson(rawValue, fallbackValue) {
  if (!rawValue) {
    return fallbackValue
  }

  try {
    const decodedValue = JSON.parse(rawValue)
    if (decodedValue && typeof decodedValue === "object") {
      return decodedValue
    }
  } catch (error) {
    console.error("[WorkOSWidgetHook] Failed to parse JSON dataset value", error)
  }

  return fallbackValue
}

function readWidgetName(element, defaultWidget) {
  return (element.dataset.widget || defaultWidget || DEFAULT_WIDGET).trim().toLowerCase()
}

function readWidgetProps(element) {
  const widgetProps = parseJson(element.dataset.widgetProps, {})
  const authToken = element.dataset.authToken

  if (authToken && widgetProps.authToken == null) {
    widgetProps.authToken = authToken
  }

  if (widgetProps.authToken == null) {
    throw new Error("Missing required WorkOS `authToken` for widget rendering")
  }

  return widgetProps
}

function readWidgetRootProps(element) {
  return parseJson(element.dataset.workosProps, {})
}

function buildWidgetTree(element, defaultWidget) {
  const widgetName = readWidgetName(element, defaultWidget)
  const Widget = WIDGET_COMPONENTS[widgetName]

  if (!Widget) {
    throw new Error(`Unsupported WorkOS widget "${widgetName}"`)
  }

  const widgetRootProps = readWidgetRootProps(element)
  const widgetProps = readWidgetProps(element)

  return React.createElement(
    WorkOsWidgets,
    widgetRootProps,
    React.createElement(Widget, widgetProps)
  )
}

function renderWidget(hook, defaultWidget) {
  try {
    hook.__workosRoot.render(buildWidgetTree(hook.el, defaultWidget))
  } catch (error) {
    console.error("[WorkOSWidgetHook] Unable to render widget", error)
    hook.el.dataset.widgetError = "true"
    hook.el.innerHTML =
      '<div class="rounded-box border border-error/40 bg-error/10 p-3 text-sm">' +
      "Unable to load the WorkOS widget." +
      "</div>"
  }
}

function mountRoot(hook) {
  const reactRootElement = document.createElement("div")
  reactRootElement.id = `${hook.el.id}-react-root`
  reactRootElement.className = "w-full"
  hook.el.replaceChildren(reactRootElement)
  hook.__workosRootElement = reactRootElement
  hook.__workosRoot = createRoot(reactRootElement)
}

function unmountRoot(hook) {
  if (hook.__workosRoot) {
    hook.__workosRoot.unmount()
  }

  hook.__workosRoot = null
  hook.__workosRootElement = null
}

export function createWorkOSWidgetHook(defaultWidget = DEFAULT_WIDGET) {
  return {
    mounted() {
      mountRoot(this)
      renderWidget(this, defaultWidget)
    },

    updated() {
      renderWidget(this, defaultWidget)
    },

    destroyed() {
      unmountRoot(this)
    },
  }
}

export const WorkOSReactWidget = createWorkOSWidgetHook()
export const PipesWidget = createWorkOSWidgetHook("pipes")
