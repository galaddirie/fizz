defmodule Fizz.Workflows.Compiler do
  @moduledoc false

  alias Fizz.Workflows.Compiler.Assembler
  alias Fizz.Workflows.Compiler.ExpressionCompiler
  alias Fizz.Workflows.Compiler.Hasher
  alias Fizz.Workflows.Compiler.Normalizer
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @compiler_version 3

  def compiler_version, do: @compiler_version

  @spec compile(WorkflowDefinitionVersion.t()) ::
          {:ok, Runic.Workflow.t(), String.t()} | {:error, [map()]}
  def compile(%WorkflowDefinitionVersion{} = version) do
    with {:ok, ir} <- Normalizer.normalize(version),
         {:ok, compiled_ir} <- ExpressionCompiler.compile(ir),
         {:ok, workflow} <- Assembler.assemble(compiled_ir) do
      {:ok, workflow, Hasher.hash(ir)}
    end
  end
end
