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

  @attr_size 0x00000001
  @attr_uid_gid 0x00000002
  @attr_permissions 0x00000004
  @attr_times 0x00000008
  @attr_extended 0x80000000

  def request(id, :open, {path, flags}), do: <<3, id::32, string(path)::binary, flags::32, 0::32>>

  def request(id, op, handle) when op in [:close_file, :close_dir],
    do: <<4, id::32, string(handle)::binary>>

  def request(id, :read, {handle, offset, count}),
    do: <<5, id::32, string(handle)::binary, offset::64, count::32>>

  def request(id, :write, {handle, offset, bytes}),
    do: <<6, id::32, string(handle)::binary, offset::64, string(bytes)::binary>>

  def request(id, :lstat, path), do: <<7, id::32, string(path)::binary>>
  def request(id, :fstat, handle), do: <<8, id::32, string(handle)::binary>>

  def request(id, :setstat, {path, attrs}),
    do: <<9, id::32, string(path)::binary, attributes(attrs)::binary>>

  def request(id, :fsetstat, {handle, attrs}),
    do: <<10, id::32, string(handle)::binary, attributes(attrs)::binary>>

  def request(id, :opendir, path), do: <<11, id::32, string(path)::binary>>
  def request(id, :readdir, handle), do: <<12, id::32, string(handle)::binary>>
  def request(id, :remove, path), do: <<13, id::32, string(path)::binary>>
  def request(id, :mkdir, path), do: <<14, id::32, string(path)::binary, 0::32>>
  def request(id, :rmdir, path), do: <<15, id::32, string(path)::binary>>
  def request(id, :realpath, path), do: <<16, id::32, string(path)::binary>>
  def request(id, :stat, path), do: <<17, id::32, string(path)::binary>>

  def request(id, :rename, {old, new}),
    do: <<18, id::32, string(old)::binary, string(new)::binary>>

  def request(id, :readlink, path), do: <<19, id::32, string(path)::binary>>

  # OpenSSH reverses the SSH_FXP_SYMLINK arguments; the pinned client follows it.
  def request(id, :symlink, {target, link}),
    do: <<20, id::32, string(target)::binary, string(link)::binary>>

  def request(id, :hardlink, {old, new}),
    do: extended(id, "hardlink@openssh.com", string(old) <> string(new))

  def request(id, :posix_rename, {old, new}),
    do: extended(id, "posix-rename@openssh.com", string(old) <> string(new))

  def request(id, :statvfs, path), do: extended(id, "statvfs@openssh.com", string(path))
  def request(id, :fsync, handle), do: extended(id, "fsync@openssh.com", string(handle))

  defp extended(id, name, args), do: <<200, id::32, string(name)::binary, args::binary>>

  # The pinned setstat payload for each single-purpose client call.
  defp attributes({:times, atime, mtime}), do: <<@attr_times::32, atime::32, mtime::32>>
  defp attributes({:owner, uid, gid}), do: <<@attr_uid_gid::32, uid::32, gid::32>>
  defp attributes({:permissions, mode}), do: <<@attr_permissions::32, mode::32>>
  defp attributes({:size, size}), do: <<@attr_size::32, size::64>>

  defp attributes({:extended, pairs}) do
    encoded = for {type, data} <- pairs, into: <<>>, do: string(type) <> string(data)
    <<@attr_extended::32, length(pairs)::32, encoded::binary>>
  end

  @doc false
  # Splits a reply into {type, id, payload}; the payload includes everything after the id.
  def split(<<type, id::32, payload::binary>>), do: {:ok, type, id, payload}
  def split(_), do: {:error, :sftp_protocol}

  @doc false
  # Decodes a matched reply leniently where the pinned client is lenient.
  def reply(101, <<code::32, rest::binary>>), do: {:status, status(code, rest)}
  def reply(102, payload), do: lift(take_string(payload), &{:handle, &1})
  def reply(103, payload), do: lift(take_string(payload), &{:data, &1})
  def reply(104, payload), do: names(payload)
  def reply(105, payload), do: lift(attrs(payload), &{:attrs, &1})
  def reply(201, payload), do: {:extended, payload}
  def reply(type, _), do: {:malformed, type}

  defp lift({:ok, value, _}, wrap), do: wrap.(value)
  defp lift(_, _), do: :malformed

  # unmarshalStatus: a missing message or language decodes as empty.
  defp status(code, rest) do
    {message, rest} =
      case take_string(rest) do
        {:ok, message, rest} -> {message, rest}
        _ -> {"", <<>>}
      end

    language =
      case take_string(rest) do
        {:ok, language, _} -> language
        _ -> ""
      end

    {code, message, language}
  end

  defp names(<<count::32, rest::binary>>), do: names(rest, count, [])
  defp names(_), do: :malformed

  defp names(_, 0, acc), do: {:name, Enum.reverse(acc)}

  defp names(bytes, count, acc) do
    with {:ok, name, rest} <- take_string(bytes),
         {:ok, _long, rest} <- take_string(rest),
         {:ok, attrs, rest} <- attrs(rest) do
      names(rest, count - 1, [{name, attrs} | acc])
    else
      _ -> :malformed
    end
  end

  @doc false
  # unmarshalAttrs: only the attributes the flags announce, in the native order.
  def attrs(<<flags::32, rest::binary>>) do
    with {:ok, acc, rest} <- field(flags, @attr_size, rest, %{}, &size/2),
         {:ok, acc, rest} <- field(flags, @attr_uid_gid, rest, acc, &owner/2),
         {:ok, acc, rest} <- field(flags, @attr_permissions, rest, acc, &permissions/2),
         {:ok, acc, rest} <- field(flags, @attr_times, rest, acc, &times/2) do
      field(flags, @attr_extended, rest, acc, &extended_attrs/2)
    end
  end

  def attrs(_), do: :error

  defp field(flags, bit, rest, acc, decode) do
    if Bitwise.band(flags, bit) == bit, do: decode.(rest, acc), else: {:ok, acc, rest}
  end

  defp size(<<size::64, rest::binary>>, acc), do: {:ok, Map.put(acc, :size, size), rest}
  defp size(_, _), do: :error

  defp owner(<<uid::32, gid::32, rest::binary>>, acc),
    do: {:ok, Map.merge(acc, %{uid: uid, gid: gid}), rest}

  defp owner(_, _), do: :error

  defp permissions(<<mode::32, rest::binary>>, acc), do: {:ok, Map.put(acc, :mode, mode), rest}
  defp permissions(_, _), do: :error

  defp times(<<atime::32, mtime::32, rest::binary>>, acc),
    do: {:ok, Map.merge(acc, %{atime: atime, mtime: mtime}), rest}

  defp times(_, _), do: :error

  defp extended_attrs(<<count::32, rest::binary>>, acc), do: pairs(rest, count, [], acc)
  defp extended_attrs(_, _), do: :error

  defp pairs(rest, 0, pairs, acc), do: {:ok, Map.put(acc, :extended, Enum.reverse(pairs)), rest}

  defp pairs(bytes, count, pairs, acc) do
    with {:ok, type, rest} <- take_string(bytes),
         {:ok, data, rest} <- take_string(rest) do
      pairs(rest, count - 1, [{type, data} | pairs], acc)
    else
      _ -> :error
    end
  end

  defp take_string(<<length::32, bytes::binary-size(length), rest::binary>>),
    do: {:ok, bytes, rest}

  defp take_string(_), do: {:error, :sftp_protocol}
end
