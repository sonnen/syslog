defmodule Logger.Backends.Syslog do
  @behaviour :gen_event

  use Bitwise

  defstruct format: nil,
    metadata: nil,
    level: nil,
    socket: nil,
    host: nil,
    port: nil,
    facility: nil,
    appid: nil,
    hostname: nil

  def init(_) do
    config = Application.get_env(:logger, :syslog)

    if user = Process.whereis(:user) do
      Process.group_leader(self(), user)
      {:ok, socket} = :gen_udp.open(0)
      {:ok, init(config, %__MODULE__{socket: socket})}
    else
      {:error, :ignore}
    end
  end

  def handle_call({:configure, options}, state) do
    {:ok, :ok, configure(options, state)}
  end

  def handle_event({_level, gl, _event}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, %{level: min_level} = state) do
    # using :warn produces a deprecation warning from Logger since Elixir v1.15
    level =
      case level do
        :warn -> :warning
        level -> level
      end

    if is_nil(min_level) or Logger.compare_levels(level, min_level) != :lt do
      log_event(level, msg, ts, md, state)
    end
    {:ok, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  def terminate(_, state) do
    socket = state.socket
    if socket, do: :gen_udp.close(socket)
    :ok
  end

  ## Helpers

  defp configure(options, state) do
    config = Keyword.merge(Application.get_env(:logger, :syslog, []), options)
    Application.put_env(:logger, :syslog, config)
    init(config, state)
  end

  defp init(config, state) do
    format = config
      |> Keyword.get(:format)
      |> Logger.Formatter.compile

    level    = Keyword.get(config, :level)
    metadata = Keyword.get(config, :metadata, []) |> configure_metadata()
    host     = Keyword.get(config, :host, '127.0.0.1')
    port     = Keyword.get(config, :port, 514)
    facility = Keyword.get(config, :facility, :local2) |> Logger.Syslog.Utils.facility
    appid    = Keyword.get(config, :appid, :elixir)
    [hostname | _] = String.split("#{:net_adm.localhost()}", ".")

    %{state |
      format: format,
      metadata: metadata,
      level: level,
      socket: state.socket,
      host: host,
      port: port,
      facility: facility,
      appid: appid,
      hostname: hostname}
  end

  defp configure_metadata(:all), do: :all
  defp configure_metadata(metadata), do: Enum.reverse(metadata)

  defp log_event(level, msg, ts, md, state) do
    %{format: format, metadata: keys, facility: facility, appid: appid,
    hostname: hostname, host: host, port: port, socket: socket} = state

    level_num = Logger.Syslog.Utils.level(level)
    pre = :io_lib.format('<~B>~s ~s ~s~p: ', [facility ||| level_num,
      Logger.Syslog.Utils.iso8601_timestamp(ts), hostname, appid, self()])
    packet = [pre, Logger.Formatter.format(format, level, msg, ts, take_metadata(md, keys))]
    if socket, do: :gen_udp.send(socket, host, port, packet)
  end

  defp take_metadata(metadata, :all) do
    Keyword.drop(metadata, [:crash_reason, :ancestors, :callers])
  end

  defp take_metadata(metadata, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case Keyword.fetch(metadata, key) do
        {:ok, val} -> [{key, val} | acc]
        :error -> acc
      end
    end)
  end
end
