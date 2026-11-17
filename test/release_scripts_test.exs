defmodule Opsmaru.Incus.ReleaseScriptsTest do
  # Drives the publish workflow's Hex scripts against a fake Hex API with
  # short wait settings, so their decisions are checked without the network.
  use ExUnit.Case, async: true

  @scripts Path.expand("../.github/scripts", __DIR__)
  @version "0.2.1"
  @release "/api/packages/opsmaru_incus/releases/#{@version}"
  @key "test-hex-key"
  @approval "https://hex.pm/packages/opsmaru_incus/releases/#{@version}/staged"

  defmodule FakeHex do
    @moduledoc false
    # Answers from a list of phases. Each phase maps a path to a response;
    # every request for the public release endpoint (the first request of
    # each state read) moves to the next phase, and the last phase repeats.
    #
    # A timeline instead holds each phase for a while: `{milliseconds, phase}`
    # until that long has passed since the first state read that saw it, and
    # `{:read, phase}` until one state read has used it. Phases change only
    # at the start of a state read, so a slow runner cannot skip one.
    import Plug.Conn

    def init(state), do: state

    def call(conn, state) do
      authorization = get_req_header(conn, "authorization")
      path = conn.request_path
      read? = not String.ends_with?(path, "/staged")

      response =
        Agent.get_and_update(state, fn current ->
          current = if read?, do: advance(current), else: current
          phase = phase(current)
          log = [{path, authorization} | current.log]
          {Map.get(phase, path, {404, %{}}), %{current | log: log}}
        end)

      case response do
        :hang ->
          Process.sleep(3_000)
          send_resp(conn, 200, "{}")

        {status, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))
      end
    end

    defp advance(%{timeline: nil, index: index} = current), do: %{current | index: index + 1}

    defp advance(%{timeline: timeline} = current) do
      now = System.monotonic_time(:millisecond)
      current = %{current | started: current.started || now}

      current =
        if current.index + 1 < length(timeline) and
             held?(Enum.at(timeline, current.index), current, now),
           do: advance(%{current | index: current.index + 1, started: now, reads: 0}),
           else: current

      %{current | reads: current.reads + 1}
    end

    defp held?({:read, _phase}, current, _now), do: current.reads >= 1
    defp held?({ms, _phase}, current, now), do: now - current.started >= ms

    defp phase(%{timeline: nil, phases: phases, index: index}),
      do: Enum.at(phases, min(index, length(phases) - 1))

    defp phase(%{timeline: timeline, index: index}), do: timeline |> Enum.at(index) |> elem(1)
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "release-scripts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, state} =
      Agent.start_link(fn ->
        %{phases: [%{}], timeline: nil, index: -1, started: nil, reads: 0, log: []}
      end)

    ref = {__MODULE__, context.test}

    {:ok, _} =
      Plug.Cowboy.http(FakeHex, state, ip: {127, 0, 0, 1}, port: 0, ref: ref)

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    %{root: root, state: state, api: "http://127.0.0.1:#{:ranch.get_port(ref)}/api"}
  end

  defp phases(context, phases),
    do:
      Agent.update(
        context.state,
        &%{&1 | phases: phases, timeline: nil, index: -1, started: nil, reads: 0}
      )

  defp timeline(context, timeline),
    do:
      Agent.update(
        context.state,
        &%{&1 | timeline: timeline, index: 0, started: nil, reads: 0}
      )

  defp log(context), do: context.state |> Agent.get(& &1.log) |> Enum.reverse()

  defp run(context, script, env \\ []) do
    summary = Path.join(context.root, "summary-#{System.unique_integer([:positive])}")

    env =
      [
        {"HEX_API_URL", context.api},
        {"HEX_API_KEY", @key},
        {"GITHUB_STEP_SUMMARY", summary},
        {"HEX_WAIT_INTERVAL", "0.2"},
        {"HEX_WAIT_TIMEOUT", "30"},
        {"HEX_DOCS_GRACE", "30"},
        {"HEX_WAIT_ERRORS", "5"},
        {"HEX_CONNECT_TIMEOUT", "2"},
        {"HEX_REQUEST_TIMEOUT", "2"}
      ]
      |> Map.new()
      |> Map.merge(Map.new(env))
      |> Enum.to_list()

    {output, status} =
      System.cmd("bash", [Path.join(@scripts, script), @version],
        env: env,
        stderr_to_stdout: true
      )

    {status, output, File.read(summary) |> elem_or_empty()}
  end

  defp elem_or_empty({:ok, text}), do: text
  defp elem_or_empty(_), do: ""

  defp live(has_docs), do: {200, %{"version" => @version, "has_docs" => has_docs}}
  defp staged(status), do: {200, %{"status" => status, "html_url" => @approval}}

  defp state(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key in ["package", "docs", "approval_url"] -> [{key, value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  describe "hex-release-state.sh" do
    test "a live release with docs is read without the API key", context do
      phases(context, [%{@release => live(true)}])
      assert {0, output, _} = run(context, "hex-release-state.sh")

      assert state(output) == %{
               "package" => "live",
               "docs" => "live",
               "approval_url" => "https://hex.pm/dashboard"
             }

      assert log(context) == [{@release, []}]
    end

    test "staged and pending releases and docs report their state and approval page", context do
      cases = [
        {%{@release => live(false), "#{@release}/docs/staged" => staged("staged")},
         %{"package" => "live", "docs" => "staged", "approval_url" => @approval}},
        {%{"#{@release}/staged" => staged("staged")},
         %{"package" => "staged", "docs" => "missing", "approval_url" => @approval}},
        {%{
           "#{@release}/staged" => staged("approved"),
           "#{@release}/docs/staged" => staged("approved")
         },
         %{
           "package" => "approved",
           "docs" => "approved",
           "approval_url" => "https://hex.pm/dashboard"
         }},
        {%{
           "#{@release}/staged" => staged("rejected"),
           "#{@release}/docs/staged" => staged("expired")
         },
         %{
           "package" => "missing",
           "docs" => "missing",
           "approval_url" => "https://hex.pm/dashboard"
         }},
        {%{},
         %{
           "package" => "missing",
           "docs" => "missing",
           "approval_url" => "https://hex.pm/dashboard"
         }}
      ]

      for {phase, expected} <- cases do
        phases(context, [phase])
        assert {0, output, _} = run(context, "hex-release-state.sh")
        assert state(output) == expected, inspect(phase)
      end

      # Staged endpoints are read with the API key; the public one without it.
      for {path, authorization} <- log(context) do
        expected = if String.ends_with?(path, "/staged"), do: [@key], else: []
        assert authorization == expected
      end
    end

    test "unexpected answers stop with an error instead of reporting a state", context do
      for phase <- [
            %{@release => {500, %{}}},
            %{"#{@release}/staged" => staged("revoked")},
            %{"#{@release}/staged" => {200, %{"html_url" => @approval}}},
            %{"#{@release}/staged" => {503, %{}}}
          ] do
        phases(context, [phase])
        assert {status, output, _} = run(context, "hex-release-state.sh")
        assert status != 0, inspect(phase)
        assert output =~ "::error::"
        refute output =~ "package="
      end
    end

    test "staged releases cannot be read without the API key", context do
      phases(context, [%{}])
      assert {status, output, _} = run(context, "hex-release-state.sh", [{"HEX_API_KEY", ""}])
      assert status != 0
      assert output =~ "HEX_API_KEY is needed"
    end

    test "a request that gets no answer fails within its bound", context do
      phases(context, [%{@release => :hang}])
      started = System.monotonic_time(:millisecond)
      assert {status, _, _} = run(context, "hex-release-state.sh", [{"HEX_REQUEST_TIMEOUT", "1"}])
      assert status != 0
      assert System.monotonic_time(:millisecond) - started < 4_000
    end
  end

  describe "wait-for-hex-release.sh" do
    test "a staged release is announced once and the wait ends when it is live", context do
      staged_phase = %{
        "#{@release}/staged" => staged("staged"),
        "#{@release}/docs/staged" => staged("staged")
      }

      phases(context, [staged_phase, staged_phase, staged_phase, %{@release => live(true)}])

      assert {0, output, summary} = run(context, "wait-for-hex-release.sh")
      assert summary =~ "Approve it at #{@approval}"
      assert length(String.split(output, "::notice::")) == 2
      assert output =~ "package staged, docs staged"
      assert output =~ "package live, docs live"
    end

    test "an approved release waits without asking for approval", context do
      approved = %{
        "#{@release}/staged" => staged("approved"),
        "#{@release}/docs/staged" => staged("approved")
      }

      phases(context, [approved, approved, %{@release => live(true)}])

      assert {0, output, summary} = run(context, "wait-for-hex-release.sh")
      refute output =~ "::notice::"
      assert summary == ""
    end

    test "a rejected or expired upload stops the wait", context do
      phases(context, [
        %{"#{@release}/staged" => staged("staged")},
        %{"#{@release}/staged" => staged("rejected")}
      ])

      assert {1, output, summary} = run(context, "wait-for-hex-release.sh")
      assert summary =~ "no longer staged on Hex"
      assert output =~ "::error::"
    end

    test "missing docs fail only after the grace period once the package is live", context do
      docs_missing = %{@release => live(false)}
      phases(context, [docs_missing, docs_missing, %{@release => live(true)}])
      assert {0, _, _} = run(context, "wait-for-hex-release.sh", [{"HEX_DOCS_GRACE", "30"}])

      phases(context, [docs_missing])
      assert {1, _, summary} = run(context, "wait-for-hex-release.sh", [{"HEX_DOCS_GRACE", "1"}])
      assert summary =~ "live on Hex without docs"
    end

    test "the docs grace period restarts when docs stop being missing", context do
      # Bash counts SECONDS in whole seconds. Each 1.8 s stretch of missing
      # docs starts at its first read and ends before the read that follows
      # 1.8 s later, so it measures at most 2 s; together they span at least
      # 3.6 s, which measures at least 3 s without the reset.
      missing = %{@release => live(false)}
      staged_docs = %{@release => live(false), "#{@release}/docs/staged" => staged("staged")}

      timeline(context, [
        {1_800, missing},
        {:read, staged_docs},
        {1_800, missing},
        {:read, %{@release => live(true)}}
      ])

      assert {0, output, _} = run(context, "wait-for-hex-release.sh", [{"HEX_DOCS_GRACE", "3"}])
      assert output =~ "package live, docs staged"
    end

    test "failed reads stop only when they repeat", context do
      error = %{@release => {500, %{}}}
      staged_phase = %{"#{@release}/staged" => staged("staged")}

      phases(context, [error, error, staged_phase, error, error, %{@release => live(true)}])
      assert {0, _, _} = run(context, "wait-for-hex-release.sh", [{"HEX_WAIT_ERRORS", "3"}])

      phases(context, [error])
      assert {1, _, summary} = run(context, "wait-for-hex-release.sh", [{"HEX_WAIT_ERRORS", "3"}])
      assert summary =~ "could not be read 3 times in a row"
    end

    test "the wait ends with the approval page when it runs out", context do
      phases(context, [%{"#{@release}/staged" => staged("staged")}])

      assert {1, _, summary} =
               run(context, "wait-for-hex-release.sh", [{"HEX_WAIT_TIMEOUT", "1"}])

      assert summary =~ "was not live on Hex after 1 seconds (package staged, docs missing)"
      assert summary =~ "Approve it at #{@approval}, then rerun"
    end
  end
end
