defmodule Opsmaru.Incus.OperationsNativeGeneratorTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Operations.{Composite, Fragments}
  alias Opsmaru.Incus.Operations.Native.Generator
  alias Opsmaru.TestSupport.ProfileChecks

  @priv Path.expand("../priv/incus", __DIR__)

  defp method(name, verb, path, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "verb" => verb,
        "path" => path,
        "params" => for([_, param] <- Regex.scan(~r/\{([^}]+)\}/, path), do: param),
        "query" => %{},
        "extension" => nil,
        "body" => nil,
        "model" => nil,
        "result" => "sync",
        "guards" => []
      },
      extra
    )
  end

  defp model(fields),
    do: %{
      "kind" => "struct",
      "fields" => for({name, type} <- fields, do: %{"name" => name, "type" => type})
    }

  @models %{
    "Widget" => %{
      "kind" => "struct",
      "fields" => [
        %{"name" => "name", "type" => "string"},
        %{"name" => "config", "type" => "ConfigMap"},
        %{"name" => "size", "type" => "uint64"},
        %{"name" => "ratio", "type" => "float64"},
        %{"name" => "created_at", "type" => "time.Time"},
        %{"name" => "tags", "type" => "[]string"},
        %{"name" => "extra", "type" => "map[string]any"},
        %{"name" => "owner", "type" => "*WidgetOwner"}
      ]
    },
    "WidgetOwner" => %{
      "kind" => "struct",
      "fields" => [%{"name" => "id", "type" => "int64"}]
    },
    "WidgetsPost" => %{
      "kind" => "struct",
      "fields" => [
        %{"name" => "name", "type" => "string"},
        %{"name" => "config", "type" => "ConfigMap"},
        %{"name" => "source", "type" => "WidgetSource"}
      ]
    },
    "WidgetSource" => %{
      "kind" => "struct",
      "fields" => [
        %{"name" => "type", "type" => "string"},
        %{"name" => "server", "type" => "string"},
        %{"name" => "secret", "type" => "string"}
      ]
    },
    "ConfigMap" => %{"kind" => "alias", "fields" => [], "underlying" => "map[string]string"},
    "Operation" => %{
      "kind" => "struct",
      "fields" => [%{"name" => "id", "type" => "string"}]
    },
    "InstanceExecPost" => %{
      "kind" => "struct",
      "fields" => [%{"name" => "command", "type" => "[]string"}]
    }
  }

  @methods [
    %{
      "name" => "GetWidgets",
      "verb" => "GET",
      "path" => "/1.0/widgets",
      "params" => [],
      "query" => %{"recursion" => "1"},
      "extension" => "widgets",
      "body" => nil,
      "model" => "Widget",
      "result" => "list",
      "guards" => []
    },
    %{
      "name" => "GetWidgetNames",
      "verb" => "GET",
      "path" => "/1.0/widgets",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "names",
      "guards" => []
    },
    %{
      "name" => "GetWidget",
      "verb" => "GET",
      "path" => "/1.0/widgets/{name}",
      "params" => ["name"],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => "Widget",
      "result" => "model",
      "guards" => []
    },
    %{
      "name" => "CreateWidget",
      "verb" => "POST",
      "path" => "/1.0/widgets",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => "WidgetsPost",
      "model" => nil,
      "result" => "operation",
      "guards" => [%{"field" => "source.type", "extension" => "widget_sources"}]
    },
    %{
      "name" => "UpdateWidget",
      "verb" => "PUT",
      "path" => "/1.0/widgets/{name}",
      "params" => ["name"],
      "query" => %{},
      "extension" => nil,
      "body" => "WidgetsPost",
      "model" => nil,
      "result" => "sync",
      "guards" => []
    },
    %{
      "name" => "PatchWidget",
      "verb" => "PATCH",
      "path" => "/1.0/widgets/{name}",
      "params" => ["name"],
      "query" => %{},
      "extension" => nil,
      "body" => "WidgetsPost",
      "model" => nil,
      "result" => "empty_sync",
      "guards" => []
    },
    %{
      "name" => "DeleteWidgetPart",
      "verb" => "DELETE",
      "path" => "/1.0/widgets/{widgetName}/parts/{partName}",
      "params" => ["widgetName", "partName", "force"],
      "query" => %{"force" => "{force}"},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "operation",
      "guards" => [],
      "arg_types" => %{"force" => "bool"}
    },
    %{
      "name" => "UpdateServer",
      "verb" => "PUT",
      "path" => "/1.0",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => "WidgetsPost",
      "model" => nil,
      "result" => "sync",
      "guards" => []
    },
    %{
      "name" => "PatchServer",
      "verb" => "PATCH",
      "path" => "/1.0",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => "WidgetsPost",
      "model" => nil,
      "result" => "empty_sync",
      "guards" => []
    },
    %{
      "name" => "GetCertificates",
      "verb" => "GET",
      "path" => "/1.0/certificates",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "names",
      "guards" => []
    },
    %{
      "name" => "GetClusterMemberNames",
      "verb" => "GET",
      "path" => "/1.0/cluster/members",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "names",
      "guards" => []
    },
    %{
      "name" => "GetClusteredThings",
      "verb" => "GET",
      "path" => "/1.0/clustered",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "names",
      "guards" => []
    },
    %{
      "name" => "RebuildWidget",
      "verb" => "POST",
      "path" => "/1.0/widgets/{name}/rebuild",
      "params" => ["name"],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "operation",
      "guards" => []
    },
    %{
      "name" => "ExecWidget",
      "verb" => "POST",
      "path" => "/1.0/widgets/{name}/exec",
      "params" => ["name"],
      "query" => %{},
      "extension" => nil,
      "body" => "InstanceExecPost",
      "model" => nil,
      "result" => "operation",
      "guards" => []
    },
    %{
      "name" => "GetWidgetFile",
      "verb" => "GET",
      "path" => "/1.0/widgets/{name}/file",
      "params" => ["name"],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "sync",
      "guards" => []
    },
    %{
      "name" => "MigrateWidget",
      "verb" => "POST",
      "path" => "/1.0/widgets/{name}",
      "params" => ["name"],
      "query" => %{},
      "extension" => nil,
      "body" => "WidgetsPost",
      "model" => nil,
      "result" => "operation",
      "guards" => []
    },
    %{
      "name" => "GetUnverified",
      "verb" => "GET",
      "path" => "/1.0/unverified",
      "params" => [],
      "query" => %{},
      "extension" => nil,
      "body" => nil,
      "model" => nil,
      "result" => "sync",
      "guards" => []
    }
  ]

  @policy %{
    "schema" => 1,
    "exclusions" => %{
      "binary_transfer" => [%{"method" => "GetWidgetFile", "reason" => "binary file content"}],
      "remote_backend_or_credential" => [
        %{"method" => "MigrateWidget", "reason" => "names another server"}
      ]
    },
    "body_field_denylist" => [
      %{"model" => "WidgetSource", "fields" => ["server", "secret"], "reason" => "remote source"}
    ],
    "overrides" => [
      %{"method" => "RebuildWidget", "destructive" => true, "reason" => "replaces the content"},
      %{"method" => "GetWidgetNames", "scope" => "incus.native.admin", "reason" => "fixture"},
      %{
        "method" => "DeleteWidgetPart",
        "confirm" => %{"param" => "widgetName"},
        "reason" => "the widget is the target"
      }
    ]
  }

  @upstream %{
    "paths" => %{
      "/1.0/widgets" => %{
        "get" => %{"summary" => "Get the widget URLs", "description" => "Returns URLs."},
        "post" => %{"summary" => "Create a widget", "description" => "Creates a widget."}
      },
      "/1.0/widgets?recursion=1" => %{
        "get" => %{"summary" => "Get the widgets", "description" => "Returns structs."}
      },
      "/1.0/widgets/{widget}" => %{
        "get" => %{"summary" => "Get the widget", "description" => "Gets one widget."}
      },
      "/1.0/gadgets" => %{
        "get" => %{"summary" => "Get the gadgets", "description" => "Upstream only."}
      }
    },
    "definitions" => %{
      "Widget" => %{
        "title" => "Widget represents a widget.",
        "properties" => %{
          "name" => %{"description" => "Widget name", "type" => "integer", "example" => "w"}
        }
      },
      "WidgetSource" => %{"properties" => %{"type" => %{"description" => "Source type"}}},
      "Gadget" => %{"properties" => %{"name" => %{"description" => "Never used"}}}
    }
  }

  defp inputs(overrides) do
    Map.merge(
      %{
        methods: @methods,
        models: @models,
        policy: @policy,
        upstream: @upstream,
        revision: "fixture",
        evidence: &(&1 != "GetUnverified")
      },
      overrides
    )
  end

  defp build!(overrides \\ %{}) do
    assert {:ok, generated} = Generator.build(inputs(overrides))
    generated
  end

  defp operations(generated),
    do:
      Map.new(generated["document"]["paths"], fn {_, %{"post" => post}} ->
        {post["x-opsmaru-native"]["method"], post}
      end)

  defp input(operation), do: operation["requestBody"]["content"]["application/json"]["schema"]

  defp result(operation),
    do: operation["responses"]["200"]["content"]["application/json"]["schema"]

  test "operation IDs are incus_native_ plus the snake-case method name" do
    ids = %{
      "DeleteInstance" => "incus_native_delete_instance",
      "GetAPIVersions" => "incus_native_get_api_versions",
      "GetNetworkACLs" => "incus_native_get_network_acls",
      "GetNetworkACLsAllProjects" => "incus_native_get_network_acls_all_projects",
      "GetOperationUUIDs" => "incus_native_get_operation_uuids",
      "GetInstancesFullAllProjectsWithFilter" =>
        "incus_native_get_instances_full_all_projects_with_filter",
      "GetStoragePoolVolumeSnapshot" => "incus_native_get_storage_pool_volume_snapshot"
    }

    for {method, id} <- ids, do: assert(Generator.operation_id(method) == id)
  end

  test "operations are exactly the verified methods without an exclusion" do
    generated = build!()
    operations = operations(generated)

    assert Enum.sort(Map.keys(operations)) ==
             ~w(CreateWidget DeleteWidgetPart GetCertificates GetClusterMemberNames
                GetClusteredThings GetWidget GetWidgetNames GetWidgets PatchServer PatchWidget
                RebuildWidget UpdateServer UpdateWidget)

    assert Map.keys(generated["document"]["paths"]) ==
             Enum.sort(Map.keys(generated["document"]["paths"]))

    document = put_in(generated["document"], ["info", "version"], "0.0.0")
    assert ProfileChecks.issues(document) == []
    assert document["x-tama-source"] == "opsmaru_incus_native"
    assert document["x-opsmaru-reference-revision"] == "fixture"
  end

  test "an upstream-only route or definition is never added" do
    generated = build!()
    refute Enum.any?(operations(generated), fn {_, op} -> op["summary"] == "Get the gadgets" end)
    refute Jason.encode!(generated) =~ "gadget"
    refute Map.has_key?(generated["document"]["components"]["schemas"], "Gadget")
  end

  test "upstream text is joined by verb and normalized path, preferring the recursion entry" do
    operations = operations(build!())

    assert operations["GetWidgets"]["summary"] == "Get the widgets"
    assert operations["GetWidgetNames"]["summary"] == "Get the widget URLs"
    assert operations["GetWidget"]["summary"] == "Get the widget"

    assert operations["GetWidgets"]["description"] ==
             "Returns structs.\n\nNative method `GetWidgets`: `GET /1.0/widgets?recursion=1`. " <>
               "Result kind `list`. Requires API extension `widgets`."

    assert operations["CreateWidget"]["description"] =~
             "Result kind `operation`: returns the native operation identity at once"

    assert operations["CreateWidget"]["description"] =~
             "Field guards: `source.type` requires `widget_sources`."
  end

  test "a verified method without upstream text gets a generated summary and its native facts" do
    operation = operations(build!())["UpdateWidget"]
    assert operation["summary"] == "PUT /1.0/widgets/{name}"

    assert operation["description"] ==
             "Native method `UpdateWidget`: `PUT /1.0/widgets/{name}`. Result kind `sync`."

    patch = operations(build!())["PatchWidget"]
    assert patch["description"] =~ "Requires `etag`, sent as If-Match."
  end

  test "upstream contributes descriptions only, never types or schemas" do
    schemas = build!()["document"]["components"]["schemas"]
    assert schemas["Widget"]["description"] == "Widget represents a widget."

    assert schemas["Widget"]["properties"]["name"] == %{
             "type" => "string",
             "description" => "Widget name"
           }

    refute Jason.encode!(schemas) =~ "example"
  end

  test "each exclusion rule lists its methods as unavailable with a reason" do
    generated = build!()

    assert generated["unavailable"] == [
             %{
               "name" => "incus_native_exec_widget",
               "method" => "ExecWidget",
               "rule" => "interactive_channel",
               "reason" =>
                 "interactive channel: the operation opens websockets; use the composite incus_instance_exec to run commands"
             },
             %{
               "name" => "incus_native_get_unverified",
               "method" => "GetUnverified",
               "rule" => "no_evidence",
               "reason" => "missing client evidence"
             },
             %{
               "name" => "incus_native_get_widget_file",
               "method" => "GetWidgetFile",
               "rule" => "binary_transfer",
               "reason" => "binary file content"
             },
             %{
               "name" => "incus_native_migrate_widget",
               "method" => "MigrateWidget",
               "rule" => "remote_backend_or_credential",
               "reason" => "names another server"
             }
           ]

    exported = Map.keys(operations(generated))
    for %{"method" => method} <- generated["unavailable"], do: refute(method in exported)

    assert length(exported) + length(generated["unavailable"]) == length(@methods)
  end

  test "denylisted body fields are removed from input schemas only" do
    schemas = build!()["document"]["components"]["schemas"]

    source = schemas["WidgetSource.Input"]
    assert Map.keys(source["properties"]) == ["type"]
    assert source["additionalProperties"] == false
    assert source["properties"]["type"]["description"] == "Source type"

    body = schemas["WidgetsPost.Input"]
    assert body["additionalProperties"] == false
    assert body["properties"]["source"] == %{"$ref" => "#/components/schemas/WidgetSource.Input"}

    assert body["properties"]["config"] ==
             %{"type" => ["object", "null"], "additionalProperties" => %{"type" => "string"}}

    refute Map.has_key?(schemas, "WidgetSource")
    refute Map.has_key?(schemas, "WidgetsPost")
  end

  test "models convert to JSON Schema, with null for pointers, slices and maps" do
    widget = build!()["document"]["components"]["schemas"]["Widget"]
    refute Map.has_key?(widget, "additionalProperties")
    properties = widget["properties"]

    assert properties["size"] == %{"type" => "integer", "minimum" => 0}
    assert properties["ratio"] == %{"type" => "number"}
    assert properties["created_at"]["type"] == "string"
    assert properties["tags"] == %{"type" => ["array", "null"], "items" => %{"type" => "string"}}
    assert properties["extra"] == %{"type" => ["object", "null"], "additionalProperties" => %{}}

    assert properties["owner"] ==
             %{"oneOf" => [%{"$ref" => "#/components/schemas/WidgetOwner"}, %{"type" => "null"}]}
  end

  test "an unknown Go type fails the generator" do
    models = Map.put(@models, "Widget", model([{"name", "chan int"}]))
    assert {:error, [reason]} = Generator.build(inputs(%{models: models}))
    assert reason =~ "unknown Go type \"chan int\""

    models = Map.put(@models, "Widget", model([{"m", "map[int]string"}]))
    assert {:error, [reason]} = Generator.build(inputs(%{models: models}))
    assert reason =~ "unknown Go map key type int"
  end

  test "input schemas hold the parameters, project, etag, body and confirm" do
    operations = operations(build!())

    delete = input(operations["DeleteWidgetPart"])
    assert delete["additionalProperties"] == false
    assert delete["required"] == ["widgetName", "partName", "force", "confirm"]
    assert delete["properties"]["force"]["type"] == "boolean"
    assert delete["properties"]["partName"]["minLength"] == 1
    assert Map.has_key?(delete["properties"], "project")
    refute Map.has_key?(delete["properties"], "etag")
    refute Map.has_key?(delete["properties"], "body")

    update = input(operations["UpdateWidget"])
    assert update["required"] == ["name", "body", "confirm"]
    assert update["properties"]["body"] == %{"$ref" => "#/components/schemas/WidgetsPost.Input"}
    assert update["properties"]["etag"]["type"] == "string"

    patch = input(operations["PatchWidget"])
    assert patch["required"] == ["name", "body", "etag"]
    refute Map.has_key?(patch["properties"], "confirm")

    assert operations["UpdateWidget"]["x-opsmaru-native"]["etag"] == "optional"
    assert operations["PatchWidget"]["x-opsmaru-native"]["etag"] == "required"
    assert operations["GetWidget"]["x-opsmaru-native"]["etag"] == "none"
  end

  test "results use the bounded envelope of the method's result kind" do
    operations = operations(build!())

    list = result(operations["GetWidgets"])
    assert list["additionalProperties"] == false
    assert list["required"] == ["kind", "metadata"]
    assert list["properties"]["kind"] == %{"type" => "string", "enum" => ["list"]}

    assert list["properties"]["metadata"] ==
             %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Widget"}}

    assert result(operations["GetWidget"])["properties"]["metadata"] ==
             %{"$ref" => "#/components/schemas/Widget"}

    assert result(operations["GetWidgetNames"])["properties"]["metadata"] ==
             %{"type" => "array", "items" => %{"type" => "string"}}

    refute Map.has_key?(result(operations["PatchWidget"])["properties"], "metadata")
    assert result(operations["UpdateWidget"])["required"] == ["kind"]

    create = operations["CreateWidget"]
    assert result(create)["required"] == ["kind", "operation_id", "operation"]

    assert result(create)["properties"]["operation"] == %{
             "$ref" => "#/components/schemas/Operation"
           }

    assert create["x-tama-identity"] == ["operation_id"]
    refute Map.has_key?(operations["GetWidget"], "x-tama-identity")

    for {_, operation} <- operations do
      assert operation["responses"]["default"]["content"]["application/json"]["schema"] ==
               %{"$ref" => "#/components/schemas/Error"}

      assert operation["x-tama-bounds"] ==
               %{"max_input_bytes" => 65_536, "max_output_bytes" => 262_144}
    end

    assert build!()["document"]["components"]["schemas"]["Error"] ==
             Fragments.error_schema()
  end

  test "an unknown result kind fails the generator" do
    methods = [method("GetOdd", "GET", "/1.0/odd", %{"result" => "stream"})]
    policy = %{@policy | "exclusions" => %{}, "overrides" => []}
    assert {:error, [reason]} = Generator.build(inputs(%{methods: methods, policy: policy}))
    assert reason =~ "unknown result kind \"stream\""
  end

  test "every DELETE and PUT is destructive and confirms its last path parameter" do
    operations = operations(build!())

    for {name, operation} <- operations do
      verb = operation["x-opsmaru-native"]["verb"]
      expected = verb in ["DELETE", "PUT"] or name == "RebuildWidget"
      assert operation["x-tama-destructive"] == expected, name
      assert Map.has_key?(operation, "x-tama-confirmation") == expected, name
      assert "confirm" in Map.get(input(operation), "required", []) == expected, name
    end

    assert operations["UpdateWidget"]["x-tama-confirmation"] ==
             %{"field" => "confirm", "description" => "the exact value of `name`"}

    assert operations["UpdateWidget"]["x-opsmaru-native"]["confirm"] == %{"param" => "name"}

    assert operations["UpdateServer"]["x-tama-confirmation"] ==
             %{"field" => "confirm", "description" => "the literal `server`"}

    assert operations["UpdateServer"]["x-opsmaru-native"]["confirm"] == %{"value" => "server"}

    # Without the override the last path parameter, not a query parameter, is the target.
    policy = %{@policy | "overrides" => []}
    plain = operations(build!(%{policy: policy}))
    assert plain["DeleteWidgetPart"]["x-opsmaru-native"]["confirm"] == %{"param" => "partName"}
    assert plain["RebuildWidget"]["x-tama-destructive"] == false
  end

  test "scopes follow the verb, with admin for certificates, cluster and server writes" do
    scopes = Map.new(operations(build!()), fn {name, op} -> {name, op["x-tama-scopes"]} end)

    assert scopes["GetWidget"] == ["incus.native.read"]
    assert scopes["CreateWidget"] == ["incus.native.write"]
    assert scopes["UpdateWidget"] == ["incus.native.write"]
    assert scopes["PatchWidget"] == ["incus.native.write"]
    assert scopes["DeleteWidgetPart"] == ["incus.native.delete"]
    assert scopes["GetCertificates"] == ["incus.native.admin"]
    assert scopes["GetClusterMemberNames"] == ["incus.native.admin"]
    assert scopes["UpdateServer"] == ["incus.native.admin"]
    assert scopes["PatchServer"] == ["incus.native.admin"]
    # A path that merely starts with "cluster" is not the cluster API.
    assert scopes["GetClusteredThings"] == ["incus.native.read"]

    for {_, [scope]} <- scopes do
      assert scope in Generator.scopes()
      refute scope in Composite.scopes()
    end
  end

  test "tags are native plus the first path segment" do
    operations = operations(build!())
    assert operations["GetWidget"]["tags"] == ["native", "widgets"]
    assert operations["UpdateServer"]["tags"] == ["native", "server"]
    assert operations["GetClusterMemberNames"]["tags"] == ["native", "cluster"]
  end

  test "policy overrides apply and each needs a reason" do
    operations = operations(build!())
    assert operations["RebuildWidget"]["x-tama-destructive"] == true
    assert operations["RebuildWidget"]["x-opsmaru-native"]["confirm"] == %{"param" => "name"}
    assert operations["GetWidgetNames"]["x-tama-scopes"] == ["incus.native.admin"]

    assert operations["DeleteWidgetPart"]["x-tama-confirmation"]["description"] ==
             "the exact value of `widgetName`"

    value = %{"method" => "UpdateWidget", "confirm" => %{"value" => "widgets"}, "reason" => "r"}
    policy = %{@policy | "overrides" => [value]}

    assert operations(build!(%{policy: policy}))["UpdateWidget"]["x-tama-confirmation"] ==
             %{"field" => "confirm", "description" => "the literal `widgets`"}

    for broken <- [
          %{"method" => "RebuildWidget", "destructive" => true},
          %{"method" => "RebuildWidget", "destructive" => true, "reason" => " "},
          %{"method" => "RebuildWidget", "reason" => "changes nothing"},
          %{"method" => "RebuildWidget", "scope" => "incus.write", "reason" => "composite scope"},
          %{"method" => "RebuildWidget", "confirm" => %{"param" => "nope"}, "reason" => "r"},
          %{"method" => "RebuildWidget", "confirm" => "name", "reason" => "r"},
          %{"method" => "RebuildWidget", "wait" => true, "reason" => "unknown key"},
          %{"method" => "NoSuchMethod", "destructive" => true, "reason" => "r"},
          %{"method" => "MigrateWidget", "destructive" => true, "reason" => "excluded method"}
        ] do
      policy = %{@policy | "overrides" => [broken]}
      assert {:error, [_ | _]} = Generator.build(inputs(%{policy: policy})), inspect(broken)
    end
  end

  test "an invalid policy fails the generator" do
    put = fn path, value -> put_in(@policy, path, value) end

    broken = [
      Map.put(@policy, "schema", 2),
      Map.delete(@policy, "overrides"),
      put.(["exclusions", "binary_transfer"], [%{"method" => "GetWidgetFile"}]),
      put.(["exclusions", "binary_transfer"], [%{"method" => "Nope", "reason" => "r"}]),
      put.(["exclusions", "binary_transfer"], [
        %{"method" => "MigrateWidget", "reason" => "listed twice"}
      ]),
      put.(["body_field_denylist"], [%{"model" => "Nope", "fields" => ["a"], "reason" => "r"}]),
      put.(["body_field_denylist"], [
        %{"model" => "WidgetSource", "fields" => ["nope"], "reason" => "r"}
      ]),
      put.(["body_field_denylist"], [%{"model" => "WidgetSource", "fields" => ["server"]}])
    ]

    for policy <- broken do
      assert {:error, [_ | _]} = Generator.build(inputs(%{policy: policy})), inspect(policy)
    end
  end

  test "duplicate methods, reserved parameters and colliding IDs fail the generator" do
    duplicate = @methods ++ [hd(@methods)]
    assert {:error, reasons} = Generator.build(inputs(%{methods: duplicate}))
    assert Enum.any?(reasons, &(&1 =~ "registered twice"))

    reserved = [method("GetThing", "GET", "/1.0/things/{project}")]
    policy = %{@policy | "exclusions" => %{}, "overrides" => []}
    assert {:error, [reason]} = Generator.build(inputs(%{methods: reserved, policy: policy}))
    assert reason =~ "parameter project is reserved"
  end

  test "text over the profile's limits fails the generator instead of being cut" do
    policy = %{@policy | "exclusions" => %{}, "overrides" => []}
    long = String.duplicate("x", 121)

    cases = [
      {[method("GetThing", "GET", "/1.0/things")],
       %{"paths" => %{"/1.0/things" => %{"get" => %{"summary" => long}}}}, "summary length"},
      {[method("GetThing", "GET", "/1.0/things")],
       %{
         "paths" => %{
           "/1.0/things" => %{"get" => %{"description" => String.duplicate("d", 4096)}}
         }
       }, "description length"},
      {[method("DeleteThing", "DELETE", "/1.0/things/{#{String.duplicate("n", 250)}}")], %{},
       "confirmation description length"},
      {[method("GetThing", "GET", "/1.0/#{String.duplicate("t", 65)}")], %{}, "tag length"}
    ]

    for {methods, upstream, expected} <- cases do
      assert {:error, reasons} =
               Generator.build(inputs(%{methods: methods, policy: policy, upstream: upstream}))

      assert Enum.any?(reasons, &(&1 =~ expected)), expected
    end
  end

  test "the output is deterministic with sorted keys" do
    first = Generator.encode(build!())
    assert first == Generator.encode(build!(%{methods: Enum.reverse(@methods)}))
    assert String.ends_with?(first, "}\n")
    assert Jason.decode!(first) == build!()

    keys =
      first
      |> Jason.decode!(objects: :ordered_objects)
      |> Map.fetch!(:values)
      |> Enum.map(&elem(&1, 0))

    assert keys == ["document", "schema", "unavailable"]
  end

  describe "the checked-in document" do
    test "regenerates byte for byte from priv/incus" do
      assert {:ok, inputs} = Generator.load(@priv)
      assert {:ok, generated} = Generator.build(inputs)

      assert Generator.encode(generated) ==
               File.read!(Path.join(@priv, "native-operations.json"))
    end

    test "fails before generation when rest-api.yaml differs from its recorded SHA-256" do
      directory =
        Path.join(System.tmp_dir!(), "native-generator-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)

      for name <- ~w(methods.json models.json native-policy.json),
          do: File.cp!(Path.join(@priv, name), Path.join(directory, name))

      yaml = File.read!(Path.join(@priv, "rest-api.yaml"))
      File.write!(Path.join(directory, "rest-api.yaml"), yaml <> "\n")

      assert {:error, [reason]} = Generator.load(directory)
      assert reason =~ "SHA-256"

      File.write!(Path.join(directory, "rest-api.yaml"), yaml)
      assert {:ok, %{upstream: %{"paths" => _}}} = Generator.load(directory)
    end

    test "changing any input changes the output" do
      {:ok, inputs} = Generator.load(@priv)
      {:ok, generated} = Generator.build(inputs)
      current = Generator.encode(generated)

      changed = [
        %{inputs | methods: tl(inputs.methods)},
        %{inputs | models: put_in(inputs.models, ["Operation", "fields"], [])},
        %{inputs | policy: put_in(inputs.policy, ["overrides"], [])},
        %{inputs | upstream: put_in(inputs.upstream, ["paths"], %{})}
      ]

      for inputs <- changed do
        assert {:ok, generated} = Generator.build(inputs)
        refute Generator.encode(generated) == current
      end
    end
  end
end
