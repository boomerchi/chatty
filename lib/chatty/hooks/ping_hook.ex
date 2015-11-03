defmodule Chatty.Hooks.PingHook do
  @replies [
    "pong", "zap", "spank", "pow", "bang", "ka-pow", "woosh", "smack", "pink",
  ]
  @num_replies Enum.count(@replies)

  def run(_sender, text) do
    case String.downcase(text) do
      "ping" ->
        {:reply, Enum.at(@replies, :random.uniform(@num_replies)-1)}

      _ -> nil
    end
  end
end
