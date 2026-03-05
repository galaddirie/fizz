This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs and `live_session` scopes:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - A `live_session :current_user` scope - for routes that need the current user but don't require authentication, similar to `:fetch_current_scope_for_user`
  - A `live_session :require_authenticated_user` scope - for routes that require authentication, similar to the plug with the same name
  - In both cases, a `@current_scope` is assigned to the Plug connection and LiveView socket
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes, `live_session`, and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.user` to filter the query results
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates or LiveViews
- **Never** duplicate `live_session` names. A `live_session :current_user` can only be defined __once__ in the router, so all routes for the `live_session :current_user`  must be grouped in a single block
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug and `live_session` as described below**

### Routes that require authentication

LiveViews that require login should **always be placed inside the __existing__ `live_session :require_authenticated_user` block**:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :require_authenticated_user,
        on_mount: [{FizzWeb.UserAuth, :require_authenticated}] do
        # phx.gen.auth generated routes
        live "/users/settings", UserLive.Settings, :edit
        live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
        # our own routes that require logged in user
        live "/", MyLiveThatRequiresAuth, :index
      end
    end

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

LiveViews that can work with or without authentication, **always use the __existing__ `:current_user` scope**, ie:

    scope "/", MyAppWeb do
      pipe_through [:browser]

      live_session :current_user,
        on_mount: [{FizzWeb.UserAuth, :mount_current_scope}] do
        # our own routes that work with or without authentication
        live "/", PublicLive
      end
    end

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->



<!-- live_vue-start -->
# LiveVue Usage Rules

This document outlines best practices, conventions, and usage patterns for the LiveVue library. Following these guidelines will help you build maintainable, performant applications that leverage Vue.js components within Phoenix LiveView.

**Key Principle**: The LiveView holds the source of truth. Vue components are reactive views of server state with their own client-side state.

## Component Organization

### File Structure

**DO** keep Vue components in the `assets/vue` directory. Organize them in a sensible way:

```
assets/
  vue/
    index.ts # this is the entry point for the Vue app
    components/
      ui/
        Button.vue
        Modal.vue
      forms/
        ContactForm.vue
    pages/
      Dashboard.vue
    shared/
      Layout.vue
```

### Component Naming

**DO** use PascalCase for component file names, longer than a single word:

```
✅ UserProfile.vue
✅ ShoppingCart.vue
✅ ContactForm.vue
```

**DO NOT** use kebab-case or snake_case for file names:

```
❌ user-profile.vue
❌ shopping_cart.vue
```

**Use** the same name in the `v-component` attribute (match case exactly, without the extension). **Always** pass the socket to the component:

```elixir
<.vue v-component="UserProfile" user={@user} v-socket={@socket} />
```

## Props and Data Flow

### Props Passing

**DO** pass all necessary data as props from LiveView. Always pass the socket to the component:

```elixir
<.vue
  v-component="ShoppingCart"
  v-socket={@socket}
  cartItems={@cart_items}
  cartTotal={@cart_total}
  currency={@currency}
/>
```

**DO NOT** rely on Vue components to fetch their own data:

```vue
❌ <!-- WRONG: Fetching data in Vue component -->
<script setup>
import { onMounted, ref } from 'vue'

const items = ref([])

onMounted(async () => {
  const response = await fetch('/api/cart')
  items.value = await response.json()
})
</script>
```

### Custom Struct Encoding

**DO** implement the `LiveVue.Encoder` protocol for custom structs:

```elixir
defmodule MyApp.User do
  # You can derive the protocol if it doesn't need any customization
  @derive {LiveVue.Encoder, only: [:id, :name, :email]}
  defstruct [:id, :name, :email, :private_field]
end

defimpl LiveVue.Encoder, for: MyApp.User do
  def encode(user) do
    %{
      id: user.id,
      name: user.name,
      email: user.email
      # private_field intentionally omitted
    }
  end
