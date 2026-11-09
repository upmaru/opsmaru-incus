defmodule Opsmaru.TestSupport.Timing do
  @moduledoc """
  Shared timing for tests that stall a request on purpose and wait for its
  `RequestContext` deadline to expire.

  The test first asserts that the stalled backend received the request, so the
  deadline only has to cover connecting, the TLS handshake and sending the
  request under a loaded, parallel suite. What is verified (the deadline
  outcome, peer close and no replay) does not depend on its length, while
  every expiring test waits out the whole deadline.
  """

  @doc "Request deadline, in milliseconds, for a test that waits for it to expire."
  def expiring_deadline, do: 500
end
