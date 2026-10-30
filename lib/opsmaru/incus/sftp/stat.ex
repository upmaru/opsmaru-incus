defmodule Opsmaru.Incus.SFTP.Stat do
  @moduledoc """
  File attributes as the pinned `pkg/sftp` client returns them: its `os.FileInfo`
  name, signed size and Go `os.FileMode` (`file_mode`), plus the native `FileStat`
  fields. Attributes a reply omits are zero, as natively. Times are Unix seconds.
  """
  import Bitwise
  # Copyright (c) 2013, Dave Cheney; adapted mode mapping, BSD-2-Clause.
  # Full license: priv/notices/pkg-sftp-BSD-2-Clause.txt.
  defstruct name: "",
            size: 0,
            mode: 0,
            file_mode: 0,
            mtime: 0,
            atime: 0,
            uid: 0,
            gid: 0,
            extended: []

  @type t :: %__MODULE__{}

  # Go os.FileMode bits.
  @go_dir 1 <<< 31
  @go_symlink 1 <<< 27
  @go_device 1 <<< 26
  @go_named_pipe 1 <<< 25
  @go_socket 1 <<< 24
  @go_setuid 1 <<< 23
  @go_setgid 1 <<< 22
  @go_char_device 1 <<< 21
  @go_sticky 1 <<< 20

  @doc false
  def new(fields, name) do
    size = Map.get(fields, :size, 0)
    mode = Map.get(fields, :mode, 0)

    struct!(__MODULE__,
      name: name,
      size: if(size >= 1 <<< 63, do: size - (1 <<< 64), else: size),
      mode: mode,
      file_mode: file_mode(mode),
      mtime: Map.get(fields, :mtime, 0),
      atime: Map.get(fields, :atime, 0),
      uid: Map.get(fields, :uid, 0),
      gid: Map.get(fields, :gid, 0),
      extended: Map.get(fields, :extended, [])
    )
  end

  @doc "Whether Go's `FileInfo.IsDir` is true."
  def dir?(%__MODULE__{file_mode: mode}), do: (mode &&& @go_dir) != 0

  @doc "Go's file type for the native mode."
  def type(%__MODULE__{mode: mode}), do: type_of(mode &&& 0xF000)

  defp type_of(0x1000), do: :named_pipe
  defp type_of(0x2000), do: :char_device
  defp type_of(0x4000), do: :directory
  defp type_of(0x6000), do: :device
  defp type_of(0x8000), do: :regular
  defp type_of(0xA000), do: :symlink
  defp type_of(0xC000), do: :socket
  defp type_of(_), do: :regular

  # pkg/sftp toFileMode.
  defp file_mode(mode) do
    type =
      case mode &&& 0xF000 do
        0x6000 -> @go_device
        0x2000 -> @go_device ||| @go_char_device
        0x4000 -> @go_dir
        0x1000 -> @go_named_pipe
        0xA000 -> @go_symlink
        0xC000 -> @go_socket
        _ -> 0
      end

    (mode &&& 0o777) ||| type |||
      if((mode &&& 0o4000) != 0, do: @go_setuid, else: 0) |||
      if((mode &&& 0o2000) != 0, do: @go_setgid, else: 0) |||
      if (mode &&& 0o1000) != 0, do: @go_sticky, else: 0
  end

  @doc false
  # pkg/sftp toChmodPerm: permission and special bits, including Go's FileMode flags.
  def chmod_perm(mode) do
    (mode &&& (0o777 ||| 0o7000)) |||
      if((mode &&& @go_setuid) != 0, do: 0o4000, else: 0) |||
      if((mode &&& @go_setgid) != 0, do: 0o2000, else: 0) |||
      if (mode &&& @go_sticky) != 0, do: 0o1000, else: 0
  end
end

defmodule Opsmaru.Incus.SFTP.StatVFS do
  @moduledoc "Filesystem statistics from the `statvfs@openssh.com` extension, as the pinned client decodes them."
  defstruct [
    :bsize,
    :frsize,
    :blocks,
    :bfree,
    :bavail,
    :files,
    :ffree,
    :favail,
    :fsid,
    :flag,
    :namemax
  ]

  @type t :: %__MODULE__{}
end
