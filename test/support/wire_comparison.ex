defmodule Opsmaru.TestSupport.WireComparison do
  @moduledoc "Bounded native request/response comparison shared by client-port fixtures."

  def compare(expected, actual) do
    keys = (Map.keys(expected) ++ Map.keys(actual)) |> Enum.uniq() |> Enum.sort()
    differences = Enum.filter(keys, &(Map.fetch(expected, &1) != Map.fetch(actual, &1)))
    if differences == [], do: :ok, else: {:error, differences}
  end

  def request(%{method: method, target: target, headers: headers, body: body}) do
    uri = URI.parse(target)

    %{
      "method" => method,
      "path" => uri.path,
      "query" => URI.decode_query(uri.query || ""),
      "body" => if(body == "", do: nil, else: Jason.decode!(body)),
      "if_match" => Map.get(headers, "if-match"),
      "content_type" => Map.get(headers, "content-type")
    }
  end
end
