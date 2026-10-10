ExUnit.start()

Application.load(:opsmaru)
for app <- Application.spec(:opsmaru, :applications), do: Application.ensure_all_started(app)
