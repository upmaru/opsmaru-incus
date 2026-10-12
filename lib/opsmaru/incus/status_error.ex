defmodule Opsmaru.Incus.StatusError do
  @moduledoc """
  Pure immutable counterpart of the native `shared/api.StatusError` value.

  `new/2` is the constructor counterpart of `StatusErrorf`. It takes an
  already-formatted message and does not emulate Go `fmt` verbs: the native
  no-argument path keeps the format string literally, so a message such as
  `"100%"` stays `"100%"` and callers preformat before calling `new/2`.

  `error/1` returns the message when non-empty, otherwise the exact embedded
  `net/http.StatusText` table ("" for unknown codes). The table is compiled in;
  there is no network or runtime lookup. `status/1` returns the status code.

  `match/2` and `check/2` are the counterparts of `StatusErrorMatch` and
  `StatusErrorCheck`. Go `errors.As` unwrapping has no Elixir equivalent: only
  a direct `%StatusError{}` term matches; wrapped terms,
  `Opsmaru.Incus.Error` values and any other term never match, even when one
  wraps or carries a status code.

  The value is pure: no logging, atoms from input, processes, I/O or backend
  contact. `Inspect` redacts the message like `Opsmaru.Incus.Error`.
  """

  alias Opsmaru.Incus.Error

  # Mirrors the native zero value: Go's `StatusError{}` is {status: 0, msg: ""}.
  defstruct status: 0, message: ""

  @type t :: %__MODULE__{}

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  @message_max_bytes 65_536
  @codes_max 1_024

  # Exact net/http.StatusText table embedded from the pinned Go toolchain
  # (mise Go 1.25.x), which renders RFC 9110 text such as "Request Timeout".
  @status_texts %{
    100 => "Continue",
    101 => "Switching Protocols",
    102 => "Processing",
    103 => "Early Hints",
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    207 => "Multi-Status",
    208 => "Already Reported",
    226 => "IM Used",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    308 => "Permanent Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Timeout",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Request Entity Too Large",
    414 => "Request URI Too Long",
    415 => "Unsupported Media Type",
    416 => "Requested Range Not Satisfiable",
    417 => "Expectation Failed",
    418 => "I'm a teapot",
    421 => "Misdirected Request",
    422 => "Unprocessable Entity",
    423 => "Locked",
    424 => "Failed Dependency",
    425 => "Too Early",
    426 => "Upgrade Required",
    428 => "Precondition Required",
    429 => "Too Many Requests",
    431 => "Request Header Fields Too Large",
    451 => "Unavailable For Legal Reasons",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Timeout",
    505 => "HTTP Version Not Supported",
    506 => "Variant Also Negotiates",
    507 => "Insufficient Storage",
    508 => "Loop Detected",
    510 => "Not Extended",
    511 => "Network Authentication Required"
  }

  defguardp valid_status(status)
            when is_integer(status) and status >= @int64_min and status <= @int64_max

  defguardp valid_message(message)
            when is_binary(message) and byte_size(message) <= @message_max_bytes

  @doc """
  Constructs a `t/0` from an already-formatted message.

  Returns `{:ok, %StatusError{}}` on success and
  `{:error, %Error{kind: :invalid_input}}` (and never raises) when the status
  is not an integer in Go int64 range or the message is not a binary of at
  most 64 KiB.
  """
  def new(status, message) when valid_status(status) and valid_message(message),
    do: {:ok, %__MODULE__{status: status, message: message}}

  def new(_status, _message), do: invalid()

  @doc """
  The message, or the native status text for the status when the message is empty.
  Values outside the `new/2` bounds, including directly built structs, return
  `{:error, %Error{kind: :invalid_input}}`.
  """
  def error(%__MODULE__{status: status, message: ""}) when valid_status(status),
    do: status_text(status)

  def error(%__MODULE__{status: status, message: message})
      when valid_status(status) and valid_message(message),
      do: message

  def error(_term), do: invalid()

  @doc "The HTTP status code; invalid values behave as in `error/1`."
  def status(%__MODULE__{status: status, message: message})
      when valid_status(status) and valid_message(message),
      do: status

  def status(_term), do: invalid()

  @doc """
  Counterpart of `StatusErrorMatch`.

  Returns `{status, true}` when the term is a direct `%StatusError{}` and the
  codes list is empty or contains its status, otherwise `{-1, false}`. Invalid
  code lists return `{:error, %Error{kind: :invalid_input}}` and never raise.
  """
  def match(_term, codes \\ [])

  def match(%__MODULE__{status: status, message: message}, codes)
      when valid_status(status) and valid_message(message) do
    case validate_codes(codes, 0) do
      :ok -> if codes == [] or status in codes, do: {status, true}, else: {-1, false}
      :invalid -> invalid()
    end
  end

  def match(%__MODULE__{}, _codes), do: invalid()

  def match(_term, codes) do
    if validate_codes(codes, 0) == :ok, do: {-1, false}, else: invalid()
  end

  @doc "Counterpart of `StatusErrorCheck`; invalid code lists behave as in `match/2`."
  def check(term, codes \\ []) do
    case match(term, codes) do
      {status, found} when is_integer(status) -> found
      invalid -> invalid
    end
  end

  defp status_text(status), do: Map.get(@status_texts, status, "")

  defp invalid, do: {:error, %Error{kind: :invalid_input}}

  # Counted single walk: stops at the bound and rejects improper tails without
  # traversing an oversized or malformed list.
  defp validate_codes([], _count), do: :ok
  defp validate_codes([_ | _], @codes_max), do: :invalid

  defp validate_codes([code | rest], count) when valid_status(code),
    do: validate_codes(rest, count + 1)

  defp validate_codes(_codes, _count), do: :invalid
end

defimpl Inspect, for: Opsmaru.Incus.StatusError do
  def inspect(%{status: status}, _) when is_integer(status),
    do: "#Opsmaru.Incus.StatusError<status: #{status} message redacted>"

  def inspect(_error, _), do: "#Opsmaru.Incus.StatusError<invalid details redacted>"
end