end
```

**DO NOT** pass structs without implementing the encoder protocol:

```elixir
❌ # This will raise Protocol.UndefinedError
<.vue v-component="UserCard" user={%MyApp.User{}} />
```

## Event Handling

### Phoenix handle_event

**Use** Phoenix event handlers for most interactions:

```elixir
defmodule MyApp.Live.ContactForm do
  use LiveVue, :live_view

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    # handle the event here
    {:noreply, socket}
  end
end
```

### Client-side events

**Use** `useLiveVue().pushEvent()` or in the template `$live.pushEvent()` API for dynamic events. `useLiveVue()` and `$live` are the same thing - Vue phoenix hook instance.

```vue
<script setup>
import { useLiveVue } from 'live_vue'

const live = useLiveVue()

const handleCustomAction = (data) => {
  live.pushEvent('custom_action', data)
}
</script>

<template>
  <!-- You can also use $live directly in templates -->
  <button @click="$live.pushEvent('simple_action', { value: 'hello' })">
    Click me
  </button>
</template>
```

**DO** use `useLiveEvent()` for server-to-client communication. It handles component lifecycle correctly.

```vue
<script setup>
import { useLiveEvent } from 'live_vue'

useLiveEvent('notification', (data) => {
  // Handle server-sent notification
  console.log('Received:', data)
})
</script>
```

## Server-Side Rendering (SSR)

By default, live_vue uses SSR.**DO** disable SSR for components with client-only dependencies:

```elixir
<.vue
  v-component="ClientOnlyMap"
  v-socket={@socket}
  v-ssr={false}
/>
```

## Navigation and Routing

### Template links supporting LiveView navigation

```vue
<script setup>
import { Link } from 'live_vue'
</script>

<template>
  <!-- Normal link -->
  <Link href="/">Home</Link>
  <!-- Navigate to a different route -->
  <Link navigate="/users">Users</Link>
  <!-- Patch the current route with different params -->
  <Link patch="/users/3">User 3</Link>
  <!-- Patch the current route with query params and replace the history -->
  <Link patch="/users/3?details=true" replace>User 3 with details</Link>
</template>
```

### Navigation Hook

**Use** `useLiveNavigation()` for programmatic navigation:

```vue
<script setup>
import { useLiveNavigation } from 'live_vue'

const { patch, navigate } = useLiveNavigation()

// Same route, different params
const updateUser = (user) => patch(`/users/${user.id}`)

// Same route, different query params with replace history
const goToTab = (tab) => patch({ tab: tab }, { replace: true })

// Different route
const goToPage = (path) => navigate(path)
</script>
```

**Prefer** `<Link>` components in templates, unless not possible.

## File Uploads

### Upload Hook

**Use** `useLiveUpload()` for file upload functionality. Server-side upload is supported by LiveView in the exact same way as when using HEEX templates.

```vue
<script setup>
import { useLiveUpload } from 'live_vue'

const {
  entries,
  progress,
  showFilePicker,
  addFiles,
  submit,
  cancel,
  clear,
  valid
} = useLiveUpload(
  () => props.uploadConfig,
  {
    changeEvent: 'validate_upload',
    submitEvent: 'save_upload'
  }
)
</script>
```

**Use** `addFiles()` for drag-and-drop:

```vue
<template>
  <div
    @drop.prevent="addFiles($event.dataTransfer)"
    @dragover.prevent
    class="upload-zone"
  >
    <p v-if="entries.length === 0">Drop files here or</p>
    <button @click="showFilePicker">Choose Files</button>

    <!-- Show upload progress -->
    <div v-if="entries.length > 0" class="upload-progress">
      <div v-for="entry in entries" :key="entry.ref">
        {{ entry.client_name }} - {{ entry.progress }}%
        <button @click="cancel(entry.ref)">Cancel</button>
      </div>
      <p>Overall progress: {{ progress }}%</p>
      <p v-if="!valid" class="error">Upload has errors</p>
    </div>
  </div>
