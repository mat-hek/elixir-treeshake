{output, status} =
  System.cmd("mix", ~w(compile --force),
    cd: "test/fixtures/demo_app",
    env: [{"MIX_ENV", "prod"}],
    stderr_to_stdout: true
  )

if status != 0 do
  raise """
  Fixture failed to compile:
  #{output}
  """
end

ExUnit.start()
