defmodule NixployWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use NixployWeb, :html

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

  attr :current_operator, :map, default: nil, doc: "the authenticated operator"
  attr :current_path, :string, default: nil, doc: "the active top-level utility route"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200/35">
      <a
        href="#main-content"
        class="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-50 focus:rounded-field focus:bg-base-100 focus:px-4 focus:py-3 focus:shadow-lg"
      >
        Skip to content
      </a>

      <header class="sticky top-0 z-40 border-b border-base-300 bg-base-100/95 backdrop-blur-xl">
        <div class="mx-auto flex max-w-[96rem] items-center gap-3 px-3 py-2 sm:px-5">
          <.link navigate={~p"/"} class="flex shrink-0 items-center gap-2.5 font-semibold">
            <span class="grid size-8 place-items-center rounded-field bg-base-content font-mono text-xs font-black text-base-100">
              N/
            </span>
            <span class="hidden tracking-tight sm:inline">nixploy</span>
          </.link>

          <nav
            aria-label="Primary navigation"
            class="min-w-0 flex-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
          >
            <div class="flex min-w-max items-center gap-1">
              <.utility_nav_link path="/" active_path={@current_path} icon="hero-squares-2x2">
                Overview
              </.utility_nav_link>
              <.utility_nav_link
                path="/workloads"
                active_path={@current_path}
                icon="hero-cube"
              >
                Workloads
              </.utility_nav_link>
              <.utility_nav_link
                path="/deployment-inputs"
                active_path={@current_path}
                icon="hero-archive-box-arrow-down"
              >
                Inputs
              </.utility_nav_link>
              <.utility_nav_link
                path="/native-deployments"
                active_path={@current_path}
                icon="hero-command-line"
              >
                Operations
              </.utility_nav_link>
            </div>
          </nav>

          <div class="flex shrink-0 items-center gap-2">
            <span
              :if={@current_operator}
              class="hidden max-w-44 truncate font-mono text-[0.68rem] text-base-content/50 xl:block"
            >
              {@current_operator.email}
            </span>
            <.link
              :if={@current_operator && NixployWeb.OperatorAuth.password_auth?()}
              href={~p"/logout"}
              method="delete"
              class="btn btn-ghost btn-sm hidden sm:inline-flex"
            >
              Sign out
            </.link>
            <.theme_toggle />
          </div>
        </div>
      </header>

      <main id="main-content" tabindex="-1" class="px-3 py-5 sm:px-5 sm:py-7">
        <div class="mx-auto max-w-[96rem] min-w-0">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :path, :string, required: true
  attr :active_path, :string, default: nil
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp utility_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      aria-current={if @active_path == @path, do: "page"}
      class={[
        "flex min-h-10 items-center gap-2 rounded-field px-3 text-sm font-medium transition",
        @active_path == @path && "bg-base-content text-base-100 shadow-sm",
        @active_path != @path && "text-base-content/60 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </.link>
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
end