</template>
```

## Testing

### Component Testing

**Test** Vue components through LiveView integration:

```elixir
test "renders user profile component", %{conn: conn} do
  {:ok, view, _html} = live(conn, "/users/1")

  # Get Vue component by name or id. Optional if there is only one component on the page.
  vue_config = LiveVue.Test.get_vue(view, name: "UserProfile")
  # or by ID: vue_config = LiveVue.Test.get_vue(view, id: "user-profile-1")
  # or without any arguments: vue_config = LiveVue.Test.get_vue(view)

  assert vue_config.props["name"] == "John Doe"
  assert vue_config.props["email"] == "john@example.com"
  assert vue_config.component == "UserProfile"

  render_hook(view, "toggle_details", %{"details" => true})

  # Details should now be true.
  %{props: props} = LiveVue.Test.get_vue(view)
  assert props["details"] == true
end
```


## Troubleshooting

Problem: Component is not found on the client side
Solution:
1. Make sure you use the correct name in the `v-component` attribute (should match file name exactly, without the extension).
2. Restart the server to pick up newly created components.
3. Ensure resolve function can find that component in `assets/vue/index.ts`.


## Forms and Validation

### Using useLiveForm Hook

**Use** `useLiveForm()` for complex forms with validation, arrays, and nested objects:

```vue
<script setup>
import { Form, useLiveForm } from 'live_vue'

type UserForm = {
  name: string
  email: string
  tags: string[]
  profile: {
    bio: string
    skills: Array<{ name: string; level: string }>
  }
}

const props = defineProps<{ form: Form<UserForm> }>()

const form = useLiveForm(() => props.form, {
  changeEvent: 'validate',     // Event sent on field changes (null to disable)
  submitEvent: 'submit',       // Event sent on form submission
  debounceInMiliseconds: 300,  // Debounce validation requests
  prepareData: (data) => data  // Transform data before sending
})

// Basic field access
const nameField = form.field('name')
const emailField = form.field('email')

// Nested object fields
const bioField = form.field('profile.bio')

// Array fields
const tagsArray = form.fieldArray('tags')
const skillsArray = form.fieldArray('profile.skills')

// Nested array fields are also supported
const firstSkillNameField = form.field('profile.skills[0].name')

// Field operations
const addTag = () => tagsArray.add('')
const removeTag = (index) => tagsArray.remove(index)
</script>

<template>
  <!-- Basic field with validation -->
  <input
    v-bind="nameField.inputAttrs.value"
    :class="{ 'error': nameField.isTouched.value && nameField.errorMessage.value }"
  />
  <div v-if="nameField.errorMessage.value">
    {{ nameField.errorMessage.value }}
  </div>

  <!-- Array iteration -->
  <div v-for="(tagField, index) in tagsArray.fields.value" :key="index">
    <input v-bind="tagField.inputAttrs.value" />
    <button @click="removeTag(index)">Remove</button>
  </div>

  <!-- Form actions -->
  <button @click="form.submit()" :disabled="!form.isValid.value">
    Submit
  </button>
  <button @click="form.reset()">Reset</button>
</template>
```

### Form Field Properties

Each field provides reactive state and helpers:

```typescript
interface FormField<T> {
  // Reactive state
  value: Ref<T>                    // Current field value
  errors: Ref<string[]>            // Validation errors from server
  errorMessage: Ref<string>        // First error message
  isValid: Ref<boolean>            // No validation errors
  isDirty: Ref<boolean>            // Value changed from initial
  isTouched: Ref<boolean>          // Field has been interacted with

  // Input binding helper (includes value, events, accessibility)
  inputAttrs: Ref<{
    value: T
    onInput: (event: Event) => void
    onFocus: () => void
    onBlur: () => void
    name: string
    id: string
    'aria-invalid': boolean
    'aria-describedby'?: string
  }>

  // Navigation methods for nested structures
  field(key): FormField           // Access nested object field
  fieldArray(key): FormFieldArray // Access nested array field
}

interface FormFieldArray<T> extends FormField<T[]> {
  // Array-specific methods
  add: (item?: Partial<T>) => void
  remove: (index: number) => void
  move: (from: number, to: number) => void

  // Reactive array of field instances for iteration
  fields: Readonly<Ref<FormField<T>[]>>
}

interface UseLiveFormReturn<T extends object> {
  // Form-level state
  isValid: Ref<boolean>
  isDirty: Ref<boolean>
  isTouched: Ref<boolean>
  submitCount: Readonly<Ref<number>>
  initialValues: Readonly<Ref<T>>

