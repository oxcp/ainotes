import unittest

from app.analysis_workflow import BusinessAnalysisWorkflow


class FakeModel:
    def __init__(self):
        self.calls = []
        self.outputs = [
            '{"findings":["Revenue grew 12%"],"metrics":{"growth":12}}',
            "# Draft\nRevenue grew 12%.",
            "Add a data limitation.",
            "# Final report\nRevenue grew 12%. The source period is limited.",
        ]

    async def complete(self, system_prompt, user_prompt):
        self.calls.append((system_prompt, user_prompt))
        return self.outputs[len(self.calls) - 1]


class FakeRepository:
    def __init__(self):
        self.saved = []

    async def save(self, analysis_id, artifact_type, content):
        self.saved.append((analysis_id, artifact_type, content))


class BusinessAnalysisWorkflowTests(unittest.IsolatedAsyncioTestCase):
    async def test_runs_all_roles_and_persists_each_artifact(self):
        model = FakeModel()
        repository = FakeRepository()
        workflow = BusinessAnalysisWorkflow(model, repository)

        result = await workflow.run("Analyze revenue growth", "period,revenue\n2026,112")

        self.assertEqual(4, len(model.calls))
        self.assertIn("reader agent", model.calls[0][0])
        self.assertIn("writer agent", model.calls[1][0])
        self.assertIn("reviewer agent", model.calls[2][0])
        self.assertIn("revising", model.calls[3][0])
        self.assertEqual(
            ["evidence", "draft", "review", "final_report"],
            [artifact_type for _, artifact_type, _ in repository.saved],
        )
        self.assertEqual(
            "# Final report\nRevenue grew 12%. The source period is limited.",
            result["final_report"],
        )
        self.assertTrue(all(saved[0] == result["analysis_id"] for saved in repository.saved))

    async def test_rejects_missing_inputs(self):
        workflow = BusinessAnalysisWorkflow(FakeModel(), FakeRepository())

        with self.assertRaises(ValueError):
            await workflow.run("", "data")