defmodule NixployExpoFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :nixploy_expo_fixture,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:expo, "~> 1.1"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