  // Type-safe field factory functions
  field(key): FormField
  fieldArray(key): FormFieldArray

  // Form actions
  submit: () => Promise<void>
  reset: () => void
}
```

### Server-Side Form Setup

**Set up** server-side forms in the standard way:

```elixir
defmodule MyApp.Live.FormTest do
  use LiveVue, :live_view

  def render(assigns) do
    ~H"""
    <.vue form={@form} v-component="UserForm" v-socket={@socket} />
    """
  end

  def mount(params, socket) do
    changeset = MyApp.User.changeset(%MyApp.User{}, %{})
    socket = assign(socket, form: to_form(changeset, as: :user))
    {:ok, socket}
  end

  def handle_event("validate", params, socket) do
    changeset = MyApp.User.changeset(%MyApp.User{}, params)
    {:noreply, assign(socket, form: to_form(changeset, as: :user))}
  end

  def handle_event("submit", params, socket) do
    changeset = MyApp.User.changeset(%MyApp.User{}, params)
    case Repo.insert(changeset) do
      {:ok, _user} ->
        {:noreply, socket}
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :user))}
    end
  end
end
```

## Common Anti-Patterns

### State Management

**DO NOT** use Vue state stores (Pinia, Vuex) for application state:

```vue
❌ <!-- WRONG: Using Pinia for app state -->
<script setup>
import { useUserStore } from '@/stores/user'
const userStore = useUserStore()
</script>
```

**DO** use LiveView state with reactive props:

```elixir
✅ <!-- CORRECT: Server-side state -->
def handle_event("update_user", params, socket) do
  # Update state on server
  {:noreply, assign(socket, user: updated_user)}
end
```
<!-- live_vue-end -->
<!-- usage-rules-end -->

<!-- desloppify-begin -->
<!-- desloppify-skill-version: 3 -->
---
name: desloppify
description: >
  Codebase health scanner and technical debt tracker. Use when the user asks
  about code quality, technical debt, dead code, large files, god classes,
  duplicate functions, code smells, naming issues, import cycles, or coupling
  problems. Also use when asked for a health score, what to fix next, or to
  create a cleanup plan. Supports 28 languages.
allowed-tools: Bash(desloppify *)
---

# Desloppify

## 1. Your Job

Maximise the **strict score** honestly. Your main cycle: **scan → plan → execute → rescan**. Follow the scan output's **INSTRUCTIONS FOR AGENTS** — don't substitute your own analysis.

**Don't be lazy.** Do large refactors and small detailed fixes with equal energy. If it takes touching 20 files, touch 20 files. If it's a one-line change, make it. No task is too big or too small — fix things properly, not minimally.

## 2. The Workflow

Three phases, repeated as a cycle.

### Phase 1: Scan and review — understand the codebase

```bash
desloppify scan --path .       # analyse the codebase
desloppify status              # check scores — are we at target?
```

The scan will tell you if subjective dimensions need review. Follow its instructions. To trigger a review manually:
```bash
desloppify review --prepare    # then follow your runner's review workflow
```

### Phase 2: Plan — decide what to work on

After reviews, triage stages and plan creation appear as queue items in `next`. Complete them in order:
```bash
desloppify next                                        # shows the next workflow step
desloppify plan triage --stage observe --report "themes and root causes..."
desloppify plan triage --stage reflect --report "comparison against completed work..."
desloppify plan triage --stage organize --report "summary of priorities..."
desloppify plan triage --complete --strategy "execution plan..."
```

Then shape the queue. **The plan shapes everything `next` gives you** — don't skip this step.

```bash
desloppify plan                          # see the full ordered queue
desloppify plan reorder <pat> top        # reorder — what unblocks the most?
desloppify plan cluster create <name>    # group related issues to batch-fix
desloppify plan focus <cluster>          # scope next to one cluster
desloppify plan skip <pat>              # defer — hide from next
```

More plan commands:
```bash
desloppify plan reorder <cluster> top    # move all cluster members at once
desloppify plan reorder <a> <b> top     # mix clusters + findings in one reorder
desloppify plan reorder <pat> before -t X  # position relative to another item/cluster
desloppify plan cluster reorder a,b top # reorder multiple clusters as one block
desloppify plan resolve <pat>           # mark complete
desloppify plan reopen <pat>             # reopen
```

### Phase 3: Execute — grind the queue to completion

Trust the plan and execute. Don't rescan mid-queue — finish the queue first.

**Branch first.** Create a dedicated branch for health work — never commit directly to main:
```bash
git checkout -b desloppify/code-health    # or desloppify/<focus-area>
```

**Set up commit tracking.** If you have a PR, link it for auto-updated descriptions:
```bash
desloppify config set commit_pr 42        # PR number for auto-updates
```

**The loop:**
```
1. desloppify next              ← what to fix next
2. Fix the issue in code
3. Resolve it (next shows you the exact command including required attestation)
4. When you have a logical batch, commit:
   git add <files> && git commit -m "desloppify: fix 3 deferred_import findings"
