defmodule Opsmaru.Incus.SFTP.Packet do
  @moduledoc false
  # Copyright (c) 2013, Dave Cheney; adapted protocol forms, BSD-2-Clause.
  # Full license: priv/notices/pkg-sftp-BSD-2-Clause.txt.
  # Pinned pkg/sftp v1.13.10 v3 packet forms. No SSH framing or filesystem I/O.
  def frame(body), do: <<byte_size(body)::32, body::binary>>
  def string(bytes), do: <<byte_size(bytes)::32, bytes::binary>>
  def init, do: frame(<<1, 3::32>>)

  def version(<<2, 3::32, extensions::binary>>), do: extensions(extensions, %{}, 0)
  def version(_), do: {:error, :sftp_protocol}

  defp extensions(<<>>, acc, _), do: {:ok, acc}

  defp extensions(bytes, acc, count) when count < 64 do
    with {:ok, name, rest} <- take_string(bytes),
         {:ok, value, rest} <- take_string(rest),
         true <- byte_size(name) <= 1_024 and byte_size(value) <= 4_096 do
      extensions(rest, Map.put(acc, name, value), count + 1)
    else
      _ -> {:error, :sftp_protocol}
    end
  end

  defp extensions(_, _, _), do: {:error, :sftp_protocol}

  def request(id, :open, {path, flags}), do: <<3, id::32, string(path)::binary, flags::32, 0::32>>
  def request(id, :close_file, handle), do: <<4, id::32, string(handle)::binary>>

  def request(id, :read, {handle, offset, count}),
    do: <<5, id::32, string(handle)::binary, offset::64, count::32>>

  def request(id, :write, {handle, offset, bytes}),
    do: <<6, id::32, string(handle)::binary, offset::64, string(bytes)::binary>>

  def reply(<<101, id::32, code::32, rest::binary>>, id, _) do
    with {:ok, message, rest} <- take_string(rest),
         {:ok, language, <<>>} <- take_string(rest) do
      {:status, code, message, language}
    else
      _ -> {:error, :sftp_protocol}
    end
  end

  def reply(<<102, id::32, rest::binary>>, id, :open) do
    case take_string(rest) do
      {:ok, handle, <<>>} when byte_size(handle) in 1..256 -> {:handle, handle}
      _ -> {:error, :sftp_protocol}
    end
  end

  def reply(<<103, id::32, rest::binary>>, id, :read) do
    case take_string(rest) do
      {:ok, bytes, <<>>} -> {:data, bytes}
      _ -> {:error, :sftp_protocol}
    end
  end

  def reply(_, _, _), do: {:error, :sftp_protocol}

  defp take_string(<<length::32, bytes::binary-size(length), rest::binary>>),
    do: {:ok, bytes, rest}

  defp take_string(_), do: {:error, :sftp_protocol}
end
