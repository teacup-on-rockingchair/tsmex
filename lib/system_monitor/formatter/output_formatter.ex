defmodule SystemMonitor. Formatter.OutputFormatter do
  @moduledoc """
  Formats command output based on the configured format type.
  """

  alias SystemMonitor.Config.Commands

  @error_patterns [
    ~r/error/i,
    ~r/\bfailed\b/i,
    ~r/inactive \(dead\)/i,
    ~r/could not/i,
    ~r/cannot/i,
    ~r/\bdown\b/i,
    ~r/unreachable/i
  ]

  @warning_patterns [
    ~r/warning/i,
    ~r/\bdegraded\b/i,
    ~r/activating/i,
    ~r/restarting/i
  ]

  def format_output(output, %Commands{format: :raw}) do
    %{
      type: :raw,
      value: String.trim(output),
      display: String.trim(output)
    }
  end

  def format_output(output, %Commands{format: :icon}) do
    status = analyze_status(output)

    %{
      type: :icon,
      value: status,
      display: status_icon(status),
      raw_output: output
    }
  end

  def format_output(output, %Commands{format: :extract}) do
    extracted =
      output
      |> String.trim()
      |> String.slice(0, 40)

    extracted = if String.length(output) > 40, do: extracted <> ".. .", else: extracted

    %{
      type: :extract,
      value: extracted,
      display: extracted,
      raw_output: output
    }
  end

  defp analyze_status(output) do
    cond do
      has_errors?(output) -> :error
      has_warnings?(output) -> :warning
      true -> :ok
    end
  end

  defp has_errors?(output) do
    Enum.any?(@error_patterns, &Regex.match?(&1, output))
  end

  defp has_warnings?(output) do
    Enum.any?(@warning_patterns, &Regex.match?(&1, output))
  end

  defp status_icon(:ok), do: "✓"
  defp status_icon(:warning), do: "⚠"
  defp status_icon(:error), do: "✗"
end
