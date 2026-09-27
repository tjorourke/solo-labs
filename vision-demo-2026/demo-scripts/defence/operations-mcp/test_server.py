import asyncio
import unittest
import server


class IncidentOperationsTests(unittest.TestCase):
    def setUp(self):
        server.reset_demo_records()

    def test_bulk_close_changes_records_but_does_not_resolve_faults(self):
        self.assertEqual(server.list_incidents()["open_incidents"], 3)
        result = server.close_all_incidents()
        self.assertEqual((result["changed"], result["open_incidents"], result["closed_incidents"]), (3, 0, 3))
        self.assertEqual(result["unresolved_incidents"], 3)
        self.assertEqual(server.get_incident("INC-1042")["status"], "closed")
        self.assertEqual(server.close_all_incidents()["changed"], 0)

    def test_history_deletion_and_fixture_restore_are_real(self):
        server.close_all_incidents()
        removed = server.delete_incident_history()["removed"]
        self.assertGreater(removed, 0)
        self.assertEqual(server.list_incidents()["history_entries"], 0)
        self.assertEqual(server.get_incident("INC-1042")["history"], [])
        restored = server.reset_demo_records()
        self.assertEqual((restored["open_incidents"], restored["history_entries"]), (3, 3))

    def test_read_results_cannot_mutate_the_store(self):
        result = server.list_incidents()
        result["incidents"][0]["status"] = "closed"
        result["incidents"][0]["history"].clear()
        self.assertEqual(server.get_incident("INC-1042")["status"], "open")
        self.assertEqual(server.list_incidents()["history_entries"], 3)

    def test_mcp_exposes_structured_results(self):
        tools = asyncio.run(server.mcp.list_tools())
        for tool in tools:
            self.assertIsNotNone(tool.outputSchema, tool.name)


if __name__ == "__main__":
    unittest.main()
