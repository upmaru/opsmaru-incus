defmodule Opsmaru.TestSupport.CertificateHost do
  @moduledoc """
  Test-only owner-admin certificate policy with explicitly started ephemeral
  Agent state. No disk trust store, issuer or production authentication code.
  A single-use fixture token admits the TLS peer's own client certificate.
  """
  @behaviour Opsmaru.Incus.Gateway.Host

  def start_link(opts), do: Agent.start_link(fn -> Map.new(opts) end)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def revoke(state, fingerprint),
    do: Agent.update(state, &update_in(&1.trust, fn trust -> Map.delete(trust, fingerprint) end))

  def fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  @impl true
  def ready?(_), do: true

  @impl true
  def authorize(request, config) do
    if request.project in [nil, "default"] and request.target == nil and not request.all_projects do
      certificate = Map.get(request.peer, :certificate)
      fingerprint = if certificate, do: fingerprint(certificate)

      case Agent.get(config.state, &Map.get(&1.trust, fingerprint)) do
        %{role: :owner_admin} -> {:ok, fingerprint}
        nil -> {:error, :unauthenticated}
        _ -> {:error, :forbidden}
      end
    else
      {:error, :forbidden}
    end
  end

  @impl true
  def valid?(_request, grant, config) do
    case Agent.get(config.state, &Map.get(&1.trust, grant)) do
      %{role: :owner_admin, expires: expires} -> expires > System.monotonic_time(:millisecond)
      _ -> false
    end
  end

  @impl true
  def identity(_request, config), do: {:ok, config.identity}

  @impl true
  def certificates(:create, request, grant, input, config) do
    body = input.body
    peer = request.peer.certificate
    # Token enrollment is bound to the actual TLS peer; an owner/admin can
    # enroll a supplied native base64 DER certificate instead.
    der = if body["certificate"] in [nil, ""], do: peer, else: Base.decode64!(body["certificate"])

    Agent.get_and_update(config.state, fn state ->
      admin = Map.has_key?(state.trust, grant)

      token =
        is_nil(grant) and state.token != nil and body["trust_token"] == state.token and
          der == peer

      if (admin or token) and is_binary(der) do
        :public_key.pkix_decode_cert(der, :otp)
        fingerprint = fingerprint(der)

        entry = %{
          role: :owner_admin,
          expires: System.monotonic_time(:millisecond) + 60_000,
          certificate: :public_key.pem_encode([{:Certificate, der, :not_encrypted}]),
          name: Map.get(body, "name", "fixture")
        }

        {{:ok, %{}, [{"location", "/1.0/certificates/" <> fingerprint}]},
         %{
           state
           | trust: Map.put(state.trust, fingerprint, entry),
             token: if(token, do: nil, else: state.token)
         }}
      else
        {{:error, 403}, state}
      end
    end)
  end

  def certificates(action, request, grant, input, config) do
    Agent.get_and_update(config.state, fn state ->
      if Map.has_key?(state.trust, grant) do
        trust_action(action, request, input, state)
      else
        {{:error, 403}, state}
      end
    end)
  end

  defp trust_action(:list, request, _, state) do
    recursive = URI.decode_query(request.query)["recursion"] == "1"

    entries =
      for {fingerprint, entry} <- Enum.sort(state.trust) do
        if recursive, do: wire(fingerprint, entry), else: "/1.0/certificates/" <> fingerprint
      end

    {{:ok, entries, []}, state}
  end

  defp trust_action(action, _, input, state) do
    case Map.fetch(state.trust, input.fingerprint) do
      :error ->
        {{:error, 404}, state}

      {:ok, entry} ->
        etag = etag(entry)

        cond do
          input.if_match not in [nil, etag] ->
            {{:error, 412}, state}

          action == :get ->
            {{:ok, wire(input.fingerprint, entry), [{"etag", etag}]}, state}

          action == :delete ->
            {{:ok, %{}, []}, %{state | trust: Map.delete(state.trust, input.fingerprint)}}

          action == :update ->
            updated = %{entry | name: Map.get(input.body, "name", entry.name)}
            {{:ok, %{}, []}, %{state | trust: Map.put(state.trust, input.fingerprint, updated)}}
        end
    end
  end

  defp etag(entry),
    do: "\"" <> Base.encode16(:crypto.hash(:sha256, entry.name), case: :lower) <> "\""

  defp wire(fingerprint, entry),
    do: %{
      "fingerprint" => fingerprint,
      "certificate" => entry.certificate,
      "name" => entry.name,
      "type" => "client",
      "restricted" => false,
      "projects" => []
    }
end
