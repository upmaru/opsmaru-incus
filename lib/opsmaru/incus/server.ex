defmodule Opsmaru.Incus.Server do
  @moduledoc "Native server discovery; unknown/optional/null metadata remains in raw."
  defstruct [:api_version, :api_status, :auth, :environment, api_extensions: [], raw: %{}]
  @type t :: %__MODULE__{}

  def decode(%{"api_version" => version, "api_extensions" => extensions} = raw)
      when is_binary(version) and is_list(extensions) do
    if Enum.all?(extensions, &is_binary/1) do
      {:ok,
       %__MODULE__{
         api_version: version,
         api_status: raw["api_status"],
         auth: raw["auth"],
         environment: raw["environment"],
         api_extensions: extensions,
         raw: raw
       }}
    else
      {:error, :invalid_server}
    end
  end

  def decode(_), do: {:error, :invalid_server}
end

defimpl Inspect, for: Opsmaru.Incus.Server do
  def inspect(_, _), do: "#Opsmaru.Incus.Server<native discovery redacted>"
end
