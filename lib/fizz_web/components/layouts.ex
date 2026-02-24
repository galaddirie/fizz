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
                <svg
                  class="h-6 w-6 text-base-content"
                  viewBox="0 0 1080 700"
                  fill="currentColor"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path d="M1041.6,218.5h0c0-101.3-82.1-183.4-183.4-183.4h-332.6c-27.2,0-49.2,22-49.2,49.2v26.5c0,9.9,2,19.6,5.9,28.7l54.4,127.3c25.2,59.2,33.1,125.2-6.5,176.8l-40.9,53.3c-8.4,10.9-12.9,24.3-12.9,38v80.7c0,27.2,22,49.2,49.2,49.2h437.2c43.5,0,78.7-35.2,78.7-78.7v-6.8c0-14.2,7.9-137.2-13.2-174.9-21.1-37.7-95.8,8.6-115.4,8.6s-19.3-46.6-19.3-46.6c81.7,0,147.9-66.2,147.9-147.9ZM830.2,193.9c-1.3-41.1,32.3-74.7,73.4-73.4,37.2,1.2,67.6,31.5,68.8,68.8,1.3,41.1-32.3,74.7-73.4,73.4-37.2-1.2-67.6-31.5-68.8-68.8Z" />
                  <path d="M472.3,443.6l-40.4,52.7c-8.7,11.3-13.4,25.2-13.4,39.5v87.5c0,23-18.6,41.6-41.6,41.6H112.6c-41.8,0-75.7-33.9-75.7-75.7,0,0,99.5-554,187-554h153c23,0,35.6,47.3,43.2,72.4,67.5,225.1,130.8,262,52.2,336Z" />
                </svg>
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
