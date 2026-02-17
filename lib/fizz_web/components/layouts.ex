defmodule FizzWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FizzWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :page_header, doc: "content for the page header section"
  slot :inner_block, required: true, doc: "main content below the page header"

  attr :current_path, :string, default: "/"
  attr :hide_nav, :boolean, default: false
  attr :full_bleed, :boolean, default: false

  def app(assigns) do
    ~H"""
    <div class={[
      "flex min-h-screen flex-col",
      @full_bleed && "bg-base-200",
      !@full_bleed && "bg-base-200/50"
    ]}>
      <%= if !@hide_nav do %>
        <header class="sticky top-0 z-50 border-b border-base-200 bg-base-100/85 backdrop-blur supports-[backdrop-filter]:bg-base-100/70">
          <div class="navbar mx-auto w-full  px-4 sm:px-6 lg:px-8">
            <div class="navbar-start gap-2">
              <div class="dropdown lg:hidden">
                <button tabindex="0" class="btn btn-ghost btn-sm" aria-label="Open menu">
                  <.icon name="hero-bars-3" class="size-5" />
                </button>
                <ul
                  tabindex="0"
                  class="menu menu-sm dropdown-content mt-3 w-64 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
                >
                  <li>
                    <.link href={~p"/"} class="gap-2">
                      <.icon name="hero-home" class="size-4" /> Overview
                    </.link>
                  </li>
                  <li>
                    <.link
                      href={~p"/workspaces"}
                      class={["gap-2", workspace_nav_active?(@current_path) && "active"]}
                    >
                      <.icon name="hero-rectangle-group" class="size-4" /> Workspaces
                    </.link>
                  </li>

                  <li><hr class="my-1 border-base-300" /></li>
                  <%= if @current_scope && @current_scope.user do %>
                    <li class="menu-title">
                      <span class="text-sm normal-case">{@current_scope.user.email}</span>
                    </li>
                    <li>
                      <.link href={~p"/users/log-out"} method="delete" class="gap-2">
                        <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                      </.link>
                    </li>
                  <% else %>
                    <li>
                      <.link href={~p"/users/log-in"} class="gap-2">
                        <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log in
                      </.link>
                    </li>
                  <% end %>
                </ul>
              </div>

              <.link href={~p"/"} class="btn btn-ghost gap-2 px-2 normal-case text-base font-semibold">
                <img
                  src={static_url(FizzWeb.Endpoint, ~p"/images/logo.svg")}
                  width="28"
                  height="28"
                  alt="Fizz logo"
                />
                <span>Fizz</span>
              </.link>
            </div>

            <nav class="navbar-end gap-2">
              <ul class="menu menu-horizontal hidden px-1 lg:flex">
                <li>
                  <.link
                    href={~p"/"}
                    class={["btn btn-ghost gap-2", @current_path == "/" && "btn-active"]}
                  >
                    <.icon name="hero-home" class="size-5" /> Overview
                  </.link>
                </li>
                <li>
                  <.link
                    href={~p"/workspaces"}
                    class={[
                      "btn btn-ghost gap-2",
                      workspace_nav_active?(@current_path) && "btn-active"
                    ]}
                  >
                    <.icon name="hero-rectangle-group" class="size-5" /> Workspaces
                  </.link>
                </li>
              </ul>

              <%= if @current_scope && @current_scope.user do %>
                <div class="dropdown dropdown-end hidden lg:block">
                  <button
                    tabindex="0"
                    class="btn btn-ghost btn-sm gap-2 hover:bg-base-200"
                    aria-label="User menu"
                  >
                    <div class="avatar">
                      <div class="w-6 rounded-full bg-primary/15 text-primary">
                        <.icon name="hero-user" class="size-4" />
                      </div>
                    </div>
                    <span class="hidden max-w-[18ch] truncate text-sm font-medium sm:inline">
                      {@current_scope.user.email}
                    </span>
                    <.icon name="hero-chevron-down" class="size-4" />
                  </button>
                  <ul
                    tabindex="0"
                    class="menu menu-sm dropdown-content mt-3 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
                  >
                    <li>
                      <.link href={~p"/settings/"} class="gap-2">
                        <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
                      </.link>
                    </li>
                    <li>
                      <.link href={~p"/users/log-out"} method="delete" class="gap-2">
                        <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                      </.link>
                    </li>
                  </ul>
                </div>
              <% else %>
                <.link
                  href={~p"/users/log-in"}
                  class="btn btn-primary btn-sm gap-2 transition-colors hover:brightness-110"
                >
                  <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log in
                </.link>
              <% end %>

              <.theme_toggle />
            </nav>
          </div>
        </header>
      <% end %>

      <main class="flex flex-1 flex-col">
        <%= if @page_header != [] do %>
          <section class="border-b border-base-200 bg-base-100 pt-16">
            <div class={[
              "flex min-h-[180px] w-full flex-col justify-end pb-8",
              !@full_bleed && "mx-auto max-w-7xl px-4 sm:px-6 lg:px-8"
            ]}>
              {render_slot(@page_header)}
            </div>
          </section>
        <% end %>

        <section class={["flex-1", !@full_bleed && "px-4 py-6 sm:px-6 lg:px-8"]}>
          <div class={["w-full", !@full_bleed && "mx-auto max-w-7xl"]}>
            <.flash_group flash={@flash} />
            <div class={!@full_bleed && "py-6"}>
              {render_slot(@inner_block)}
            </div>
          </div>
        </section>
      </main>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  defp workspace_nav_active?(path) when is_binary(path),
    do: String.starts_with?(path, "/workspaces")

  defp workspace_nav_active?(_path), do: false
end
