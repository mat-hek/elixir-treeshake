defprotocol DemoApp.Formatter do
  @doc "Formats a value as a string."
  def format(value)
end

defimpl DemoApp.Formatter, for: Integer do
  def format(value), do: "int:#{value}"
end
