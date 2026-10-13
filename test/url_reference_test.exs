defmodule Opsmaru.Incus.URLReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Error, URL}
  @driver Path.expand("../.integration/url-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./urlbuilder"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "native path replacement, reserved characters, Unicode and empty parts" do
    for value <- ["", "plain", "space +/:;,@&=$?#%雪", <<0, 9, 10, 13>>, "!'()*[]~", "a/b/c"] do
      compare([{"path", ["1.0", "instances", value]}, {"path", [value, ""]}, {"path", []}])
    end
  end

  test "native append semantics, stable duplicate order and suppressed selections" do
    compare([
      {"path", ["1.0"]},
      {"project", ["one"]},
      {"project", ["default"]},
      {"project", [""]},
      {"project", ["two"]},
      {"target", ["member"]},
      {"target", ["none"]},
      {"target", [""]},
      {"query", ["z", "value"]},
      {"query", ["a", "space +雪"]},
      {"query", ["z", "second"]},
      {"query", ["", ""]},
      {"query", ["project", "explicit"]},
      {"query", ["&;=", <<0, 10>>]}
    ])
  end

  test "native scheme, authority and fragment rendering without any connection" do
    for host <- ["", "example.test:8443", "[fe80::1%zone]:8443", "雪.test", "space #/?@"],
        fragment <- ["", "a/b?c&d=e+f:;,@!()*'[]%雪", <<0, 9, 13>>] do
      compare([
        {"scheme", ["https"]},
        {"host", [host]},
        {"fragment", [fragment]},
        {"path", ["1.0"]},
        {"scheme", [""]},
        {"host", [""]},
        {"path", []}
      ])
    end
  end

  test "all byte escapes match native for path, query and fragment" do
    value = Enum.map_join(0..127, &<<&1>>)
    compare([{"path", [value]}, {"query", [value, value]}, {"fragment", [value]}])
  end

  test "invalid and excess values fail visibly without exposing inputs or changing old values" do
    original = URL.new()
    assert {:ok, private} = URL.with_query(original, "secret", "private")
    refute inspect(private) =~ "private"
    assert {:ok, ""} = URL.render(original)

    for value <- [nil, :host, <<255>>, String.duplicate("private", 1000)] do
      assert {:error, %Error{kind: :invalid_native_url}} = URL.host(private, value)
      assert {:error, %Error{}} = URL.project(private, value)
    end

    assert {:error, %Error{}} = URL.path(private, List.duplicate("part", 65))
    assert {:error, %Error{}} = URL.path(private, List.duplicate(String.duplicate("/", 4096), 2))
    assert {:error, %Error{}} = URL.render(%URL{query: [nil]})
    assert {:error, %Error{}} = URL.project(nil, "default")

    assert {:error, %Error{}} =
             URL.with_query(%URL{query: List.duplicate({"a", "b"}, 128)}, "x", "y")

    assert {:ok, "?secret=private"} = URL.render(private)
  end

  test "improper path/query lists return redacted errors rather than crashing the caller" do
    for malformed <- [%URL{parts: ["ok" | :bad]}, %URL{query: [{"a", "private"} | :bad]}] do
      assert {:error, %Error{kind: :invalid_native_url} = error} = URL.render(malformed)
      refute inspect(error) =~ "private"
      assert {:error, %Error{kind: :invalid_native_url}} = URL.project(malformed, "default")
      assert {:error, %Error{kind: :invalid_native_url}} = URL.scheme(malformed, "https")
    end

    assert {:error, %Error{}} = URL.path(URL.new(), ["ok" | :bad])
    assert {:error, %Error{}} = URL.with_query(%URL{query: [{"a", "b"} | :bad]}, "c", "d")
  end

  defp compare(steps) do
    {_, actual} =
      Enum.reduce(steps, {URL.new(), [""]}, fn {action, values}, {url, results} ->
        result =
          case action do
            "scheme" -> URL.scheme(url, hd(values))
            "host" -> URL.host(url, hd(values))
            "path" -> URL.path(url, values)
            "project" -> URL.project(url, hd(values))
            "target" -> URL.target(url, hd(values))
            "query" -> URL.with_query(url, hd(values), List.last(values))
            "fragment" -> URL.fragment(url, hd(values))
          end

        assert {:ok, next} = result
        assert {:ok, rendered} = URL.render(next)
        {next, results ++ [rendered]}
      end)

    input = %{
      steps: Enum.map(steps, fn {action, values} -> %{action: action, values: values} end)
    }

    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    assert actual == collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)
      {^port, {:exit_status, status}} -> flunk("native URL oracle failed #{status}")
    after
      5_000 ->
        Port.close(port)
        flunk("native URL oracle deadline")
    end
  end
end
