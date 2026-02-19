defmodule FizzWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: FizzWeb.Gettext

  alias Phoenix.LiveView.{JS, LiveStream}

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert flex gap-3 items-start",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :string
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            "select w-full",
            "bg-base-100 border-base-200",
            @class,
            @errors != [] && (@error_class || "select-error")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :rest, :global, include: ~w(phx-change phx-submit phx-target multipart as autocomplete)

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} {@rest}>
      <div class="mt-10 space-y-8 bg-base-100">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-end gap-3">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Renders a footer.
  """
  slot :inner_block, required: true

  def footer(assigns) do
    ~H"""
    <footer class="mt-10">
      {render_slot(@inner_block)}
    </footer>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a flexible data table with streaming support, loading states, and
  customizable slots for rows, empty states, and footers.

  ## Slots

    * `:col` – defines a column. The slot receives each row item via `:let`. Optional
      attributes:
        * `:label` – header label text.
        * `:class` – classes applied to table cells.
        * `:header_class` – classes applied to the header cell.
        * `:align` – shortcut for `text-left`, `text-center`, or `text-right`.
        * `:width` – CSS width value applied to the column.
    * `:action` – optional slot for row-level actions rendered in a dedicated column.
    * `:empty_state` – rendered when the table has no rows and is not loading.
    * `:skeleton_row` – optional skeleton markup shown while `loading?` is true.
    * `:footer` – rendered below the table, typically for pagination controls.

  ## Examples

      <.data_table id="users" rows={@streams.users} rows_empty?={@count == 0}>
        <:col :let={user} label="Name">{user.name}</:col>
        <:col :let={user} label="Email">{user.email}</:col>
        <:action :let={user}>
          <.link class="btn btn-ghost btn-xs">View</.link>
        </:action>
        <:empty_state>
          <div class="py-12 text-sm text-muted">No users found.</div>
        </:empty_state>
        <:footer>
          <div class="flex justify-between text-xs text-muted">
            Showing {@range_start}-{@range_end} of {@total}
          </div>
        </:footer>
      </.data_table>
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :row_id, :any, default: nil
  attr :row_item, :any, default: nil

  attr :row_class, :any,
    default: [
      "border-b",
      "border-base-200/70",
      "align-middle",
      "transition-colors",
      "hover:bg-neutral/10"
    ]

  attr :row_click, :any, default: nil
  attr :rows_empty?, :boolean, default: nil
  attr :loading?, :boolean, default: false
  attr :skeleton_rows, :integer, default: 3
  attr :class, :any, default: ["table", "w-full", "table-fixed", "table-hover", "text-sm"]
  attr :wrapper_class, :any, default: ["overflow-x-auto"]

  attr :thead_class, :any,
    default: [
      "sticky",
      "top-0",
      "z-10",
      "bg-base-100/95",
      "backdrop-blur",
      "text-xs",
      "font-semibold",
      "text-base-content/70",
      "border-b",
      "border-base-200"
    ]

  attr :tbody_class, :any, default: nil
  attr :actions_label, :string, default: nil
  attr :actions_header_class, :any, default: ["px-4", "py-3", "text-right", "align-middle"]
  attr :actions_label_class, :any, default: ["sr-only"]
  attr :actions_cell_class, :any, default: ["px-4", "py-3", "text-right", "align-middle"]

  attr :actions_container_class, :any,
    default: ["inline-flex", "items-center", "gap-1.5", "justify-end"]

  attr :rest, :global,
    include: ~w(phx-target phx-hook phx-update id data-role data-test aria-describedby)

  slot :col, required: true do
    attr :label, :string
    attr :class, :any
    attr :header_class, :any
    attr :align, :string
    attr :width, :string
  end

  slot :action do
    attr :class, :any
  end

  slot :empty_state
  slot :skeleton_row
  slot :footer

  def data_table(assigns) do
    assigns = data_table_prepare_assigns(assigns)

    ~H"""
    <div class={@wrapper_class}>
      <table class={@class} {@rest}>
        <thead class={@thead_class}>
          <tr>
            <th
              :for={col <- @col}
              class={data_table_header_class(col)}
              style={data_table_column_width(col)}
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class={@actions_header_class}>
              <span class={@actions_label_class}>
                {@actions_label || gettext("Actions")}
              </span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} class={@tbody_class} phx-update={@phx_update}>
          <%= if @loading? do %>
            <%= if @skeleton_row != [] do %>
              <%= for index <- 1..@skeleton_rows do %>
                {render_slot(@skeleton_row, index)}
              <% end %>
            <% else %>
              <tr :for={index <- 1..@skeleton_rows} id={"#{@id}-skeleton-#{index}"}>
                <td :for={_col <- @col} class="px-4 py-3">
                  <div class="skeleton h-4 w-3/4"></div>
                </td>
                <td :if={@action != []} class="px-4 py-3 text-right">
                  <div class="skeleton ml-auto h-6 w-6 rounded-full"></div>
                </td>
              </tr>
            <% end %>
          <% end %>

          <tr
            :if={data_table_show_empty?(@rows_empty?, @loading?) && @empty_state != []}
            id={"#{@id}-empty"}
            class="hover:bg-transparent"
          >
            <td colspan={@column_count} class="px-6 py-10 text-center text-sm text-muted">
              {render_slot(@empty_state)}
            </td>
          </tr>

          <tr
            :for={row <- @rows}
            id={data_table_row_dom_id(row, @row_id, @row_item)}
            class={data_table_row_class(row, @row_class)}
            phx-click={data_table_row_click(@row_click, row)}
          >
            <% item = @row_item.(row) %>
            <td
              :for={col <- @col}
              class={data_table_cell_class(col)}
              style={data_table_column_width(col)}
            >
              {render_slot(col, item)}
            </td>
            <td :if={@action != []} class={data_table_actions_cell_class(@actions_cell_class)}>
              <div class={@actions_container_class}>
                <%= for action <- @action do %>
                  <div class={List.wrap(action[:class] || [])}>
                    {render_slot(action, item)}
                  </div>
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@footer != []} class="mt-4">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  defp data_table_prepare_assigns(assigns) do
    row_item =
      case assigns[:row_item] do
        nil -> &data_table_default_row_item/1
        fun -> fun
      end

    rows_empty? =
      case assigns[:rows_empty?] do
        nil -> data_table_rows_empty?(assigns.rows)
        value -> value
      end

    assigns
    |> assign(:row_item, row_item)
    |> assign_new(:row_id, fn -> nil end)
    |> assign_new(:row_class, fn -> nil end)
    |> assign_new(:row_click, fn -> nil end)
    |> assign(:rows_empty?, rows_empty?)
    |> assign(:phx_update, data_table_phx_update(assigns.rows))
    |> assign(:column_count, data_table_column_count(assigns))
    |> assign(
      :class,
      List.wrap(assigns[:class] || ["table", "w-full", "table-fixed", "table-hover", "text-sm"])
    )
    |> assign(:wrapper_class, List.wrap(assigns[:wrapper_class] || "overflow-x-auto"))
    |> assign(:thead_class, List.wrap(assigns[:thead_class] || []))
    |> assign(:tbody_class, data_table_optional_class(assigns[:tbody_class]))
    |> assign(:actions_header_class, List.wrap(assigns[:actions_header_class] || []))
    |> assign(:actions_label_class, List.wrap(assigns[:actions_label_class] || []))
    |> assign(:actions_cell_class, List.wrap(assigns[:actions_cell_class] || []))
    |> assign(:actions_container_class, List.wrap(assigns[:actions_container_class] || []))
  end

  defp data_table_optional_class(nil), do: nil
  defp data_table_optional_class(value), do: List.wrap(value)

  defp data_table_column_count(assigns) do
    base = length(assigns.col || [])

    if assigns.action != [] do
      base + 1
    else
      base
    end
  end

  defp data_table_rows_empty?(%LiveStream{} = stream), do: Enum.empty?(stream)
  defp data_table_rows_empty?(rows) when is_list(rows), do: rows == []
  defp data_table_rows_empty?(rows), do: Enum.empty?(rows)

  defp data_table_phx_update(%LiveStream{}), do: "stream"
  defp data_table_phx_update(_), do: nil

  defp data_table_show_empty?(true, false), do: true
  defp data_table_show_empty?(_, _), do: false

  defp data_table_default_row_item({_, item}), do: item
  defp data_table_default_row_item(item), do: item

  defp data_table_row_dom_id(row, nil, row_item_fun) do
    cond do
      match?({_id, _}, row) and not is_nil(elem(row, 0)) ->
        data_table_normalize_dom_id(elem(row, 0))

      (item = row_item_fun.(row)) |> is_map() and Map.has_key?(item, :id) ->
        data_table_normalize_dom_id(item.id)

      true ->
        nil
    end
  end

  defp data_table_row_dom_id(row, row_id_fun, row_item_fun) when is_function(row_id_fun, 1) do
    row_id_fun.(row) || data_table_row_dom_id(row, nil, row_item_fun)
  end

  defp data_table_row_dom_id(row, row_id, row_item_fun) do
    row_id
    |> data_table_normalize_dom_id()
    |> case do
      nil -> data_table_row_dom_id(row, nil, row_item_fun)
      value -> value
    end
  end

  defp data_table_row_class(row, row_class) when is_function(row_class, 1) do
    row_class.(row)
  end

  defp data_table_row_class(_row, row_class) do
    row_class
  end

  defp data_table_row_click(nil, _row), do: nil
  defp data_table_row_click(row_click, row) when is_function(row_click, 1), do: row_click.(row)
  defp data_table_row_click(value, _row), do: value

  defp data_table_normalize_dom_id(value) when value in [nil, ""], do: nil
  defp data_table_normalize_dom_id(value) when is_binary(value), do: value
  defp data_table_normalize_dom_id(value), do: to_string(value)

  defp data_table_header_class(col) do
    base = [
      "px-4",
      "py-3",
      "align-middle",
      "text-xs",
      "font-semibold",
      "text-base-content/70"
    ]

    base
    |> data_table_apply_align(col[:align])
    |> Kernel.++(List.wrap(col[:header_class] || []))
  end

  defp data_table_cell_class(col) do
    base = ["px-4", "py-3", "align-middle"]

    base
    |> data_table_apply_align(col[:align])
    |> Kernel.++(List.wrap(col[:class] || []))
  end

  defp data_table_apply_align(classes, align) do
    additions =
      case align do
        nil -> ["text-left"]
        "left" -> ["text-left"]
        "text-left" -> ["text-left"]
        "center" -> ["text-center"]
        "text-center" -> ["text-center"]
        "right" -> ["text-right"]
        "text-right" -> ["text-right"]
        other -> [other]
      end

    classes
    |> Kernel.++(additions)
    |> Enum.uniq()
  end

  defp data_table_actions_cell_class(cell_class), do: List.wrap(cell_class || [])

  defp data_table_column_width(col) do
    width = col[:width]

    if width in [nil, ""] do
      nil
    else
      "width: #{width}"
    end
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a DaisyUI card with header, content, (optional) actions, and footer.

  ## Examples

    <.card variant={:elevated}>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-rocket-launch" class="size-4 opacity-70" />
          <span class="card-title text-base">Active Sessions</span>
        </div>
        <div class="text-xs opacity-70">Last 24h</div>
      </:header>

      <:content>
        <div class="text-4xl font-bold tracking-tight">42</div>
        <p class="text-sm opacity-75">+8 since yesterday</p>
      </:content>

      <:actions>
        <a href="/sessions" class="btn btn-sm btn-primary">View all</a>
        <button class="btn btn-sm btn-ghost">Refresh</button>
      </:actions>

      <:footer>
        <span class="text-xs opacity-70">Updated moments ago</span>
      </:footer>
    </.card>
  """
  slot :header, required: true
  slot :content, required: true
  slot :actions
  slot :footer
  attr :class, :string, default: nil
  attr :variant, :atom, default: :elevated, values: [:elevated, :soft, :outline]
  attr :hover, :boolean, default: true

  def card(assigns) do
    ~H"""
    <div class={[
      "card relative overflow-hidden transition-all duration-300 border border-base-300 ",
      "rounded-2xl",
      @variant == :elevated && "shadow-sm ring-1 ring-base-300/70 bg-base-100",
      @variant == :soft && "bg-base-200/60 ring-1 ring-base-300/60",
      @variant == :outline && "bg-base-100 border border-base-300",
      @hover && "hover:shadow-lg hover:ring-base-200",
      @class
    ]}>
      
    <!-- header -->
      <div
        :if={@header != []}
        class="flex items-center justify-between gap-3 border-b border-base-200 px-4 py-3"
      >
        <div class="flex min-w-0 items-center gap-2 w-full">
          {render_slot(@header)}
        </div>
      </div>
      
    <!-- body -->
      <div class="card-body px-6 py-5 gap-3">
        {render_slot(@content)}
        
    <!-- actions row (optional) -->
        <div :if={@actions != []} class="card-actions mt-1 justify-start">
          {render_slot(@actions)}
        </div>
      </div>
      
    <!-- footer (optional) -->
      <div :if={@footer != []} class="border-t border-base-200 px-6 py-3">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/canceling of the modal, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  The modal uses DaisyUI's modal classes.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div
        id={"#{@id}-bg"}
        class="fixed inset-0 bg-base-300/50 backdrop-blur-sm transition-opacity"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class="relative hidden rounded-2xl bg-base-100 p-10 shadow-lg ring-1 ring-base-content/10 transition"
            >
              <div class="absolute top-6 right-5">
                <button
                  type="button"
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  class="-m-3 flex-none p-3 opacity-20 hover:opacity-40"
                  aria-label={gettext("close")}
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a custom alert component with theme-aware styling.

  ## Examples

      <.alert kind={:info}>
        This is an info alert
      </.alert>

      <.alert kind={:error} title="Error occurred">
        Something went wrong
      </.alert>
  """
  attr :kind, :atom, values: [:info, :success, :warning, :error], default: :info
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  attr :icon_name, :string, default: nil

  slot :inner_block, required: true

  def alert(assigns) do
    icon_name =
      assigns.icon_name ||
        case assigns.kind do
          :info -> "hero-information-circle"
          :success -> "hero-check-circle"
          :warning -> "hero-exclamation-triangle"
          :error -> "hero-exclamation-circle"
        end

    assigns = assign(assigns, :icon_name, icon_name)

    ~H"""
    <div class={[
      "alert flex gap-3 items-start",
      @kind == :info && "alert-info",
      @kind == :success && "alert-success",
      @kind == :warning && "alert-warning",
      @kind == :error && "alert-error",
      @class
    ]}>
      <.icon name={@icon_name} class="size-5 shrink-0 mt-0.5" />
      <div class="flex-1">
        <p :if={@title} class="font-semibold mb-1">{@title}</p>
        <div>{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :any, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def icon(%{name: %{src: src} = config} = assigns) do
    assigns = assign(assigns, :src, src) |> assign(:config, config)

    ~H"""
    <div
      class={[@class, "inline-block flex-shrink-0 adaptive-icon"]}
      style={adaptive_icon_style(@config)}
    >
      <%= if !@config[:light_color] && !@config[:dark_color] do %>
        <img src={@src} class="w-full h-full object-contain" />
      <% end %>
    </div>
    """
  end

  def icon(%{name: name} = assigns) do
    if is_image_path?(name) do
      ~H"""
      <img src={@name} class={@class} />
      """
    else
      ~H"""
      <span class={["hero-question-mark-circle", @class]} />
      """
    end
  end

  defp adaptive_icon_style(%{src: src} = config) do
    light = config[:light_color]
    dark = config[:dark_color] || light

    mask_style =
      "-webkit-mask-image: url('#{src}'); mask-image: url('#{src}'); -webkit-mask-size: contain; mask-size: contain; -webkit-mask-repeat: no-repeat; mask-repeat: no-repeat; -webkit-mask-position: center; mask-position: center;"

    if light || dark do
      mask_style <> " --icon-light: #{light}; --icon-dark: #{dark};"
    else
      ""
    end
  end

  defp is_image_path?(name) when is_binary(name) do
    String.starts_with?(name, "/") or
      String.ends_with?(name, [".svg", ".png", ".jpg", ".jpeg", ".webp"])
  end

  defp is_image_path?(_), do: false

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-container",
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-container",
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(FizzWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(FizzWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
