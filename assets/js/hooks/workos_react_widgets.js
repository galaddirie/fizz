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
import {ApiProvider} from "../../../node_modules/@workos-inc/widgets/dist/esm/api/api-provider.js"
import {useMyDataIntegrations} from "../../../node_modules/@workos-inc/widgets/dist/esm/api/endpoint.js"
import {ErrorBoundary} from "../../../node_modules/@workos-inc/widgets/dist/esm/lib/error-boundary.js"
import {
  Pipes as PipesList,
  PipesError,
  PipesLoading,
} from "../../../node_modules/@workos-inc/widgets/dist/esm/lib/pipes.js"
import {useIsHydrated} from "../../../node_modules/@workos-inc/widgets/dist/esm/lib/use-is-hydrated.js"
import {useWorkOsApiUrl} from "../../../node_modules/@workos-inc/widgets/dist/esm/lib/widgets-context.js"
import "@radix-ui/themes/styles.css"
import "@workos-inc/widgets/styles.css"

const DEFAULT_WIDGET = "pipes"
const CONNECTION_REFRESH_DELAY_MS = 1200

const WIDGET_COMPONENTS = {
  pipes: Pipes,
  "scoped-pipes": ScopedPipes,
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

function readArray(rawValue) {
  const parsed = parseJson(rawValue, [])

  if (Array.isArray(parsed)) {
    return parsed.filter(value => typeof value === "string" && value.trim() !== "")
  }

  if (typeof parsed === "string" && parsed.trim() !== "") {
    return [parsed.trim()]
  }

  return []
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

  const integrationSlugs = readArray(element.dataset.integrationSlugs)

  if (integrationSlugs.length > 0 && widgetProps.integrationSlugs == null) {
    widgetProps.integrationSlugs = integrationSlugs
  }

  if (widgetProps.authToken == null) {
    throw new Error("Missing required WorkOS `authToken` for widget rendering")
  }

  return widgetProps
}

function readWidgetRootProps(element) {
  return parseJson(element.dataset.workosProps, {})
}

function buildWidgetTree(controller, defaultWidget) {
  const {el: element} = controller
  const widgetName = readWidgetName(element, defaultWidget)
  const Widget = WIDGET_COMPONENTS[widgetName]

  if (!Widget) {
    throw new Error(`Unsupported WorkOS widget "${widgetName}"`)
  }

  const widgetRootProps = readWidgetRootProps(element)
  const widgetProps = readWidgetProps(element)

  if (
    controller.__workosOnConnectionSettled &&
    widgetName === "scoped-pipes"
  ) {
    widgetProps.onConnectionSettled = controller.__workosOnConnectionSettled
  }

  return React.createElement(
    WorkOsWidgets,
    widgetRootProps,
    React.createElement(Widget, widgetProps)
  )
}

function renderWidget(controller, defaultWidget) {
  try {
    controller.__workosRoot.render(buildWidgetTree(controller, defaultWidget))
  } catch (error) {
    console.error("[WorkOSWidgetHook] Unable to render widget", error)
    controller.el.dataset.widgetError = "true"
    controller.el.innerHTML =
      '<div class="rounded-box border border-error/40 bg-error/10 p-3 text-sm">' +
      "Unable to load the WorkOS widget." +
      "</div>"
  }
}

function mountRoot(controller) {
  const reactRootElement = document.createElement("div")
  reactRootElement.id = `${controller.el.id}-react-root`
  reactRootElement.className = "w-full"
  controller.el.replaceChildren(reactRootElement)
  controller.__workosRootElement = reactRootElement
  controller.__workosRoot = createRoot(reactRootElement)
}

function unmountRoot(controller) {
  if (controller.__workosRoot) {
    controller.__workosRoot.unmount()
  }

  controller.__workosRoot = null
  controller.__workosRootElement = null
}

function normalizeProviderSlugs(value) {
  if (Array.isArray(value)) {
    return value.filter(item => typeof item === "string" && item.trim() !== "")
  }

  if (typeof value === "string" && value.trim() !== "") {
    return [value.trim()]
  }

  return []
}

function integrationMatchesProvider(integration, providerSlugs) {
  if (providerSlugs.length === 0) {
    return true
  }

  const normalizedProviderSlugs = new Set(providerSlugs.map(slug => slug.toLowerCase()))
  const integrationValues = [
    integration.slug,
    integration.integrationSlug,
    integration.integrationType,
    integration.provider,
    integration.providerSlug,
  ]

  return integrationValues.some(
    value => typeof value === "string" && normalizedProviderSlugs.has(value.toLowerCase())
  )
}

function ScopedPipes({
  authToken,
  integrationSlug,
  integrationSlugs,
  onConnectionSettled,
  ...domProps
}) {
  const providerSlugs = React.useMemo(
    () =>
      normalizeProviderSlugs(integrationSlugs).concat(normalizeProviderSlugs(integrationSlug)),
    [integrationSlug, integrationSlugs]
  )
  const baseUrl = useWorkOsApiUrl()

  return React.createElement(
    ErrorBoundary,
    {
      fallbackRender: ({error}) => React.createElement(PipesError, {...domProps, error}),
    },
    React.createElement(
      ApiProvider,
      {widgetType: "pipes", authToken, baseUrl},
      React.createElement(ScopedPipesImpl, {
        ...domProps,
        providerSlugs,
        onConnectionSettled,
      })
    )
  )
}

function ScopedPipesImpl({providerSlugs, onConnectionSettled, ...domProps}) {
  const isHydrated = useIsHydrated()
  const integrations = useMyDataIntegrations()
  const notifyTimer = React.useRef(null)
  const connectionPending = React.useRef(false)

  React.useEffect(() => {
    return () => {
      if (notifyTimer.current) {
        window.clearTimeout(notifyTimer.current)
      }
    }
  }, [])

  const notifyConnectionSettled = React.useCallback(() => {
    if (!onConnectionSettled) {
      return
    }

    connectionPending.current = false

    if (notifyTimer.current) {
      window.clearTimeout(notifyTimer.current)
    }

    notifyTimer.current = window.setTimeout(() => {
      integrations.refetch()
      onConnectionSettled()
    }, CONNECTION_REFRESH_DELAY_MS)
  }, [integrations, onConnectionSettled])

  const markPotentialConnection = React.useCallback(() => {
    connectionPending.current = true
  }, [])

  React.useEffect(() => {
    if (!onConnectionSettled) {
      return undefined
    }

    const handleConnectionSignal = () => {
      if (connectionPending.current) {
        notifyConnectionSettled()
      }
    }

    window.addEventListener("focus", handleConnectionSignal)
    window.addEventListener("message", handleConnectionSignal)

    return () => {
      window.removeEventListener("focus", handleConnectionSignal)
      window.removeEventListener("message", handleConnectionSignal)
    }
  }, [notifyConnectionSettled, onConnectionSettled])

  if (!isHydrated || integrations.isLoading) {
    return React.createElement(PipesLoading, {
      count: Math.max(providerSlugs.length, 1),
      ...domProps,
    })
  }

  if (integrations.isError) {
    return React.createElement(PipesError, {error: integrations.error, ...domProps})
  }

  if (integrations.isSuccess) {
    const filteredIntegrations = (integrations.data.data || []).filter(integration =>
      integrationMatchesProvider(integration, providerSlugs)
    )

    return React.createElement(
      "div",
      {onClickCapture: markPotentialConnection},
      React.createElement(PipesList, {
        integrations: filteredIntegrations,
        ...domProps,
      })
    )
  }

  return React.createElement(PipesError, {error: integrations.error, ...domProps})
}

export function mountWorkOSWidget(element, options = {}) {
  const controller = {
    el: element,
    __workosRoot: null,
    __workosRootElement: null,
    __workosOnConnectionSettled: options.onConnectionSettled || null,
  }
  const defaultWidget = options.defaultWidget || DEFAULT_WIDGET

  mountRoot(controller)
  renderWidget(controller, defaultWidget)

  return {
    update() {
      controller.__workosOnConnectionSettled = options.onConnectionSettled || null
      renderWidget(controller, defaultWidget)
    },
    destroy() {
      unmountRoot(controller)
    },
  }
}

export function createWorkOSWidgetHook(defaultWidget = DEFAULT_WIDGET) {
  return {
    mounted() {
      this.__workosWidgetController = mountWorkOSWidget(this.el, {
        defaultWidget,
        onConnectionSettled: () => {
          const event = this.el.dataset.connectedEvent

          if (event) {
            this.pushEvent(event, {})
          }
        },
      })
    },

    updated() {
      this.__workosWidgetController?.update()
    },

    destroyed() {
      this.__workosWidgetController?.destroy()
      this.__workosWidgetController = null
    },
  }
}

export const WorkOSReactWidget = createWorkOSWidgetHook()
export const PipesWidget = createWorkOSWidgetHook("pipes")
