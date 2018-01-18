defmodule Drab do
  @moduledoc """
  Drab allows to query and manipulate the User Interface directly from the Phoenix server backend.

  To enable it on the specific page you must find its controller and
  enable Drab by `use Drab.Controller` there:

      defmodule DrabExample.PageController do
        use Example.Web, :controller
        use Drab.Controller

        def index(conn, _params) do
          render conn, "index.html"
        end
      end

  Notice that it will enable Drab on all the pages generated by `DrabExample.PageController`.

  All Drab functions (callbacks and event handlers) should be placed in a module called 'commander'. It is very
  similar to controller, but it does not render any pages - it works with the live page instead. Each controller with
  enabled Drab should have the corresponding commander.

      defmodule DrabExample.PageCommander do
        use Drab.Commander

        onload :page_loaded

        # Drab Callbacks
        def page_loaded(socket) do
          set_prop socket, "div.jumbotron h2", innerHTML: "This page has been DRABBED"
        end

        # Drab Events
        def button_clicked(socket, sender) do
          set_prop socket, this(sender), innerText: "already clicked"
        end

      end

  ## Debugging Drab in IEx

  When started with iex (`iex -S mix phoenix.server`) Drab shows the helpful message on how to debug its functions:

          Started Drab for /drab/docs, handling events in DrabPoc.DocsCommander
          You may debug Drab functions in IEx by copy/paste the following:
      import Drab.{Core, Query, Modal, Waiter}
      socket = Drab.get_socket(pid("0.443.0"))

          Examples:
      socket |> select(:htmls, from: "h4")
      socket |> exec_js("alert('hello from IEx!')")
      socket |> alert("Title", "Sure?", buttons: [ok: "Azaliż", cancel: "Poniechaj"])

  All you need to do is to copy/paste the line with `socket = ...` and now you can run Drab function directly
  from IEx, observing the results on the running browser in the realtime.


  ## Handling Exceptions

  Drab intercepts all exceptions from event handler function and let it die, but before it presents the error message
  in the logs and an alert for a user on the page.

  By default it is just an `alert()`, but you can easly override it by creating the template in the
  `priv/templates/drab/drab.error_handler.js` folder with your own javascript presenting the message. You may use
  the local variable `message` there to get the exception description, like:

      alert(<%= message %>);

  ## Modules

  Drab is modular. You may choose which modules to use in the specific Commander by using `:module` option
  in `use Drab.Commander` directive. By default, `Drab.Live` and `Drab.Element` are loaded, but you may override it
  using  `modules` option with `use Drab.Commander` directive.

  Every module must have the corresponding javascript template, which is added to the client code in case
  the module is loaded.

  `Drab.Core` module is always loaded.

  ## Learnig Drab

  There is a [tutorial/demo page](https://tg.pl/drab).

  The point to start reading docs should be `Drab.Core`.
  """

  require Logger
  use GenServer

  @type t :: %Drab{
          store: map,
          session: map,
          commander: atom,
          socket: Phoenix.Socket.t(),
          priv: map
        }

  defstruct store: %{}, session: %{}, commander: nil, socket: nil, priv: %{}

  @doc false
  def start_link(socket) do
    GenServer.start_link(__MODULE__, %Drab{commander: Drab.get_commander(socket)})
  end

  @doc false
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @doc false
  def terminate(_reason, %Drab{store: store, session: session, commander: commander} = state) do
    if commander.__drab__().ondisconnect do
      # TODO: timeout
      :ok = apply(commander, commander_config(commander).ondisconnect, [store, session])
    end

    {:noreply, state}
  end

  @doc false
  def handle_info({:EXIT, pid, :normal}, state) when pid != self() do
    # ignore exits of the subprocesses
    # Logger.debug "************** #{inspect pid} process exit normal"

    {:noreply, state}
  end

  @doc false
  def handle_info({:EXIT, pid, :killed}, state) when pid != self() do
    failed(state.socket, %RuntimeError{message: "Drab Process #{inspect(pid)} has been killed."})
    {:noreply, state}
  end

  @doc false
  def handle_info({:EXIT, pid, {reason, stack}}, state) when pid != self() do
    # subprocess died
    Logger.error("""
    Drab Process #{inspect(pid)} died because of #{inspect(reason)}
    #{Exception.format_stacktrace(stack)}
    """)

    {:noreply, state}
  end

  @doc false
  def handle_cast({:onconnect, socket, payload}, %Drab{commander: commander} = state) do
    # TODO: there is an issue when the below failed and client tried to reconnect again and again
    # tasks = [Task.async(fn -> Drab.Core.save_session(socket, Drab.Core.session(socket)) end),
    #          Task.async(fn -> Drab.Core.save_store(socket, Drab.Core.store(socket)) end)]
    # Enum.each(tasks, fn(task) -> Task.await(task) end)

    # Logger.debug "******"
    # Logger.debug inspect(Drab.Core.session(socket))

    # IO.inspect payload

    socket = transform_socket(payload["payload"], socket, state)

    Drab.Core.save_session(
      socket,
      Drab.Core.detokenize_store(socket, payload["drab_session_token"])
    )

    Drab.Core.save_store(socket, Drab.Core.detokenize_store(socket, payload["drab_store_token"]))
    Drab.Core.save_socket(socket)

    onconnect = commander_config(commander).onconnect
    handle_callback(socket, commander, onconnect)

    {:noreply, state}
  end

  @doc false
  def handle_cast({:onload, socket, payload}, %Drab{commander: commander} = state) do
    # {_, socket} = transform_payload_and_socket(payload, socket, commander_module)
    # IO.inspect payload

    socket = transform_socket(payload["payload"], socket, state)

    onload = commander_config(commander).onload
    # returns socket
    handle_callback(socket, commander, onload)
    {:noreply, state}
  end

  # casts for update values from the state
  Enum.each([:store, :session, :socket, :priv], fn name ->
    msg_name = "set_#{name}" |> String.to_atom()
    @doc false
    def handle_cast({unquote(msg_name), value}, state) do
      new_state = Map.put(state, unquote(name), value)
      {:noreply, new_state}
    end
  end)

  @doc false
  # any other cast is an event handler
  def handle_cast({event_name, socket, payload, event_handler_function, reply_to}, state) do
    handle_event(socket, event_name, event_handler_function, payload, reply_to, state)
  end

  # calls for get values from the state
  Enum.each([:store, :session, :socket, :priv], fn name ->
    msg_name = "get_#{name}" |> String.to_atom()
    @doc false
    def handle_call(unquote(msg_name), _from, state) do
      value = Map.get(state, unquote(name))
      {:reply, value, state}
    end
  end)

  defp handle_callback(socket, commander, callback) do
    if callback do
      # TODO: rethink the subprocess strategies - now it is just spawn_link
      spawn_link(fn ->
        try do
          apply(commander, callback, [socket])
        rescue
          e ->
            failed(socket, e)
        end
      end)
    end

    socket
  end

  defp transform_payload(payload, state) do
    all_modules = DrabModule.all_modules_for(state.commander.__drab__().modules)

    # transform payload via callbacks in DrabModules
    Enum.reduce(all_modules, payload, fn m, p ->
      m.transform_payload(p, state)
    end)
  end

  defp transform_socket(payload, socket, state) do
    all_modules = DrabModule.all_modules_for(state.commander.__drab__().modules)

    # transform socket via callbacks
    Enum.reduce(all_modules, socket, fn m, s ->
      m.transform_socket(s, payload, state)
    end)
  end

  defp handle_event(
         socket,
         _event_name,
         event_handler_function,
         payload,
         reply_to,
         %Drab{commander: commander_module} = state
       ) do
    # TODO: rethink the subprocess strategies - now it is just spawn_link
    spawn_link(fn ->
      try do
        {commander_module, event_handler} =
          case event_handler(event_handler_function) do
            {nil, function} -> raise_if_handler_not_exists(commander_module, function)
            {module, function} -> raise_if_handler_is_not_public(module, function)
          end

        payload = Map.delete(payload, "event_handler_function")

        payload = transform_payload(payload, state)
        socket = transform_socket(payload, socket, state)

        commander_cfg = commander_config(commander_module)

        # run before_handlers first
        returns_from_befores =
          Enum.map(
            callbacks_for(event_handler, commander_cfg.before_handler),
            fn callback_handler ->
              apply(commander_module, callback_handler, [socket, payload])
            end
          )

        # if ANY of them fail (return false or nil), do not proceed
        unless Enum.any?(returns_from_befores, &(!&1)) do
          # run actuall event handler
          returned_from_handler = apply(commander_module, event_handler, [socket, payload])

          Enum.map(
            callbacks_for(event_handler, commander_cfg.after_handler),
            fn callback_handler ->
              apply(commander_module, callback_handler, [socket, payload, returned_from_handler])
            end
          )
        end
      rescue
        e ->
          failed(socket, e)
      after
        # push reply to the browser, to re-enable controls
        push_reply(socket, reply_to, commander_module, event_handler_function)
      end
    end)

    {:noreply, state}
  end

  defp event_handler(function_name) do
    case String.split(function_name, ".") do
      [function] ->
        {nil, String.to_existing_atom(function)}

      module_and_function ->
        module = List.delete_at(module_and_function, -1) |> Module.safe_concat()

        unless Code.ensure_loaded?(module) do
          raise """
          module #{inspect(module)} does not exists.
          """
        end

        function = List.last(module_and_function) |> String.to_existing_atom()
        {module, function}
    end
  end

  defp raise_if_handler_not_exists(module, function) do
    # TODO: check if handler is not a callback
    if !({function, 2} in apply(module, :__info__, [:functions])) ||
         is_callback?(module, function) do
      raise """
      handler `#{function}` does not exist.
      """
    end

    {module, function}
  end

  defp is_callback?(module, function) do
    options = apply(module, :__drab__, [])
    # TODO: group callbacks in compile time
    callbacks = Map.get(options, :before_handler, []) ++ Map.get(options, :after_handler, [])
    function in callbacks
  end

  defp raise_if_handler_is_not_public(module, function) do
    if {:__drab__, 0} in apply(module, :__info__, [:functions]) do
      options = apply(module, :__drab__, [])

      unless function in Map.get(options, :public_handlers, []) do
        raise """
        handler #{module}.#{function} is not public.

        Use `Drab.Commander.public/1` macro to make it executable from any page.
        """
      end
    else
      raise """
      #{module} is not a Drab module.
      """
    end

    {module, function}
  end

  defp failed(socket, e) do
    error = """
    Drab Handler failed with the following exception:
    #{Exception.format_banner(:error, e)}
    #{Exception.format_stacktrace(System.stacktrace())}
    """

    Logger.error(error)

    if socket do
      js =
        Drab.Template.render_template(
          "drab.error_handler.js",
          message: Drab.Core.encode_js(error)
        )

      {:ok, _} = Drab.Core.exec_js(socket, js)
    end
  end

  defp push_reply(socket, reply_to, _, _) do
    Phoenix.Channel.push(socket, "event", %{
      finished: reply_to
    })
  end

  @doc false
  # Returns the list of callbacks (before_handler, after_handler) defined in handler_config
  def callbacks_for(_, []) do
    []
  end

  @doc false
  def callbacks_for(event_handler_function, handler_config) do
    # :uppercase, [{:run_before_each, []}, {:run_before_uppercase, [only: [:uppercase]]}]
    Enum.map(handler_config, fn {callback_name, callback_filter} ->
      case callback_filter do
        [] ->
          callback_name

        [only: handlers] ->
          if event_handler_function in handlers, do: callback_name, else: false

        [except: handlers] ->
          if event_handler_function in handlers, do: false, else: callback_name

        _ ->
          false
      end
    end)
    |> Enum.filter(& &1)
  end

  # setter and getter functions
  Enum.each([:store, :session, :socket, :priv], fn name ->
    get_name = "get_#{name}" |> String.to_atom()
    update_name = "set_#{name}" |> String.to_atom()

    @doc false
    def unquote(get_name)(pid) do
      GenServer.call(pid, unquote(get_name))
    end

    @doc false
    def unquote(update_name)(pid, new_value) do
      GenServer.cast(pid, {unquote(update_name), new_value})
    end
  end)

  @doc false
  def push_and_wait_for_response(socket, pid, message, payload \\ [], options \\ []) do
    ref = make_ref()
    push(socket, pid, ref, message, payload)
    timeout = options[:timeout] || Drab.Config.get(:browser_response_timeout)

    receive do
      {:got_results_from_client, status, ^ref, reply} ->
        {status, reply}
    after
      timeout ->
        # TODO: message is still in a queue
        {:timeout, "timed out after #{timeout} ms."}
    end
  end

  @doc false
  def push_and_wait_forever(socket, pid, message, payload \\ []) do
    push(socket, pid, nil, message, payload)

    receive do
      {:got_results_from_client, status, _, reply} ->
        {status, reply}
    end
  end

  @doc false
  def push(socket, pid, ref, message, payload \\ []) do
    do_push_or_broadcast(socket, pid, ref, message, payload, &Phoenix.Channel.push/3)
  end

  @doc false
  def broadcast(subject, pid, message, payload \\ [])

  def broadcast(%Phoenix.Socket{} = socket, pid, message, payload) do
    do_push_or_broadcast(socket, pid, nil, message, payload, &Phoenix.Channel.broadcast/3)
  end

  def broadcast(subject, _pid, message, payload) when is_binary(subject) do
    Phoenix.Channel.Server.broadcast(
      Drab.Config.pubsub(),
      "__drab:#{subject}",
      message,
      Map.new(payload)
    )
  end

  @doc false
  def broadcast(topics, _pid, _ref, message, payload) when is_list(topics) do
    for topic <- topics do
      broadcast(topic, nil, message, payload)
    end

    :ok
  end

  defp do_push_or_broadcast(socket, pid, ref, message, payload, function) do
    m = payload |> Enum.into(%{}) |> Map.merge(%{sender: tokenize(socket, {pid, ref})})
    function.(socket, message, m)
  end

  @doc false
  def tokenize(socket, what, salt \\ "drab token") do
    Phoenix.Token.sign(socket, salt, what)
  end

  @doc false
  def detokenize(socket, token, salt \\ "drab token") do
    case Phoenix.Token.verify(socket, salt, token, max_age: 86400) do
      {:ok, detokenized} ->
        detokenized

      {:error, reason} ->
        # let it die
        raise "Can't verify the token `#{salt}`: #{inspect(reason)}"
    end
  end

  # returns the commander name for the given controller (assigned in socket)
  @doc false
  def get_commander(socket) do
    controller = socket.assigns.__controller
    controller.__drab__()[:commander]
  end

  # returns the controller name used with the socket
  @doc false
  def get_controller(socket) do
    socket.assigns.__controller
  end

  # returns the view name used with the socket
  @doc false
  def get_view(socket) do
    controller = socket.assigns.__controller
    controller.__drab__()[:view]
  end

  # returns the drab_pid from socket
  @doc "Extract Drab PID from the socket"
  def pid(socket) do
    socket.assigns.__drab_pid
  end

  # if module is commander or controller with drab enabled, it has __drab__/0 function with Drab configuration
  defp commander_config(module) do
    module.__drab__()
  end

  # @doc false
  # def config() do
  #   Drab.Config.config()
  # end
end
