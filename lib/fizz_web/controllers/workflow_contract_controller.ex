defmodule FizzWeb.WorkflowContractController do
  use FizzWeb, :controller

  alias Fizz.Workflows
  alias Fizz.Workflows.{Contract, WorkflowDraft}

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Workflows.get_workflow_with_draft(scope, id) do
      {:ok, workflow} ->
        draft = workflow.draft || %WorkflowDraft{steps: []}
        contract = Contract.derive(draft)
        json(conn, contract)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end
end
