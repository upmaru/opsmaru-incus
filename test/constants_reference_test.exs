defmodule Opsmaru.Incus.ConstantsReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Constants, Error, Model}

  test "every exported pinned API constant has its unchanged native JSON value" do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "run", "./constants"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    expected = Jason.decode!(out)
    assert length(Constants.names()) == 188
    assert Constants.names() == Enum.sort(Map.keys(expected))
    for {name, value} <- expected, do: assert(Constants.fetch(name) == {:ok, value})
  end

  test "native response, operation and instance enums remain plain model data" do
    assert {:ok, "async"} = Constants.fetch("AsyncResponse")
    assert {:ok, "task"} = Constants.fetch("OperationClassTask")
    assert {:ok, "container"} = Constants.fetch("InstanceTypeContainer")
    assert {:ok, "tls"} = Constants.fetch("AuthenticationMethodTLS")
    assert {:ok, 103} = Constants.fetch("Running")
    assert {:ok, model} = Model.decode("Operation", %{"class" => "task", "status_code" => 103})
    assert Model.encode(model) == %{"class" => "task", "status_code" => 103}
  end

  test "untrusted names never become runtime atoms or backend requests" do
    assert {:error, %Error{kind: :unknown_native_constant}} =
             Constants.fetch("not-a-native-constant")

    for name <- [nil, 42, :Running, String.duplicate("x", 257)],
        do: assert(match?({:error, %Error{kind: :invalid_arguments}}, Constants.fetch(name)))
  end
end
