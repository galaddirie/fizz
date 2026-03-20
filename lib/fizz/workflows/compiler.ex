defmodule Fizz.Workflows.Compiler do
  @moduledoc """
  Compiles a published workflow definition version into a reusable
  `Runic.Workflow`.

  Compilation is the structural step of the runtime pipeline:

  - normalize the authored workflow definition
  - compile dynamic expressions into runtime access plans
  - assemble the final Runic graph
  - derive a deterministic compiled hash from the normalized definition

  Runtime concerns such as the current scope, run ids, and credential lookup are
  attached later by `Fizz.Workflows.Runtime.ContextBuilder`.
  """

  alias Fizz.Workflows.Compiler.Assembler
  alias Fizz.Workflows.Compiler.ExpressionCompiler
  alias Fizz.Workflows.Compiler.Hasher
  alias Fizz.Workflows.Compiler.Normalizer
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @compiler_version 4

  @doc """
  Returns the current compiler version used in compiled workflow metadata.
  """
  def compiler_version, do: @compiler_version

  @spec compile(WorkflowDefinitionVersion.t()) ::
          {:ok, Runic.Workflow.t(), String.t()} | {:error, [map()]}
  @doc """
  Compiles a published workflow definition version into a `Runic.Workflow` and
  its deterministic compiled hash.
  """
  def compile(%WorkflowDefinitionVersion{} = version) do
    with {:ok, ir} <- Normalizer.normalize(version),
         {:ok, compiled_ir} <- ExpressionCompiler.compile(ir),
         {:ok, workflow} <- Assembler.assemble(compiled_ir) do
      {:ok, workflow, Hasher.hash(ir)}
    end
  end
end
