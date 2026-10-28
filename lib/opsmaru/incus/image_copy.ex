defmodule Opsmaru.Incus.ImageCopy do
  @moduledoc """
  Accepted native handles of one image copy, returned by `Images.copy/4`.

  `mode` is `"pull"`, `"push"` or `"relay"`. `target` is the destination's
  operation: the image creation in pull and relay mode, the push token in push
  mode. `source` is the source's operation: the download secret in pull mode
  (nil for a public image), the export that drives a push, nil in relay mode.
  `aliases` are the alias names `Images.wait_copy/2` has yet to send once the
  copy succeeds, where the pinned client creates them after its wait, and
  `fingerprint` is the alias target known before the wait (relay). No field
  performs I/O; the host cancels any handle with `Operation.cancel/1`.
  """
  defstruct [:mode, :source, :target, :fingerprint, aliases: []]
end
