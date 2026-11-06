# One concurrent module per scheduler. Most async tests also start OS processes
# (openssl, Go reference drivers) and use short deadlines, so ExUnit's default of
# twice the schedulers oversubscribes the machine and deadlines expire under load.
ExUnit.start(max_cases: System.schedulers_online())

# :opsmaru_incus has no application callback; this only starts :ssl and friends.
{:ok, _} = Application.ensure_all_started(:opsmaru_incus)
