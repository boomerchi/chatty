defmodule Chatty.HookManager do
  use GenServer

  require Logger

  alias Chatty.Hook
  alias Chatty.HookAgent
  alias Chatty.HookTaskSupervisor

  import Chatty.IRCHelpers, only: [irc_cmd: 3]

  @default_task_timeout 2000

  def start_link(user_info) do
    GenServer.start_link(__MODULE__, [user_info], name: __MODULE__)
  end

  # TODO: consider replacing the anonymous function with a module and a behaviour
  def add_hook(id, f, options \\ []) do
    GenServer.call(__MODULE__, {:add_hook, id, f, options})
  end

  def remove_hook(id) do
    GenServer.call(__MODULE__, {:remove_hook, id})
  end

  def process_message({message, sock}) do
    GenServer.cast(__MODULE__, {:process_message, message, sock})
  end

  ###

  def init([user_info]) do
    GenEvent.add_handler(Chatty.IRCEventManager, Chatty.IRCHookHandler, __MODULE__)
    hooks = HookAgent.get_all_hooks
    state = %{
      user_info: user_info,
      hooks: hooks,
    }
    {:ok, state}
  end

  def handle_cast({:process_message, _, _}, %{hooks: hooks} = state) when hooks == %{} do
    {:noreply, state}
  end

  def handle_cast({:process_message, message, sock}, %{user_info: user_info, hooks: hooks} = state)
  do
    Logger.debug("HookManager: Handling #{inspect message}")
    case message do
      {:topic, _chan, _topic} ->
        # TODO: support hooks for this message
        nil
      {command, _chan, _sender} when command in [:join, :part] ->
        # TODO: support hooks for these messages
        nil
      {:privmsg, chan, sender, message} ->
        process_message({chan, sender, message}, hooks, user_info, max_hook_timeout(hooks), sock)
    end
    {:noreply, state}
  end

  def handle_call({:add_hook, id, f, options}, _from, state) do
    hook = %Hook{
      id: id, fn: f, task_timeout: Chatty.Env.get(:hook_task_timeout, @default_task_timeout)
    }
    {response, updated_state} = case apply_hook_options(hook, options) do
      {:ok, hook} ->
        case HookAgent.put_hook(id, hook) do
          :ok ->
            {:ok, Map.update!(state, :hooks, &Map.put(&1, id, hook))}
          :id_collision ->
            {{:error, :hook_id_already_used}, state}
        end
      {:bad_option, _} = reason ->
        {{:error, reason}, state}
    end
    {:reply, response, updated_state}
  end

  def handle_call({:remove_hook, id}, _from, %{hooks: hooks} = state) do
    updated_state = Map.update!(state, :hooks, &Map.delete(&1, id))
    response = if hooks != updated_state.hooks do
      :ok = HookAgent.delete_hook(id)
      :ok
    else
      :not_found
    end
    {:reply, response, updated_state}
  end

  def handle_info({:hook_task_result, ref, result}, state) do
    Logger.debug("Got unprocessed task result with ref #{inspect ref}: #{inspect result}")
    {:noreply, state}
  end

  ###

  defp apply_hook_options(hook, options) do
    {hook, bad_options} = Enum.reduce(options, {hook, []}, fn option, {hook, bad_options} ->
      hook = case option do
        {:in, type} when is_atom(type) ->
          %Hook{hook | type: type}
        {:channel, chan} when is_binary(chan) ->
          %Hook{hook | chan: chan}
        {:direct, flag} when is_boolean(flag) ->
          %Hook{hook | direct: flag}
        {:exclusive, flag} when is_boolean(flag) ->
          %Hook{hook | exclusive: flag}
        {:public_only, flag} when is_boolean(flag) ->
          %Hook{hook | public_only: flag}
        {:task_timeout, timeout} when is_integer(timeout) and timeout > 0 ->
          %Hook{hook | task_timeout: timeout}
        _ ->
          bad_options = [option | bad_options]
          hook
      end
      {hook, bad_options}
    end)
    if bad_options == [] do
      {:ok, hook}
    else
      {:bad_option, List.first(bad_options)}
    end
  end

  defp process_message({chan, sender, message}, hooks, user_info, max_task_timeout, sock) do
    receiver = get_message_receiver(message)

    hooks
    |> Enum.map(fn {_, hook} -> hook_to_task(hook, chan, sender, message, receiver, user_info) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
    |> collect_tasks(max_task_timeout)
    |> send_responses(sock)
  end

  defp hook_to_task(hook, chan, sender, message, receiver, user_info) do
    applicable_on_chan? = is_nil(hook.chan) or ("#" <> hook.chan == chan)
    if applicable_on_chan? do
      applicable_to_receiver? = (not hook.direct) or (receiver == user_info.nickname)
      if applicable_to_receiver? do
        message_sans_receiver = strip_message_receiver(hook.direct, message, receiver)
        input = case hook.type do
          :text -> message_sans_receiver
          :token -> tokenize(message_sans_receiver)
        end
        response_chan =
          case {resolve_response_channel(chan, user_info.nickname, sender), hook.public_only} do
            {{:private, _}, true} -> nil
            {chan, _} -> chan
          end
        if response_chan != nil do
          # TODO: test resilience to crashes in tasks
          parent = self()
          ref = make_ref()
          {:ok, task} = Task.Supervisor.start_child(HookTaskSupervisor, fn ->
            :random.seed(:erlang.monotonic_time)
            result = resolve_hook_result(hook.fn.(sender, input), response_chan, sender)
            send(parent, {:hook_task_result, ref, result})
          end)
          {ref, {hook, task}}
        end
      end
    end
  end

  defp collect_tasks(hook_tasks, max_task_timeout) do
    collect_tasks(hook_tasks, max_task_timeout, :erlang.monotonic_time, [])
  end

  defp collect_tasks(hook_tasks, _, _, results) when hook_tasks == %{} do
    results
  end

  defp collect_tasks(hook_tasks, max_task_timeout, timestamp, results) do
    # TODO: kill overtime tasks and make sure we don't get results from tasks spawned during
    # previous invocations of process_message()
    receive do
      {:hook_task_result, ref, result} ->
        new_timestamp = :erlang.monotonic_time
        elapsed_milliseconds =
          :erlang.convert_time_unit(new_timestamp - timestamp, :native, :milli_seconds)
        remaining_timeout = max(0, max_task_timeout - elapsed_milliseconds)

        {{hook, _}, remaining_hook_tasks} = Map.pop(hook_tasks, ref)
        updated_results = if result != [] do
          [{hook, result} | results]
        else
          results
        end

        collect_tasks(remaining_hook_tasks, remaining_timeout, new_timestamp, updated_results)

      after max_task_timeout ->
        results
    end
  end

  defp get_message_receiver(msg) do
    case Regex.run(~r"^([-_^[:alnum:]]+)(?::)", msg) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp tokenize(msg),
    do: String.split(msg, ~r"[[:space:]]")

  defp strip_message_receiver(false, message, _) do
    message
  end

  defp strip_message_receiver(true, message, receiver) do
    message
    |> String.slice(byte_size(receiver), byte_size(message))
    |> String.lstrip(?:)
    |> String.strip()
  end

  defp resolve_hook_result(nil, _chan, _sender),
    do: []

  defp resolve_hook_result(messages, chan, sender) when is_list(messages),
    do: Enum.flat_map(messages, &do_resolve_hook_result(split_text(&1), chan, sender))

  defp resolve_hook_result(message, chan, sender),
    do: do_resolve_hook_result(split_text(message), chan, sender)

  # Reply to the person that we received the message from
  defp do_resolve_hook_result({:reply, lines}, chan, sender) do
    {first_line, rest_lines} = Enum.split(lines, 1)
    [
      {"PRIVMSG", [response_prefix(:reply, chan, sender), first_line]}
      |
      prepare_lines("PRIVMSG", rest_lines, chan)
    ]
  end

  # Reply to the indicated person
  defp do_resolve_hook_result({:reply, to, lines}, chan, _sender) do
    {first_line, rest_lines} = Enum.split(lines, 1)
    [
      {"PRIVMSG", [response_prefix(:reply, chan, to), first_line]}
      |
      prepare_lines("PRIVMSG", rest_lines, chan)
    ]
  end

  # Just send a message to the channel
  defp do_resolve_hook_result({:msg, lines}, chan, _sender) do
    prepare_lines("PRIVMSG", lines, chan)
  end

  # Send a notice to the channel
  defp do_resolve_hook_result({:notice, lines}, chan, _sender) do
    prepare_lines("NOTICE", lines, chan)
  end

  defp split_text({:reply, text}),
    do: {:reply, split_lines(text)}

  defp split_text({:reply, to, text}),
    do: {:reply, to, split_lines(text)}

  defp split_text({:msg, text}),
    do: {:msg, split_lines(text)}

  defp split_text({:notice, text}),
    do: {:notice, split_lines(text)}

  defp split_lines(text) do
    text
    |> String.rstrip
    |> String.split("\n")
    |> Enum.drop_while(&String.strip(&1) == "")
  end

  defp prepare_lines(msg_type, lines, chan),
    do: Enum.map(lines, &{msg_type, [response_prefix(:msg, chan), &1]})

  # This is a private message, use the sender's name as the channel for the response
  defp resolve_response_channel(nickname, nickname, sender),
    do: {:private, sender}

  defp resolve_response_channel(chan, _, _),
    do: {:public, chan}

  defp response_prefix(:msg, {_, chan}),
    do: "#{chan} :"

  defp response_prefix(:reply, {:private, sender}, sender),
    do: "#{sender} :"

  defp response_prefix(:reply, {_, chan}, sender),
    do: "#{chan} :#{sender}: "


  defp send_responses(responses, sock) do
    Enum.map(responses, fn
      {%Hook{exclusive: true}, response} ->
        if match?([_], responses) do
          # Only send exclusive replies if no other hook matched the message
          send_response(response, sock)
        end
      {_, response} ->
        send_response(response, sock)
    end)
  end

  defp send_response(response, sock),
    do: Enum.each(response, fn {msg_type, payload} -> irc_cmd(sock, msg_type, payload) end)

  defp max_hook_timeout(hooks) do
    hooks
    |> Enum.map(fn {_, %Hook{task_timeout: timeout}} -> timeout end)
    |> Enum.max
  end
end