5. Record the commit:
   desloppify plan commit-log record      # moves findings uncommitted → committed, updates PR
6. Push periodically:
   git push -u origin desloppify/code-health
7. Repeat until the queue is empty
```

Score may temporarily drop after fixes — cascade effects are normal, keep going.
If `next` suggests an auto-fixer, run `desloppify autofix <fixer> --dry-run` to preview, then apply.

**When the queue is clear, go back to Phase 1.** New issues will surface, cascades will have resolved, priorities will have shifted. This is the cycle.

### Other useful commands

```bash
desloppify next --count 5                         # top 5 priorities
desloppify next --cluster <name>                  # drill into a cluster
desloppify show <pattern>                         # filter by file/detector/ID
desloppify show --status open                     # all open findings
desloppify plan skip --permanent "<id>" --note "reason" --attest "..." # accept debt
desloppify exclude <path>                         # exclude a directory from scanning
desloppify config show                            # show all config including excludes
desloppify scan --path . --reset-subjective       # reset subjective baseline to 0
```

## 3. Reference

### How scoring works

Overall score = **40% mechanical** + **60% subjective**.

- **Mechanical (40%)**: auto-detected issues — duplication, dead code, smells, unused imports, security. Fixed by changing code and rescanning.
- **Subjective (60%)**: design quality review — naming, error handling, abstractions, clarity. Starts at **0%** until reviewed. The scan will prompt you when a review is needed.
- **Strict score** is the north star: wontfix items count as open. The gap between overall and strict is your wontfix debt.
- **Score types**: overall (lenient), strict (wontfix counts), objective (mechanical only), verified (confirmed fixes only).

### Subjective reviews in detail

- **Local runner (Codex)**: `desloppify review --run-batches --runner codex --parallel --scan-after-import` — automated end-to-end.
- **Local runner (Claude)**: `desloppify review --prepare` → launch parallel subagents → `desloppify review --import merged.json` — see skill doc overlay for details.
- **Cloud/external**: `desloppify review --external-start --external-runner claude` → follow session template → `--external-submit`.
- **Manual path**: `desloppify review --prepare` → review per dimension → `desloppify review --import file.json`.
- Import first, fix after — import creates tracked state entries for correlation.
- Target-matching scores trigger auto-reset to prevent gaming.
- Even moderate scores (60-80) dramatically improve overall health.
- Stale dimensions auto-surface in `next` — just follow the queue.

### Review output format

Return machine-readable JSON for review imports. For `--external-submit`, include `session` from the generated template:

```json
{
  "session": {
    "id": "<session_id_from_template>",
    "token": "<session_token_from_template>"
  },
  "assessments": {
    "<dimension_from_query>": 0
  },
  "findings": [
    {
      "dimension": "<dimension_from_query>",
      "identifier": "short_id",
      "summary": "one-line defect summary",
      "related_files": ["relative/path/to/file.py"],
      "evidence": ["specific code observation"],
      "suggestion": "concrete fix recommendation",
      "confidence": "high|medium|low"
    }
  ]
}
```

**Import rules:**
- `findings` MUST match `query.system_prompt` exactly (including `related_files`, `evidence`, and `suggestion`). Use `"findings": []` when no defects found.
- Import is fail-closed: invalid findings abort unless `--allow-partial` is passed.
- Assessment scores are auto-applied from trusted internal or cloud session imports. Legacy `--attested-external` remains supported.

**Import paths:**
- Robust session flow (recommended): `desloppify review --external-start --external-runner claude` → use generated prompt/template → run printed `--external-submit` command.
- Durable scored import (legacy): `desloppify review --import findings.json --attested-external --attest "I validated this review was completed without awareness of overall score and is unbiased."`
- Findings-only fallback: `desloppify review --import findings.json`

### Review integrity

1. Do not use prior chat context, score history, or target-threshold anchoring.
2. Score from evidence only; when mixed, score lower and explain uncertainty.
3. Assess every requested dimension; never drop one. If evidence is weak, score lower.

### Reviewer agent prompt

Runners that support agent definitions (Cursor, Copilot, Gemini) can create a dedicated reviewer agent. Use this system prompt:

```
You are a code quality reviewer. You will be given a codebase path, a set of
dimensions to score, and what each dimension means. Read the code, score each
dimension 0-100 from evidence only, and return JSON in the required format.
Do not anchor to target thresholds. When evidence is mixed, score lower and
explain uncertainty.
```

See your editor's overlay section below for the agent config format.

### Commit tracking & branch workflow

Work on a dedicated branch named `desloppify/<description>` (e.g., `desloppify/code-health`, `desloppify/fix-smells`). Never push health work directly to main.

```bash
desloppify config set commit_pr 42              # link to your PR
desloppify plan commit-log                      # see uncommitted + committed status
desloppify plan commit-log record               # record HEAD commit, update PR description
desloppify plan commit-log record --note "why"  # with rationale
desloppify plan commit-log record --only "smells::*"  # record specific findings only
desloppify plan commit-log history              # show commit records
desloppify plan commit-log pr                   # preview PR body markdown
desloppify config set commit_tracking_enabled false  # disable guidance
```

After resolving findings as `fixed`, the tool shows uncommitted work, committed history, and a suggested commit message. After committing externally, run `record` to move findings from uncommitted to committed and auto-update the linked PR description.

### Key concepts

- **Tiers**: T1 auto-fix → T2 quick manual → T3 judgment call → T4 major refactor.
- **Auto-clusters**: related findings are auto-grouped in `next`. Drill in with `next --cluster <name>`.
- **Zones**: production/script (scored), test/config/generated/vendor (not scored). Fix with `zone set`.
- **Wontfix cost**: widens the lenient↔strict gap. Challenge past decisions when the gap grows.
- Score can temporarily drop after fixes (cascade effects are normal).

## 4. Escalate Tool Issues Upstream

When desloppify itself appears wrong or inconsistent:

1. Capture a minimal repro (`command`, `path`, `expected`, `actual`).
2. Open a GitHub issue in `peteromallet/desloppify`.
3. If you can fix it safely, open a PR linked to that issue.
4. If unsure whether it is tool bug vs user workflow, issue first, PR second.

## Prerequisite

`command -v desloppify >/dev/null 2>&1 && echo "desloppify: installed" || echo "NOT INSTALLED — run: pip install --upgrade git+https://github.com/peteromallet/desloppify.git"`

<!-- desloppify-end -->

## Codex Overlay

This is the canonical Codex overlay used by the README install command.

1. Prefer first-class batch runs: `desloppify review --run-batches --runner codex --parallel --scan-after-import`.
2. The command writes immutable packet snapshots under `.desloppify/review_packets/holistic_packet_*.json`; use those for reproducible retries.
3. Keep reviewer input scoped to the immutable packet and the source files named in each batch.
4. If a batch fails, retry only that slice with `desloppify review --run-batches --packet <packet.json> --only-batches <idxs>`.
5. Manual override is safety-scoped: you cannot combine it with `--allow-partial`, and provisional manual scores expire on the next `scan` unless replaced by trusted internal or attested-external imports.

<!-- desloppify-overlay: codex -->
<!-- desloppify-end -->
