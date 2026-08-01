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
    <div class="min-h-screen bg-base-200/35 lg:pl-64">
      <a
        href="#main-content"
        class="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70] focus:rounded-field focus:bg-base-100 focus:px-4 focus:py-3 focus:shadow-lg"
      >
        Skip to content
      </a>

      <aside class="fixed inset-y-0 left-0 z-40 hidden w-64 flex-col border-r border-base-300 bg-base-100 lg:flex">
        <div class="flex h-16 items-center gap-3 border-b border-base-300 px-5">
          <.brand />
        </div>

        <nav class="flex-1 space-y-1 p-3" aria-label="Primary navigation">
          <.utility_nav_link path="/" active_path={@current_path} icon="hero-squares-2x2">
            Overview
          </.utility_nav_link>
          <.utility_nav_link path="/machine" active_path={@current_path} icon="hero-server-stack">
            Machine
          </.utility_nav_link>
          <.utility_nav_link path="/applications" active_path={@current_path} icon="hero-cube">
            Applications
          </.utility_nav_link>
          <.utility_nav_link
            path="/releases"
            active_path={@current_path}
            icon="hero-rocket-launch"
          >
            Releases
          </.utility_nav_link>
          <.utility_nav_link
            path="/deployments"
            active_path={@current_path}
            icon="hero-clock"
          >
            Deployments
          </.utility_nav_link>
        </nav>

        <div class="space-y-3 border-t border-base-300 p-4">
          <p :if={@current_operator} class="truncate font-mono text-[0.68rem] text-base-content/50">
            {@current_operator.email}
          </p>
          <div class="flex items-center justify-between gap-2">
            <.theme_toggle />
            <.link
              :if={@current_operator && NixployWeb.OperatorAuth.password_auth?()}
              href={~p"/logout"}
              method="delete"
              class="btn btn-ghost btn-sm"
            >
              Sign out
            </.link>
          </div>
        </div>
      </aside>

      <header class="sticky top-0 z-40 flex h-16 items-center justify-between border-b border-base-300 bg-base-100/95 px-4 backdrop-blur-xl lg:hidden">
        <.brand />
        <div class="flex items-center gap-3">
          <span class="text-sm font-medium text-base-content/55">
            {current_path_label(@current_path)}
          </span>
          <button
            id="mobile-nav-open"
            type="button"
            phx-click={open_mobile_nav()}
            aria-label="Open navigation"
            aria-controls="mobile-nav"
            aria-expanded="false"
            class="grid size-11 place-items-center rounded-field border border-base-300 bg-base-100 text-base-content transition active:scale-95"
          >
            <.icon name="hero-bars-3" class="size-6" />
          </button>
        </div>
      </header>

      <div
        id="mobile-nav"
        role="dialog"
        aria-modal="true"
        aria-label="Navigation"
        aria-hidden="true"
        phx-window-keydown={close_mobile_nav()}
        phx-key="escape"
        class="fixed inset-0 z-[60] hidden min-h-dvh overflow-y-auto bg-base-100 lg:hidden"
      >
        <div class="flex min-h-dvh flex-col p-4">
          <div class="flex h-12 items-center justify-between">
            <.brand />
            <button
              id="mobile-nav-close"
              type="button"
              phx-click={close_mobile_nav()}
              aria-label="Close navigation"
              class="grid size-11 place-items-center rounded-field border border-base-300"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
          </div>

          <nav class="my-auto space-y-2 py-10" aria-label="Mobile navigation">
            <.mobile_nav_link
              path="/"
              active_path={@current_path}
              icon="hero-squares-2x2"
            >
              Overview
            </.mobile_nav_link>
            <.mobile_nav_link
              path="/machine"
              active_path={@current_path}
              icon="hero-server-stack"
            >
              Machine
            </.mobile_nav_link>
            <.mobile_nav_link
              path="/applications"
              active_path={@current_path}
              icon="hero-cube"
            >
              Applications
            </.mobile_nav_link>
            <.mobile_nav_link
              path="/releases"
              active_path={@current_path}
              icon="hero-rocket-launch"
            >
              Releases
            </.mobile_nav_link>
            <.mobile_nav_link
              path="/deployments"
              active_path={@current_path}
              icon="hero-clock"
            >
              Deployments
            </.mobile_nav_link>
          </nav>

          <div class="flex items-end justify-between gap-3 border-t border-base-300 pt-4">
            <div class="min-w-0">
              <p class="np-kicker">Signed in</p>
              <p :if={@current_operator} class="mt-1 truncate font-mono text-xs">
                {@current_operator.email}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <.link
                :if={@current_operator && NixployWeb.OperatorAuth.password_auth?()}
                href={~p"/logout"}
                method="delete"
                class="btn btn-ghost btn-sm"
              >
                Sign out
              </.link>
              <.theme_toggle />
            </div>
          </div>
        </div>
      </div>

      <main id="main-content" tabindex="-1" class="px-3 py-5 sm:px-5 sm:py-7 lg:px-8">
        <div class="mx-auto max-w-[80rem] min-w-0">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="flex shrink-0 items-center gap-2.5 font-semibold">
      <span class="grid size-9 place-items-center rounded-field bg-base-content font-mono text-xs font-black text-base-100">
        N/
      </span>
      <span class="tracking-tight">nixploy</span>
    </.link>
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
        "flex min-h-11 w-full items-center gap-3 rounded-field px-3 text-sm font-medium transition",
        @active_path == @path && "bg-base-content text-base-100 shadow-sm",
        @active_path != @path && "text-base-content/60 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-5 shrink-0" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :path, :string, required: true
  attr :active_path, :string, default: nil
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp mobile_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      phx-click={close_mobile_nav()}
      aria-current={if @active_path == @path, do: "page"}
      class={[
        "flex min-h-16 items-center gap-4 rounded-box px-4 text-xl font-semibold transition",
        @active_path == @path && "bg-base-content text-base-100",
        @active_path != @path && "text-base-content hover:bg-base-200"
      ]}
    >
      <.icon name={@icon} class="size-6 shrink-0" />
      <span>{render_slot(@inner_block)}</span>
      <.icon name="hero-chevron-right" class="ml-auto size-5 opacity-40" />
    </.link>
    """
  end

  defp current_path_label("/"), do: "Overview"
  defp current_path_label("/machine"), do: "Machine"
  defp current_path_label("/applications"), do: "Applications"
  defp current_path_label("/releases"), do: "Releases"
  defp current_path_label("/deployments"), do: "Deployments"
  defp current_path_label(_path), do: "nixploy"

  defp open_mobile_nav do
    JS.show(
      to: "#mobile-nav",
      transition: {"transition ease-out duration-200", "opacity-0", "opacity-100"}
    )
    |> JS.set_attribute({"aria-hidden", "false"}, to: "#mobile-nav")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#mobile-nav-open")
  end

  defp close_mobile_nav do
    JS.hide(
      to: "#mobile-nav",
      transition: {"transition ease-in duration-150", "opacity-100", "opacity-0"}
    )
    |> JS.set_attribute({"aria-hidden", "true"}, to: "#mobile-nav")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#mobile-nav-open")
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
