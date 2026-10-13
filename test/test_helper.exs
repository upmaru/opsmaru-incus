ExUnit.start()

# :opsmaru_incus has no application callback; this only starts :ssl and friends.
{:ok, _} = Application.ensure_all_started(:opsmaru_incus)
